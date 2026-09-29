#!/usr/bin/env python3
"""Fail-closed validator for MacKVM E2E result evidence (M1-TOOLING-001)."""

import argparse
import datetime
import hashlib
import json
import math
import os
import re
import stat
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]

SCHEMA_VERSION = 1
MAX_RESULT_BYTES = 1024 * 1024
MAX_CASES = 256
MAX_ARTIFACTS = 256
MAX_EVIDENCE_ITEMS = 32
MAX_ARTIFACT_PATH_LENGTH = 512
MAX_JSON_NESTING_DEPTH = 64
HASH_CHUNK_BYTES = 64 * 1024

EXIT_OK = 0
EXIT_NOT_PASSED = 1
EXIT_USAGE = 64
EXIT_DATA = 65
EXIT_NO_INPUT = 66
EXIT_UNSAFE_PATH = 77

TOP_LEVEL_KEYS = frozenset(
    {
        "schemaVersion",
        "issueId",
        "status",
        "startedAt",
        "endedAt",
        "commit",
        "toolchain",
        "environment",
        "cases",
        "artifacts",
        "privacy",
        "approvedDecisionRef",
    }
)
TOOLCHAIN_KEYS = frozenset({"pythonVersion", "platform", "machine"})
ENVIRONMENT_KEYS = frozenset(
    {
        "localOS",
        "peerProduct",
        "peerVersion",
        "peerRole",
        "peerOS",
        "networkScope",
        "tls",
    }
)
CASE_KEYS = frozenset({"id", "status", "exitCode", "evidence"})
ARTIFACT_KEYS = frozenset({"path", "sha256", "byteLength", "kind", "reviewStatus"})
PRIVACY_REQUIRED_VALUES = {
    "containsSensitiveData": False,
    "containsTypedText": False,
    "containsClipboardPayload": False,
    "containsCredentials": False,
    "containsKeyMaterial": False,
    "containsHostnames": False,
    "containsIPAddresses": False,
    "rawCaptureCommitted": False,
    "sanitizationReviewed": True,
}

EXECUTION_STATUSES = ("passed", "failed", "timed_out", "cancelled")
RESULT_STATUSES = frozenset(EXECUTION_STATUSES + ("not_executed",))
CASE_STATUSES = frozenset(EXECUTION_STATUSES)
ARTIFACT_KINDS = frozenset(
    {"sanitized-fixture", "sanitized-log", "machine-report", "manual-record"}
)
REVIEW_STATUSES = frozenset({"reviewed", "pending-review"})

ISSUE_PATTERN = re.compile(r"M[1-5]-[0-9]{3}")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
TIMESTAMP_PATTERN = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z"
)
CASE_ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
METADATA_TEXT_PATTERN = re.compile(r"[!-~](?:[ -~]{0,126}[!-~])?")
DESCRIPTION_PATTERN = re.compile(r"[!-~](?:[ -~]{0,198}[!-~])?")
DECISION_REF_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._#/-]{0,159}")
ARTIFACT_PATH_PATTERN = re.compile(
    r"(?:evidence/e2e/M[1-5]-[0-9]{3}|Tests/Fixtures)"
    r"(?:/[A-Za-z0-9_-][A-Za-z0-9._-]{0,127})+"
)

# Bounded, deterministic markers for obviously secret or private content.
# This is a guard rail for descriptive text only, not a secret scanner.
SECRET_SUBSTRINGS = (
    "-----begin",
    "private key",
    "password",
    "passwd",
    "secret",
    "token",
    "apikey",
    "api_key",
    "api-key",
    "bearer ",
    "authorization",
    "ssh-rsa",
    "ssh-ed25519",
    "ghp_",
    "gho_",
    "github_pat_",
    "xoxb-",
    "xoxp-",
    "://",
)
SECRET_PATTERNS = (
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+"),
    re.compile(r"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])"),
    re.compile(r"[A-Za-z0-9+=_-]{40,}"),
)


class ValidationError(Exception):
    def __init__(self, code, exit_code=EXIT_DATA):
        self.code = code
        self.exit_code = exit_code
        super().__init__(code)


class _DuplicateKeyError(Exception):
    pass


class _NonFiniteNumberError(Exception):
    pass


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValidationError("invalid_arguments", EXIT_USAGE)


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKeyError()
        result[key] = value
    return result


def _reject_constant(value):
    raise _NonFiniteNumberError()


def _parse_finite_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise _NonFiniteNumberError()
    return value


_JSON_STRUCTURAL_CHARACTER = re.compile(r'[\[\]{}"\\]')


