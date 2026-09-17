#!/usr/bin/env python3

import argparse
import json
import os
import re
import sys
import tempfile
import uuid
import zipfile
from pathlib import Path


BUNDLE_SCHEMA_VERSION = 1
MAX_INPUT_BYTES = 1024 * 1024
MAX_RECORDS = 256

_APPLICATION_VERSION_PATTERN = re.compile(
    r"\A[0-9]{1,4}(?:\.[0-9]{1,4}){1,3}(?:[-+][A-Za-z0-9.]{1,32})?\Z"
)
_OPERATING_SYSTEM_VERSION_PATTERN = re.compile(
    r"\AmacOS-[0-9]{1,2}\.[0-9]{1,2}(?:\.[0-9]{1,2})?\Z"
)
_CONFIG_FIELDS = frozenset(
    {
        "applicationVersion",
        "operatingSystemVersion",
        "protocolMode",
        "tlsEnabled",
    }
)
_PROTOCOL_MODES = frozenset({"barrierCompatibility", "native", "disabled"})
_EVENT_FIELDS = frozenset(
    {"category", "eventId", "correlationId", "metadata"}
)
_EVENT_CATALOG = {
    "connectivity.connection.failed": {
        "category": "connectivity",
        "metadata": {
            "stage": frozenset({"connect", "handshake", "read", "write"}),
            "reason": frozenset(
                {"unavailable", "disconnected", "refused", "reset", "timeout"}
            ),
            "retry": frozenset(
                {"never", "userActionRequired", "backoff", "immediateAfterStateChange"}
            ),
        },
    },
    "inputSafety.cleanup.completed": {
        "category": "inputSafety",
        "metadata": {
            "outcome": frozenset({"completed", "partial", "failed"}),
        },
    },
}


class BundleError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _require_mapping(value):
    if not isinstance(value, dict):
        raise BundleError("invalid_type")


def _require_exact_fields(value, expected):
    _require_mapping(value)
    if set(value) != set(expected):
        raise BundleError("unknown_field")


def _validate_version(value, pattern):
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise BundleError("invalid_value")
    return value


def _validate_config(config):
    _require_mapping(config)
    if not set(config).issubset(_CONFIG_FIELDS):
        raise BundleError("unknown_field")

    validated = {}
    for key in sorted(config):
        value = config[key]
        if key == "applicationVersion":
            validated[key] = _validate_version(value, _APPLICATION_VERSION_PATTERN)
        elif key == "operatingSystemVersion":
            validated[key] = _validate_version(
                value, _OPERATING_SYSTEM_VERSION_PATTERN
            )
        elif key == "protocolMode":
            if not isinstance(value, str) or value not in _PROTOCOL_MODES:
                raise BundleError("invalid_value")
            validated[key] = value
        elif key == "tlsEnabled":
            if not isinstance(value, bool):
                raise BundleError("invalid_type")
            validated[key] = value
    return validated


def _validate_correlation_id(value):
    if value is None:
        return None
    if not isinstance(value, str):
        raise BundleError("invalid_correlation_id")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        raise BundleError("invalid_correlation_id") from None
    if parsed.version != 4 or str(parsed) != value:
        raise BundleError("invalid_correlation_id")
    return value


def _validate_event(event):
    _require_exact_fields(event, _EVENT_FIELDS)

    event_id = event["eventId"]
    if not isinstance(event_id, str) or event_id not in _EVENT_CATALOG:
        raise BundleError("unknown_event")
    catalog_entry = _EVENT_CATALOG[event_id]

    category = event["category"]
    if category != catalog_entry["category"]:
        raise BundleError("category_mismatch")

    metadata = event["metadata"]
    metadata_schema = catalog_entry["metadata"]
    _require_exact_fields(metadata, metadata_schema)
    validated_metadata = {}
    for key in sorted(metadata_schema):
        value = metadata[key]
        if not isinstance(value, str) or value not in metadata_schema[key]:
            raise BundleError("invalid_value")
        validated_metadata[key] = value

    return {
        "category": category,
        "eventId": event_id,
        "correlationId": _validate_correlation_id(event["correlationId"]),
        "metadata": validated_metadata,
    }


