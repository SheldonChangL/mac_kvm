#!/usr/bin/env python3
"""Read-only, fail-closed E2E evidence runner for `make e2e ISSUE=Mx-xxx`."""

import argparse
import hashlib
import os
import platform
import re
import signal
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import validate_evidence  # noqa: E402


RUNNER_VERSION = "1"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_ROOT = Path("Tests", "SystemTests", "Scripts")
RESULT_ROOT = Path("evidence", "e2e")
RESULT_NAME = "result.json"
DEFAULT_TIMEOUT_SECONDS = 1800
MAX_TIMEOUT_SECONDS = 86400
GIT_TIMEOUT_SECONDS = 10
TERMINATE_GRACE_SECONDS = 2
KILL_REAP_SECONDS = 5
DRAIN_TIMEOUT_SECONDS = 5
# Independent cap per stream (stdout, stderr). Output is hashed as it streams
# and never stored, so memory stays at one chunk per stream and no disk is used.
MAX_OUTPUT_BYTES_PER_STREAM = 8 * 1024 * 1024
OUTPUT_CHUNK_BYTES = 64 * 1024

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 64
EXIT_DATA = 65
EXIT_NO_INPUT = 66
EXIT_SOFTWARE = 70
EXIT_UNSAFE_PATH = 77
EXIT_TIMEOUT = 124
EXIT_CANCELLED = 130

STATUS_EXIT_CODES = {
    "passed": EXIT_OK,
    "not_executed": EXIT_OK,
    "failed": EXIT_FAILED,
    "timed_out": EXIT_TIMEOUT,
    "cancelled": EXIT_CANCELLED,
}

ISSUE_PATTERN = re.compile(r"M[1-5]-[0-9]{3}")
SCRIPT_NAME_PATTERN = re.compile(r"M[1-5]-[0-9]{3}-[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}\.sh")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")


class RunnerError(Exception):
    def __init__(self, code, exit_code):
        self.code = code
        self.exit_code = exit_code
        super().__init__(code)


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise RunnerError("invalid_arguments", EXIT_USAGE)


def handle_termination_signal(signum, frame):
    del signum, frame
    raise KeyboardInterrupt


def signal_process(process, group_signal, direct_method):
    """Signal the process group; fall back to the direct process on any failure."""
    try:
        os.killpg(process.pid, group_signal)
        return
    except OSError:
        pass
    try:
        getattr(process, direct_method)()
    except OSError:
        pass


def terminate_process_group(process, outputs=()):
    """SIGTERM then SIGKILL the group until the script is reaped and every
    output reader has drained, or raise cleanup_failed."""
    steps = (
        (signal.SIGTERM, "terminate", TERMINATE_GRACE_SECONDS, TERMINATE_GRACE_SECONDS),
        (signal.SIGKILL, "kill", KILL_REAP_SECONDS, DRAIN_TIMEOUT_SECONDS),
    )
    for group_signal, direct_method, wait_seconds, drain_seconds in steps:
        signal_process(process, group_signal, direct_method)
        try:
            process.wait(timeout=wait_seconds)
        except subprocess.TimeoutExpired:
            continue
        except Exception:
            break
        # A reaped leader is not enough: a group member that ignores SIGTERM
        # can still hold the pipes open, so escalate until they drain.
        drain_deadline = time.monotonic() + drain_seconds
        if all(
            output.join(max(0.0, drain_deadline - time.monotonic())) for output in outputs
        ):
            return
    raise RunnerError("cleanup_failed", EXIT_SOFTWARE)


class BoundedOutput:
    """Streams one pipe into line-count/SHA-256 metadata, reading at most `limit` bytes."""

    def __init__(self, stream, limit, on_overflow):
        self._stream = stream
        self._limit = limit
        self._on_overflow = on_overflow
        self._lock = threading.Lock()
        self._digest = hashlib.sha256()
        self._newlines = 0
        self._last_byte = b""
        self.retained_bytes = 0
        self.truncated = False
        self.failed = False
        self._thread = threading.Thread(target=self._drain, daemon=True)

    def start(self):
        self._thread.start()

    def join(self, timeout):
        # A reader cancelled before it started has nothing left to drain.
        if self._thread.ident is None:
            return True
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def close(self):
        # Closing a stream another thread is blocked reading could hang.
        if self._stream is not None and not self._thread.is_alive():
            try:
                self._stream.close()
            except (OSError, ValueError):
                pass

    def _drain(self):
        if self._stream is None:
            return
        try:
            while True:
                chunk = self._stream.read1(OUTPUT_CHUNK_BYTES)
                if not chunk:
                    return
                room = self._limit - self.retained_bytes
                overflow = len(chunk) > room
                if overflow:
                    chunk = chunk[:room]
                with self._lock:
                    if chunk:
                        self._digest.update(chunk)
                        self._newlines += chunk.count(b"\n")
                        self._last_byte = chunk[-1:]
                        self.retained_bytes += len(chunk)
                    if overflow:
                        self.truncated = True
                if overflow:
                    self._on_overflow()
                    return
        except Exception:
            self.failed = True

    def describe(self):
        with self._lock:
            line_count = self._newlines
            if self.retained_bytes and self._last_byte != b"\n":
                line_count += 1
            text = "lines={0} sha256={1}".format(line_count, self._digest.hexdigest())
            if self.truncated:
                text += " capture=truncated"
        return text


