import hashlib
import importlib.util
import io
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPOSITORY_ROOT / "Tools/Evidence/run_e2e.py"
ISSUE = "M1-999"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
SCRIPT_RELATIVE = "Tests/SystemTests/Scripts/M1-999-linux-e2e.sh"
RESULT_RELATIVE = "evidence/e2e/M1-999/result.json"


def load_tool():
    specification = importlib.util.spec_from_file_location("run_e2e_under_test", TOOL_PATH)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


run_e2e = load_tool()


def result_document(status="passed", issue=ISSUE):
    exit_codes = {"passed": 0, "failed": 1, "timed_out": None, "cancelled": None}
    document = {
        "schemaVersion": 1,
        "issueId": issue,
        "status": status,
        "startedAt": "2026-09-29T01:02:03Z",
        "endedAt": "2026-09-29T01:03:03Z",
        "commit": COMMIT,
        "toolchain": {"pythonVersion": "3.12.4", "platform": "Linux", "machine": "x86_64"},
        "environment": {
            "localOS": "macOS 26.6",
            "peerProduct": "Barrier",
            "peerVersion": "2.4.0",
            "peerRole": "server",
            "peerOS": "Linux",
            "networkScope": "isolated-lab-lan",
            "tls": "enabled",
        },
        "cases": [],
        "artifacts": [],
        "privacy": {
            "containsSensitiveData": False,
            "containsTypedText": False,
            "containsClipboardPayload": False,
            "containsCredentials": False,
            "containsKeyMaterial": False,
            "containsHostnames": False,
            "containsIPAddresses": False,
            "rawCaptureCommitted": False,
            "sanitizationReviewed": True,
        },
        "approvedDecisionRef": None,
    }
    if status == "not_executed":
        document["approvedDecisionRef"] = "docs/adr/M1-SCOPE-001-linux-only-validation.md"
    else:
        document["cases"] = [
            {
                "id": "linux-server-session",
                "status": status,
                "exitCode": exit_codes[status],
                "evidence": ["Terminal state recorded by the E2E script"],
            }
        ]
    return document


class FakeProcess:
    pid = 424242

    def __init__(self, owner):
        self.owner = owner
        self.returncode = None
        self.wait_calls = 0
        self.direct_calls = []
        self.stdout = io.BytesIO(owner.stdout)
        self.stderr = io.BytesIO(owner.stderr)

    def wait(self, timeout=None):
        self.wait_calls += 1
        if self.wait_calls == 1:
            if self.owner.wait_error is not None:
                raise self.owner.wait_error
            self.returncode = self.owner.returncode
        elif self.returncode is None:
            self.returncode = -signal.SIGTERM
        return self.returncode

    def terminate(self):
        self.direct_calls.append("terminate")

    def kill(self):
        self.direct_calls.append("kill")


class FakePopen:
    def __init__(
        self,
        action=None,
        returncode=0,
        stdout=b"",
        stderr=b"",
        wait_error=None,
    ):
        self.action = action
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.wait_error = wait_error
        self.calls = []
        self.processes = []

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if self.action is not None:
            self.action()
        process = FakeProcess(self)
        self.processes.append(process)
        return process


