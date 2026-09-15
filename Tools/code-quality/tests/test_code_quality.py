import importlib.util
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPOSITORY_ROOT / "Tools/code-quality/code-quality.py"

spec = importlib.util.spec_from_file_location("code_quality", MODULE_PATH)
code_quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(code_quality)


class CodeQualityTests(unittest.TestCase):
    def result(self, command, stdout="", stderr="", exit_code=0):
        return code_quality.CommandResult(
            command=list(command),
            exit_code=exit_code,
            stdout=stdout,
            stderr=stderr,
        )

    def test_happy_path_uses_pinned_formatter_and_warnings_as_errors(self):
        commands = []

        def execute(command, repository_root, timeout_seconds):
            commands.append(tuple(command))
            stdout = "6.2.3\n" if command == ("swift", "format", "--version") else ""
            return self.result(command, stdout=stdout)

        exit_code = code_quality.run_quality_checks(
            REPOSITORY_ROOT, timeout_seconds=30, execute=execute
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(commands[0], ("swift", "format", "--version"))
        self.assertIn("--strict", commands[1])
        self.assertIn("--recursive", commands[1])
        self.assertEqual(
            commands[2], ("swift", "test", "-Xswiftc", "-warnings-as-errors")
        )

    def test_formatter_version_mismatch_fails_before_lint_or_build(self):
        commands = []

        def execute(command, repository_root, timeout_seconds):
            commands.append(tuple(command))
            return self.result(command, stdout="6.2.2\n")

        exit_code = code_quality.run_quality_checks(
            REPOSITORY_ROOT, timeout_seconds=30, execute=execute
        )

        self.assertEqual(exit_code, 1)
        self.assertEqual(commands, [("swift", "format", "--version")])

    def test_lint_failure_blocks_warnings_build(self):
        commands = []

        def execute(command, repository_root, timeout_seconds):
            commands.append(tuple(command))
            if len(commands) == 1:
                return self.result(command, stdout="6.2.3\n")
            return self.result(command, stderr="format finding", exit_code=1)

        exit_code = code_quality.run_quality_checks(
            REPOSITORY_ROOT, timeout_seconds=30, execute=execute
        )

        self.assertEqual(exit_code, 1)
        self.assertEqual(len(commands), 2)

    def test_warnings_build_failure_is_not_ignored(self):
        calls = 0

        def execute(command, repository_root, timeout_seconds):
            nonlocal calls
            calls += 1
            if calls == 1:
                return self.result(command, stdout="6.2.3\n")
            if calls == 3:
                return self.result(command, stderr="warning promoted", exit_code=1)
            return self.result(command)

        exit_code = code_quality.run_quality_checks(
            REPOSITORY_ROOT, timeout_seconds=30, execute=execute
        )

        self.assertEqual(exit_code, 1)
        self.assertEqual(calls, 3)

    def test_timeout_terminates_process_group(self):
        process = mock.Mock(pid=321, returncode=-signal.SIGTERM)
        process.communicate.side_effect = [
            subprocess.TimeoutExpired(["slow"], 1),
            ("", ""),
        ]
        process.wait.return_value = 0

        with mock.patch.object(
            code_quality.subprocess, "Popen", return_value=process
        ), mock.patch.object(code_quality.os, "killpg") as killpg:
            result = code_quality.execute_command(("slow",), REPOSITORY_ROOT, 1)

        self.assertEqual(result.exit_code, code_quality.EXIT_TIMEOUT)
        killpg.assert_any_call(321, signal.SIGTERM)

    def test_cancellation_terminates_process_group_and_propagates(self):
        process = mock.Mock(pid=654, returncode=-signal.SIGTERM)
        process.communicate.side_effect = KeyboardInterrupt
        process.wait.return_value = 0

        with mock.patch.object(
            code_quality.subprocess, "Popen", return_value=process
        ), mock.patch.object(code_quality.os, "killpg") as killpg:
            with self.assertRaises(KeyboardInterrupt):
                code_quality.execute_command(("cancel",), REPOSITORY_ROOT, 1)

        killpg.assert_any_call(654, signal.SIGTERM)

    def test_missing_repository_root_and_invalid_timeout_are_typed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing = Path(temporary_directory) / "missing"
            self.assertEqual(
                code_quality.main(["--repository-root", str(missing)]), 66
            )
        self.assertEqual(
            code_quality.main(
                ["--repository-root", str(REPOSITORY_ROOT), "--timeout-seconds", "0"]
            ),
            64,
        )

    def test_main_installs_and_restores_sigterm_handler(self):
        previous_handler = object()

        with mock.patch.object(
            code_quality.signal,
            "signal",
            side_effect=[previous_handler, previous_handler],
        ) as install_handler, mock.patch.object(
            code_quality, "run_quality_checks", return_value=0
        ):
            exit_code = code_quality.main(
                ["--repository-root", str(REPOSITORY_ROOT)]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            install_handler.call_args_list,
            [
                mock.call(signal.SIGTERM, code_quality.handle_termination_signal),
                mock.call(signal.SIGTERM, previous_handler),
            ],
        )

    def test_make_and_ci_use_the_same_code_quality_entrypoint(self):
        makefile = (REPOSITORY_ROOT / "Makefile").read_text()
        ci_gate = (REPOSITORY_ROOT / "Tools/cigates/cigates.py").read_text()

        self.assertIn("code-quality-check:", makefile)
        self.assertIn("Tools/code-quality/code-quality.py", makefile)
        self.assertIn('"code-quality"', ci_gate)
        self.assertIn(
            '("python3", "Tools/code-quality/code-quality.py")', ci_gate
        )


if __name__ == "__main__":
    unittest.main()
