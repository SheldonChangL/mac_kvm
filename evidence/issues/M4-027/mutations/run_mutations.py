"""M4-027 mutation runner for LinuxScreenBackend.

Usage (from anywhere):
  python3 -I evidence/issues/M4-027/mutations/run_mutations.py <repository> [--out <json>]
      [--only <id> ...] [--image <docker image>] [--volume <docker volume>]

LinuxPlatform builds only on Linux, so each run executes the M4-027 suite in a Linux container:
the repository is mounted read-only, copied to /work inside the container, and
`swift test --filter LinuxScreen` runs with MACKVM_X11_TESTS=1 (the `.x11` tests start their own
Xvfb). The image is built from the Dockerfile next to this script (`docker build -t m4027-dev
<this directory>`); the volume caches the Swift build between runs.

For each mutant the runner edits the production source by exact text replacement, runs the
suite, records which tests failed, and restores the source from a backup. A mutant is killed when
the suite exits non-zero with at least one named failing test and no compile error. Before the
mutants it runs the suite unmodified (the baseline, which must pass). After every restore it
checks the source is byte-for-byte the original and that `git diff --exit-code` on it returns 0,
so stage the source and the tests before running. The JSON report holds repository-relative
paths only. The exit code is 0 only when the baseline passes, every mutant is killed and every
restore is clean.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

SOURCE = "Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxScreenBackend.swift"
TESTS = "Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxScreenBackendTests.swift"
TIMEOUT_SECONDS = 900
CONTAINER_SCRIPT = (
    "set -o pipefail; mkdir -p /work; "
    "tar -C /src --exclude=./.build --exclude=./.build-linux --exclude=./artifacts --exclude=./.git"
    " -cf - . | tar -C /work -xf -; cd /work; "
    "timeout -s KILL 240 swift test --scratch-path /scratch --filter LinuxScreen"
)

CLOSE_WAKE = "      close(wakeRead)\n      close(wakeWrite)\n"
CLOSE_DISPLAYS = "        XCloseDisplay(eventDisplay)\n        XCloseDisplay(queryDisplay)\n      }\n"
SHUTDOWN_FINISH = "      continuation.finish()\n      // The event thread has exited"

MUTANTS = [
    {"id": "G1", "requirement": "rule: the DINF maximum is 0x7FFF",
     "description": "maximumDimension becomes 0x8000",
     "replacements": [("maximumDimension = 0x7FFF", "maximumDimension = 0x8000")]},
    {"id": "G2", "requirement": "rule: a zero width or height is rejected",
     "description": "the accepted range starts at 0",
     "replacements": [("let range = 1...maximumDimension", "let range = 0...maximumDimension")]},
    {"id": "G3", "requirement": "rule: the height is range-checked",
     "description": "only the width is checked",
     "replacements": [("guard range.contains(width), range.contains(height) else {",
                       "guard range.contains(width) else {")]},
    {"id": "G4", "requirement": "rule: a height change is a change",
     "description": "hasChanged ignores the height",
     "replacements": [("old.width != new.width\n        || old.height != new.height",
                       "old.width != new.width")]},
    {"id": "G5", "requirement": "rule: pointer movement alone is not a change",
     "description": "hasChanged also compares the pointer",
     "replacements": [("old.originX != new.originX ||",
                       "old.cursorX != new.cursorX || old.originX != new.originX ||")]},
    {"id": "G6", "requirement": "rule: the X11 origin is (0, 0)",
     "description": "the geometry gets originX 1",
     "replacements": [("originX: 0, originY: 0, width: width", "originX: 1, originY: 0, width: width")]},
    {"id": "E1", "requirement": "errors are terminal",
     "description": "invariantViolation allows a backoff retry",
     "replacements": [("code: .protocolViolation(.invariantViolation), severity: .error, retryDisposition: .never",
                       "code: .protocolViolation(.invariantViolation), severity: .error, retryDisposition: .backoff")]},
    {"id": "E2", "requirement": "error code: an unusable display is lifecycle.subsystemUnavailable",
     "description": "subsystemUnavailable carries lifecycle.sleep",
     "replacements": [("code: .lifecycle(.subsystemUnavailable)", "code: .lifecycle(.sleep)")]},
    {"id": "E3", "requirement": "errors need no cleanup",
     "description": "capabilityUnavailable reports a failed cleanup",
     "replacements": [("code: .permission(.capabilityUnavailable), severity: .error, retryDisposition: .never,\n      cleanupDisposition: .notRequired",
                       "code: .permission(.capabilityUnavailable), severity: .error, retryDisposition: .never,\n      cleanupDisposition: .failed")]},
    {"id": "O1", "requirement": "failure: an unopenable display fails with subsystemUnavailable",
     "description": "the first open failure reports invariantViolation",
     "replacements": [("guard let queryDisplay = XOpenDisplay(displayName) else {\n        throw LinuxScreenError.subsystemUnavailable",
                       "guard let queryDisplay = XOpenDisplay(displayName) else {\n        throw LinuxScreenError.invariantViolation")]},
    {"id": "R1", "requirement": "failure: no RandR fails with capabilityUnavailable",
     "description": "a missing RandR reports subsystemUnavailable",
     "replacements": [("throw LinuxScreenError.capabilityUnavailable",
                       "throw LinuxScreenError.subsystemUnavailable")]},
    {"id": "Q1", "requirement": "geometry: the pointer position is (rootX, rootY)",
     "description": "cursorX and cursorY are swapped",
     "replacements": [("cursorX: Int(rootX), cursorY: Int(rootY))", "cursorX: Int(rootY), cursorY: Int(rootX))")]},
    {"id": "Q2", "requirement": "geometry: the size is the root window's width and height",
     "description": "width and height are swapped",
     "replacements": [("width: Int(width), height: Int(height), cursorX", "width: Int(height), height: Int(width), cursorX")]},
    {"id": "C1", "requirement": "changes: only RRScreenChangeNotify events count",
     "description": "the event type is compared with the wrong offset",
     "replacements": [("eventBase + Int32(RRScreenChangeNotify)", "eventBase + Int32(RRScreenChangeNotify) + 1")]},
    {"id": "C2", "requirement": "changes: a screen change is selected from the server",
     "description": "XRRSelectInput is never called",
     "replacements": [("      XRRSelectInput(eventDisplay, root, Int32(RRScreenChangeNotifyMask))\n", "")]},
    {"id": "C3", "requirement": "changes: an unchanged size is not reported",
     "description": "publish yields whenever a screen event arrives",
     "replacements": [("LinuxScreenGeometryRules.hasChanged(from: lastReported, to: geometry)", "true")]},
    {"id": "C4", "requirement": "changes: a consumer that falls behind gets the newest geometry",
     "description": "the stream keeps the oldest buffered value",
     "replacements": [(".bufferingNewest(1)", ".bufferingOldest(1)")]},
    {"id": "S1", "requirement": "stop: later currentGeometry fails with subsystemUnavailable",
     "description": "currentGeometry reports invariantViolation once stopped",
     "replacements": [("guard !stopped, !lost else { return .failure(LinuxScreenError.subsystemUnavailable) }",
                       "guard !stopped, !lost else { return .failure(LinuxScreenError.invariantViolation) }")]},
    {"id": "S2", "requirement": "stop: changes finishes",
     "description": "shutdown does not finish the stream",
     "replacements": [(SHUTDOWN_FINISH, "      // The event thread has exited")]},
    {"id": "S3", "requirement": "cleanup: the wake pipe is closed",
     "description": "shutdown leaves the pipe descriptors open",
     "replacements": [(CLOSE_WAKE, "")]},
    {"id": "S4", "requirement": "cleanup: both X connections are closed",
     "description": "shutdown leaves the displays open",
     "replacements": [(CLOSE_DISPLAYS, "      }\n")]},
    {"id": "Q3", "requirement": "failure: the query connection is checked before Xlib uses it",
     "description": "currentGeometry hands a closed connection to Xlib (crash kill: Xlib exits the process)",
     "crashKill": True,
     "replacements": [("      guard queryConnectionIsOpen() else { return .failure(LinuxScreenError.subsystemUnavailable) }\n      return Self.readGeometry",
                       "      return Self.readGeometry")]},
    {"id": "L1", "requirement": "failure: the event thread notices a closed connection before Xlib reads",
     "description": "neither POLLHUP nor the EOF peek is checked (crash kill: Xlib exits the process)",
     "crashKill": True,
     "replacements": [("if descriptors[0].revents & hangUp != 0 || Self.connectionClosed(eventDescriptor) {",
                       "if descriptors[0].revents & hangUp == 7 {")]},
    {"id": "L2", "requirement": "failure: the drain loop never reads the socket after the EOF check",
     "description": "the drain loop uses QueuedAfterReading, which reads the socket again (documented: not deterministically testable)",
     "documentedSurvivor": True,
     "replacements": [("while XEventsQueued(eventDisplay, 0) > 0 {", "while XEventsQueued(eventDisplay, 1) > 0 {")]},
    {"id": "H1", "requirement": "failure: a lost display finishes changes",
     "description": "markLost does not finish the stream",
     "replacements": [("      lock.unlock()\n      continuation.finish()\n    }\n\n    // MARK: Shutdown",
                       "      lock.unlock()\n    }\n\n    // MARK: Shutdown")]},
]

FAILED_TEST = re.compile(r"Test (\"[^\"]+\"|\w+\([^)]*\))(?: with \d+ test cases?)? failed")
RUN_SUMMARY = re.compile(r"Test run with \d+ tests? in \d+ suites? (passed|failed)[^\n]*")
COMPILE_ERROR = re.compile(r"\berror: ")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_suite(repository: pathlib.Path, image: str, volume: str) -> dict:
    started = time.monotonic()
    command = [
        "docker", "run", "--rm", "--init", "--platform", "linux/arm64",
        "-v", f"{repository}:/src:ro", "-v", f"{volume}:/scratch",
        "-e", "MACKVM_X11_TESTS=1", image, "bash", "-c", CONTAINER_SCRIPT,
    ]
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=TIMEOUT_SECONDS)
        exit_code, output = process.returncode, process.stdout + process.stderr
    except subprocess.TimeoutExpired as expired:
        exit_code = "timeout"
        partial = expired.stdout or ""
        output = partial.decode("utf-8", "replace") if isinstance(partial, bytes) else partial
    summary_line = RUN_SUMMARY.search(output)
    return {
        "exitCode": exit_code,
        "durationSeconds": round(time.monotonic() - started, 1),
        "failingTests": sorted(set(FAILED_TEST.findall(output))),
        "compileError": bool(COMPILE_ERROR.search(output)) and summary_line is None,
        "xlibFatalIO": ("fatal IO error" in output or "broken (explicit kill or server shutdown)" in output),
        "summary": summary_line.group(0) if summary_line else None,
    }


def git_diff_exit_code(repository: pathlib.Path, path: str) -> int:
    return subprocess.run(["git", "diff", "--exit-code", "--quiet", "--", path],
                          cwd=repository).returncode


def is_tracked(repository: pathlib.Path, path: str) -> bool:
    return subprocess.run(["git", "ls-files", "--error-unmatch", "--", path], cwd=repository,
                          capture_output=True).returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path)
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--image", default="m4027-dev")
    parser.add_argument("--volume", default="m4027-scratch")
    args = parser.parse_args()
    repository = args.repository.resolve()
    source = repository / SOURCE
    original = source.read_bytes()
    original_text = original.decode("utf-8")
    tracked = is_tracked(repository, SOURCE)
    backup = pathlib.Path(tempfile.mkdtemp()) / "source.backup"
    shutil.copyfile(source, backup)

    report = {
        "schemaVersion": 1,
        "issue": "M4-027",
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE,
        "sourceSha256": sha256(original),
        "tests": TESTS,
        "testsSha256": sha256((repository / TESTS).read_bytes()),
        "command": "swift test --filter LinuxScreen (linux/arm64 container, MACKVM_X11_TESTS=1)",
        "timeoutSeconds": TIMEOUT_SECONDS,
    }
    ok = True
    try:
        report["baseline"] = run_suite(repository, args.image, args.volume)
        if report["baseline"]["exitCode"] != 0:
            ok = False
        results = []
        for mutant in MUTANTS:
            if args.only and mutant["id"] not in args.only:
                continue
            text = original_text
            applied = True
            for old, new in mutant["replacements"]:
                if text.count(old) != 1:
                    applied = False
                    break
                text = text.replace(old, new)
            entry = {"id": mutant["id"], "requirement": mutant["requirement"],
                     "description": mutant["description"]}
            if not applied:
                entry.update({"killed": False, "error": "replacement text not found exactly once"})
                ok = False
                results.append(entry)
                continue
            source.write_text(text, encoding="utf-8")
            try:
                outcome = run_suite(repository, args.image, args.volume)
            finally:
                shutil.copyfile(backup, source)
            restored = source.read_bytes() == original
            diff_clean = (not tracked) or git_diff_exit_code(repository, SOURCE) == 0
            killed = (outcome["exitCode"] not in (0, "timeout") and bool(outcome["failingTests"])
                      and not outcome["compileError"])
            if mutant.get("crashKill") and outcome["xlibFatalIO"] and outcome["exitCode"] != 0:
                killed = True  # the named test was running when Xlib ended the process
            if mutant.get("documentedSurvivor"):
                entry["documentedSurvivor"] = True
            entry.update({"killed": killed, **outcome, "restoredIdentical": restored,
                          "gitDiffClean": diff_clean})
            if not (restored and diff_clean) or not (killed or mutant.get("documentedSurvivor")):
                ok = False
            results.append(entry)
            if args.out:
                partial = dict(report, mutants=results, allKilled=None)
                args.out.write_text(json.dumps(partial, indent=2) + "\n", encoding="utf-8")
        report["mutants"] = results
    finally:
        shutil.copyfile(backup, source)
    report["allKilled"] = ok
    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