def _check_json_nesting(text):
    # Version-independent cap: json.loads recursion limits differ across
    # Python releases, so reject deep nesting before parsing.
    depth = 0
    in_string = False
    escaped_index = -1
    for match in _JSON_STRUCTURAL_CHARACTER.finditer(text):
        index = match.start()
        if index == escaped_index:
            continue
        character = match.group()
        if in_string:
            if character == "\\":
                escaped_index = index + 1
            elif character == '"':
                in_string = False
        elif character == '"':
            in_string = True
        elif character in "[{":
            depth += 1
            if depth > MAX_JSON_NESTING_DEPTH:
                raise ValidationError("invalid_json")
        elif character in "]}":
            depth -= 1


def parse_json_bytes(data):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise ValidationError("invalid_json") from None
    _check_json_nesting(text)
    try:
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
            parse_float=_parse_finite_float,
        )
    except _DuplicateKeyError:
        raise ValidationError("duplicate_json_key") from None
    except _NonFiniteNumberError:
        raise ValidationError("non_finite_number") from None
    except (ValueError, RecursionError):
        raise ValidationError("invalid_json") from None


def _lstat_walk(repository_root, relative, label):
    """Reject missing or symlinked components below the repository root."""
    current = Path(repository_root)
    status = None
    for part in relative.parts:
        current = current / part
        try:
            status = os.lstat(current)
        except FileNotFoundError:
            raise ValidationError(label + "_missing", EXIT_NO_INPUT) from None
        except NotADirectoryError:
            raise ValidationError(label + "_missing", EXIT_NO_INPUT) from None
        except OSError:
            raise ValidationError(label + "_unreadable", EXIT_UNSAFE_PATH) from None
        if stat.S_ISLNK(status.st_mode):
            raise ValidationError(label + "_symlink", EXIT_UNSAFE_PATH)
    if status is None or not stat.S_ISREG(status.st_mode):
        raise ValidationError(label + "_not_regular_file", EXIT_UNSAFE_PATH)
    return current


def _open_regular_file(path, label):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        raise ValidationError(label + "_missing", EXIT_NO_INPUT) from None
    except OSError:
        raise ValidationError(label + "_unreadable", EXIT_UNSAFE_PATH) from None
    try:
        file_status = os.fstat(descriptor)
    except OSError:
        os.close(descriptor)
        raise ValidationError(label + "_unreadable", EXIT_UNSAFE_PATH) from None
    if not stat.S_ISREG(file_status.st_mode):
        os.close(descriptor)
        raise ValidationError(label + "_not_regular_file", EXIT_UNSAFE_PATH)
    return os.fdopen(descriptor, "rb"), file_status


def repository_relative_path(path, repository_root, label="result"):
    root = Path(repository_root)
    candidate = Path(os.path.abspath(os.fspath(path)))
    try:
        relative = candidate.relative_to(root)
    except ValueError:
        raise ValidationError(label + "_outside_repository", EXIT_UNSAFE_PATH) from None
    if not relative.parts:
        raise ValidationError(label + "_not_regular_file", EXIT_UNSAFE_PATH)
    return relative


def read_result_bytes(path, repository_root):
    relative = repository_relative_path(path, repository_root, "result")
    final_path = _lstat_walk(repository_root, relative, "result")
    handle, file_status = _open_regular_file(final_path, "result")
    with handle:
        if file_status.st_size > MAX_RESULT_BYTES:
            raise ValidationError("result_too_large")
        try:
            data = handle.read(MAX_RESULT_BYTES + 1)
        except OSError:
            raise ValidationError("result_unreadable", EXIT_UNSAFE_PATH) from None
    if len(data) > MAX_RESULT_BYTES:
        raise ValidationError("result_too_large")
    return relative, data


def _require_exact_keys(value, expected, label):
    if not isinstance(value, dict):
        raise ValidationError(label + "_invalid_type")
    keys = set(value)
    if keys - expected:
        raise ValidationError(label + "_unknown_field")
    if expected - keys:
        raise ValidationError(label + "_missing_field")


def _is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _contains_secret_marker(text):
    lowered = text.lower()
    if any(marker in lowered for marker in SECRET_SUBSTRINGS):
        return True
    return any(pattern.search(text) for pattern in SECRET_PATTERNS)


def _validate_text(value, pattern, label):
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ValidationError(label + "_invalid")
    if _contains_secret_marker(value):
        raise ValidationError(label + "_sensitive_marker")
    return value


def _parse_timestamp(value, label):
    if not isinstance(value, str) or TIMESTAMP_PATTERN.fullmatch(value) is None:
        raise ValidationError(label + "_invalid")
    text = value[:-1]
    time_format = "%Y-%m-%dT%H:%M:%S.%f" if "." in text else "%Y-%m-%dT%H:%M:%S"
    try:
        return datetime.datetime.strptime(text, time_format)
    except ValueError:
        raise ValidationError(label + "_invalid") from None


