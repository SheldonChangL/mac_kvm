"""M1-061 mutation runner for RecoveryCoordinator (MacRecoveryCoordinator.swift).

Usage (from anywhere):
  python3 -I evidence/issues/M1-061/mutations/run_mutations.py <repository> [--out <json>]
      [--only <id> ...]

For each mutant the runner edits the production source by exact text replacement, runs the
M1-061 suite under GNU `timeout`, reads the failing tests from the Swift Testing xunit report,
and restores the source from a backup copy. A mutant is killed when the suite exits non-zero
(not by `timeout`), at least one named test failed, there was no compile error, and every test
named in the mutant's `killers` is among the failures. Before the mutants it runs the suite once
unmodified (the baseline, which must pass). After every restore it checks that the source is
byte-for-byte the original and that `git diff --exit-code` on it returns 0, so stage the source
and the tests before running.

The suite has a one-minute time limit and cancellation-aware barriers, so a mutant that makes a
test wait fails that test at the limit instead of hanging; `timeout` is the second guard.

The JSON report holds repository-relative paths only. It defaults to
evidence/issues/M1-061/mutations/mutations.json inside the repository. The exit code is 0 only
when the baseline passes, every mutant is killed and every restore is clean.
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
import xml.etree.ElementTree as ElementTree

SOURCE = "Packages/KVMCore/Sources/KVMCore/MacRecoveryCoordinator.swift"
TESTS = "Packages/KVMCore/Tests/KVMCoreTests/MacRecoveryCoordinatorTests.swift"
TIMEOUT_SECONDS = 600
KILL_AFTER_SECONDS = 30
COMMAND = [
    "timeout", f"--kill-after={KILL_AFTER_SECONDS}", str(TIMEOUT_SECONDS),
    "swift", "test", "--filter", "MacRecoveryCoordinator",
]
TIMEOUT_EXIT_CODES = (124, 137)

WAKE_GUARD = (
    "      guard networkAvailable else {\n"
    "        awaitingNetworkAfterWake = true\n"
    "        return\n"
    "      }\n"
)
NETWORK_CONNECT = (
    "      awaitingNetworkAfterWake = false\n"
    "      await reconnector.connect()\n"
    "    case .willSleep:\n"
)
SLEEP_BRANCH = (
    "    case .willSleep:\n"
    "      awaitingNetworkAfterWake = false\n"
    "      await onSleep()\n"
    "      await reconnector.disconnect()\n"
)
DRAINING = "  private var draining = false\n"
HANDLE_BODY = (
    "    received &+= 1\n"
    "    let ticket = received\n"
    "    queued.append(signal)\n"
    "    resumeWaiters()\n"
    "    if !draining {\n"
    "      draining = true\n"
    "      Task { await self.drain() }\n"
    "    }\n"
    "    await wait(for: .processed(ticket))\n"
)

MUTANTS = [
    {
        "id": "1",
        "requirement": "wake connects although the network is unavailable",
        "description": "didWake calls connect() whatever the network state; it still remembers "
                       "the wake when the network is down",
        "replacements": [(
            WAKE_GUARD,
            "      if !networkAvailable {\n"
            "        awaitingNetworkAfterWake = true\n"
            "      }\n",
        )],
        "killers": ["wakeWithoutNetworkDoesNotConnect()"],
    },
    {
        "id": "2",
        "requirement": "sleep disconnects before the cleanup hook runs",
        "description": "willSleep calls disconnect() first and runs the onSleep hook after it",
        "replacements": [(
            "      await onSleep()\n      await reconnector.disconnect()\n",
            "      await reconnector.disconnect()\n      await onSleep()\n",
        )],
        "killers": [
            "sleepRunsTheCleanupHookBeforeDisconnecting()",
            "sleepAndWakeDriveTheReconnectManager()",
        ],
    },
    {
        "id": "3",
        "requirement": "network loss while connected triggers a disconnect",
        "description": "networkAvailable(false) calls disconnect()",
        "replacements": [(
            "      networkAvailable = available\n",
            "      networkAvailable = available\n"
            "      if !available { await reconnector.disconnect() }\n",
        )],
        "killers": ["networkLossWhileConnectedDoesNothing()"],
    },
    {
        "id": "4",
        "requirement": "a late networkAvailable(true) after a wake does not connect",
        "description": "the network's return clears the waiting wake without calling connect()",
        "replacements": [(
            NETWORK_CONNECT,
            "      awaitingNetworkAfterWake = false\n"
            "    case .willSleep:\n",
        )],
        "killers": ["lateNetworkAfterWakeConnectsOnce()"],
    },
    {
        "id": "5a",
        "requirement": "a duplicate wake starts a second connect beyond the supersede rule",
        "description": "wakes during an outage are counted, and the network's return calls "
                       "connect() once per wake instead of once",
        "replacements": [
            (DRAINING, DRAINING + "  private var extraWakes = 0\n"),
            (
                WAKE_GUARD,
                "      guard networkAvailable else {\n"
                "        if awaitingNetworkAfterWake { extraWakes += 1 }\n"
                "        awaitingNetworkAfterWake = true\n"
                "        return\n"
                "      }\n",
            ),
            (
                NETWORK_CONNECT,
                "      awaitingNetworkAfterWake = false\n"
                "      await reconnector.connect()\n"
                "      for _ in 0..<extraWakes { await reconnector.connect() }\n"
                "      extraWakes = 0\n"
                "    case .willSleep:\n",
            ),
        ],
        "killers": ["duplicateWakesConnectOncePerWakeAndOncePerOutage()"],
    },
    {
        "id": "5b",
        "requirement": "a duplicate wake starts a second connect beyond the supersede rule",
        "description": "a repeated wake while an earlier one waits for the network calls "
                       "connect() at once, and the network's return connects again",
        "replacements": [(
            "      guard networkAvailable else {\n",
            "      guard networkAvailable || awaitingNetworkAfterWake else {\n",
        )],
        "killers": ["duplicateWakesConnectOncePerWakeAndOncePerOutage()"],
    },
    {
        "id": "6",
        "requirement": "extra: signals are not processed one at a time",
        "description": "handle(_:) applies its signal at once on the reentrant actor, so a wake "
                       "that arrives during the sleep cleanup connects before the disconnect",
        "replacements": [(HANDLE_BODY, "    await apply(signal)\n")],
        "killers": ["signalsAreProcessedOneAtATimeInArrivalOrder()"],
    },
    {
        "id": "7",
        "requirement": "extra: a sleep keeps a wake that waits for the network",
        "description": "willSleep no longer clears awaitingNetworkAfterWake, so the network's "
                       "return connects during or after the sleep",
        "replacements": [(
            SLEEP_BRANCH,
            "    case .willSleep:\n"
            "      await onSleep()\n"
            "      await reconnector.disconnect()\n",
        )],
        "killers": ["sleepCancelsAPendingWakeReconnect()"],
    },
    {
        "id": "8",
        "requirement": "extra: a repeated sleep skips the cleanup hook",
        "description": "a willSleep with no didWake since the previous one calls disconnect() "
                       "without running the onSleep hook",
        "replacements": [
            (DRAINING, DRAINING + "  private var asleep = false\n"),
            (
                SLEEP_BRANCH,
                "    case .willSleep:\n"
                "      awaitingNetworkAfterWake = false\n"
                "      if !asleep { await onSleep() }\n"
                "      asleep = true\n"
                "      await reconnector.disconnect()\n",
            ),
            ("    case .didWake:\n", "    case .didWake:\n      asleep = false\n"),
        ],
        "killers": ["repeatedSleepRunsTheCleanupEveryTime()"],
    },
    {
        "id": "9",
        "requirement": "extra: a caller that stops waiting drops queued signals",
        "description": "a cancelled caller of handle(_:) empties the queue, so a queued wake "
                       "is never processed",
        "replacements": [(
            "    await wait(for: .processed(ticket))\n",
            "    await wait(for: .processed(ticket))\n"
            "    if Task.isCancelled { queued.removeAll() }\n",
        )],
        "killers": ["cancelledCallersStillHaveTheirSignalsProcessed()"],
    },
    {
        "id": "10",
        "requirement": "extra: before any network signal the network counts as unavailable",
        "description": "networkAvailable starts false, so a wake before the first network "
                       "report waits instead of connecting",
        "replacements": [(
            "  package private(set) var networkAvailable = true\n",
            "  package private(set) var networkAvailable = false\n",
        )],
        "killers": ["beforeAnyNetworkSignalTheNetworkCountsAsAvailable()"],
    },
    {
        "id": "11",
        "requirement": "extra: the network's return connects with no wake waiting",
        "description": "every networkAvailable(true) calls connect(), whether or not a wake "
                       "waits for it",
        "replacements": [(
            "      guard available, awaitingNetworkAfterWake else { return }\n",
            "      guard available else { return }\n",
        )],
        "killers": [
            "networkReportsWithoutAWakeCauseNoEffect()",
            "networkLossWhileConnectedDoesNothing()",
        ],
    },
    {
        "id": "12",
        "requirement": "extra (review): the source imports a module through an attribute and "
                       "writes text",
        "description": "`@preconcurrency import Foundation` is added and every signal writes to "
                       "standard error through FileHandle; behavior is otherwise unchanged, so "
                       "only the source check can catch it",
        "replacements": [
            (
                "/// A platform-neutral lifecycle or network signal (M1-061).\n",
                "@preconcurrency import Foundation\n\n"
                "/// A platform-neutral lifecycle or network signal (M1-061).\n",
            ),
            (
                "  private func apply(_ signal: RecoverySignal) async {\n",
                "  private func apply(_ signal: RecoverySignal) async {\n"
                "    FileHandle.standardError.write(Data())\n",
            ),
        ],
        "killers": ["productionSourceImportsNoPlatformModuleAndNeverLogs()"],
    },
]

RUN_SUMMARY = re.compile(r"Test run with \d+ tests? in \d+ suites? (passed|failed)[^\n]*")
COMPILE_ERROR = re.compile(r"\berror: ")
TIME_LIMIT = re.compile(r"Time limit was exceeded")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def failing_tests(report: pathlib.Path) -> list:
    """The names of the test cases with a failure in a Swift Testing xunit report."""
    if not report.exists():
        return []
    root = ElementTree.parse(report).getroot()
    names = {case.get("name") for case in root.iter("testcase")
             if case.find("failure") is not None or case.find("error") is not None}
    return sorted(name for name in names if name)


def run_suite(repository: pathlib.Path, scratch: pathlib.Path) -> dict:
    for stale in scratch.glob("xunit*.xml"):
        stale.unlink()
    command = COMMAND + ["--xunit-output", str(scratch / "xunit.xml")]
    started = time.monotonic()
    try:
        process = subprocess.run(command, cwd=repository, capture_output=True, text=True,
                                 timeout=TIMEOUT_SECONDS + KILL_AFTER_SECONDS + 60)
        exit_code, output = process.returncode, process.stdout + process.stderr
    except subprocess.TimeoutExpired as expired:
        exit_code = "timeout"
        partial = expired.stdout or ""
        output = partial.decode("utf-8", "replace") if isinstance(partial, bytes) else partial
    summary_line = RUN_SUMMARY.search(output)
    return {
        "exitCode": exit_code,
        "timedOut": exit_code == "timeout" or exit_code in TIMEOUT_EXIT_CODES,
        "durationSeconds": round(time.monotonic() - started, 1),
        "failingTests": failing_tests(scratch / "xunit-swift-testing.xml"),
        "timeLimitIssues": len(TIME_LIMIT.findall(output)),
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
    parser.add_argument("--out", default="evidence/issues/M1-061/mutations/mutations.json")
    parser.add_argument("--only", action="append", default=[],
                        help="run only the mutant with this id; repeat for more")
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
    tests_hash = sha256(tests_path.read_bytes())
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="m1-061-mutations-"))
    backup = scratch / "MacRecoveryCoordinator.swift.backup"
    shutil.copyfile(source_path, backup)

    results = []
    clean = True
    try:
        baseline = run_suite(repository, scratch)
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
                outcome = run_suite(repository, scratch)
            finally:
                shutil.copyfile(backup, source_path)
            restored = sha256(source_path.read_bytes()) == original_hash
            diff_exit = git_diff_exit_code(repository, SOURCE)
            clean = clean and restored and diff_exit == 0
            killers_failed = all(name in outcome["failingTests"] for name in mutant["killers"])
            killed = (outcome["exitCode"] not in (0, "timeout") and not outcome["timedOut"]
                      and bool(outcome["failingTests"]) and not outcome["compileError"]
                      and killers_failed)
            result = {
                "id": mutant["id"],
                "requirement": mutant["requirement"],
                "description": mutant["description"],
                "killers": mutant["killers"],
                "killersFailed": killers_failed,
                "killed": killed,
                **outcome,
                "restoredByteForByte": restored,
                "gitDiffExitCodeAfterRestore": diff_exit,
            }
            results.append(result)
            print(f"mutant {mutant['id']}: killed={killed} exit={outcome['exitCode']} "
                  f"failing={len(outcome['failingTests'])} killers={killers_failed} "
                  f"restored={restored} diff={diff_exit}", flush=True)
    finally:
        shutil.copyfile(backup, source_path)
        shutil.rmtree(scratch, ignore_errors=True)
    tests_unchanged = (sha256(tests_path.read_bytes()) == tests_hash
                       and git_diff_exit_code(repository, TESTS) == 0)
    clean = clean and tests_unchanged

    baseline_ok = baseline["exitCode"] == 0 and not baseline["failingTests"]
    all_killed = all(result["killed"] for result in results)
    report = {
        "schemaVersion": 1,
        "issue": "M1-061",
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE,
        "sourceSha256": original_hash,
        "tests": TESTS,
        "testsSha256": tests_hash,
        "command": " ".join(COMMAND + ["--xunit-output", "<temporary>/xunit.xml"]),
        "timeoutSeconds": TIMEOUT_SECONDS,
        "baseline": baseline,
        "mutants": results,
        "baselinePassed": baseline_ok,
        "allKilled": all_killed,
        "testsUnchanged": tests_unchanged,
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
