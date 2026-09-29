import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPOSITORY_ROOT / "Tools/Evidence/validate_evidence.py"
SCHEMA_PATH = (
    REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2/schemas/e2e-result.schema.json"
)
ISSUE = "M1-999"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
ARTIFACT_BYTES = b"sanitized machine report\n"


def load_tool():
    specification = importlib.util.spec_from_file_location(
        "validate_evidence_under_test", TOOL_PATH
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


validate_evidence = load_tool()


def privacy():
    return {
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


def passed_document():
    return {
        "schemaVersion": 1,
        "issueId": ISSUE,
        "status": "passed",
        "startedAt": "2026-09-29T01:02:03Z",
        "endedAt": "2026-09-29T01:05:03.250Z",
        "commit": COMMIT,
        "toolchain": {
            "pythonVersion": "3.12.4",
            "platform": "macOS-26.6-arm64-arm-64bit",
            "machine": "arm64",
        },
        "environment": {
            "localOS": "macOS 26.6",
            "peerProduct": "Barrier",
            "peerVersion": "2.4.0",
            "peerRole": "server",
            "peerOS": "Linux",
            "networkScope": "isolated-lab-lan",
            "tls": "enabled",
        },
        "cases": [
            {
                "id": "handshake.linux-server",
                "status": "passed",
                "exitCode": 0,
                "evidence": ["Handshake completed; see sanitized machine report"],
            }
        ],
        "artifacts": [
            {
                "path": "evidence/e2e/{0}/report.json".format(ISSUE),
                "sha256": hashlib.sha256(ARTIFACT_BYTES).hexdigest(),
                "byteLength": len(ARTIFACT_BYTES),
                "kind": "machine-report",
                "reviewStatus": "reviewed",
            }
        ],
        "privacy": privacy(),
        "approvedDecisionRef": None,
    }


def not_executed_document():
    document = passed_document()
    document["status"] = "not_executed"
    document["cases"] = []
    document["artifacts"] = []
    document["approvedDecisionRef"] = "docs/adr/M1-SCOPE-001-linux-only-validation.md"
    return document


def status_document(status, exit_code):
    document = passed_document()
    document["status"] = status
    document["cases"] = [
        {
            "id": "handshake.linux-server",
            "status": status,
            "exitCode": exit_code,
            "evidence": ["Terminal state recorded by the E2E script"],
        }
    ]
    return document


class ValidatorTestCase(unittest.TestCase):
    def setUp(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        self.root = Path(temporary_directory.name).resolve()
        self.issue_directory = self.root / "evidence/e2e" / ISSUE
        self.issue_directory.mkdir(parents=True)
        (self.issue_directory / "report.json").write_bytes(ARTIFACT_BYTES)
        self.result_path = self.issue_directory / "result.json"

    def write_result(self, document):
        self.result_path.write_text(json.dumps(document), encoding="utf-8")
        return self.result_path

    def validate(self, document, expected_issue=None):
        self.write_result(document)
        return validate_evidence.validate_result_file(
            self.result_path, self.root, expected_issue
        )

    def assert_invalid(self, document, code, exit_code=65):
        with self.assertRaises(validate_evidence.ValidationError) as context:
            self.validate(document)
        self.assertEqual(context.exception.code, code)
        self.assertEqual(context.exception.exit_code, exit_code)

    def assert_raw_invalid(self, raw, code, exit_code=65):
        self.result_path.write_bytes(raw)
        with self.assertRaises(validate_evidence.ValidationError) as context:
            validate_evidence.validate_result_file(self.result_path, self.root)
        self.assertEqual(context.exception.code, code)
        self.assertEqual(context.exception.exit_code, exit_code)

    def run_main(self, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            exit_code = validate_evidence.main(arguments, repository_root=self.root)
        return exit_code, stdout.getvalue(), stderr.getvalue()


class HappyPathTests(ValidatorTestCase):
    def test_passed_result_is_valid(self):
        self.assertEqual(self.validate(passed_document()), (ISSUE, "passed"))

    def test_passed_result_without_artifacts_is_valid(self):
        document = passed_document()
        document["artifacts"] = []
        self.assertEqual(self.validate(document), (ISSUE, "passed"))

    def test_tests_fixtures_artifact_is_valid(self):
        fixture = self.root / "Tests/Fixtures/Barrier/linux-handshake.bin"
        fixture.parent.mkdir(parents=True)
        fixture.write_bytes(b"\x00\x01binary")
        document = passed_document()
        document["artifacts"][0].update(
            {
                "path": "Tests/Fixtures/Barrier/linux-handshake.bin",
                "sha256": hashlib.sha256(b"\x00\x01binary").hexdigest(),
                "byteLength": 8,
                "kind": "sanitized-fixture",
            }
        )
        self.assertEqual(self.validate(document), (ISSUE, "passed"))

    def test_retained_failure_statuses_are_valid(self):
        for status, exit_code in (
            ("failed", 1),
            ("failed", 255),
            ("timed_out", None),
            ("timed_out", 124),
            ("cancelled", None),
            ("cancelled", 130),
        ):
            with self.subTest(status=status, exit_code=exit_code):
                self.assertEqual(
                    self.validate(status_document(status, exit_code)), (ISSUE, status)
                )

    def test_failed_result_may_retain_pending_review_artifact(self):
        document = status_document("failed", 2)
        document["artifacts"][0]["reviewStatus"] = "pending-review"
        self.assertEqual(self.validate(document), (ISSUE, "failed"))

    def test_failed_result_may_mix_passed_cases(self):
        document = status_document("failed", 3)
        document["cases"].insert(
            0,
            {
                "id": "connect",
                "status": "passed",
                "exitCode": 0,
                "evidence": ["Connected"],
            },
        )
        self.assertEqual(self.validate(document), (ISSUE, "failed"))

    def test_not_executed_with_decision_is_valid(self):
        self.assertEqual(self.validate(not_executed_document()), (ISSUE, "not_executed"))

    def test_equal_timestamps_are_valid(self):
        document = passed_document()
        document["endedAt"] = document["startedAt"]
        self.assertEqual(self.validate(document), (ISSUE, "passed"))

    def test_expected_issue_matches(self):
        self.assertEqual(self.validate(passed_document(), ISSUE), (ISSUE, "passed"))

    def test_validation_does_not_modify_files(self):
        path = self.write_result(passed_document())
        before = (path.read_bytes(), os.stat(path).st_mtime_ns)
        report = self.issue_directory / "report.json"
        report_before = (report.read_bytes(), os.stat(report).st_mtime_ns)
        validate_evidence.validate_result_file(path, self.root)
        self.assertEqual(before, (path.read_bytes(), os.stat(path).st_mtime_ns))
        self.assertEqual(
            report_before, (report.read_bytes(), os.stat(report).st_mtime_ns)
        )
        self.assertEqual(
            sorted(p.name for p in self.issue_directory.iterdir()),
            ["report.json", "result.json"],
        )


class CommandLineTests(ValidatorTestCase):
    def test_success_prints_closed_line(self):
        self.write_result(passed_document())
        exit_code, stdout, stderr = self.run_main([str(self.result_path)])
        self.assertEqual(exit_code, 0)
        self.assertEqual(stdout, "evidence valid: issue=M1-999 status=passed\n")
        self.assertEqual(stderr, "")

    def test_expected_issue_and_require_passed(self):
        self.write_result(passed_document())
        exit_code, _, _ = self.run_main(
            [str(self.result_path), "--expected-issue", ISSUE, "--require-passed"]
        )
        self.assertEqual(exit_code, 0)

    def test_require_passed_rejects_retained_failure(self):
        self.write_result(status_document("failed", 1))
        exit_code, stdout, stderr = self.run_main(
            [str(self.result_path), "--require-passed"]
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "evidence validation failed: status_not_passed\n")

    def test_require_passed_rejects_not_executed(self):
        self.write_result(not_executed_document())
        exit_code, stdout, _ = self.run_main([str(self.result_path), "--require-passed"])
        self.assertEqual(exit_code, 1)
        self.assertNotIn("passed", stdout)

    def test_expected_issue_mismatch(self):
        self.write_result(passed_document())
        exit_code, _, stderr = self.run_main(
            [str(self.result_path), "--expected-issue", "M1-998"]
        )
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "evidence validation failed: issue_mismatch\n")

    def test_usage_errors(self):
        self.write_result(passed_document())
        for arguments in (
            [],
            [str(self.result_path), "extra"],
            [str(self.result_path), "--unknown"],
            [str(self.result_path), "--expected-issue", "../M1-999"],
            [str(self.result_path), "--expected-issue", "M1-999\n"],
        ):
            with self.subTest(arguments=arguments):
                exit_code, stdout, stderr = self.run_main(arguments)
                self.assertEqual(exit_code, 64)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, "evidence validation failed: invalid_arguments\n")

    def test_failure_output_does_not_echo_untrusted_values(self):
        document = passed_document()
        document["UNTRUSTED-FIELD-MARKER"] = "UNTRUSTED-VALUE-MARKER"
        self.write_result(document)
        exit_code, stdout, stderr = self.run_main([str(self.result_path)])
        self.assertEqual(exit_code, 65)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "evidence validation failed: result_unknown_field\n")

    def test_direct_invocation_from_other_cwd_uses_tool_location_root(self):
        tool_copy = self.root / "Tools/Evidence/validate_evidence.py"
        tool_copy.parent.mkdir(parents=True)
        shutil.copyfile(TOOL_PATH, tool_copy)
        self.write_result(passed_document())
        with tempfile.TemporaryDirectory() as other_cwd:
            completed = subprocess.run(
                [sys.executable, str(tool_copy), str(self.result_path)],
                cwd=other_cwd,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "evidence valid: issue=M1-999 status=passed\n")

    def test_relative_path_is_resolved_from_cwd(self):
        self.write_result(passed_document())
        previous = os.getcwd()
        os.chdir(self.root)
        try:
            exit_code, _, stderr = self.run_main(["evidence/e2e/M1-999/result.json"])
        finally:
            os.chdir(previous)
        self.assertEqual(exit_code, 0, stderr)


class JsonParsingTests(ValidatorTestCase):
    def test_malformed_json(self):
        for raw in (b"", b"{", b"{'a': 1}", b"[1,]", b"{\"a\":1} trailing"):
            with self.subTest(raw=raw):
                self.assert_raw_invalid(raw, "invalid_json")

    def test_invalid_utf8(self):
        self.assert_raw_invalid(b"\xff\xfe{}", "invalid_json")

    def test_duplicate_keys_top_level_and_nested(self):
        self.assert_raw_invalid(b'{"status": "passed", "status": "failed"}', "duplicate_json_key")
        text = json.dumps(passed_document()).replace(
            '"machine": "arm64"', '"machine": "arm64", "machine": "x86_64"'
        )
        self.assert_raw_invalid(text.encode("utf-8"), "duplicate_json_key")

    def test_non_finite_numbers(self):
        for literal in (b"NaN", b"Infinity", b"-Infinity", b"1e400"):
            with self.subTest(literal=literal):
                self.assert_raw_invalid(
                    b'{"schemaVersion": ' + literal + b"}", "non_finite_number"
                )

    def test_non_object_document(self):
        self.assert_raw_invalid(b"[]", "result_invalid_type")
        self.assert_raw_invalid(b"null", "result_invalid_type")

    def test_deeply_nested_json(self):
        self.assert_raw_invalid(b"[" * 100000 + b"]" * 100000, "invalid_json")


class ResultPathTests(ValidatorTestCase):
    def test_oversize_result(self):
        self.assert_raw_invalid(
            b" " * (validate_evidence.MAX_RESULT_BYTES + 1), "result_too_large"
        )

    def test_missing_result(self):
        with self.assertRaises(validate_evidence.ValidationError) as context:
            validate_evidence.validate_result_file(self.result_path, self.root)
        self.assertEqual(context.exception.code, "result_missing")
        self.assertEqual(context.exception.exit_code, 66)

    def test_symlink_result(self):
        target = self.issue_directory / "real.json"
        target.write_text(json.dumps(passed_document()), encoding="utf-8")
        self.result_path.symlink_to(target)
        with self.assertRaises(validate_evidence.ValidationError) as context:
            validate_evidence.validate_result_file(self.result_path, self.root)
        self.assertEqual(context.exception.code, "result_symlink")
        self.assertEqual(context.exception.exit_code, 77)

    def test_symlinked_parent_directory(self):
        real = self.root / "evidence/e2e/real"
        real.mkdir()
        (real / "result.json").write_text(json.dumps(passed_document()), encoding="utf-8")
        link = self.root / "evidence/e2e/linked"
        link.symlink_to(real, target_is_directory=True)
        with self.assertRaises(validate_evidence.ValidationError) as context:
            validate_evidence.validate_result_file(link / "result.json", self.root)
        self.assertEqual(context.exception.code, "result_symlink")
        self.assertEqual(context.exception.exit_code, 77)

    def test_result_outside_repository(self):
        with tempfile.TemporaryDirectory() as outside:
            outside_result = Path(outside).resolve() / "result.json"
            outside_result.write_text(json.dumps(passed_document()), encoding="utf-8")
            for path in (outside_result, self.root / ".." / outside_result.name):
                with self.subTest(path=path):
                    with self.assertRaises(validate_evidence.ValidationError) as context:
                        validate_evidence.validate_result_file(path, self.root)
                    self.assertEqual(context.exception.code, "result_outside_repository")
                    self.assertEqual(context.exception.exit_code, 77)

    def test_result_directory(self):
        with self.assertRaises(validate_evidence.ValidationError) as context:
            validate_evidence.validate_result_file(self.issue_directory, self.root)
        self.assertEqual(context.exception.code, "result_not_regular_file")
        self.assertEqual(context.exception.exit_code, 77)


class TopLevelFieldTests(ValidatorTestCase):
    def test_unknown_and_missing_fields(self):
        document = passed_document()
        document["extra"] = 1
        self.assert_invalid(document, "result_unknown_field")
        document = passed_document()
        del document["privacy"]
        self.assert_invalid(document, "result_missing_field")

    def test_nested_unknown_fields(self):
        for key, code in (
            ("toolchain", "toolchain_unknown_field"),
            ("environment", "environment_unknown_field"),
            ("privacy", "privacy_unknown_field"),
        ):
            with self.subTest(key=key):
                document = passed_document()
                document[key]["extra"] = "x"
                self.assert_invalid(document, code)
        document = passed_document()
        document["cases"][0]["extra"] = "x"
        self.assert_invalid(document, "case_unknown_field")
        document = passed_document()
        document["artifacts"][0]["extra"] = "x"
        self.assert_invalid(document, "artifact_unknown_field")

    def test_nested_missing_fields(self):
        document = passed_document()
        del document["environment"]["tls"]
        self.assert_invalid(document, "environment_missing_field")
        document = passed_document()
        del document["cases"][0]["exitCode"]
        self.assert_invalid(document, "case_missing_field")

    def test_schema_version(self):
        for value in (2, 0, True, "1", 1.0, None):
            with self.subTest(value=value):
                document = passed_document()
                document["schemaVersion"] = value
                self.assert_invalid(document, "schema_version_unsupported")

    def test_issue_id(self):
        for value in ("M6-001", "M1-01", "m1-001", "M1-0011", "M1-001\n", 1, None):
            with self.subTest(value=value):
                document = passed_document()
                document["issueId"] = value
                self.assert_invalid(document, "issue_id_invalid")

    def test_wrong_issue(self):
        document = passed_document()
        document["issueId"] = "M1-998"
        document["artifacts"] = []
        self.write_result(document)
        with self.assertRaises(validate_evidence.ValidationError) as context:
            validate_evidence.validate_result_file(self.result_path, self.root, ISSUE)
        self.assertEqual(context.exception.code, "issue_mismatch")

    def test_status(self):
        for value in ("PASSED", "pass", "skipped", "", None, 0):
            with self.subTest(value=value):
                document = passed_document()
                document["status"] = value
                self.assert_invalid(document, "status_invalid")

    def test_timestamps(self):
        for value in (
            "2026-09-29T01:02:03",
            "2026-09-29T01:02:03+00:00",
            "2026-09-29T01:02:03z",
            "2026-09-29 01:02:03Z",
            "2026-02-30T01:02:03Z",
            "2026-09-29T24:00:00Z",
            "2026-09-29T01:02:60Z",
            "2026-09-29T01:02:03.1234567Z",
            "２０２６-09-29T01:02:03Z",
            1759107723,
            None,
        ):
            with self.subTest(value=value):
                document = passed_document()
                document["startedAt"] = value
                self.assert_invalid(document, "started_at_invalid")
        document = passed_document()
        document["endedAt"] = "not-a-time"
        self.assert_invalid(document, "ended_at_invalid")

    def test_timestamp_order(self):
        document = passed_document()
        document["startedAt"] = "2026-09-29T01:05:03.251Z"
        self.assert_invalid(document, "timestamp_order_invalid")

    def test_commit(self):
        for value in (COMMIT[:39], COMMIT + "0", COMMIT.upper(), "g" * 40, None):
            with self.subTest(value=value):
                document = passed_document()
                document["commit"] = value
                self.assert_invalid(document, "commit_invalid")

    def test_metadata_text(self):
        for value in ("", " leading", "trailing ", "tab\there", "line\nbreak", "é", 1, None):
            with self.subTest(value=value):
                document = passed_document()
                document["toolchain"]["machine"] = value
                self.assert_invalid(document, "toolchain_value_invalid")
                document = passed_document()
                document["environment"]["peerOS"] = value
                self.assert_invalid(document, "environment_value_invalid")

    def test_metadata_sensitive_marker(self):
        document = passed_document()
        document["environment"]["networkScope"] = "192.168.1.10"
        self.assert_invalid(document, "environment_value_sensitive_marker")

    def test_privacy_flags(self):
        for key, required in privacy().items():
            for value in (not required, int(required), None, str(required).lower()):
                with self.subTest(key=key, value=value):
                    document = passed_document()
                    document["privacy"][key] = value
                    self.assert_invalid(document, "privacy_violation")


class CaseTests(ValidatorTestCase):
    def case_document(self, **overrides):
        document = passed_document()
        document["cases"][0].update(overrides)
        return document

    def test_cases_required_for_execution_statuses(self):
        for status in ("passed", "failed", "timed_out", "cancelled"):
            with self.subTest(status=status):
                document = passed_document()
                document["status"] = status
                document["cases"] = []
                self.assert_invalid(document, "cases_empty")

    def test_cases_type(self):
        document = passed_document()
        document["cases"] = {}
        self.assert_invalid(document, "cases_invalid_type")
        document = passed_document()
        document["cases"] = ["case"]
        self.assert_invalid(document, "case_invalid_type")

    def test_case_id(self):
        for value in ("", "Upper", "-leading", "has space", "a" * 65, "../x", 1):
            with self.subTest(value=value):
                self.assert_invalid(self.case_document(id=value), "case_id_invalid")

    def test_duplicate_case_id(self):
        document = passed_document()
        document["cases"].append(copy.deepcopy(document["cases"][0]))
        self.assert_invalid(document, "case_id_duplicate")

    def test_case_status(self):
        for value in ("not_executed", "skipped", None):
            with self.subTest(value=value):
                self.assert_invalid(self.case_document(status=value), "case_status_invalid")

    def test_exit_code_type_and_range(self):
        for value in (-1, 256, True, False, 0.0, "0"):
            with self.subTest(value=value):
                self.assert_invalid(
                    self.case_document(exitCode=value), "case_exit_code_invalid"
                )

    def test_exit_code_consistency(self):
        for status, exit_code in (
            ("passed", 1),
            ("passed", None),
            ("failed", 0),
            ("failed", None),
            ("timed_out", 0),
            ("timed_out", 1),
            ("timed_out", 130),
            ("cancelled", 0),
            ("cancelled", 124),
        ):
            with self.subTest(status=status, exit_code=exit_code):
                self.assert_invalid(
                    status_document(status, exit_code), "case_exit_code_inconsistent"
                )

    def test_top_level_passed_requires_all_cases_passed(self):
        document = passed_document()
        document["cases"].append(
            {"id": "second", "status": "failed", "exitCode": 1, "evidence": ["Failed"]}
        )
        self.assert_invalid(document, "status_cases_inconsistent")

    def test_non_passed_status_requires_corresponding_case(self):
        for status in ("failed", "timed_out", "cancelled"):
            with self.subTest(status=status):
                document = passed_document()
                document["status"] = status
                self.assert_invalid(document, "status_cases_inconsistent")
        document = status_document("timed_out", None)
        document["status"] = "failed"
        self.assert_invalid(document, "status_cases_inconsistent")

    def test_evidence_list(self):
        for value in ([], "text", None):
            with self.subTest(value=value):
                self.assert_invalid(self.case_document(evidence=value), "case_evidence_invalid")
        self.assert_invalid(
            self.case_document(evidence=["ok"] * 33), "case_evidence_limit_exceeded"
        )

    def test_evidence_description_text(self):
        for value in ("", " x", "x ", "bell\x07", "nul\x00", "del\x7f", "é", "x" * 201, 1):
            with self.subTest(value=value):
                self.assert_invalid(
                    self.case_document(evidence=[value]), "case_evidence_invalid"
                )

    def test_evidence_secret_markers(self):
        for value in (
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "password=hunter2",
            "Authorization header captured",
            "Bearer abc",
            "api_key found",
            "session token value",
            "client secret",
            "ssh-ed25519 AAAAC3",
            "ghp_0123456789",
            "AKIAABCDEFGHIJKLMNOP",
            "contact user@example.com",
            "peer at 10.0.0.12",
            "see https://example.invalid/x",
            "blob " + "A" * 40,
        ):
            with self.subTest(value=value):
                self.assert_invalid(
                    self.case_document(evidence=[value]), "case_evidence_sensitive_marker"
                )

    def test_cases_limit(self):
        document = passed_document()
        document["cases"] = [
            {"id": "case-{0}".format(index), "status": "passed", "exitCode": 0, "evidence": ["ok"]}
            for index in range(257)
        ]
        self.assert_invalid(document, "cases_limit_exceeded")


class NotExecutedTests(ValidatorTestCase):
    def test_not_executed_rejects_cases(self):
        document = not_executed_document()
        document["cases"] = passed_document()["cases"]
        self.assert_invalid(document, "not_executed_has_cases")

    def test_not_executed_rejects_artifacts(self):
        document = not_executed_document()
        document["artifacts"] = passed_document()["artifacts"]
        self.assert_invalid(document, "not_executed_has_artifacts")

    def test_not_executed_requires_decision(self):
        for value in (None, ""):
            with self.subTest(value=value):
                document = not_executed_document()
                document["approvedDecisionRef"] = value
                self.assert_invalid(document, "approved_decision_ref_missing")

    def test_not_executed_decision_must_be_safe(self):
        for value in (
            " leading",
            "has space",
            "ctrl\x01",
            "https://example.invalid/decision",
            "-flag",
            "x" * 161,
            1,
            ["ref"],
        ):
            with self.subTest(value=value):
                document = not_executed_document()
                document["approvedDecisionRef"] = value
                self.assert_invalid(document, "approved_decision_ref_invalid")
        document = not_executed_document()
        document["approvedDecisionRef"] = "token-issue-270"
        self.assert_invalid(document, "approved_decision_ref_sensitive_marker")

    def test_execution_status_rejects_decision(self):
        for document in (passed_document(), status_document("failed", 1)):
            with self.subTest(status=document["status"]):
                document["approvedDecisionRef"] = "GitHub-Issue-270"
                self.assert_invalid(document, "approved_decision_ref_not_allowed")


class ArtifactTests(ValidatorTestCase):
    def artifact_document(self, **overrides):
        document = passed_document()
        document["artifacts"][0].update(overrides)
        return document

    def test_invalid_paths(self):
        for value in (
            "",
            "/evidence/e2e/M1-999/report.json",
            str(self.issue_directory / "report.json"),
            "evidence\\e2e\\M1-999\\report.json",
            "evidence/e2e/M1-999/./report.json",
            "evidence/e2e/M1-999/../M1-999/report.json",
            "evidence/e2e/M1-999/sub/../../M1-998/report.json",
            "evidence/e2e/M1-999//report.json",
            "evidence/e2e/M1-999/report.json/",
            "evidence/e2e/M1-999/report\x00.json",
            "evidence/e2e/M1-999",
            "evidence/e2e/M1-999/.hidden",
            "evidence/issues/M1-999/report.json",
            "Tests/Other/report.json",
            "Tests/Fixtures",
            "C:/evidence/report.json",
            "evidence/e2e/M1-999/" + "a" * 600,
            1,
            None,
        ):
            with self.subTest(value=value):
                self.assert_invalid(
                    self.artifact_document(path=value), "artifact_path_invalid"
                )

    def test_path_for_other_issue(self):
        other = self.root / "evidence/e2e/M1-998"
        other.mkdir()
        (other / "report.json").write_bytes(ARTIFACT_BYTES)
        self.assert_invalid(
            self.artifact_document(path="evidence/e2e/M1-998/report.json"),
            "artifact_path_issue_mismatch",
        )

    def test_missing_artifact(self):
        self.assert_invalid(
            self.artifact_document(path="evidence/e2e/M1-999/missing.json"),
            "artifact_missing",
            66,
        )

    def test_symlink_artifact(self):
        (self.issue_directory / "link.json").symlink_to(self.issue_directory / "report.json")
        self.assert_invalid(
            self.artifact_document(path="evidence/e2e/M1-999/link.json"),
            "artifact_symlink",
            77,
        )

    def test_symlink_directory_component(self):
        (self.issue_directory / "linked").symlink_to(
            self.issue_directory, target_is_directory=True
        )
        self.assert_invalid(
            self.artifact_document(path="evidence/e2e/M1-999/linked/report.json"),
            "artifact_symlink",
            77,
        )

    def test_symlinked_fixture_root(self):
        real = self.root / "real-fixtures"
        real.mkdir()
        (real / "fixture.bin").write_bytes(ARTIFACT_BYTES)
        (self.root / "Tests").mkdir()
        (self.root / "Tests/Fixtures").symlink_to(real, target_is_directory=True)
        self.assert_invalid(
            self.artifact_document(path="Tests/Fixtures/fixture.bin"),
            "artifact_symlink",
            77,
        )

    def test_directory_artifact(self):
        (self.issue_directory / "logs").mkdir()
        self.assert_invalid(
            self.artifact_document(path="evidence/e2e/M1-999/logs"),
            "artifact_not_regular_file",
            77,
        )

    def test_hash_mismatch(self):
        self.assert_invalid(
            self.artifact_document(sha256=hashlib.sha256(b"other").hexdigest()),
            "artifact_hash_mismatch",
        )

    def test_length_mismatch(self):
        self.assert_invalid(
            self.artifact_document(byteLength=len(ARTIFACT_BYTES) + 1),
            "artifact_length_mismatch",
        )

    def test_sha256_format(self):
        digest = hashlib.sha256(ARTIFACT_BYTES).hexdigest()
        for value in (digest.upper(), digest[:63], "", None):
            with self.subTest(value=value):
                self.assert_invalid(
                    self.artifact_document(sha256=value), "artifact_sha256_invalid"
                )

    def test_byte_length_type(self):
        for value in (-1, True, 1.0, "25", None):
            with self.subTest(value=value):
                self.assert_invalid(
                    self.artifact_document(byteLength=value), "artifact_byte_length_invalid"
                )

    def test_kind_and_review_status_enums(self):
        self.assert_invalid(self.artifact_document(kind="raw-capture"), "artifact_kind_invalid")
        self.assert_invalid(
            self.artifact_document(reviewStatus="approved"), "artifact_review_status_invalid"
        )

    def test_passed_requires_reviewed_artifacts(self):
        self.assert_invalid(
            self.artifact_document(reviewStatus="pending-review"), "artifact_not_reviewed"
        )

    def test_duplicate_artifact_path(self):
        document = passed_document()
        document["artifacts"].append(copy.deepcopy(document["artifacts"][0]))
        self.assert_invalid(document, "artifact_path_duplicate")

    def test_result_cannot_list_itself(self):
        self.assert_invalid(
            self.artifact_document(path="evidence/e2e/M1-999/result.json"),
            "artifact_is_result",
        )

    def test_artifacts_type(self):
        document = passed_document()
        document["artifacts"] = {}
        self.assert_invalid(document, "artifacts_invalid_type")
        document = passed_document()
        document["artifacts"] = ["path"]
        self.assert_invalid(document, "artifact_invalid_type")


class SchemaContractTests(unittest.TestCase):
    def setUp(self):
        self.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    def iter_object_schemas(self, node):
        if isinstance(node, dict):
            if node.get("type") == "object":
                yield node
            for value in node.values():
                yield from self.iter_object_schemas(value)
        elif isinstance(node, list):
            for value in node:
                yield from self.iter_object_schemas(value)

    def test_schema_dialect(self):
        self.assertEqual(
            self.schema["$schema"], "https://json-schema.org/draft/2020-12/schema"
        )

    def test_every_object_schema_is_closed(self):
        objects = list(self.iter_object_schemas(self.schema))
        self.assertEqual(len(objects), 6)
        for node in objects:
            self.assertIs(node.get("additionalProperties"), False)
            self.assertEqual(set(node["required"]), set(node["properties"]))

    def test_schema_matches_validator_keys(self):
        definitions = self.schema["$defs"]
        properties = self.schema["properties"]
        self.assertEqual(set(self.schema["required"]), validate_evidence.TOP_LEVEL_KEYS)
        self.assertEqual(
            set(properties["toolchain"]["required"]), validate_evidence.TOOLCHAIN_KEYS
        )
        self.assertEqual(
            set(properties["environment"]["required"]), validate_evidence.ENVIRONMENT_KEYS
        )
        self.assertEqual(set(definitions["case"]["required"]), validate_evidence.CASE_KEYS)
        self.assertEqual(
            set(definitions["artifact"]["required"]), validate_evidence.ARTIFACT_KEYS
        )
        self.assertEqual(
            {
                key: value["const"]
                for key, value in properties["privacy"]["properties"].items()
            },
            validate_evidence.PRIVACY_REQUIRED_VALUES,
        )

    def test_schema_matches_validator_enums(self):
        definitions = self.schema["$defs"]
        self.assertEqual(
            set(self.schema["properties"]["status"]["enum"]),
            validate_evidence.RESULT_STATUSES,
        )
        self.assertEqual(
            set(definitions["case"]["properties"]["status"]["enum"]),
            validate_evidence.CASE_STATUSES,
        )
        self.assertEqual(
            set(definitions["artifact"]["properties"]["kind"]["enum"]),
            validate_evidence.ARTIFACT_KINDS,
        )
        self.assertEqual(
            set(definitions["artifact"]["properties"]["reviewStatus"]["enum"]),
            validate_evidence.REVIEW_STATUSES,
        )
        self.assertEqual(self.schema["properties"]["schemaVersion"]["const"], 1)

    def test_schema_patterns_match_validator(self):
        definitions = self.schema["$defs"]
        pairs = (
            (self.schema["properties"]["issueId"]["pattern"], validate_evidence.ISSUE_PATTERN),
            (self.schema["properties"]["commit"]["pattern"], validate_evidence.COMMIT_PATTERN),
            (definitions["decisionRef"]["pattern"], validate_evidence.DECISION_REF_PATTERN),
            (definitions["case"]["properties"]["id"]["pattern"], validate_evidence.CASE_ID_PATTERN),
        )
        for schema_pattern, validator_pattern in pairs:
            with self.subTest(pattern=schema_pattern):
                self.assertEqual(schema_pattern, "^" + validator_pattern.pattern + "$")


if __name__ == "__main__":
    unittest.main()