def validate_issue(issue):
    if not isinstance(issue, str) or ISSUE_PATTERN.fullmatch(issue) is None:
        raise RunnerError("invalid_issue", EXIT_USAGE)
    return issue


def _require_real_directory(repository_root, relative, label):
    current = Path(repository_root)
    for part in relative.parts:
        current = current / part
        try:
            status = os.lstat(current)
        except FileNotFoundError:
            raise RunnerError(label + "_missing", EXIT_NO_INPUT) from None
        except OSError:
            raise RunnerError(label + "_unreadable", EXIT_UNSAFE_PATH) from None
        if stat.S_ISLNK(status.st_mode):
            raise RunnerError(label + "_symlink", EXIT_UNSAFE_PATH)
        if not stat.S_ISDIR(status.st_mode):
            raise RunnerError(label + "_not_directory", EXIT_UNSAFE_PATH)
    return current


def resolve_script(issue, repository_root):
    """Return the repository-relative path of the single script for `issue`."""
    root = Path(repository_root)
    script_directory = _require_real_directory(root, SCRIPT_ROOT, "script_root")
    prefix = issue + "-"
    try:
        with os.scandir(script_directory) as entries:
            matches = sorted(
                entry.name
                for entry in entries
                if entry.name.startswith(prefix) and entry.name.endswith(".sh")
            )
    except OSError:
        raise RunnerError("script_root_unreadable", EXIT_UNSAFE_PATH) from None

    if not matches:
        raise RunnerError("script_missing", EXIT_NO_INPUT)
    if len(matches) > 1:
        raise RunnerError("script_ambiguous", EXIT_DATA)
    name = matches[0]
    if SCRIPT_NAME_PATTERN.fullmatch(name) is None:
        raise RunnerError("script_name_invalid", EXIT_DATA)

    candidate = script_directory / name
    try:
        status = os.lstat(candidate)
    except OSError:
        raise RunnerError("script_unreadable", EXIT_UNSAFE_PATH) from None
    if stat.S_ISLNK(status.st_mode):
        raise RunnerError("script_symlink", EXIT_UNSAFE_PATH)
    if not stat.S_ISREG(status.st_mode):
        raise RunnerError("script_not_regular_file", EXIT_UNSAFE_PATH)
    if Path(os.path.realpath(candidate)).parent != Path(os.path.realpath(script_directory)):
        raise RunnerError("script_outside_root", EXIT_UNSAFE_PATH)
    return SCRIPT_ROOT / name


def result_relative_path(issue):
    return RESULT_ROOT / issue / RESULT_NAME


