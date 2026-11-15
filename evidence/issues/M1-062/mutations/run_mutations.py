"""M1-062 mutation runner for InputStateLedger.

Usage (from anywhere):
  python3 -I evidence/issues/M1-062/mutations/run_mutations.py <repository> [--out <json>]
      [--only <id> ...] [--test-revision <git revision>]

For each mutant the runner edits the production source by exact text replacement, runs the
M1-062 suite from the root package (KVMCore has no package manifest of its own), records which
tests failed, and restores the source from a backup copy. A mutant is killed when the suite
exits non-zero with at least one named failing test and no compile error. Before the mutants it
runs the suite once unmodified (the baseline, which must pass). After every restore it checks
that the source is byte-for-byte the original and that `git diff --exit-code` on it returns 0,
so stage the source and the tests before running.

Adapted from the M1-046 runner. The JSON report holds repository-relative paths only. The exit
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

SOURCE = "Packages/KVMCore/Sources/KVMCore/InputStateLedger.swift"
TESTS = "Packages/KVMCore/Tests/KVMCoreTests/InputStateLedgerTests.swift"
COMMAND = ["swift", "test", "--filter", "InputStateLedger"]
TIMEOUT_SECONDS = 900

KEY_DOWN = "    case .down:\n      guard index == nil, overflowIndex == nil else { return .dropDuplicateDown }\n      if heldKeys.count"
BUTTON_DOWN = "    case .down:\n      guard index == nil, overflowIndex == nil else { return .dropDuplicateDown }\n      if heldButtons.count"
KEY_UP = "      if let index {\n        heldKeys.remove(at: index)\n        return .inject\n      }\n      guard let overflowIndex else { return .injectUnheldRelease }\n      overflowedKeys"
BUTTON_UP = "      if let index {\n        heldButtons.remove(at: index)\n        return .inject\n      }\n"

MUTANTS = [
    {"id": "1", "requirement": "a duplicate down is injected",
     "description": "a press of a held key is injected (and not re-recorded)",
     "replacements": [(KEY_DOWN, KEY_DOWN.replace("return .dropDuplicateDown", "return .inject"))]},
    {"id": "2", "requirement": "an unheld repeat is injected",
     "description": "every repeat is injected",
     "replacements": [("      return index == nil && overflowIndex == nil ? .dropUnheldRepeat : .inject\n",
                       "      return .inject\n")]},
    {"id": "3", "requirement": "an unheld release is recorded",
     "description": "a release of an unheld key is recorded as a held key",
     "replacements": [(KEY_UP, KEY_UP.replace(
         "guard let overflowIndex else { return .injectUnheldRelease }",
         "guard let overflowIndex else {\n        heldKeys.append(HeldKey(key: key, modifiers: modifierState))\n"
         "        return .injectUnheldRelease\n      }"))]},
    {"id": "4", "requirement": "a held release is not freed",
     "description": "a release of a held key is injected but the key stays held",
     "replacements": [(KEY_UP, KEY_UP.replace("        heldKeys.remove(at: index)\n",
                                              "        _ = index\n"))]},
    {"id": "5", "requirement": "press order is lost",
     "description": "a new press is inserted first instead of appended",
     "replacements": [("        heldKeys.append(HeldKey(key: key, modifiers: modifierState))\n",
                       "        heldKeys.insert(HeldKey(key: key, modifiers: modifierState), at: 0)\n")]},
    {"id": "6a", "requirement": "the bound is not enforced",
     "description": "the key bound check always admits",
     "replacements": [("      if heldKeys.count < keyBound {\n", "      if true || heldKeys.count < keyBound {\n")]},
    {"id": "6b", "requirement": "the overflow is not flagged",
     "description": "an overflowed key press is not counted",
     "replacements": [("        overflowedKeys.append(key)\n", "        _ = key\n")]},
    {"id": "6c", "requirement": "extra: the button bound is not enforced",
     "description": "the button bound check always admits",
     "replacements": [("      if heldButtons.count < buttonBound {\n",
                       "      if true || heldButtons.count < buttonBound {\n")]},
    {"id": "7", "requirement": "the snapshot exposes an identity",
     "description": "the snapshot gains a field holding the held keys",
     "replacements": [
         ("  package let clipboardTransaction: ClipboardTransactionID?\n\n",
          "  package let clipboardTransaction: ClipboardTransactionID?\n"
          "  package var keys: [HeldKey] = []\n\n"),
         ("      clipboardTransaction: clipboardTransaction)\n",
          "      clipboardTransaction: clipboardTransaction, keys: heldKeys)\n")]},
    {"id": "8", "requirement": "reset() is a no-op",
     "description": "reset() changes nothing",
     "replacements": [("  package mutating func reset() {\n    heldKeys = []\n",
                       "  package mutating func reset() {\n    return\n    heldKeys = []\n")]},
    {"id": "9", "requirement": "the clipboard transaction is not tracked",
     "description": "a clipboard event is injected without remembering its transaction",
     "replacements": [("      clipboardTransaction = payload.transactionID\n",
                       "      _ = payload\n")]},
    {"id": "10", "requirement": "Caps Lock is treated as a modifier",
     "description": "Caps Lock presses and releases are injected but not held, like a lock",
     "replacements": [("    let index = heldKeys.firstIndex { $0.key == key }\n",
                       "    if key == .capsLock, phase != .repeatKey { return .inject }\n"
                       "    let index = heldKeys.firstIndex { $0.key == key }\n")]},
    {"id": "R-M1a", "requirement": "review M1: a second down of an overflowed key is injected",
     "description": "the duplicate check ignores the overflow set",
     "replacements": [(KEY_DOWN, KEY_DOWN.replace("guard index == nil, overflowIndex == nil", "guard index == nil"))]},
    {"id": "R-M1b", "requirement": "review M1: repeats of an overflowed key are dropped",
     "description": "the repeat check ignores the overflow set",
     "replacements": [("      return index == nil && overflowIndex == nil ? .dropUnheldRepeat : .inject\n",
                       "      return index == nil ? .dropUnheldRepeat : .inject\n")]},
    {"id": "R-M2", "requirement": "review M2: releasing an overflowed key does not clear the flag",
     "description": "the overflowed key stays in the overflow set after its release",
     "replacements": [("      overflowedKeys.remove(at: overflowIndex)\n", "      _ = overflowIndex\n")]},
    {"id": "R-M2b", "requirement": "extra: releasing an overflowed button does not clear the flag",
     "description": "the overflowed button stays in the overflow set after its release",
     "replacements": [("      overflowedButtons.remove(at: overflowIndex)\n", "      _ = overflowIndex\n")]},
    {"id": "R-L3", "requirement": "review L3: a negative bound is not clamped to zero",
     "description": "the key bound is taken as given",
     "replacements": [("    keyBound = max(0, maximumHeldKeys)\n", "    keyBound = maximumHeldKeys == 0 ? 0 : abs(maximumHeldKeys)\n")]},
    {"id": "11", "requirement": "a button release frees a different button",
     "description": "a held button's release frees the first held button",
     "replacements": [(BUTTON_UP, BUTTON_UP.replace("heldButtons.remove(at: index)",
                                                    "_ = index\n      heldButtons.removeFirst()"))]},
    {"id": "12", "requirement": "extra: dropped key events reach the modifier ledger",
     "description": "every key event is applied to the modifier ledger",
     "replacements": [("      if decision == .inject || decision == .injectUnheldRelease {\n",
                       "      if true {\n")]},
    {"id": "13", "requirement": "extra: a duplicate button press is injected",
     "description": "a press of a held button is injected",
     "replacements": [(BUTTON_DOWN, BUTTON_DOWN.replace("return .dropDuplicateDown", "return .inject"))]},
]

FAILED_TEST = re.compile(r"Test (\w+)\([^)]*\)(?: with \d+ test cases?)? failed")
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
    parser.add_argument("--out", default="evidence/issues/M1-062/mutations/mutations.json")
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
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m1-062-mutations-"))
    backup = backup_directory / "InputStateLedger.swift.backup"
    tests_backup = backup_directory / "InputStateLedgerTests.swift.backup"
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
        "issue": "M1-062",
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