class RunnerTestCase(unittest.TestCase):
    def setUp(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        self.root = Path(temporary_directory.name).resolve()
        self.script_root = self.root / "Tests/SystemTests/Scripts"
        self.script_root.mkdir(parents=True)
        self.result_path = self.root / RESULT_RELATIVE

    def write_script(self, name="M1-999-linux-e2e.sh", body="exit 0\n"):
        path = self.script_root / name
        path.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
        return path

    def write_result(self, document=None, raw=None):
        self.result_path.parent.mkdir(parents=True, exist_ok=True)
        if raw is None:
            raw = json.dumps(result_document() if document is None else document)
        self.result_path.write_text(raw, encoding="utf-8")

    def writer(self, document=None, raw=None):
        return lambda: self.write_result(document, raw)

    def run_runner(self, popen, issue=ISSUE, timeout_seconds=30):
        out = io.StringIO()
        err = io.StringIO()
        exit_code = run_e2e.run(
            issue,
            repository_root=self.root,
            timeout_seconds=timeout_seconds,
            popen=popen,
            commit_provider=lambda root: COMMIT,
            out=out,
            err=err,
        )
        return exit_code, out.getvalue(), err.getvalue()

    def assert_terminal(self, stdout, disposition, exit_code):
        lines = stdout.splitlines()
        self.assertEqual(
            lines[-2:],
            ["e2e disposition: {0}".format(disposition), "e2e exit: {0}".format(exit_code)],
        )


class IssueValidationTests(RunnerTestCase):
    def test_invalid_issue_is_rejected_before_path_resolution(self):
        self.write_script()
        for issue in (
            "",
            "M1-24",
            "M6-001",
            "m1-999",
            "M1-999\n",
            "../M1-999",
            "M1-999/../x",
            "M1-999'; touch pwned; '",
            "M1-*",
            None,
        ):
            with self.subTest(issue=issue):
                popen = FakePopen()
                exit_code, stdout, stderr = self.run_runner(popen, issue=issue)
                self.assertEqual(exit_code, 64)
                self.assertEqual(popen.calls, [])
                self.assertEqual(stderr, "e2e error: invalid_issue\n")
                self.assertEqual(stdout, "e2e disposition: error\ne2e exit: 64\n")
        self.assertFalse((self.root / "pwned").exists())


class ScriptResolutionTests(RunnerTestCase):
    def assert_resolution_error(self, code, exit_code):
        popen = FakePopen()
        result = self.run_runner(popen)
        self.assertEqual(result[0], exit_code)
        self.assertEqual(result[2], "e2e error: {0}\n".format(code))
        self.assert_terminal(result[1], "error", exit_code)
        self.assertEqual(popen.calls, [])

    def test_zero_scripts(self):
        self.write_script(name="M1-998-other.sh")
        self.write_script(name="M1-9990-other.sh")
        self.write_script(name="M1-999-notes.txt")
        self.assert_resolution_error("script_missing", 66)

    def test_multiple_scripts(self):
        self.write_script(name="M1-999-a.sh")
        self.write_script(name="M1-999-b.sh")
        self.assert_resolution_error("script_ambiguous", 65)

    def test_symlink_script(self):
        target = self.root / "outside.sh"
        target.write_text("exit 0\n", encoding="utf-8")
        (self.script_root / "M1-999-link.sh").symlink_to(target)
        self.assert_resolution_error("script_symlink", 77)

    def test_directory_named_like_script(self):
        (self.script_root / "M1-999-dir.sh").mkdir()
        self.assert_resolution_error("script_not_regular_file", 77)

    def test_unsafe_script_name(self):
        self.write_script(name="M1-999-has space.sh")
        self.assert_resolution_error("script_name_invalid", 65)

    def test_missing_script_root(self):
        shutil.rmtree(self.root / "Tests")
        self.assert_resolution_error("script_root_missing", 66)

    def test_symlinked_script_root(self):
        real = self.root / "real-scripts"
        real.mkdir()
        (real / "M1-999-linux-e2e.sh").write_text("exit 0\n", encoding="utf-8")
        shutil.rmtree(self.script_root)
        self.script_root.symlink_to(real, target_is_directory=True)
        self.assert_resolution_error("script_root_symlink", 77)

    def test_symlinked_script_root_ancestor(self):
        real = self.root / "real-system-tests"
        (real / "Scripts").mkdir(parents=True)
        (real / "Scripts/M1-999-linux-e2e.sh").write_text("exit 0\n", encoding="utf-8")
        shutil.rmtree(self.root / "Tests/SystemTests")
        (self.root / "Tests/SystemTests").symlink_to(real, target_is_directory=True)
        self.assert_resolution_error("script_root_symlink", 77)

    def test_script_resolving_outside_root(self):
        self.write_script()
        real_realpath = os.path.realpath

        def fake_realpath(path, *args, **kwargs):
            if Path(path).name == "M1-999-linux-e2e.sh":
                return "/elsewhere/M1-999-linux-e2e.sh"
            return real_realpath(path, *args, **kwargs)

        with mock.patch.object(run_e2e.os.path, "realpath", side_effect=fake_realpath):
            self.assert_resolution_error("script_outside_root", 77)


class ExecutionTests(RunnerTestCase):
    def test_valid_passed_result(self):
        self.write_script()
        popen = FakePopen(action=self.writer())
        exit_code, stdout, stderr = self.run_runner(popen)
        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr, "")
        empty_digest = hashlib.sha256(b"").hexdigest()
        self.assertEqual(
            stdout.splitlines(),
            [
                "e2e runner version: 1",
                "e2e issue: M1-999",
                "e2e commit: " + COMMIT,
                "e2e python: " + platform.python_version(),
                "e2e script: " + SCRIPT_RELATIVE,
                "e2e stdout: lines=0 sha256=" + empty_digest,
                "e2e stderr: lines=0 sha256=" + empty_digest,
                "e2e script exit: 0",
                "e2e disposition: passed",
                "e2e exit: 0",
            ],
        )

    def test_uses_bash_argv_without_shell(self):
        self.write_script()
        popen = FakePopen(action=self.writer())
        self.run_runner(popen, timeout_seconds=17)
        self.assertEqual(len(popen.calls), 1)
        args, kwargs = popen.calls[0]
        self.assertEqual(args, ["bash", SCRIPT_RELATIVE])
        self.assertNotIn("shell", kwargs)
        self.assertEqual(kwargs["cwd"], str(self.root))
        self.assertIs(kwargs["start_new_session"], True)
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(kwargs["stderr"], subprocess.PIPE)
        self.assertEqual(kwargs["env"]["MACKVM_E2E_ISSUE"], ISSUE)
        self.assertEqual(kwargs["env"]["MACKVM_E2E_RESULT"], RESULT_RELATIVE)

    def test_timeout_is_bounded_and_forwarded(self):
        self.write_script()
        observed = []

        class RecordingProcess(FakeProcess):
            def wait(self, timeout=None):
                observed.append(timeout)
                return super().wait(timeout)

        popen = FakePopen(action=self.writer())

        def recording_popen(args, **kwargs):
            popen.action()
            return RecordingProcess(popen)

        self.run_runner(recording_popen, timeout_seconds=17)
        self.assertEqual(observed, [17])

    def test_no_raw_output_replay(self):
        self.write_script()
        stdout_bytes = b"RAW-STDOUT-MARKER typed text\nsecond line\n"
        stderr_bytes = b"RAW-STDERR-MARKER clipboard"
        popen = FakePopen(action=self.writer(), stdout=stdout_bytes, stderr=stderr_bytes)
        exit_code, stdout, stderr = self.run_runner(popen)
        self.assertEqual(exit_code, 0)
        combined = stdout + stderr
        for marker in ("RAW-STDOUT-MARKER", "RAW-STDERR-MARKER", "typed text", "clipboard"):
            self.assertNotIn(marker, combined)
        self.assertIn(
            "e2e stdout: lines=2 sha256=" + hashlib.sha256(stdout_bytes).hexdigest(),
            stdout,
        )
        self.assertIn(
            "e2e stderr: lines=1 sha256=" + hashlib.sha256(stderr_bytes).hexdigest(),
            stdout,
        )

    def test_script_failure_with_passed_result_is_nonzero(self):
        self.write_script()
        for returncode, expected in ((3, 3), (125, 125), (126, 1), (200, 1), (-9, 1)):
            with self.subTest(returncode=returncode):
                popen = FakePopen(action=self.writer(), returncode=returncode)
                exit_code, stdout, _ = self.run_runner(popen)
                self.assertEqual(exit_code, expected)
                self.assertNotIn("passed", stdout)
                self.assert_terminal(stdout, "script_failed", expected)

    def test_missing_result(self):
        self.write_script()
        exit_code, stdout, stderr = self.run_runner(FakePopen())
        self.assertEqual(exit_code, 66)
        self.assertEqual(stderr, "e2e error: result_missing\n")
        self.assert_terminal(stdout, "error", 66)

    def test_stale_result_is_rejected(self):
        self.write_script()
        self.write_result()
        exit_code, stdout, stderr = self.run_runner(FakePopen())
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "e2e error: result_not_updated\n")
        self.assertNotIn("passed", stdout)

    def test_rewritten_result_is_accepted(self):
        self.write_script()
        self.write_result(result_document("failed"))

        def rewrite():
            time.sleep(0.01)
            self.write_result()

        exit_code, stdout, _ = self.run_runner(FakePopen(action=rewrite))
        self.assertEqual(exit_code, 0)
        self.assert_terminal(stdout, "passed", 0)

    def test_retained_failure_statuses_are_nonzero(self):
        self.write_script()
        for status, expected in (("failed", 1), ("timed_out", 124), ("cancelled", 130)):
            with self.subTest(status=status):
                if self.result_path.exists():
                    self.result_path.unlink()
                popen = FakePopen(action=self.writer(result_document(status)))
                exit_code, stdout, _ = self.run_runner(popen)
                self.assertEqual(exit_code, expected)
                self.assert_terminal(stdout, status, expected)
                self.assertNotIn("passed", stdout)

    def test_not_executed_with_decision_is_disposition_gate(self):
        self.write_script()
        popen = FakePopen(action=self.writer(result_document("not_executed")))
        exit_code, stdout, stderr = self.run_runner(popen)
        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr, "")
        self.assert_terminal(stdout, "not_executed", 0)
        self.assertNotIn("passed", stdout)

    def test_not_executed_without_decision_is_invalid(self):
        self.write_script()
        document = result_document("not_executed")
        document["approvedDecisionRef"] = None
        exit_code, stdout, stderr = self.run_runner(FakePopen(action=self.writer(document)))
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "e2e error: approved_decision_ref_missing\n")
        self.assertNotIn("not_executed", stdout)
        self.assertNotIn("passed", stdout)

    def test_invalid_result_is_rejected(self):
        self.write_script()
        document = result_document()
        document["unexpected"] = "UNTRUSTED-VALUE"
        exit_code, stdout, stderr = self.run_runner(FakePopen(action=self.writer(document)))
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "e2e error: result_unknown_field\n")
        self.assertNotIn("UNTRUSTED-VALUE", stdout + stderr)

    def test_malformed_result_json(self):
        self.write_script()
        exit_code, _, stderr = self.run_runner(FakePopen(action=self.writer(raw="{")))
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "e2e error: invalid_json\n")

    def test_result_for_wrong_issue(self):
        self.write_script()
        popen = FakePopen(action=self.writer(result_document(issue="M1-998")))
        exit_code, _, stderr = self.run_runner(popen)
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "e2e error: issue_mismatch\n")

    def test_symlink_result(self):
        self.write_script()

        def write_symlink():
            real = self.root / "elsewhere.json"
            real.write_text(json.dumps(result_document()), encoding="utf-8")
            self.result_path.parent.mkdir(parents=True, exist_ok=True)
            self.result_path.symlink_to(real)

        exit_code, _, stderr = self.run_runner(FakePopen(action=write_symlink))
        self.assertEqual(exit_code, 77)
        self.assertEqual(stderr, "e2e error: result_symlink\n")

    def test_symlink_result_directory(self):
        self.write_script()

        def write_symlink_directory():
            real = self.root / "elsewhere"
            real.mkdir()
            (real / "result.json").write_text(
                json.dumps(result_document()), encoding="utf-8"
            )
            (self.root / "evidence/e2e").mkdir(parents=True)
            (self.root / "evidence/e2e" / ISSUE).symlink_to(real, target_is_directory=True)

        exit_code, _, stderr = self.run_runner(FakePopen(action=write_symlink_directory))
        self.assertEqual(exit_code, 77)
        self.assertEqual(stderr, "e2e error: result_symlink\n")

    def test_runner_does_not_modify_evidence(self):
        self.write_script()
        popen = FakePopen(action=self.writer())
        self.run_runner(popen)
        written = self.result_path.read_bytes()
        status = os.stat(self.result_path)
        self.assertEqual(written, json.dumps(result_document()).encode("utf-8"))
        self.assertEqual(sorted(p.name for p in self.result_path.parent.iterdir()), ["result.json"])
        self.assertEqual(os.stat(self.result_path).st_mtime_ns, status.st_mtime_ns)

    def test_bash_unavailable(self):
        self.write_script()

        def missing_bash(args, **kwargs):
            raise FileNotFoundError("bash")

        exit_code, stdout, stderr = self.run_runner(missing_bash)
        self.assertEqual(exit_code, 66)
        self.assertEqual(stderr, "e2e error: bash_unavailable\n")
        self.assert_terminal(stdout, "error", 66)


