import importlib.util
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPOSITORY_ROOT / "Tools/docs-check/docs-check.py"

spec = importlib.util.spec_from_file_location("docs_check", MODULE_PATH)
docs_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docs_check)


class DocsCheckTests(unittest.TestCase):
    def test_current_repository_passes(self):
        self.assertEqual(docs_check.scan_repository(REPOSITORY_ROOT), [])

    def test_valid_markdown_and_json_pass(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "doc.md").write_text("# Title\n\n```text\nvalue\n```\n")
            (root / "data.json").write_text('{"value": 1}\n')

            violations = docs_check.scan_repository(
                root, tracked_paths=(Path("doc.md"), Path("data.json"))
            )

        self.assertEqual(violations, [])

    def test_markdown_whitespace_and_newline_rules_fail(self):
        cases = {
            "trailing.md": (b"# Title  \n", "markdown-trailing-whitespace"),
            "crlf.md": (b"# Title\r\n", "markdown-non-lf-newline"),
            "missing.md": (b"# Title", "markdown-final-newline"),
            "extra.md": (b"# Title\n\n", "markdown-final-newline"),
        }
        for name, (content, expected_rule) in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                path = root / name
                path.write_bytes(content)

                violations = docs_check.scan_repository(
                    root, tracked_paths=(Path(name),)
                )

            self.assertIn(expected_rule, [item.rule for item in violations])

    def test_unbalanced_fence_fails_at_opening_line(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "doc.md").write_text("# Title\n\n```swift\nlet x = 1\n")

            violations = docs_check.scan_repository(
                root, tracked_paths=(Path("doc.md"),)
            )

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "markdown-unbalanced-fence")
        self.assertEqual(violations[0].line, 3)

    def test_invalid_utf8_fails_without_logging_content(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "doc.md").write_bytes(b"\xff\xfe\n")

            violations = docs_check.scan_repository(
                root, tracked_paths=(Path("doc.md"),)
            )

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "invalid-utf8")
        self.assertNotIn("ff", docs_check.format_violation(violations[0]))

    def test_invalid_and_duplicate_key_json_fail(self):
        cases = {
            "invalid.json": ("{\n", "json-invalid"),
            "duplicate.json": ('{"value": 1, "value": 2}\n', "json-duplicate-key"),
        }
        for name, (content, expected_rule) in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                (root / name).write_text(content)

                violations = docs_check.scan_repository(
                    root, tracked_paths=(Path(name),)
                )

            self.assertEqual(len(violations), 1)
            self.assertEqual(violations[0].rule, expected_rule)

    def test_missing_and_symlinked_tracked_files_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            outside = root / "outside.md"
            outside.write_text("# Outside\n")
            (root / "linked.md").symlink_to(outside)

            violations = docs_check.scan_repository(
                root,
                tracked_paths=(Path("missing.md"), Path("linked.md")),
            )

        self.assertEqual(
            [item.rule for item in violations],
            ["tracked-file-symlink", "tracked-file-missing"],
        )

    def test_git_failure_is_typed_without_replaying_stderr(self):
        process = mock.Mock(returncode=2)
        process.communicate.return_value = (b"", b"private git detail")

        with mock.patch.object(docs_check.subprocess, "Popen", return_value=process):
            with self.assertRaises(docs_check.DocsCheckError) as context:
                docs_check.list_tracked_files(REPOSITORY_ROOT, 10)

        self.assertEqual(str(context.exception), "git-ls-files-failed")

    def test_git_timeout_and_cancellation_clean_up_process_group(self):
        for side_effect in (
            subprocess.TimeoutExpired(["git"], 1),
            KeyboardInterrupt(),
        ):
            with self.subTest(effect=type(side_effect).__name__):
                process = mock.Mock(pid=321, returncode=-signal.SIGTERM)
                process.communicate.side_effect = side_effect
                process.wait.return_value = 0
                with mock.patch.object(
                    docs_check.subprocess, "Popen", return_value=process
                ), mock.patch.object(docs_check.os, "killpg") as killpg:
                    with self.assertRaises((docs_check.DocsCheckError, KeyboardInterrupt)):
                        docs_check.list_tracked_files(REPOSITORY_ROOT, 1)
                killpg.assert_any_call(321, signal.SIGTERM)

    def test_missing_root_and_invalid_timeout_are_typed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing = Path(temporary_directory) / "missing"
            self.assertEqual(docs_check.main(["--repository-root", str(missing)]), 66)
        self.assertEqual(
            docs_check.main(
                ["--repository-root", str(REPOSITORY_ROOT), "--timeout-seconds", "0"]
            ),
            64,
        )

    def test_main_handles_cancellation_and_restores_sigterm(self):
        previous_handler = object()
        with mock.patch.object(
            docs_check.signal,
            "signal",
            side_effect=[previous_handler, previous_handler],
        ) as install_handler, mock.patch.object(
            docs_check, "scan_repository", side_effect=KeyboardInterrupt
        ):
            exit_code = docs_check.main(
                ["--repository-root", str(REPOSITORY_ROOT)]
            )

        self.assertEqual(exit_code, 130)
        self.assertEqual(
            install_handler.call_args_list,
            [
                mock.call(signal.SIGTERM, docs_check.handle_termination_signal),
                mock.call(signal.SIGTERM, previous_handler),
            ],
        )

    def test_make_and_ci_run_docs_command_and_unit_suite(self):
        makefile = (REPOSITORY_ROOT / "Makefile").read_text()
        ci_gate = (REPOSITORY_ROOT / "Tools/cigates/cigates.py").read_text()

        self.assertIn("docs-check:", makefile)
        self.assertIn("Tools/docs-check/docs-check.py", makefile)
        self.assertIn('"docs-check"', ci_gate)
        self.assertIn('"docs-check-unit-tests"', ci_gate)
        self.assertIn('"Tools/docs-check/tests"', ci_gate)


if __name__ == "__main__":
    unittest.main()
