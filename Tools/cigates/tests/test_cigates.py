import importlib.util
import json
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPOSITORY_ROOT / "Tools/cigates/cigates.py"

spec = importlib.util.spec_from_file_location("cigates", MODULE_PATH)
cigates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cigates)


class CIGateTests(unittest.TestCase):
    def gate_result(self, gate, status="passed", exit_code=0):
        return cigates.GateResult(
            name=gate.name,
            command=list(gate.command),
            status=status,
            exit_code=exit_code,
            started_at="2026-09-15T00:00:00.000+00:00",
            ended_at="2026-09-15T00:00:00.010+00:00",
            duration_ms=10,
            stdout_sha256="0" * 64,
            stderr_sha256="0" * 64,
            stdout_line_count=0,
            stderr_line_count=0,
        )

    def context(self):
        return {
            "commit": "a" * 40,
            "pythonVersion": "3.9.0",
            "swiftVersion": "Swift 6.2",
            "platform": "macOS",
            "machine": "arm64",
        }

    def test_happy_path_writes_machine_readable_report(self):
        executed = []

        def execute(gate, repository_root, timeout_seconds):
            executed.append(gate.name)
            return self.gate_result(gate)

        with tempfile.TemporaryDirectory() as temporary_directory:
            report = Path(temporary_directory) / "report.json"
            exit_code = cigates.run_pipeline(
                REPOSITORY_ROOT,
                report,
                timeout_seconds=30,
                execute_gate=execute,
                context_provider=self.context,
            )
            payload = json.loads(report.read_text())

        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["status"], "passed")
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["toolchain"]["machine"], "arm64")
        self.assertEqual(executed, [gate["name"] for gate in payload["gates"]])
        self.assertNotIn("stdout", payload["gates"][0])
        self.assertNotIn("stderr", payload["gates"][0])

    def test_failed_gate_blocks_and_marks_later_gates_not_run(self):
        calls = []

        def execute(gate, repository_root, timeout_seconds):
            calls.append(gate.name)
            if len(calls) == 2:
                return self.gate_result(gate, status="failed", exit_code=7)
            return self.gate_result(gate)

        with tempfile.TemporaryDirectory() as temporary_directory:
            report = Path(temporary_directory) / "report.json"
            exit_code = cigates.run_pipeline(
                REPOSITORY_ROOT,
                report,
                timeout_seconds=30,
                execute_gate=execute,
                context_provider=self.context,
            )
            payload = json.loads(report.read_text())

        self.assertEqual(exit_code, 1)
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["gates"][1]["exitCode"], 7)
        self.assertTrue(
            all(gate["status"] == "not-run" for gate in payload["gates"][2:])
        )
        self.assertEqual(len(calls), 2)

    def test_timeout_terminates_process_group(self):
        process = mock.Mock(pid=321, returncode=-signal.SIGTERM)
        process.communicate.side_effect = [
            subprocess.TimeoutExpired(["slow"], 1),
            ("", ""),
        ]
        process.wait.return_value = 0

        with mock.patch.object(cigates.subprocess, "Popen", return_value=process), mock.patch.object(
            cigates.os, "killpg"
        ) as killpg:
            result = cigates.run_gate(
                cigates.GateSpec("slow", ("slow",)), REPOSITORY_ROOT, 1
            )

        self.assertEqual(result.status, "timed-out")
        self.assertIsNone(result.exit_code)
        killpg.assert_any_call(321, signal.SIGTERM)

    def test_cancellation_terminates_process_group_and_propagates(self):
        process = mock.Mock(pid=654, returncode=-signal.SIGTERM)
        process.communicate.side_effect = KeyboardInterrupt
        process.wait.return_value = 0

        with mock.patch.object(cigates.subprocess, "Popen", return_value=process), mock.patch.object(
            cigates.os, "killpg"
        ) as killpg:
            with self.assertRaises(KeyboardInterrupt):
                cigates.run_gate(
                    cigates.GateSpec("cancel", ("cancel",)), REPOSITORY_ROOT, 1
                )

        killpg.assert_any_call(654, signal.SIGTERM)

    def test_pipeline_cancellation_writes_report_and_returns_130(self):
        def execute(gate, repository_root, timeout_seconds):
            raise KeyboardInterrupt

        with tempfile.TemporaryDirectory() as temporary_directory:
            report = Path(temporary_directory) / "report.json"
            exit_code = cigates.run_pipeline(
                REPOSITORY_ROOT,
                report,
                timeout_seconds=30,
                execute_gate=execute,
                context_provider=self.context,
            )
            payload = json.loads(report.read_text())

        self.assertEqual(exit_code, 130)
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["gates"][0]["status"], "cancelled")
        self.assertTrue(
            all(gate["status"] == "not-run" for gate in payload["gates"][1:])
        )

    def test_main_routes_sigterm_through_cancellation_cleanup(self):
        previous_handler = object()

        with mock.patch.object(
            cigates.signal,
            "signal",
            side_effect=[previous_handler, previous_handler],
        ) as install_handler, mock.patch.object(
            cigates, "run_pipeline", return_value=0
        ):
            exit_code = cigates.main(
                [
                    "--repository-root",
                    str(REPOSITORY_ROOT),
                    "--report",
                    "artifacts/ci/test-report.json",
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            install_handler.call_args_list,
            [
                mock.call(signal.SIGTERM, cigates.handle_termination_signal),
                mock.call(signal.SIGTERM, previous_handler),
            ],
        )

    def test_missing_repository_root_returns_typed_exit(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing = Path(temporary_directory) / "missing"
            exit_code = cigates.main(
                ["--repository-root", str(missing), "--report", "report.json"]
            )

        self.assertEqual(exit_code, 66)

    def test_non_positive_timeout_returns_usage_exit(self):
        exit_code = cigates.main(
            [
                "--repository-root",
                str(REPOSITORY_ROOT),
                "--report",
                "report.json",
                "--timeout-seconds",
                "0",
            ]
        )

        self.assertEqual(exit_code, 64)

    def test_workflow_is_arm64_read_only_and_uses_node24_actions(self):
        workflow = (REPOSITORY_ROOT / ".github/workflows/m1-ci.yml").read_text()

        self.assertIn("pull_request:", workflow)
        self.assertIn("push:", workflow)
        self.assertIn("runs-on: macos-15", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("/Applications/Xcode_26.2.app/Contents/Developer", workflow)
        self.assertIn("make verify", workflow)
        self.assertIn("if: always()", workflow)
        self.assertIn("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", workflow)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", workflow)

    def test_make_verify_and_canonical_backlog_path_exist(self):
        makefile = (REPOSITORY_ROOT / "Makefile").read_text()
        canonical_validator = REPOSITORY_ROOT / "Tools/Backlog/validate_package.py"

        self.assertIn("verify:", makefile)
        self.assertIn("Tools/cigates/cigates.py", makefile)
        self.assertTrue(canonical_validator.is_file())


if __name__ == "__main__":
    unittest.main()
