"""M1-043 mutation runner for BarrierVirtualKeyMapper.

Usage (from anywhere):
  python3 -I evidence/issues/M1-043/mutations/run_mutations.py <repository> [--out <json>]

For each mutant the runner edits the production source by exact text replacement, runs the
M1-043 suite, records which tests failed, and restores the source from a backup copy. A mutant
is killed when the suite exits non-zero with at least one named failing test and no compile
error. Before the mutants it runs the suite once unmodified (the baseline, which must pass).
After every restore it checks that the source is byte-for-byte the original and that
`git diff --exit-code` on it returns 0, so stage the source before running.

The JSON report holds repository-relative paths only. It defaults to
evidence/issues/M1-043/mutations/mutations.json inside the repository. The exit code is 0 only
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

SOURCE = "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierVirtualKeyMapper.swift"
COMMAND = [
    "swift", "test", "--package-path", "Packages/BarrierCompatibility",
    "--filter", "BarrierVirtualKeyMapperTests",
]
TIMEOUT_SECONDS = 900
RETURN_TABLE = "    return table\n  }()"

MUTANTS = [
    {
        "id": "1",
        "requirement": "swap two punctuation entries",
        "description": "bracketleft (0x005B/0x007B) and bracketright (0x005D/0x007D) map to "
                       "each other's key",
        "replacements": [(
            "    (0x005B, 0x007B, .leftBracket), (0x005D, 0x007D, .rightBracket),",
            "    (0x005B, 0x007B, .rightBracket), (0x005D, 0x007D, .leftBracket),",
        )],
    },
    {
        "id": "2",
        "requirement": "map an unknown identifier to a default key instead of unknown(raw)",
        "description": "an identifier without a table row maps to .space",
        "replacements": [(
            "table[identifier.rawValue] ?? .unknown(UInt32(identifier.rawValue))",
            "table[identifier.rawValue] ?? .space",
        )],
    },
    {
        "id": "3",
        "requirement": "remove the 34 convention identifiers",
        "description": "0x0042-0x005A and the nine shifted digits other than 0x0021 are removed "
                       "from the table, so they fall back to unknown(raw)",
        "replacements": [(
            RETURN_TABLE,
            "    for identifier in UInt16(0x0042)...0x005A { table[identifier] = nil }\n"
            "    for identifier: UInt16 in [0x29, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28] {\n"
            "      table[identifier] = nil\n"
            "    }\n" + RETURN_TABLE,
        )],
    },
    {
        "id": "4a",
        "requirement": "map a shifted identifier to a different physical key from its "
                       "unshifted pair",
        "description": "the captured underscore 0x005F maps to the equal key; its plain pair "
                       "0x002D stays minus",
        "replacements": [(RETURN_TABLE, "    table[0x005F] = .punctuation(.equal)\n" + RETURN_TABLE)],
    },
    {
        "id": "4b",
        "requirement": "map a shifted identifier to a different physical key from its "
                       "unshifted pair",
        "description": "the convention identifier 0x0040 (@) maps to the 3 key; its plain pair "
                       "0x0032 stays the 2 key",
        "replacements": [(RETURN_TABLE, "    table[0x0040] = .digit(3)\n" + RETURN_TABLE)],
    },
    {
        "id": "5a",
        "requirement": "map Insert or keypad Enter to a catalog member",
        "description": "keypad Enter 0xEF8D maps to .enter",
        "replacements": [(RETURN_TABLE, "    table[0xEF8D] = .enter\n" + RETURN_TABLE)],
    },
    {
        "id": "5b",
        "requirement": "map Insert or keypad Enter to a catalog member",
        "description": "Insert 0xEF63 maps to .delete",
        "replacements": [(RETURN_TABLE, "    table[0xEF63] = .delete\n" + RETURN_TABLE)],
    },
    {
        "id": "6a",
        "requirement": "make kvmEvent(for:) drop the modifiers or change the phase",
        "description": "kvmEvent(for:) drops the modifiers",
        "replacements": [("modifiers: event.modifiers)", "modifiers: ModifierState())")],
    },
    {
        "id": "6b",
        "requirement": "make kvmEvent(for:) drop the modifiers or change the phase",
        "description": "kvmEvent(for:) turns a repeat into a press",
        "replacements": [(
            "phase: event.phase,",
            "phase: event.phase == .repeatKey ? .down : event.phase,",
        )],
    },
    {
        "id": "7a",
        "requirement": "extra: a raw-value shortcut",
        "description": "letters computed by arithmetic over 0x0041-0x007A, which turns "
                       "0x005B-0x0060 into out-of-domain letters",
        "replacements": [(
            "    table[identifier.rawValue] ?? .unknown(UInt32(identifier.rawValue))\n",
            "    if (0x0041...0x007A).contains(identifier.rawValue) {\n"
            "      return .letter(UInt8((identifier.rawValue - 0x0041) % 32))\n"
            "    }\n"
            "    return table[identifier.rawValue] ?? .unknown(UInt32(identifier.rawValue))\n",
        )],
    },
    {
        "id": "7b",
        "requirement": "extra: a raw-value shortcut",
        "description": "kvmEvent(for:) maps the button (the server's key code) instead of the "
                       "identifier",
        "replacements": [(
            ".key(key: virtualKey(for: event.identifier),",
            ".key(key: virtualKey(for: BarrierKeyIdentifier(rawValue: event.button.rawValue)),",
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


def git_diff_exit_code(repository: pathlib.Path) -> int:
    return subprocess.run(["git", "diff", "--exit-code", "--quiet", "--", SOURCE],
                          cwd=repository).returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    parser.add_argument("--out", default="evidence/issues/M1-043/mutations/mutations.json")
    arguments = parser.parse_args()
    repository = pathlib.Path(arguments.repository).resolve()
    source_path = repository / SOURCE
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", "--", SOURCE], cwd=repository,
                             capture_output=True).returncode == 0
    if not tracked:
        raise SystemExit("stage the source first: the git diff restore check needs it tracked")
    original = source_path.read_bytes()
    original_hash = sha256(original)
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m1-043-mutations-"))
    backup = backup_directory / "BarrierVirtualKeyMapper.swift.backup"
    shutil.copyfile(source_path, backup)

    baseline = run_suite(repository)
    print(f"baseline: exit {baseline['exitCode']}, {baseline['summary']}", flush=True)
    results = []
    clean = True
    try:
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
            diff_exit = git_diff_exit_code(repository)
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
    finally:
        shutil.copyfile(backup, source_path)
        shutil.rmtree(backup_directory, ignore_errors=True)

    baseline_ok = baseline["exitCode"] == 0 and not baseline["failingTests"]
    all_killed = all(result["killed"] for result in results)
    report = {
        "schemaVersion": 1,
        "issue": "M1-043",
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE,
        "sourceSha256": original_hash,
        "command": " ".join(COMMAND),
        "timeoutSeconds": TIMEOUT_SECONDS,
        "baseline": baseline,
        "mutants": results,
        "baselinePassed": baseline_ok,
        "allKilled": all_killed,
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