def _validate_payload(payload):
    _require_exact_fields(payload, {"schemaVersion", "config", "logs"})
    if (
        not isinstance(payload["schemaVersion"], int)
        or isinstance(payload["schemaVersion"], bool)
        or payload["schemaVersion"] != BUNDLE_SCHEMA_VERSION
    ):
        raise BundleError("unsupported_schema")

    logs = payload["logs"]
    if not isinstance(logs, list):
        raise BundleError("invalid_type")
    if len(logs) > MAX_RECORDS:
        raise BundleError("record_limit_exceeded")

    return {
        "config": _validate_config(payload["config"]),
        "logs": [_validate_event(event) for event in logs],
    }


def _json_bytes(value):
    return (
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")


def _write_archive(path, validated):
    manifest = {
        "config": validated["config"],
        "recordCount": len(validated["logs"]),
        "schemaVersion": BUNDLE_SCHEMA_VERSION,
    }
    events = b"".join(_json_bytes(event) for event in validated["logs"])

    with zipfile.ZipFile(
        path, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        archive.writestr("manifest.json", _json_bytes(manifest))
        archive.writestr("events.jsonl", events)


def create_bundle(payload, output_path, before_commit=None):
    output = Path(output_path)
    if output.exists() or output.is_symlink():
        raise BundleError("output_exists")
    if not output.parent.is_dir():
        raise BundleError("output_parent_missing")

    validated = _validate_payload(payload)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=".diagnostic-bundle-",
            suffix=".tmp",
            dir=output.parent,
            delete=False,
        ) as temporary_file:
            temporary_path = Path(temporary_file.name)

        _write_archive(temporary_path, validated)
        if before_commit is not None:
            before_commit()
        try:
            os.link(temporary_path, output)
        except FileExistsError:
            raise BundleError("output_exists") from None
        except OSError:
            raise BundleError("io_failure") from None
    except BundleError:
        raise
    except KeyboardInterrupt:
        raise
    except (OSError, zipfile.BadZipFile):
        raise BundleError("io_failure") from None
    finally:
        if temporary_path is not None and temporary_path.exists():
            try:
                temporary_path.unlink()
            except OSError:
                raise BundleError("cleanup_failed") from None


def create_bundle_from_file(input_path, output_path, before_commit=None):
    source = Path(input_path)
    try:
        if source.stat().st_size > MAX_INPUT_BYTES:
            raise BundleError("input_too_large")
        with source.open("rb") as source_file:
            raw_input = source_file.read(MAX_INPUT_BYTES + 1)
    except BundleError:
        raise
    except OSError:
        raise BundleError("input_unavailable") from None

    if len(raw_input) > MAX_INPUT_BYTES:
        raise BundleError("input_too_large")
    try:
        payload = json.loads(raw_input.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        raise BundleError("invalid_json") from None

    create_bundle(payload, output_path, before_commit=before_commit)


def _parse_arguments(arguments):
    parser = argparse.ArgumentParser(
        description="Create a fail-closed, allowlisted MacKVM diagnostic bundle."
    )
    parser.add_argument("--input", required=True, help="Structured JSON input")
    parser.add_argument("--output", required=True, help="New diagnostic ZIP path")
    return parser.parse_args(arguments)


def main(arguments=None):
    options = _parse_arguments(arguments)
    try:
        create_bundle_from_file(options.input, options.output)
    except BundleError as error:
        print(
            "diagnostic bundle failed: {0}".format(error.code),
            file=sys.stderr,
        )
        return 2
    except KeyboardInterrupt:
        print("diagnostic bundle cancelled", file=sys.stderr)
        return 130
    print("diagnostic bundle created")
    return 0


if __name__ == "__main__":
    sys.exit(main())