def _validate_text_mapping(value, keys, label):
    _require_exact_keys(value, keys, label)
    for key in sorted(keys):
        _validate_text(value[key], METADATA_TEXT_PATTERN, label + "_value")


def _validate_privacy(value):
    _require_exact_keys(value, frozenset(PRIVACY_REQUIRED_VALUES), "privacy")
    for key, required in PRIVACY_REQUIRED_VALUES.items():
        if not isinstance(value[key], bool) or value[key] is not required:
            raise ValidationError("privacy_violation")


def _validate_case(case):
    _require_exact_keys(case, CASE_KEYS, "case")
    if not isinstance(case["id"], str) or CASE_ID_PATTERN.fullmatch(case["id"]) is None:
        raise ValidationError("case_id_invalid")
    status = case["status"]
    if not isinstance(status, str) or status not in CASE_STATUSES:
        raise ValidationError("case_status_invalid")

    exit_code = case["exitCode"]
    if exit_code is not None and (not _is_integer(exit_code) or not 0 <= exit_code <= 255):
        raise ValidationError("case_exit_code_invalid")
    if status == "passed":
        consistent = exit_code == 0
    elif status == "failed":
        consistent = exit_code is not None and exit_code != 0
    elif status == "timed_out":
        consistent = exit_code is None or exit_code == 124
    else:
        consistent = exit_code is None or exit_code == 130
    if not consistent:
        raise ValidationError("case_exit_code_inconsistent")

    evidence = case["evidence"]
    if not isinstance(evidence, list) or not evidence:
        raise ValidationError("case_evidence_invalid")
    if len(evidence) > MAX_EVIDENCE_ITEMS:
        raise ValidationError("case_evidence_limit_exceeded")
    for description in evidence:
        _validate_text(description, DESCRIPTION_PATTERN, "case_evidence")
    return case["id"], status


def _validate_cases(cases, status):
    if not isinstance(cases, list):
        raise ValidationError("cases_invalid_type")
    if len(cases) > MAX_CASES:
        raise ValidationError("cases_limit_exceeded")
    if status == "not_executed":
        if cases:
            raise ValidationError("not_executed_has_cases")
        return

    if not cases:
        raise ValidationError("cases_empty")
    seen = set()
    case_statuses = []
    for case in cases:
        case_id, case_status = _validate_case(case)
        if case_id in seen:
            raise ValidationError("case_id_duplicate")
        seen.add(case_id)
        case_statuses.append(case_status)

    if status == "passed":
        if any(case_status != "passed" for case_status in case_statuses):
            raise ValidationError("status_cases_inconsistent")
    elif status not in case_statuses:
        raise ValidationError("status_cases_inconsistent")


def _validate_artifact_path(value, issue_id):
    if not isinstance(value, str) or not value:
        raise ValidationError("artifact_path_invalid")
    if (
        len(value) > MAX_ARTIFACT_PATH_LENGTH
        or "\0" in value
        or "\\" in value
        or value.startswith("/")
    ):
        raise ValidationError("artifact_path_invalid")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValidationError("artifact_path_invalid")
    if ARTIFACT_PATH_PATTERN.fullmatch(value) is None:
        raise ValidationError("artifact_path_invalid")
    if parts[0] == "evidence" and parts[2] != issue_id:
        raise ValidationError("artifact_path_issue_mismatch")
    return Path(*parts)


def _validate_artifacts(artifacts, status, issue_id):
    if not isinstance(artifacts, list):
        raise ValidationError("artifacts_invalid_type")
    if len(artifacts) > MAX_ARTIFACTS:
        raise ValidationError("artifacts_limit_exceeded")
    if status == "not_executed" and artifacts:
        raise ValidationError("not_executed_has_artifacts")

    validated = []
    seen = set()
    for artifact in artifacts:
        _require_exact_keys(artifact, ARTIFACT_KEYS, "artifact")
        relative = _validate_artifact_path(artifact["path"], issue_id)
        if relative in seen:
            raise ValidationError("artifact_path_duplicate")
        seen.add(relative)
        sha256 = artifact["sha256"]
        if not isinstance(sha256, str) or SHA256_PATTERN.fullmatch(sha256) is None:
            raise ValidationError("artifact_sha256_invalid")
        byte_length = artifact["byteLength"]
        if not _is_integer(byte_length) or byte_length < 0:
            raise ValidationError("artifact_byte_length_invalid")
        kind = artifact["kind"]
        if not isinstance(kind, str) or kind not in ARTIFACT_KINDS:
            raise ValidationError("artifact_kind_invalid")
        review_status = artifact["reviewStatus"]
        if not isinstance(review_status, str) or review_status not in REVIEW_STATUSES:
            raise ValidationError("artifact_review_status_invalid")
        if status == "passed" and review_status != "reviewed":
            raise ValidationError("artifact_not_reviewed")
        validated.append((relative, sha256, byte_length))
    return validated