class TerminationTests(RunnerTestCase):
    def test_timeout_terminates_process_group(self):
        self.write_script()
        popen = FakePopen(
            action=self.writer(),
            wait_error=subprocess.TimeoutExpired(["bash"], 5),
            stdout=b"partial\n",
        )
        with mock.patch.object(run_e2e.os, "killpg") as killpg:
            exit_code, stdout, _ = self.run_runner(popen, timeout_seconds=5)
        self.assertEqual(exit_code, 124)
        killpg.assert_called_once_with(FakeProcess.pid, signal.SIGTERM)
        self.assertIn("e2e script exit: none", stdout)
        self.assertIn("e2e stdout: lines=1 sha256=", stdout)
        self.assert_terminal(stdout, "timed_out", 124)
        self.assertNotIn("passed", stdout)

    def test_cancellation_terminates_process_group(self):
        self.write_script()
        popen = FakePopen(action=self.writer(), wait_error=KeyboardInterrupt())
        with mock.patch.object(run_e2e.os, "killpg") as killpg:
            exit_code, stdout, stderr = self.run_runner(popen)
        self.assertEqual(exit_code, 130)
        killpg.assert_called_once_with(FakeProcess.pid, signal.SIGTERM)
        self.assertEqual(stderr, "e2e error: cancelled\n")
        self.assert_terminal(stdout, "cancelled", 130)
        self.assertNotIn("passed", stdout)

    def test_termination_escalates_to_sigkill(self):
        class StubbornProcess:
            pid = 515151

            def __init__(self):
                self.waits = 0

            def wait(self, timeout=None):
                self.waits += 1
                if self.waits == 1:
                    raise subprocess.TimeoutExpired(["bash"], timeout)
                return -9

        with mock.patch.object(run_e2e.os, "killpg") as killpg:
            run_e2e.terminate_process_group(StubbornProcess())
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(515151, signal.SIGTERM), mock.call(515151, signal.SIGKILL)],
        )

    def test_real_timeout_kills_background_children(self):
        if shutil.which("bash") is None:
            self.skipTest("bash unavailable")
        self.write_script(body="sleep 60 &\necho $! > child.pid\nwait\n")
        exit_code, stdout, _ = self.run_runner(subprocess.Popen, timeout_seconds=1)
        self.assertEqual(exit_code, 124)
        self.assert_terminal(stdout, "timed_out", 124)
        child_pid = int((self.root / "child.pid").read_text(encoding="utf-8"))
        deadline = time.monotonic() + 5
        alive = True
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                alive = False
                break
            time.sleep(0.05)
        self.assertFalse(alive)

    def test_real_script_failure_with_passed_result(self):
        if shutil.which("bash") is None:
            self.skipTest("bash unavailable")
        template = self.root / "template.json"
        template.write_text(json.dumps(result_document()), encoding="utf-8")
        self.write_script(
            body=(
                'mkdir -p "$(dirname "$MACKVM_E2E_RESULT")"\n'
                'cp template.json "$MACKVM_E2E_RESULT"\n'
                "echo RAW-REAL-OUTPUT\n"
                "exit 7\n"
            )
        )
        exit_code, stdout, stderr = self.run_runner(subprocess.Popen)
        self.assertEqual(exit_code, 7)
        self.assertTrue(self.result_path.is_file())
        self.assertNotIn("RAW-REAL-OUTPUT", stdout + stderr)
        self.assertIn("e2e stdout: lines=1 sha256=", stdout)
        self.assert_terminal(stdout, "script_failed", 7)

    def test_real_passing_script(self):
        if shutil.which("bash") is None:
            self.skipTest("bash unavailable")
        template = self.root / "template.json"
        template.write_text(json.dumps(result_document()), encoding="utf-8")
        self.write_script(
            body=(
                'mkdir -p "$(dirname "$MACKVM_E2E_RESULT")"\n'
                'cp template.json "$MACKVM_E2E_RESULT"\n'
            )
        )
        exit_code, stdout, stderr = self.run_runner(subprocess.Popen)
        self.assertEqual(exit_code, 0, stderr)
        self.assert_terminal(stdout, "passed", 0)


