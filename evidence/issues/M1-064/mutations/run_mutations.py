"""M1-064 mutation runner for CleanupHooks.

Usage (from anywhere):
  python3 -I evidence/issues/M1-064/mutations/run_mutations.py <repository> [--out <json>]
      [--only <id> ...] [--test-revision <git revision>]

For each mutant the runner edits the production source by exact text replacement, runs the
M1-064 suite from the root package (KVMCore has no package manifest of its own), records which
tests failed, and restores the source from a backup copy. A mutant is killed when the suite
exits non-zero with at least one named failing test and no compile error. Before the mutants it
runs the suite once unmodified (the baseline, which must pass). After every restore it checks
that the source is byte-for-byte the original and that `git diff --exit-code` on it returns 0,
so stage the source and the tests before running.

Adapted from the M1-063 runner. The JSON report holds repository-relative paths only. The exit
code is 0 only when the baseline passes, every mutant is killed and every restore is clean.
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

SOURCE = "Packages/KVMCore/Sources/KVMCore/CleanupHooks.swift"
TESTS = "Packages/KVMCore/Tests/KVMCoreTests/CleanupHooksTests.swift"
COMMAND = ["swift", "test", "--filter", "CleanupHooks"]
TIMEOUT_SECONDS = 600

RECOVER = "    let disposition = await recoverOffPool()\n"
DISCONNECT = "    let timedOut = await boundedDisconnect(Self.disconnectReason(for: trigger))\n"

MUTANTS = [
    {"id": "O1", "requirement": "order: release before disconnect (plan b.6)",
     "description": "the disconnect is awaited before the recovery",
     "replacements": [(RECOVER + DISCONNECT, DISCONNECT + RECOVER)]},
    {"id": "G1", "requirement": "exactly one logical cleanup per generation",
     "description": "the generation check is removed: every caller runs",
     "replacements": [("    guard claimed else { return .skipped }\n", "    _ = claimed\n")]},
    {"id": "G2", "requirement": "exactly one logical cleanup per generation (claim)",
     "description": "the generation is checked but never consumed",
     "replacements": [("open.remove(generation.rawValue) != nil", "open.contains(generation.rawValue)")]},
    {"id": "G3", "requirement": "invalid input: an unissued generation runs nothing",
     "description": "any generation is accepted",
     "replacements": [("open.remove(generation.rawValue) != nil",
                       "{ open.remove(generation.rawValue); return true }()")]},
    {"id": "P1", "requirement": "recovery runs off the cooperative pool (M1-063 review)",
     "description": "no thread is used: the recovery runs inline on the caller's pool thread",
     "replacements": [("      let thread = Thread {\n", "      let thread = Thread {}\n      do {\n"),
                      ("        Thread.current.name = Self.threadName\n", "")]},
    {"id": "L1", "requirement": "ledger cleared before disconnect (plan a.6.4)",
     "description": "clearLedger is never called",
     "replacements": [("          clearLedger()\n", "")]},
    {"id": "B1", "requirement": "a hung disconnect is bounded and still reports",
     "description": "the timeout is reported as a normal disconnect",
     "replacements": [("          continuation.resume(returning: true)\n",
                       "          continuation.resume(returning: false)\n")]},
    {"id": "F1", "requirement": "a failed recovery is reported, never swallowed",
     "description": "runOnce always reports completed",
     "replacements": [("    return CleanupOutcome(ran: true, disposition: disposition, disconnectTimedOut: timedOut)\n",
                       "    return CleanupOutcome(ran: true, disposition: .completed, disconnectTimedOut: timedOut)\n")]},
    {"id": "M1", "requirement": "mapping: keepalive timeout",
     "description": "timeout(.keepalive) maps to transportFailure",
     "replacements": [("    case .timeout(.keepalive):\n      return .keepaliveTimeout\n", "")]},
    {"id": "M2", "requirement": "mapping: shutdown cancellation is termination",
     "description": "DisconnectReason.cancellation(.shutdown) maps to cancelled",
     "replacements": [("    case .cancellation(let cancellation):\n      return cancellation == .shutdown ? .termination : .cancelled\n    case .applicationTermination:",
                       "    case .cancellation:\n      return .cancelled\n    case .applicationTermination:")]},
    {"id": "M3", "requirement": "mapping: TLS (security) error is a transport failure",
     "description": "security errors map to streamEnded",
     "replacements": [("    case .timeout, .transport, .security:\n", "    case .security:\n      return .streamEnded(reason)\n    case .timeout, .transport:\n")]},
    {"id": "M4", "requirement": "mapping: display loss",
     "description": "lifecycle(.subsystemUnavailable) maps to streamEnded",
     "replacements": [("    case .lifecycle(.subsystemUnavailable):\n      return .displayLost\n", ""),
                      ("    case .lifecycle(.wake), .permission", "    case .lifecycle(.wake), .lifecycle(.subsystemUnavailable), .permission")]},
    {"id": "R1", "requirement": "disconnect reason for a cancelled generation",
     "description": "cancelled disconnects with cancellation(.requested)",
     "replacements": [("      return .cancellation(.superseded)\n", "      return .cancellation(.requested)\n")]},
    {"id": "R2", "requirement": "round trip: termination disconnect reason",
     "description": "termination disconnects with userRequested",
     "replacements": [("    case .termination:\n      return .applicationTermination\n",
                       "    case .termination:\n      return .userRequested\n")]},
]

FAILED_TEST = re.compile(r"Test (\"[^\"]+\"|\w+\([^)]*\))(?: with \d+ test cases?)? failed")
RUN_SUMMARY = re.compile(r"Test run with \d+ tests? in \d+ suites? (passed|failed)[^\n]*")
COMPILE_ERROR = re.compile(r"\berror: ")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_suite(repository: pathlib.Path) -> dict:
    started = time.monotonic()
    try:
        process = subprocess.run(COMMAND, cwd=repository, capture_output=True, text=True,
                                 timeout=TIMEOUT_SECONDS)
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
    parser.add_argument("repository")
    parser.add_argument("--out", default="evidence/issues/M1-064/mutations/mutations.json")
    parser.add_argument("--only", action="append", default=[],
                        help="run only the mutant with this id; repeat for more")
    parser.add_argument("--test-revision",
                        help="run against the test file as of this git revision")
    arguments = parser.parse_args()
    repository = pathlib.Path(arguments.repository).resolve()
    selected = [mutant for mutant in MUTANTS
                if not arguments.only or mutant["id"] in arguments.only]
    if arguments.only and len(selected) != len(set(arguments.only)):
        raise SystemExit("--only names a mutant that does not exist")
    source_path = repository / SOURCE
    tests_path = repository / TESTS
    for path in (SOURCE, TESTS):
        if not is_tracked(repository, path):
            raise SystemExit("stage the source and the tests first: the git diff restore "
                             "check needs them tracked")
    original = source_path.read_bytes()
    original_hash = sha256(original)
    tests_original_hash = sha256(tests_path.read_bytes())
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m1-064-mutations-"))
    backup = backup_directory / "CleanupHooks.swift.backup"
    tests_backup = backup_directory / "CleanupHooksTests.swift.backup"
    shutil.copyfile(source_path, backup)
    shutil.copyfile(tests_path, tests_backup)
    tests_hash = tests_original_hash
    if arguments.test_revision:
        older = subprocess.run(["git", "show", f"{arguments.test_revision}:{TESTS}"],
                               cwd=repository, capture_output=True, check=True).stdout
        tests_path.write_bytes(older)
        tests_hash = sha256(older)

    results = []
    clean = True
    try:
        baseline = run_suite(repository)
        print(f"baseline: exit {baseline['exitCode']}, {baseline['summary']}", flush=True)
        for mutant in selected:
            if sha256(source_path.read_bytes()) != original_hash:
                raise SystemExit("the source changed before a mutant was applied")
            text = original.decode("utf-8")
            for old, new in mutant["replacements"]:
                if text.count(old) != 1:
                    raise SystemExit(f"mutant {mutant['id']}: the text to replace is not unique")
                text = text.replace(old, new)
            source_path.write_text(text, encoding="utf-8")
            try:
                outcome = run_suite(repository)
            finally:
                shutil.copyfile(backup, source_path)
            restored = sha256(source_path.read_bytes()) == original_hash
            diff_exit = git_diff_exit_code(repository, SOURCE)
            clean = clean and restored and diff_exit == 0
            killed = (outcome["exitCode"] not in (0, "timeout") and bool(outcome["failingTests"])
                      and not outcome["compileError"])
            result = {
                "id": mutant["id"],
                "requirement": mutant["requirement"],
                "description": mutant["description"],
                "killed": killed,
                **outcome,
                "restoredByteForByte": restored,
                "gitDiffExitCodeAfterRestore": diff_exit,
            }
            results.append(result)
            print(f"mutant {mutant['id']}: killed={killed} exit={outcome['exitCode']} "
                  f"failing={len(outcome['failingTests'])} restored={restored} "
                  f"diff={diff_exit}", flush=True)
            print(f"  {outcome['summary']}", flush=True)
            print(f"  failing: {', '.join(outcome['failingTests']) or 'none'}", flush=True)
    finally:
        shutil.copyfile(backup, source_path)
        shutil.copyfile(tests_backup, tests_path)
        shutil.rmtree(backup_directory, ignore_errors=True)
    tests_untouched = (sha256(tests_path.read_bytes()) == tests_original_hash
                       and git_diff_exit_code(repository, TESTS) == 0)
    clean = clean and tests_untouched

    baseline_ok = baseline["exitCode"] == 0 and not baseline["failingTests"]
    all_killed = all(result["killed"] for result in results)
    report = {
        "schemaVersion": 1,
        "issue": "M1-064",
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE,
        "sourceSha256": original_hash,
        "tests": TESTS,
        "testRevision": arguments.test_revision,
        "testsSha256": tests_hash,
        "command": " ".join(COMMAND),
        "timeoutSeconds": TIMEOUT_SECONDS,
        "baseline": baseline,
        "mutants": results,
        "baselinePassed": baseline_ok,
        "allKilled": all_killed,
        "testsUntouched": tests_untouched,
        "allRestored": clean,
        "killedCount": sum(result["killed"] for result in results),
        "mutantCount": len(results),
    }
    out = pathlib.Path(arguments.out)
    out = out if out.is_absolute() else repository / out
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{report['killedCount']} of {report['mutantCount']} mutants killed; baseline "
          f"{'passed' if baseline_ok else 'FAILED'}; restores {'clean' if clean else 'NOT clean'}")
    return 0 if baseline_ok and all_killed and clean else 1


if __name__ == "__main__":
    sys.exit(main())