def result_fingerprint(repository_root, relative):
    """Metadata used to reject a stale result the script did not rewrite."""
    path = Path(repository_root) / relative
    try:
        status = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(status.st_mode):
        return None
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(64 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return None
    return (status.st_ino, status.st_size, status.st_mtime_ns, digest.hexdigest())


def git_commit(repository_root):
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=str(repository_root),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "unavailable"
    commit = completed.stdout.decode("ascii", errors="replace").strip()
    if completed.returncode != 0 or COMMIT_PATTERN.fullmatch(commit) is None:
        return "unavailable"
    return commit


def execute_script(script_relative, repository_root, timeout_seconds, issue, popen):
    """Run the script with bash; returns (disposition, exit_code, outputs)."""
    environment = dict(os.environ)
    environment["MACKVM_E2E_ISSUE"] = issue
    environment["MACKVM_E2E_RESULT"] = result_relative_path(issue).as_posix()
    try:
        process = popen(
            ["bash", script_relative.as_posix()],
            cwd=str(repository_root),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError:
        raise RunnerError("bash_unavailable", EXIT_NO_INPUT) from None

    def stop_on_overflow():
        # Runs on a reader thread: signal only; the main thread reaps.
        signal_process(process, signal.SIGKILL, "kill")

    limit = MAX_OUTPUT_BYTES_PER_STREAM
    outputs = [
        BoundedOutput(getattr(process, "stdout", None), limit, stop_on_overflow),
        BoundedOutput(getattr(process, "stderr", None), limit, stop_on_overflow),
    ]
    deadline = time.monotonic() + timeout_seconds
    cleanup_attempted = False
    try:
        for output in outputs:
            output.start()
        disposition = "completed"
        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            disposition = "timed_out"
        else:
            # Background children may still hold the pipes open.
            for output in outputs:
                if not output.join(max(0.0, deadline - time.monotonic())):
                    disposition = "timed_out"
        if disposition == "timed_out" or any(
            output.truncated or output.failed for output in outputs
        ):
            cleanup_attempted = True
            terminate_process_group(process, outputs)
    except BaseException:
        if not cleanup_attempted:
            terminate_process_group(process, outputs)
        raise
    finally:
        for output in outputs:
            output.close()

    if any(output.failed for output in outputs):
        raise RunnerError("output_capture_failed", EXIT_SOFTWARE)
    if any(output.truncated for output in outputs):
        return "output_limit_exceeded", None, outputs
    if disposition == "timed_out":
        return "timed_out", None, outputs
    return "completed", process.returncode, outputs


def child_exit_code(returncode):
    if isinstance(returncode, int) and 1 <= returncode <= 125:
        return returncode
    return EXIT_FAILED


def run(
    issue,
    repository_root=REPOSITORY_ROOT,
    timeout_seconds=DEFAULT_TIMEOUT_SECONDS,
    popen=subprocess.Popen,
    commit_provider=git_commit,
    out=None,
    err=None,
):
    out = sys.stdout if out is None else out
    err = sys.stderr if err is None else err
    root = Path(repository_root)

    def emit(label, value):
        print("e2e {0}: {1}".format(label, value), file=out)

    def finish(disposition, exit_code):
        emit("disposition", disposition)
        emit("exit", exit_code)
        return exit_code

    def fail(error):
        print("e2e error: {0}".format(error.code), file=err)
        return finish("error", error.exit_code)

    try:
        validate_issue(issue)
    except RunnerError as error:
        return fail(error)

    emit("runner version", RUNNER_VERSION)
    emit("issue", issue)
    emit("commit", commit_provider(root))
    emit("python", platform.python_version())

    try:
        script_relative = resolve_script(issue, root)
        emit("script", script_relative.as_posix())
        result_relative = result_relative_path(issue)
        before = result_fingerprint(root, result_relative)
        disposition, returncode, outputs = execute_script(
            script_relative, root, timeout_seconds, issue, popen
        )
    except RunnerError as error:
        return fail(error)
    except KeyboardInterrupt:
        print("e2e error: cancelled", file=err)
        return finish("cancelled", EXIT_CANCELLED)

    for label, output in zip(("stdout", "stderr"), outputs):
        emit(label, output.describe())

    if disposition == "output_limit_exceeded":
        emit("script exit", "none")
        return fail(RunnerError("output_limit_exceeded", EXIT_DATA))
    if disposition == "timed_out":
        emit("script exit", "none")
        return finish("timed_out", EXIT_TIMEOUT)
    emit("script exit", returncode)
    if returncode != 0:
        return finish("script_failed", child_exit_code(returncode))

    if before is not None and result_fingerprint(root, result_relative) == before:
        return fail(RunnerError("result_not_updated", EXIT_DATA))
    try:
        _, status = validate_evidence.validate_result_file(
            root / result_relative, root, expected_issue=issue
        )
    except validate_evidence.ValidationError as error:
        return fail(RunnerError(error.code, error.exit_code))
    return finish(status, STATUS_EXIT_CODES[status])


def _parse_arguments(arguments):
    parser = _SafeArgumentParser(
        description="Run the single E2E script for an Issue and gate its result."
    )
    parser.add_argument("--issue", required=True, help="Issue ID, e.g. M1-024")
    parser.add_argument(
        "--timeout-seconds", type=int, default=DEFAULT_TIMEOUT_SECONDS
    )
    return parser.parse_args(arguments)


def main(arguments=None):
    previous_handlers = {}
    try:
        try:
            options = _parse_arguments(arguments)
            if not 1 <= options.timeout_seconds <= MAX_TIMEOUT_SECONDS:
                raise RunnerError("invalid_timeout", EXIT_USAGE)
        except RunnerError as error:
            print("e2e error: {0}".format(error.code), file=sys.stderr)
            return error.exit_code

        for signal_number in (signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signal_number] = signal.signal(
                signal_number, handle_termination_signal
            )
        return run(options.issue, timeout_seconds=options.timeout_seconds)
    except KeyboardInterrupt:
        print("e2e error: cancelled", file=sys.stderr)
        return EXIT_CANCELLED
    except Exception:
        # Never let a traceback (local paths, untrusted values) reach the log.
        print("e2e error: internal_failure", file=sys.stderr)
        return EXIT_SOFTWARE
    finally:
        for signal_number, handler in previous_handlers.items():
            signal.signal(signal_number, handler)


if __name__ == "__main__":
    sys.exit(main())