def wait_until_gone(probe, seconds=5):
    """Return True once `probe()` raises ProcessLookupError within `seconds`."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            probe()
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


def kill_group_quietly(pgid):
    """Test safety net: never leak a real process group past a failing test."""
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        pass


def retained_metadata(data, truncated):
    line_count = data.count(b"\n")
    if data and not data.endswith(b"\n"):
        line_count += 1
    text = "lines={0} sha256={1}".format(line_count, hashlib.sha256(data).hexdigest())
    return text + " capture=truncated" if truncated else text


class BoundedOutputTests(unittest.TestCase):
    def capture(self, stream, limit):
        overflows = []
        output = run_e2e.BoundedOutput(stream, limit, lambda: overflows.append(True))
        output.start()
        self.assertTrue(output.join(5))
        return output, overflows

    def test_over_limit_retains_only_limit_bytes(self):
        stream = io.BytesIO(b"A\n" * 20480)
        with mock.patch.object(run_e2e, "OUTPUT_CHUNK_BYTES", 1024):
            output, overflows = self.capture(stream, 4096)
        self.assertTrue(output.truncated)
        self.assertFalse(output.failed)
        self.assertEqual(overflows, [True])
        self.assertEqual(output.retained_bytes, 4096)
        # Reading stops at the first chunk that crosses the cap.
        self.assertLessEqual(stream.tell(), 4096 + 1024)
        self.assertEqual(output.describe(), retained_metadata(b"A\n" * 2048, True))

    def test_exactly_limit_is_not_truncated(self):
        output, overflows = self.capture(io.BytesIO(b"B" * 4096), 4096)
        self.assertFalse(output.truncated)
        self.assertEqual(overflows, [])
        self.assertEqual(output.describe(), retained_metadata(b"B" * 4096, False))

    def test_read_failure_is_recorded(self):
        class BrokenStream:
            def read1(self, size):
                raise OSError("/Users/private/path")

        output, overflows = self.capture(BrokenStream(), 4096)
        self.assertTrue(output.failed)
        self.assertEqual(overflows, [])

    def test_unstarted_reader_counts_as_drained(self):
        output = run_e2e.BoundedOutput(io.BytesIO(b"x"), 4096, lambda: None)
        self.assertTrue(output.join(0))


class OutputLimitTests(RunnerTestCase):
    def test_over_limit_output_fails_even_with_passed_result(self):
        self.write_script()
        flood = b"RAW-STDERR-FLOOD typed text\n" * 1000
        popen = FakePopen(action=self.writer(), stdout=b"ok\n", stderr=flood)
        with mock.patch.object(run_e2e, "MAX_OUTPUT_BYTES_PER_STREAM", 1024), \
                mock.patch.object(run_e2e.os, "killpg") as killpg:
            exit_code, stdout, stderr = self.run_runner(popen)
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "e2e error: output_limit_exceeded\n")
        self.assert_terminal(stdout, "error", 65)
        self.assertIn("e2e script exit: none", stdout)
        self.assertNotIn("passed", stdout)
        self.assertNotIn("RAW-STDERR-FLOOD", stdout + stderr)
        self.assertNotIn("typed text", stdout + stderr)
        self.assertIn("e2e stdout: " + retained_metadata(b"ok\n", False) + "\n", stdout)
        self.assertIn("e2e stderr: " + retained_metadata(flood[:1024], True) + "\n", stdout)
        self.assertIn(mock.call(FakeProcess.pid, signal.SIGKILL), killpg.call_args_list)
        self.assertIn(mock.call(FakeProcess.pid, signal.SIGTERM), killpg.call_args_list)
        self.assertIsNotNone(popen.processes[0].returncode)

    def test_output_capture_failure_is_nonzero_and_redacted(self):
        self.write_script()

        class BrokenStream:
            def read1(self, size):
                raise OSError("/Users/private/path")

            def close(self):
                pass

        popen = FakePopen(action=self.writer())

        def broken_popen(args, **kwargs):
            process = popen(args, **kwargs)
            process.stdout = BrokenStream()
            return process

        with mock.patch.object(run_e2e.os, "killpg") as killpg:
            exit_code, stdout, stderr = self.run_runner(broken_popen)
        killpg.assert_called_once_with(FakeProcess.pid, signal.SIGTERM)
        self.assertEqual(exit_code, 70)
        self.assertEqual(stderr, "e2e error: output_capture_failed\n")
        self.assert_terminal(stdout, "error", 70)
        self.assertNotIn("/Users/private/path", stdout + stderr)
        self.assertNotIn("passed", stdout)

    def test_real_over_limit_producer_kills_and_reaps_group(self):
        if shutil.which("bash") is None:
            self.skipTest("bash unavailable")
        limit = 65536
        template = self.root / "template.json"
        template.write_text(json.dumps(result_document()), encoding="utf-8")
        self.write_script(
            body=(
                'mkdir -p "$(dirname "$MACKVM_E2E_RESULT")"\n'
                'cp template.json "$MACKVM_E2E_RESULT"\n'
                "sleep 60 &\n"
                "echo $! > child.pid\n"
                "while :; do echo RAW-FLOOD-MARKER; done\n"
            )
        )
        processes = []

        def recording_popen(*args, **kwargs):
            process = subprocess.Popen(*args, **kwargs)
            processes.append(process)
            return process

        with mock.patch.object(run_e2e, "MAX_OUTPUT_BYTES_PER_STREAM", limit):
            exit_code, stdout, stderr = self.run_runner(recording_popen, timeout_seconds=60)
        self.assertEqual(exit_code, 65)
        self.assertEqual(stderr, "e2e error: output_limit_exceeded\n")
        self.assert_terminal(stdout, "error", 65)
        self.assertIn("e2e script exit: none", stdout)
        self.assertNotIn("passed", stdout)
        self.assertNotIn("RAW-FLOOD-MARKER", stdout + stderr)
        retained = (b"RAW-FLOOD-MARKER\n" * (limit // 17 + 1))[:limit]
        self.assertIn("e2e stdout: " + retained_metadata(retained, True) + "\n", stdout)
        self.assertIn("e2e stderr: " + retained_metadata(b"", False) + "\n", stdout)
        self.assertEqual(len(processes), 1)
        self.assertIsNotNone(processes[0].returncode)
        child_pid = int((self.root / "child.pid").read_text(encoding="utf-8"))
        self.assertTrue(wait_until_gone(lambda: os.kill(child_pid, 0)))
        self.assertTrue(wait_until_gone(lambda: os.killpg(processes[0].pid, 0)))

    def test_real_exited_leader_with_sigterm_ignoring_pipe_holder_is_killed(self):
        if shutil.which("bash") is None:
            self.skipTest("bash unavailable")
        # The leader exits at once; its background child keeps both pipes open
        # and ignores SIGTERM, so only a group SIGKILL can end the drain.
        self.write_script(
            body=(
                "( trap '' TERM; exec sleep 60 ) &\n"
                "echo $! > child.pid\n"
                "exit 0\n"
            )
        )
        processes = []
        readers = []

        def recording_popen(*args, **kwargs):
            process = subprocess.Popen(*args, **kwargs)
            processes.append(process)
            self.addCleanup(kill_group_quietly, process.pid)
            return process

        class RecordingOutput(run_e2e.BoundedOutput):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                readers.append(self)

        real_killpg = os.killpg
        at_cleanup_start = []

        def recording_killpg(pgid, group_signal):
            # Pin the scenario at the first cleanup signal: the leader is already
            # reaped while its child shares the group and still holds stdout.
            if not at_cleanup_start:
                child_pid = int((self.root / "child.pid").read_text(encoding="utf-8"))
                at_cleanup_start.append(
                    (processes[0].returncode, os.getpgid(child_pid), readers[0].join(0))
                )
            return real_killpg(pgid, group_signal)

        started = time.monotonic()
        with mock.patch.object(run_e2e, "BoundedOutput", RecordingOutput), \
                mock.patch.object(run_e2e.os, "killpg", side_effect=recording_killpg) as killpg:
            exit_code, stdout, _ = self.run_runner(recording_popen, timeout_seconds=1)
        elapsed = time.monotonic() - started
        self.assertLess(
            elapsed, 1 + run_e2e.TERMINATE_GRACE_SECONDS + run_e2e.DRAIN_TIMEOUT_SECONDS
        )
        self.assertEqual(exit_code, 124)
        self.assert_terminal(stdout, "timed_out", 124)
        self.assertEqual(len(processes), 1)
        self.assertEqual(at_cleanup_start, [(0, processes[0].pid, False)])
        # SIGTERM is ignored, so only the drain-driven SIGKILL can end the child.
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(processes[0].pid, signal.SIGTERM),
             mock.call(processes[0].pid, signal.SIGKILL)],
        )
        self.assertEqual(len(readers), 2)
        for reader in readers:
            self.assertTrue(reader.join(0))
            self.assertTrue(reader._stream.closed)
        child_pid = int((self.root / "child.pid").read_text(encoding="utf-8"))
        self.assertTrue(wait_until_gone(lambda: os.kill(child_pid, 0)))
        self.assertTrue(wait_until_gone(lambda: os.killpg(processes[0].pid, 0)))


class CleanupTests(RunnerTestCase):
    class ScriptedProcess:
        pid = 616161

        def __init__(self, wait_results):
            self.wait_results = list(wait_results)
            self.calls = []

        def wait(self, timeout=None):
            self.calls.append(("wait", timeout))
            result = self.wait_results.pop(0)
            if isinstance(result, BaseException):
                raise result
            return result

        def terminate(self):
            self.calls.append(("terminate",))

        def kill(self):
            self.calls.append(("kill",))

    def timeout(self):
        return subprocess.TimeoutExpired(["bash"], 1)

    def test_killpg_permission_error_falls_back_to_direct_terminate(self):
        process = self.ScriptedProcess([-signal.SIGTERM])
        with mock.patch.object(
            run_e2e.os, "killpg", side_effect=PermissionError("/Users/private")
        ) as killpg:
            run_e2e.terminate_process_group(process)
        killpg.assert_called_once_with(616161, signal.SIGTERM)
        self.assertEqual(
            process.calls,
            [("terminate",), ("wait", run_e2e.TERMINATE_GRACE_SECONDS)],
        )

    def test_group_race_falls_back_to_direct_process(self):
        process = self.ScriptedProcess([0])
        with mock.patch.object(run_e2e.os, "killpg", side_effect=ProcessLookupError()):
            run_e2e.terminate_process_group(process)
        self.assertEqual(
            process.calls,
            [("terminate",), ("wait", run_e2e.TERMINATE_GRACE_SECONDS)],
        )

    def test_direct_sigkill_fallback(self):
        process = self.ScriptedProcess([self.timeout(), -signal.SIGKILL])
        with mock.patch.object(
            run_e2e.os, "killpg", side_effect=PermissionError()
        ) as killpg:
            run_e2e.terminate_process_group(process)
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(616161, signal.SIGTERM), mock.call(616161, signal.SIGKILL)],
        )
        self.assertEqual(
            process.calls,
            [
                ("terminate",),
                ("wait", run_e2e.TERMINATE_GRACE_SECONDS),
                ("kill",),
                ("wait", run_e2e.KILL_REAP_SECONDS),
            ],
        )

    def test_unreaped_process_is_cleanup_failure(self):
        process = self.ScriptedProcess([self.timeout(), self.timeout()])
        with mock.patch.object(run_e2e.os, "killpg"):
            with self.assertRaises(run_e2e.RunnerError) as context:
                run_e2e.terminate_process_group(process)
        self.assertEqual(context.exception.code, "cleanup_failed")
        self.assertEqual(context.exception.exit_code, 70)

    def test_wait_error_is_cleanup_failure_without_detail(self):
        process = self.ScriptedProcess([OSError("/Users/private/path")])
        with mock.patch.object(run_e2e.os, "killpg"):
            with self.assertRaises(run_e2e.RunnerError) as context:
                run_e2e.terminate_process_group(process)
        self.assertEqual(context.exception.code, "cleanup_failed")
        self.assertEqual(str(context.exception), "cleanup_failed")

    class StuckOutput:
        def __init__(self, join_results):
            self.join_results = list(join_results)
            self.timeouts = []

        def join(self, timeout):
            self.timeouts.append(timeout)
            return self.join_results.pop(0)

    def test_reaped_leader_with_undrained_pipe_escalates_to_sigkill(self):
        process = self.ScriptedProcess([0, 0])
        output = self.StuckOutput([False, True])
        with mock.patch.object(run_e2e, "TERMINATE_GRACE_SECONDS", 0), \
                mock.patch.object(run_e2e.os, "killpg") as killpg:
            run_e2e.terminate_process_group(process, [output])
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(616161, signal.SIGTERM), mock.call(616161, signal.SIGKILL)],
        )
        self.assertEqual(len(output.timeouts), 2)
        self.assertTrue(all(0 <= timeout <= run_e2e.DRAIN_TIMEOUT_SECONDS
                            for timeout in output.timeouts))

    def test_undrainable_pipe_after_sigkill_is_cleanup_failure(self):
        process = self.ScriptedProcess([0, 0])
        output = self.StuckOutput([False, False])
        with mock.patch.object(run_e2e, "TERMINATE_GRACE_SECONDS", 0), \
                mock.patch.object(run_e2e, "DRAIN_TIMEOUT_SECONDS", 0), \
                mock.patch.object(run_e2e.os, "killpg") as killpg:
            with self.assertRaises(run_e2e.RunnerError) as context:
                run_e2e.terminate_process_group(process, [output])
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(616161, signal.SIGTERM), mock.call(616161, signal.SIGKILL)],
        )
        self.assertEqual(context.exception.code, "cleanup_failed")
        self.assertEqual(context.exception.exit_code, 70)
        self.assertEqual(str(context.exception), "cleanup_failed")

    def test_cleanup_failure_through_runner_is_nonzero(self):
        self.write_script()
        for wait_error in (self.timeout(), KeyboardInterrupt()):
            with self.subTest(wait_error=type(wait_error).__name__):
                popen = FakePopen(action=self.writer())
                make_timeout = self.timeout

                class UnreapableProcess(FakeProcess):
                    def wait(self, timeout=None):
                        if self.wait_calls == 0:
                            self.wait_calls += 1
                            raise wait_error
                        raise make_timeout()

                def unreapable_popen(args, **kwargs):
                    popen.action()
                    return UnreapableProcess(popen)

                with mock.patch.object(run_e2e.os, "killpg"):
                    exit_code, stdout, stderr = self.run_runner(unreapable_popen)
                self.assertEqual(exit_code, 70)
                self.assertEqual(stderr, "e2e error: cleanup_failed\n")
                self.assert_terminal(stdout, "error", 70)
                self.assertNotIn("passed", stdout)


class CommandLineTests(unittest.TestCase):
    def run_main(self, arguments):
        out = io.StringIO()
        err = io.StringIO()
        with mock.patch.object(sys, "stdout", out), mock.patch.object(sys, "stderr", err):
            exit_code = run_e2e.main(arguments)
        return exit_code, out.getvalue(), err.getvalue()

    def test_usage_errors(self):
        for arguments in (
            [],
            ["M1-999"],
            ["--issue"],
            ["--issue", "M1-999", "extra"],
            ["--issue", "M1-999", "--timeout-seconds", "abc"],
        ):
            with self.subTest(arguments=arguments):
                exit_code, stdout, stderr = self.run_main(arguments)
                self.assertEqual(exit_code, 64)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, "e2e error: invalid_arguments\n")

    def test_timeout_bounds(self):
        for value in ("0", "-1", "86401"):
            with self.subTest(value=value):
                exit_code, _, stderr = self.run_main(
                    ["--issue", "M1-999", "--timeout-seconds", value]
                )
                self.assertEqual(exit_code, 64)
                self.assertEqual(stderr, "e2e error: invalid_timeout\n")

    def test_invalid_issue_via_main(self):
        exit_code, stdout, stderr = self.run_main(["--issue", "../M1-999"])
        self.assertEqual(exit_code, 64)
        self.assertEqual(stderr, "e2e error: invalid_issue\n")
        self.assertEqual(stdout, "e2e disposition: error\ne2e exit: 64\n")

    def test_signal_handlers_are_restored(self):
        before = signal.getsignal(signal.SIGTERM)
        self.run_main(["--issue", "bad"])
        self.assertIs(signal.getsignal(signal.SIGTERM), before)

    def current_handlers(self):
        return {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}

    def test_unexpected_exception_is_redacted_and_handlers_restored(self):
        before = self.current_handlers()
        installed = []

        def exploding_run(issue, timeout_seconds):
            installed.append(self.current_handlers())
            raise RuntimeError("/Users/private/path SECRET-DETAIL")

        with mock.patch.object(run_e2e, "run", side_effect=exploding_run):
            exit_code, stdout, stderr = self.run_main(["--issue", "M1-999"])
        self.assertEqual(exit_code, 70)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "e2e error: internal_failure\n")
        self.assertNotIn("Traceback", stderr)
        self.assertNotIn("/Users/private/path", stdout + stderr)
        self.assertNotIn("SECRET-DETAIL", stdout + stderr)
        self.assertEqual(
            installed,
            [{number: run_e2e.handle_termination_signal for number in before}],
        )
        self.assertEqual(self.current_handlers(), before)

    def test_cancellation_restores_handlers(self):
        before = self.current_handlers()
        with mock.patch.object(run_e2e, "run", side_effect=KeyboardInterrupt()):
            exit_code, _, stderr = self.run_main(["--issue", "M1-999"])
        self.assertEqual(exit_code, 130)
        self.assertEqual(stderr, "e2e error: cancelled\n")
        self.assertEqual(self.current_handlers(), before)


class MakefileTests(unittest.TestCase):
    def test_issue_is_passed_as_single_argv_without_shell_expansion(self):
        make = shutil.which("make")
        if make is None:
            self.skipTest("make unavailable")
        with tempfile.TemporaryDirectory() as temporary_directory:
            marker = Path(temporary_directory).resolve() / "pwned"
            for issue in (
                "M1-001'; touch {0}; echo '".format(marker),
                "M1-001$(touch {0})".format(marker),
                "M1-001`touch {0}`".format(marker),
                "$(shell touch {0})".format(marker),
            ):
                with self.subTest(issue=issue):
                    completed = subprocess.run(
                        [make, "-s", "--no-print-directory", "e2e", "ISSUE=" + issue,
                         "PYTHON=" + sys.executable],
                        cwd=str(REPOSITORY_ROOT),
                        stdin=subprocess.DEVNULL,
                        capture_output=True,
                        text=True,
                        timeout=60,
                        check=False,
                    )
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn("e2e error: invalid_issue", completed.stderr)
                    self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
