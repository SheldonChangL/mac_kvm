import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPOSITORY_ROOT / "Tools/diagnostic-bundle/diagnostic-bundle.py"


def load_tool():
    specification = importlib.util.spec_from_file_location(
        "diagnostic_bundle", TOOL_PATH
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


diagnostic_bundle = load_tool()


def valid_payload():
    return {
        "schemaVersion": 1,
        "config": {
            "applicationVersion": "0.1.0-alpha.1",
            "operatingSystemVersion": "macOS-26.6.2",
            "protocolMode": "barrierCompatibility",
            "tlsEnabled": True,
        },
        "logs": [
            {
                "category": "connectivity",
                "eventId": "connectivity.connection.stateChanged",
                "correlationId": "6f4dc34c-1266-4c44-b42c-250bb621a41e",
                "metadata": {"state": "connected"},
            },
            {
                "category": "inputSafety",
                "eventId": "inputSafety.cleanup.completed",
                "correlationId": None,
                "metadata": {"outcome": "completed"},
            },
        ],
    }


class DiagnosticBundleTests(unittest.TestCase):
    def create_bundle(self, payload=None, before_commit=None):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        output = Path(temporary_directory.name) / "diagnostics.zip"
        diagnostic_bundle.create_bundle(
            valid_payload() if payload is None else payload,
            output,
            before_commit=before_commit,
        )
        return output

    def test_happy_path_exports_only_allowlisted_metadata(self):
        output = self.create_bundle()

        with zipfile.ZipFile(output) as archive:
            self.assertEqual(
                set(archive.namelist()), {"manifest.json", "events.jsonl"}
            )
            manifest = json.loads(archive.read("manifest.json"))
            events = [
                json.loads(line)
                for line in archive.read("events.jsonl").decode("utf-8").splitlines()
            ]

        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["recordCount"], 2)
        self.assertEqual(manifest["config"], valid_payload()["config"])
        self.assertEqual(events, valid_payload()["logs"])

    def test_maximum_record_boundary_is_accepted(self):
        payload = valid_payload()
        payload["logs"] = [payload["logs"][1]] * diagnostic_bundle.MAX_RECORDS

        output = self.create_bundle(payload)

        with zipfile.ZipFile(output) as archive:
            manifest = json.loads(archive.read("manifest.json"))
        self.assertEqual(manifest["recordCount"], diagnostic_bundle.MAX_RECORDS)

    def test_one_record_over_limit_fails_without_output(self):
        payload = valid_payload()
        payload["logs"] = [
            payload["logs"][1]
        ] * (diagnostic_bundle.MAX_RECORDS + 1)
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "diagnostics.zip"

            with self.assertRaisesRegex(
                diagnostic_bundle.BundleError, "record_limit_exceeded"
            ):
                diagnostic_bundle.create_bundle(payload, output)

            self.assertFalse(output.exists())

    def test_prohibited_content_classes_are_rejected_before_serialization(self):
        unsafe_cases = {
            "typed text": ("metadata", "typedText", "private message"),
            "clipboard payload": ("metadata", "clipboardContent", "copied secret"),
            "keychain material": ("config", "keychain", "login.keychain-db"),
            "private key": ("metadata", "privateKey", "synthetic-key-material"),
            "input content": ("metadata", "keyCode", 42),
        }

        for name, (location, key, value) in unsafe_cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                payload = valid_payload()
                if location == "config":
                    payload["config"][key] = value
                else:
                    payload["logs"][0]["metadata"][key] = value
                output = Path(temporary_directory) / "diagnostics.zip"

                with self.assertRaisesRegex(
                    diagnostic_bundle.BundleError, "unknown_field"
                ):
                    diagnostic_bundle.create_bundle(payload, output)

                self.assertFalse(output.exists())
                self.assertEqual(
                    list(Path(temporary_directory).glob(".diagnostic-bundle-*")), []
                )

    def test_unknown_event_and_free_form_string_are_rejected(self):
        payload = valid_payload()
        payload["logs"][0]["eventId"] = "copied-password-is-hunter2"

        with self.assertRaisesRegex(diagnostic_bundle.BundleError, "unknown_event"):
            self.create_bundle(payload)

    def test_boolean_schema_version_is_not_accepted_as_integer_one(self):
        payload = valid_payload()
        payload["schemaVersion"] = True

        with self.assertRaisesRegex(
            diagnostic_bundle.BundleError, "unsupported_schema"
        ):
            self.create_bundle(payload)

    def test_free_form_text_is_rejected_in_version_fields(self):
        payload = valid_payload()
        payload["config"]["applicationVersion"] = "private-message"

        with self.assertRaisesRegex(diagnostic_bundle.BundleError, "invalid_value"):
            self.create_bundle(payload)

    def test_correlation_id_must_be_canonical_version_four_uuid(self):
        payload = valid_payload()
        payload["logs"][0]["correlationId"] = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

        with self.assertRaisesRegex(
            diagnostic_bundle.BundleError, "invalid_correlation_id"
        ):
            self.create_bundle(payload)

    def test_category_must_match_the_event_catalog(self):
        payload = valid_payload()
        payload["logs"][0]["category"] = "clipboard"

        with self.assertRaisesRegex(
            diagnostic_bundle.BundleError, "category_mismatch"
        ):
            self.create_bundle(payload)

    def test_completed_cleanup_event_cannot_claim_partial_or_failed_outcome(self):
        for outcome in ("partial", "failed"):
            with self.subTest(outcome=outcome):
                payload = valid_payload()
                payload["logs"][1]["metadata"]["outcome"] = outcome

                with self.assertRaisesRegex(
                    diagnostic_bundle.BundleError, "invalid_value"
                ):
                    self.create_bundle(payload)

    def test_event_catalog_maps_category_severity_error_and_metadata_schema(self):
        allowed_severities = {"debug", "info", "notice", "warning", "error"}

        for event_id, entry in diagnostic_bundle._EVENT_CATALOG.items():
            with self.subTest(event_id=event_id):
                self.assertEqual(
                    set(entry), {"category", "severity", "errorCode", "metadata"}
                )
                self.assertIn(entry["severity"], allowed_severities)
                self.assertIsNone(entry["errorCode"])
                self.assertIsInstance(entry["metadata"], dict)

    def test_cancellation_removes_partial_archive(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "diagnostics.zip"

            def cancel():
                raise KeyboardInterrupt

            with self.assertRaises(KeyboardInterrupt):
                diagnostic_bundle.create_bundle(
                    valid_payload(), output, before_commit=cancel
                )

            self.assertFalse(output.exists())
            self.assertEqual(
                list(Path(temporary_directory).glob(".diagnostic-bundle-*")), []
            )

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "diagnostics.zip"
            output.write_bytes(b"existing")

            with self.assertRaisesRegex(
                diagnostic_bundle.BundleError, "output_exists"
            ):
                diagnostic_bundle.create_bundle(valid_payload(), output)

            self.assertEqual(output.read_bytes(), b"existing")

    def test_invalid_json_cli_error_is_typed_and_does_not_echo_input(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            input_path = Path(temporary_directory) / "typed-secret.txt"
            output = Path(temporary_directory) / "diagnostics.zip"
            input_path.write_text("not-json: clipboard secret", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(TOOL_PATH),
                    "--input",
                    str(input_path),
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(
            result.stderr.strip(), "diagnostic bundle failed: invalid_json"
        )
        self.assertNotIn("typed-secret", result.stderr)
        self.assertNotIn("clipboard secret", result.stderr)

    def test_oversized_input_is_rejected_before_json_parsing(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            input_path = Path(temporary_directory) / "input.json"
            output = Path(temporary_directory) / "diagnostics.zip"
            input_path.write_bytes(b" " * (diagnostic_bundle.MAX_INPUT_BYTES + 1))

            result = subprocess.run(
                [
                    sys.executable,
                    str(TOOL_PATH),
                    "--input",
                    str(input_path),
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(
            result.stderr.strip(), "diagnostic bundle failed: input_too_large"
        )
        self.assertFalse(output.exists())

    def test_cli_happy_path_creates_bundle_without_echoing_content(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            input_path = Path(temporary_directory) / "input.json"
            output = Path(temporary_directory) / "diagnostics.zip"
            input_path.write_text(json.dumps(valid_payload()), encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(TOOL_PATH),
                    "--input",
                    str(input_path),
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "diagnostic bundle created")
            self.assertEqual(result.stderr, "")
            self.assertTrue(zipfile.is_zipfile(output))

    def test_input_symlink_is_rejected_without_creating_output(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory) / "source.json"
            input_path = Path(temporary_directory) / "input.json"
            output = Path(temporary_directory) / "diagnostics.zip"
            source.write_text(json.dumps(valid_payload()), encoding="utf-8")
            input_path.symlink_to(source)

            result = subprocess.run(
                [
                    sys.executable,
                    str(TOOL_PATH),
                    "--input",
                    str(input_path),
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(
            result.stderr.strip(), "diagnostic bundle failed: input_unavailable"
        )
        self.assertFalse(output.exists())

    def test_invalid_cli_arguments_do_not_echo_untrusted_values(self):
        result = subprocess.run(
            [sys.executable, str(TOOL_PATH), "--unexpected=typed-secret"],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(
            result.stderr.strip(), "diagnostic bundle failed: invalid_arguments"
        )
        self.assertNotIn("typed-secret", result.stderr)


if __name__ == "__main__":
    unittest.main()
