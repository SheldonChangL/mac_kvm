"""M1-050 mutation runner for ReleaseAllKeys.

Usage (from anywhere):
  python3 -I evidence/issues/M1-050/mutations/run_mutations.py <repository> [--out <json>]

For each mutant the runner edits the production source by exact text replacement, runs the M1-050
suite from the root package, records which tests failed and restores the source from a backup
copy. A mutant is killed when the suite exits non-zero with at least one named failing test and no
compile error. After every restore it checks that the source is byte-for-byte the original and that
`git diff --exit-code` on it returns 0, so stage the source and the tests before running.

The JSON report holds repository-relative paths only. The exit code is 0 only when the baseline
passes, every mutant is killed and every restore is clean.
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

SOURCE = "Packages/KVMCore/Sources/KVMCore/ReleaseAllKeys.swift"
TESTS = "Packages/KVMCore/Tests/KVMCoreTests/ReleaseAllKeysTests.swift"
COMMAND = ["swift", "test", "--filter", "ReleaseAllKeys"]
TIMEOUT_SECONDS = 900

PLAN_RETURN = "    return ReleasePlan(steps: ordinary + buttonReleases + modifierKeys)\n"
LOOP_OVER_KEYS = "    for held in keys.reversed() {\n"
BUTTONS = "    let buttonReleases = buttons.reversed().map"
RELEASE_LINE = (
    "      let release = KVMEvent.key(key: held.key, phase: .up, modifiers: held.modifiers)\n"
)
CATCH = "      } catch {\n        failed += 1\n      }\n"
TRY = "        try releaser.release(step)\n"
EMPTY = "    if attempted == 0 {\n      disposition = .notRequired\n"
ALL_FAILED = "    } else if failed == attempted {\n      disposition = .failed\n"
MODIFIER_CASE = "    case .shift, .control, .option, .command, .capsLock:\n      return true\n"

MUTANTS = [
    {
        "id": "1",
        "requirement": "modifiers released first",
        "description": "modifier keys come before the other keys and the buttons",
        "replacements": [(PLAN_RETURN,
                          "    return ReleasePlan(steps: modifierKeys + ordinary + buttonReleases)\n")],
    },
    {
        "id": "2",
        "requirement": "buttons released before keys",
        "description": "the buttons come before the non-modifier keys",
        "replacements": [(PLAN_RETURN,
                          "    return ReleasePlan(steps: buttonReleases + ordinary + modifierKeys)\n")],
    },
    {
        "id": "3",
        "requirement": "forward press order",
        "description": "keys and buttons release in press order instead of reverse",
        "replacements": [(LOOP_OVER_KEYS, "    for held in keys {\n"),
                         (BUTTONS, "    let buttonReleases = buttons.map")],
    },
    {
        "id": "3b",
        "requirement": "extra: forward press order for keys only",
        "description": "keys release in press order; buttons stay in reverse order",
        "replacements": [(LOOP_OVER_KEYS, "    for held in keys {\n")],
    },
    {
        "id": "3c",
        "requirement": "extra: forward press order for buttons only",
        "description": "buttons release in press order; keys stay in reverse order",
        "replacements": [(BUTTONS, "    let buttonReleases = buttons.map")],
    },
    {
        "id": "4",
        "requirement": "an early return after the first failure",
        "description": "execute stops at the first step that throws",
        "replacements": [(CATCH,
                          "      } catch {\n        failed += 1\n        break\n      }\n")],
    },
    {
        "id": "5",
        "requirement": "not idempotent",
        "description": "every step is attempted twice, so a run is not exactly one release per step",
        "replacements": [(TRY, "        try releaser.release(step)\n        try releaser.release(step)\n")],
    },
    {
        "id": "6",
        "requirement": "an empty plan not reported as notRequired",
        "description": "an empty plan reports completed",
        "replacements": [(EMPTY, "    if attempted == 0 {\n      disposition = .completed\n")],
    },
    {
        "id": "7",
        "requirement": "all steps failing reported as partial instead of failed",
        "description": "the failed disposition is never produced",
        "replacements": [(ALL_FAILED, "    } else if failed == attempted {\n      disposition = .partial\n")],
    },
    {
        "id": "8",
        "requirement": "a release without the press-time modifiers",
        "description": "each key release carries no modifiers",
        "replacements": [(RELEASE_LINE,
                          "      let release = KVMEvent.key(key: held.key, phase: .up, "
                          "modifiers: ModifierState())\n")],
    },
    {
        "id": "9",
        "requirement": "capsLock grouped with the non-modifier keys",
        "description": "capsLock is classified as an ordinary key",
        "replacements": [(MODIFIER_CASE,
                          "    case .shift, .control, .option, .command:\n      return true\n"),
                         ("      .punctuation, .unknown:\n      return false\n",
                          "      .punctuation, .unknown, .capsLock:\n      return false\n")],
    },
    {
        "id": "R1",
        "requirement": "independent review: failed also when all but one step failed",
        "description": "failed is reported when failed > 0 and failed + 1 >= attempted, so a "
                       "minority-of-one success and a two-step plan with one failure read failed",
        "replacements": [("    } else if failed == attempted {\n      disposition = .failed\n",
                          "    } else if failed > 0 && failed + 1 >= attempted {\n"
                          "      disposition = .failed\n")],
    },
    {
        "id": "10",
        "requirement": "extra: a failure counts as nothing",
        "description": "failed is never incremented, so a failing run reports completed",
        "replacements": [("        failed += 1\n", "        _ = step\n")],
    },
    {
        "id": "11",
        "requirement": "extra: the disposition ignores a partial failure",
        "description": "any failure short of all reports completed",
        "replacements": [("    } else if failed == 0 {\n      disposition = .completed\n",
                          "    } else if failed < attempted {\n      disposition = .completed\n")],
    },
    {
        "id": "12",
        "requirement": "extra: only the first modifier group member classified",
        "description": "control, option and command are treated as ordinary keys",
        "replacements": [(MODIFIER_CASE, "    case .shift, .capsLock:\n      return true\n"),
                         ("      .punctuation, .unknown:\n      return false\n",
                          "      .punctuation, .unknown, .control, .option, .command:\n"
                          "      return false\n")],
    },
    {
        "id": "13",
        "requirement": "extra: the release phase is a press",
        "description": "key releases are composed with phase down",
        "replacements": [(RELEASE_LINE,
                          "      let release = KVMEvent.key(key: held.key, phase: .down, "
                          "modifiers: held.modifiers)\n")],
    },
]

FAILED_TEST = re.compile(r"Test (\w+)\(\) failed")
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
    parser.add_argument("--out", default="evidence/issues/M1-050/mutations/mutations.json")
    arguments = parser.parse_args()
    repository = pathlib.Path(arguments.repository).resolve()
    source_path = repository / SOURCE
    tests_path = repository / TESTS
    for path in (SOURCE, TESTS):
        if not is_tracked(repository, path):
            raise SystemExit("stage the source and the tests first: the git diff restore "
                             "check needs them tracked")
    original = source_path.read_bytes()
    original_hash = sha256(original)
    tests_hash = sha256(tests_path.read_bytes())
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m1-050-mutations-"))
    backup = backup_directory / "ReleaseAllKeys.swift.backup"
    shutil.copyfile(source_path, backup)

    results = []
    clean = True
    try:
        baseline = run_suite(repository)
        print(f"baseline: exit {baseline['exitCode']}, {baseline['summary']}", flush=True)
        for mutant in MUTANTS:
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
            results.append({
                "id": mutant["id"],
                "requirement": mutant["requirement"],
                "description": mutant["description"],
                "killed": killed,
                **outcome,
                "restoredByteForByte": restored,
                "gitDiffExitCodeAfterRestore": diff_exit,
            })
            print(f"mutant {mutant['id']}: killed={killed} exit={outcome['exitCode']} "
                  f"failing={len(outcome['failingTests'])} restored={restored} "
                  f"diff={diff_exit}", flush=True)
            print(f"  failing: {', '.join(outcome['failingTests']) or 'none'}", flush=True)
    finally:
        shutil.copyfile(backup, source_path)
        shutil.rmtree(backup_directory, ignore_errors=True)
    tests_untouched = (sha256(tests_path.read_bytes()) == tests_hash
                       and git_diff_exit_code(repository, TESTS) == 0)
    clean = clean and tests_untouched

    baseline_ok = baseline["exitCode"] == 0 and not baseline["failingTests"]
    all_killed = all(result["killed"] for result in results)
    report = {
        "schemaVersion": 1,
        "issue": "M1-050",
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE,
        "sourceSha256": original_hash,
        "tests": TESTS,
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