def _validate_decision_ref(value, status):
    if status == "not_executed":
        if value is None or value == "":
            raise ValidationError("approved_decision_ref_missing")
        _validate_text(value, DECISION_REF_PATTERN, "approved_decision_ref")
    elif value is not None:
        raise ValidationError("approved_decision_ref_not_allowed")


def _verify_artifact_file(repository_root, relative, sha256, byte_length):
    final_path = _lstat_walk(repository_root, relative, "artifact")
    handle, _ = _open_regular_file(final_path, "artifact")
    digest = hashlib.sha256()
    length = 0
    with handle:
        try:
            while True:
                chunk = handle.read(HASH_CHUNK_BYTES)
                if not chunk:
                    break
                digest.update(chunk)
                length += len(chunk)
        except OSError:
            raise ValidationError("artifact_unreadable", EXIT_UNSAFE_PATH) from None
    if length != byte_length:
        raise ValidationError("artifact_length_mismatch")
    if digest.hexdigest() != sha256:
        raise ValidationError("artifact_hash_mismatch")


def validate_document(document, repository_root, result_relative=None):
    """Validate a parsed result document and its artifacts; returns (issue, status)."""
    _require_exact_keys(document, TOP_LEVEL_KEYS, "result")

    schema_version = document["schemaVersion"]
    if not _is_integer(schema_version) or schema_version != SCHEMA_VERSION:
        raise ValidationError("schema_version_unsupported")

    issue_id = document["issueId"]
    if not isinstance(issue_id, str) or ISSUE_PATTERN.fullmatch(issue_id) is None:
        raise ValidationError("issue_id_invalid")

    status = document["status"]
    if not isinstance(status, str) or status not in RESULT_STATUSES:
        raise ValidationError("status_invalid")

    started_at = _parse_timestamp(document["startedAt"], "started_at")
    ended_at = _parse_timestamp(document["endedAt"], "ended_at")
    if started_at > ended_at:
        raise ValidationError("timestamp_order_invalid")

    commit = document["commit"]
    if not isinstance(commit, str) or COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValidationError("commit_invalid")

    _validate_text_mapping(document["toolchain"], TOOLCHAIN_KEYS, "toolchain")
    _validate_text_mapping(document["environment"], ENVIRONMENT_KEYS, "environment")
    _validate_privacy(document["privacy"])
    _validate_cases(document["cases"], status)
    artifacts = _validate_artifacts(document["artifacts"], status, issue_id)
    _validate_decision_ref(document["approvedDecisionRef"], status)

    for relative, sha256, byte_length in artifacts:
        if result_relative is not None and relative == result_relative:
            # The result cannot carry its own hash; it must be omitted.
            raise ValidationError("artifact_is_result")
        _verify_artifact_file(repository_root, relative, sha256, byte_length)

    return issue_id, status


def validate_result_file(path, repository_root=REPOSITORY_ROOT, expected_issue=None):
    """Validate a result file; returns (issue, status) or raises ValidationError."""
    root = Path(repository_root)
    relative, data = read_result_bytes(path, root)
    document = parse_json_bytes(data)
    issue_id, status = validate_document(document, root, relative)
    if expected_issue is not None and issue_id != expected_issue:
        raise ValidationError("issue_mismatch")
    return issue_id, status


def _parse_arguments(arguments):
    parser = _SafeArgumentParser(
        description="Validate a MacKVM E2E result.json without modifying it."
    )
    parser.add_argument("result", help="Path to result.json inside the repository")
    parser.add_argument("--expected-issue", help="Required issueId, e.g. M1-024")
    parser.add_argument(
        "--require-passed",
        action="store_true",
        help="Fail unless the result status is passed",
    )
    return parser.parse_args(arguments)


def main(arguments=None, repository_root=REPOSITORY_ROOT):
    try:
        options = _parse_arguments(arguments)
        if options.expected_issue is not None and (
            ISSUE_PATTERN.fullmatch(options.expected_issue) is None
        ):
            raise ValidationError("invalid_arguments", EXIT_USAGE)
        issue_id, status = validate_result_file(
            options.result, repository_root, options.expected_issue
        )
        if options.require_passed and status != "passed":
            raise ValidationError("status_not_passed", EXIT_NOT_PASSED)
    except ValidationError as error:
        print("evidence validation failed: {0}".format(error.code), file=sys.stderr)
        return error.exit_code
    except KeyboardInterrupt:
        print("evidence validation cancelled", file=sys.stderr)
        return 130
    except Exception:
        print("evidence validation failed: internal_failure", file=sys.stderr)
        return EXIT_DATA
    print("evidence valid: issue={0} status={1}".format(issue_id, status))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
