"""M1-063 mutation runner for FailSafeCoordinator.

Usage (from anywhere):
  python3 -I evidence/issues/M1-063/mutations/run_mutations.py <repository> [--out <json>]
      [--only <id> ...] [--test-revision <git revision>]

For each mutant the runner edits the production source by exact text replacement, runs the
M1-063 suite from the root package (KVMCore has no package manifest of its own), records which
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

SOURCE = "Packages/KVMCore/Sources/KVMCore/FailSafeCoordinator.swift"
TESTS = "Packages/KVMCore/Tests/KVMCoreTests/FailSafeCoordinatorTests.swift"
COMMAND = ["swift", "test", "--filter", "FailSafeCoordinator"]
TIMEOUT_SECONDS = 600

CLEAR = ("    do throws(CoreError) {\n      try safety.clearTransientState()\n      succeeded += 1\n"
         "    } catch {\n      failedSteps.append(.clearTransientState)\n    }\n")
SWEEP = ("    do throws(CoreError) {\n      try safety.releaseRemaining()\n      succeeded += 1\n"
         "    } catch {\n      failedSteps.append(.releaseRemaining)\n    }\n")
RESTORE = ("    do throws(CoreError) {\n      try safety.restoreLocalInput()\n      succeeded += 1\n"
           "    } catch {\n      failedSteps.append(.restoreLocalInput)\n    }\n")
EXECUTE = "    let release = ReleaseAllKeys.execute(plan, with: safety)\n"
GUARD = "    guard !alreadyRunning else { return .notRequired }\n"

MUTANTS = [
    {"id": "T1", "requirement": "terminal path step: the queue reset is skipped",
     "description": "recover never calls clearTransientState",
     "replacements": [(CLEAR, "")]},
    {"id": "T2", "requirement": "the injector sweep is skipped (h.1)",
     "description": "recover never calls releaseRemaining",
     "replacements": [(SWEEP, "")]},
    {"id": "T3", "requirement": "terminal path step: restoreLocalInput is skipped",
     "description": "recover never calls restoreLocalInput",
     "replacements": [(RESTORE, "")]},
    {"id": "T4", "requirement": "order: the sweep runs before the ledger plan",
     "description": "releaseRemaining is moved ahead of ReleaseAllKeys.execute",
     "replacements": [(SWEEP, ""), (EXECUTE, SWEEP + EXECUTE)]},
    {"id": "T5", "requirement": "order: the queue reset runs after the releases",
     "description": "clearTransientState is moved after the sweep",
     "replacements": [(CLEAR, ""), (RESTORE, CLEAR + RESTORE)]},
    {"id": "T6", "requirement": "early return: a failed queue reset stops the recovery",
     "description": "recover returns failed as soon as clearTransientState throws",
     "replacements": [(CLEAR, CLEAR.replace(
         "      failedSteps.append(.clearTransientState)\n",
         "      failedSteps.append(.clearTransientState)\n"
         "      lock.withLock { recovering = false }\n      return .failed\n"))]},
    {"id": "T7", "requirement": "terminal path: the async joiner path does not wait",
     "description": "recoverJoiningInFlight returns notRequired instead of joining",
     "replacements": [("    guard started == .notRequired else { return started }\n",
                       "    return started\n")]},
    {"id": "T8", "requirement": "terminal path: the async joiner gets a different result",
     "description": "joiners are resumed with completed instead of the run's disposition",
     "replacements": [("    for joiner in waiting { joiner.resume(returning: disposition) }\n",
                       "    for joiner in waiting { joiner.resume(returning: .completed) }\n")]},
    {"id": "D1", "requirement": "release disposition notRequired is treated as a failure",
     "description": "an empty plan is listed as a failed step",
     "replacements": [("    case .notRequired:\n      break\n",
                       "    case .notRequired:\n      failedSteps.append(.releasePlan)\n")]},
    {"id": "D2", "requirement": "release disposition completed is treated as a failure",
     "description": "a completed plan is listed as a failed step",
     "replacements": [("    case .completed:\n      succeeded += 1\n",
                       "    case .completed:\n      failedSteps.append(.releasePlan)\n")]},
    {"id": "D3", "requirement": "release disposition partial is swallowed",
     "description": "a partial plan is counted as a success",
     "replacements": [("    case .partial:\n      succeeded += 1\n      failedSteps.append(.releasePlan)\n",
                       "    case .partial:\n      succeeded += 1\n")]},
    {"id": "D4", "requirement": "release disposition failed is swallowed",
     "description": "a failed plan is counted as a success",
     "replacements": [("    case .failed:\n      failedSteps.append(.releasePlan)\n",
                       "    case .failed:\n      succeeded += 1\n")]},
    {"id": "D5", "requirement": "the recovery never reports failed",
     "description": "a recovery with no successful step reports partial",
     "replacements": [("    } else if succeeded == 0 {\n", "    } else if succeeded < 0 {\n")]},
    {"id": "I1", "requirement": "cleanup runs twice with a visible effect",
     "description": "a reentrant or concurrent call runs the steps again instead of notRequired",
     "replacements": [(GUARD, "    _ = alreadyRunning\n")]},
    {"id": "P1", "requirement": "a key identity leaks into the report",
     "description": "the report gains a field holding the plan's events",
     "replacements": [
         ("  package let disposition: CleanupDisposition\n\n  package init(\n",
          "  package let disposition: CleanupDisposition\n  package var events: [KVMEvent] = []\n\n"
          "  package init(\n"),
         ("    let report = FailSafeReport(", "    var report = FailSafeReport("),
         ("failedSteps: failedSteps, disposition: disposition)\n",
          "failedSteps: failedSteps, disposition: disposition)\n    report.events = plan.steps\n")]},
    {"id": "R1", "requirement": "review nit: the running flag is never reset",
     "description": "recover leaves recovering set, so later calls and joiners never run",
     "replacements": [("    let waiting = lock.withLock { () -> [CheckedContinuation<CleanupDisposition, Never>] in\n      recovering = false\n",
                       "    let waiting = lock.withLock { () -> [CheckedContinuation<CleanupDisposition, Never>] in\n")]},
    {"id": "L1", "requirement": "extra: the ledger's buttons are left out of the plan",
     "description": "releasePlan(for:) passes no buttons",
     "replacements": [("      buttons: ledger.heldButtons)\n", "      buttons: [])\n")]},
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
    parser.add_argument("--out", default="evidence/issues/M1-063/mutations/mutations.json")
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
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m1-063-mutations-"))
    backup = backup_directory / "FailSafeCoordinator.swift.backup"
    tests_backup = backup_directory / "FailSafeCoordinatorTests.swift.backup"
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
        "issue": "M1-063",
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
