"""M1-046 mutation runner for ModifierStateLedger.

Usage (from anywhere):
  python3 -I evidence/issues/M1-046/mutations/run_mutations.py <repository> [--out <json>]
      [--only <id> ...] [--test-revision <git revision>]

For each mutant the runner edits the production source by exact text replacement, runs the
M1-046 suite from the root package (KVMCore has no package manifest of its own), records which
tests failed, and restores the source from a backup copy. A mutant is killed when the suite
exits non-zero with at least one named failing test and no compile error. Before the mutants it
runs the suite once unmodified (the baseline, which must pass). After every restore it checks
that the source is byte-for-byte the original and that `git diff --exit-code` on it returns 0,
so stage the source and the tests before running.

`--only` runs the listed mutants. `--test-revision` runs them against the test file as of that
git revision instead of the current one, which shows what an older suite caught; the current
test file is restored from a backup copy and checked like the source.

The JSON report holds repository-relative paths only. It defaults to
evidence/issues/M1-046/mutations/mutations.json inside the repository. The exit code is 0 only
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

SOURCE = "Packages/KVMCore/Sources/KVMCore/ModifierStateLedger.swift"
TESTS = "Packages/KVMCore/Tests/KVMCoreTests/ModifierStateLedgerTests.swift"
COMMAND = ["swift", "test", "--filter", "ModifierStateLedger"]
TIMEOUT_SECONDS = 900

STATE_LINE = "  package private(set) var state = ModifierState()\n"
GUARD = (
    "    guard case .key(let key, let phase, let modifiers) = event else {\n"
    "      return ModifierDiscrepancy()\n"
    "    }\n"
)
OWN_BLOCK = (
    "      case .down:\n"
    "        state[modifier] = true\n"
    "        reported[modifier] = true\n"
    "      case .up:\n"
    "        state[modifier] = false\n"
    "        reported[modifier] = false\n"
)
REPEAT_BLOCK = "      case .repeatKey:\n        break\n"
LOCK_BLOCK = (
    "    let toggled = key == .capsLock || lockMayHaveToggled\n"
    "    if toggled {\n"
    "      state.capsLock = modifiers.capsLock\n"
    "    }\n"
    "    let discrepancy = reconcile(with: reported)\n"
    "    state.capsLock = modifiers.capsLock\n"
    "    lockMayHaveToggled = key == .capsLock\n"
)
LOCK_TAIL = "    let discrepancy = reconcile(with: reported)\n    lockMayHaveToggled = key == .capsLock\n"
RETURN_LINE = "    return discrepancy\n"
CLEAR_BODY = (
    "  package mutating func clear() {\n"
    "    state = ModifierState()\n"
    "    lockMayHaveToggled = false\n"
    "  }\n"
)
CLASSIFICATION = (
    "    case .capsLock, .letter, .digit, .enter, .escape, .tab, .space, .backspace, .delete, "
    ".left,\n"
    "      .right, .up, .down, .home, .end, .pageUp, .pageDown, .function, .volumeUp, "
    ".volumeDown,\n"
    "      .mute, .punctuation, .unknown:\n"
    "      return nil\n"
)

MUTANTS = [
    {
        "id": "1a",
        "requirement": "the own-bit logic inverted",
        "description": "a modifier key's own press clears its flag and its own release sets it, "
                       "as the frame's inverted own bit would have it; the comparison follows "
                       "the inverted state",
        "replacements": [(OWN_BLOCK, OWN_BLOCK.replace("= true", "= TRUE")
                          .replace("= false", "= true").replace("= TRUE", "= false"))],
    },
    {
        "id": "1b",
        "requirement": "the own-bit logic inverted",
        "description": "the state follows the key, but the key's own bit is compared inverted: "
                       "clear on its own press and set on its own release, as the frame "
                       "carries it",
        "replacements": [(
            OWN_BLOCK,
            "      case .down:\n"
            "        state[modifier] = true\n"
            "        reported[modifier] = false\n"
            "      case .up:\n"
            "        state[modifier] = false\n"
            "        reported[modifier] = true\n",
        )],
    },
    {
        "id": "1c",
        "requirement": "extra: the own-bit logic replaced by the mask",
        "description": "a modifier key's flag is taken from its own frame's bit instead of the "
                       "key and phase",
        "replacements": [(
            OWN_BLOCK,
            "      case .down:\n"
            "        state[modifier] = modifiers[modifier]\n"
            "        reported[modifier] = modifiers[modifier]\n"
            "      case .up:\n"
            "        state[modifier] = modifiers[modifier]\n"
            "        reported[modifier] = modifiers[modifier]\n",
        )],
    },
    {
        "id": "2a",
        "requirement": "Caps Lock state taken from presses instead of the frame's lock bit",
        "description": "each Caps Lock press toggles the lock; no frame's lock bit is read",
        "replacements": [(
            LOCK_BLOCK,
            "    if key == .capsLock, phase == .down { state.capsLock.toggle() }\n" + LOCK_TAIL,
        )],
    },
    {
        "id": "2b",
        "requirement": "extra: Caps Lock state taken from presses instead of the frame's lock bit",
        "description": "Caps Lock is held like a modifier: set by its press, cleared by its "
                       "release",
        "replacements": [(
            LOCK_BLOCK,
            "    if key == .capsLock, phase != .repeatKey { state.capsLock = phase == .down }\n"
            + LOCK_TAIL,
        )],
    },
    {
        "id": "2c",
        "requirement": "extra: the lock bit copied only from Caps Lock frames",
        "description": "only Caps Lock's own frames update the lock bit; other keys only "
                       "reconcile it (the design sketch's literal wording)",
        "replacements": [(
            LOCK_BLOCK,
            "    if key == .capsLock { state.capsLock = modifiers.capsLock }\n" + LOCK_TAIL,
        )],
    },
    {
        "id": "3",
        "requirement": "clear() as a no-op",
        "description": "clear() leaves the state and a pending toggle unchanged",
        "replacements": [(CLEAR_BODY, "  package mutating func clear() {\n  }\n")],
    },
    {
        "id": "4",
        "requirement": "left and right modifiers not collapsed",
        "description": "presses of a modifier are counted, and its flag clears only when every "
                       "counted press has had a release",
        "replacements": [
            (STATE_LINE, STATE_LINE + "  private var presses: [HeldModifier: Int] = [:]\n"),
            (
                OWN_BLOCK,
                "      case .down:\n"
                "        presses[modifier] = (presses[modifier] ?? 0) + 1\n"
                "        state[modifier] = true\n"
                "        reported[modifier] = true\n"
                "      case .up:\n"
                "        presses[modifier] = max(0, (presses[modifier] ?? 0) - 1)\n"
                "        state[modifier] = (presses[modifier] ?? 0) > 0\n"
                "        reported[modifier] = state[modifier]\n",
            ),
        ],
    },
    {
        "id": "5",
        "requirement": "implied modifiers (reported held, no press seen) not reported",
        "description": "the implied set is always empty",
        "replacements": [(
            "      implied: Self.flags(reported, without: state),\n",
            "      implied: ModifierState(),\n",
        )],
    },
    {
        "id": "6",
        "requirement": "a stale modifier (ledger holds it, event says released) not reported",
        "description": "the stale set is always empty",
        "replacements": [(
            "      stale: Self.flags(state, without: reported))\n",
            "      stale: ModifierState())\n",
        )],
    },
    {
        "id": "7",
        "requirement": "extra: a stale modifier corrected from the mask",
        "description": "the ledger drops a held modifier that an event reports released, so a "
                       "release-all would skip it",
        "replacements": [(
            RETURN_LINE,
            "    state = Self.flags(state, without: discrepancy.stale)\n"
            "    return discrepancy\n",
        )],
    },
    {
        "id": "8",
        "requirement": "extra: an implied modifier adopted from the mask",
        "description": "the ledger adds a modifier that an event reports held without a press "
                       "(synthesis into the ledger)",
        "replacements": [(
            RETURN_LINE,
            "    state = ModifierState(\n"
            "      shift: state.shift || discrepancy.implied.shift,\n"
            "      control: state.control || discrepancy.implied.control,\n"
            "      option: state.option || discrepancy.implied.option,\n"
            "      command: state.command || discrepancy.implied.command,\n"
            "      capsLock: state.capsLock)\n"
            "    return discrepancy\n",
        )],
    },
    {
        "id": "9",
        "requirement": "extra: a modifier's repeat treated as a press",
        "description": "a repeat of Shift, Control, Option or Command sets its flag",
        "replacements": [(
            REPEAT_BLOCK,
            "      case .repeatKey:\n"
            "        state[modifier] = true\n"
            "        reported[modifier] = true\n",
        )],
    },
    {
        "id": "10",
        "requirement": "extra: isEmpty ignores the stale set",
        "description": "a discrepancy with only stale modifiers reads as empty",
        "replacements": [(
            "    implied == ModifierState() && stale == ModifierState()\n",
            "    implied == ModifierState()\n",
        )],
    },
    {
        "id": "11",
        "requirement": "extra: two fields crossed",
        "description": "the option field of implied and stale is computed from the command flags",
        "replacements": [(
            "      option: state.option && !other.option,\n",
            "      option: state.command && !other.command,\n",
        )],
    },
    {
        "id": "12",
        "requirement": "extra: a default branch in the key classification",
        "description": "behavior-neutral today; a later catalog modifier would silently count as "
                       "an ordinary key, so only the source check can catch it",
        "replacements": [(CLASSIFICATION, "    default:\n      return nil\n")],
    },
    {
        "id": "13",
        "requirement": "extra: events other than keys change the ledger",
        "description": "any event other than a key event (leaving the screen among them) clears "
                       "the ledger",
        "replacements": [(
            GUARD,
            "    guard case .key(let key, let phase, let modifiers) = event else {\n"
            "      state = ModifierState()\n"
            "      return ModifierDiscrepancy()\n"
            "    }\n",
        )],
    },
    {
        "id": "14",
        "requirement": "extra: a lock change made by a Caps Lock toggle reported",
        "description": "the first key event after a Caps Lock event compares its lock bit, so "
                       "every toggle-off reports a stale lock",
        "replacements": [(
            "    let toggled = key == .capsLock || lockMayHaveToggled\n",
            "    let toggled = key == .capsLock\n",
        )],
    },
    {
        "id": "15",
        "requirement": "extra: a lock change that no Caps Lock event explains not reported",
        "description": "every key event takes the lock bit without comparing it, so a lock "
                       "already on at enter is never reported",
        "replacements": [(
            "    let toggled = key == .capsLock || lockMayHaveToggled\n",
            "    let toggled = true\n",
        )],
    },
    {
        "id": "16",
        "requirement": "extra: the toggle exemption kept beyond the next key event",
        "description": "once a Caps Lock event was seen, no later lock change is reported",
        "replacements": [(
            "    lockMayHaveToggled = key == .capsLock\n",
            "    lockMayHaveToggled = lockMayHaveToggled || key == .capsLock\n",
        )],
    },
    {
        "id": "17",
        "requirement": "extra: clear() keeps a pending toggle",
        "description": "after a Caps Lock event and clear(), the next key event's lock bit is "
                       "taken without comparison",
        "replacements": [(
            "    lockMayHaveToggled = false\n",
            "",
        )],
    },
    {
        "id": "R1",
        "requirement": "independent review: a non-key event clears the pending toggle",
        "description": "an event other than a key event between a Caps Lock event and the next "
                       "key event ends the exemption",
        "replacements": [(
            GUARD,
            "    guard case .key(let key, let phase, let modifiers) = event else {\n"
            "      lockMayHaveToggled = false\n"
            "      return ModifierDiscrepancy()\n"
            "    }\n",
        )],
    },
    {
        "id": "R2",
        "requirement": "independent review: only a Caps Lock release opens the exemption",
        "description": "a Caps Lock press alone leaves the next key event's lock bit compared",
        "replacements": [(
            "    lockMayHaveToggled = key == .capsLock\n",
            "    lockMayHaveToggled = key == .capsLock && phase == .up\n",
        )],
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
    parser.add_argument("--out", default="evidence/issues/M1-046/mutations/mutations.json")
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
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m1-046-mutations-"))
    backup = backup_directory / "ModifierStateLedger.swift.backup"
    tests_backup = backup_directory / "ModifierStateLedgerTests.swift.backup"
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
        "issue": "M1-046",
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
