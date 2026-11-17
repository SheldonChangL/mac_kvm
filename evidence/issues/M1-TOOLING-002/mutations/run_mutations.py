"""M1-TOOLING-002 mutation runner.

Usage: python3 -I evidence/issues/M1-TOOLING-002/mutations/run_mutations.py <repository> [--out <json>]

Each mutant edits one tracked file by exact text replacement, runs the Tools/Evidence unittest
suite, records the failing test names, and restores the file from a backup. A mutant is killed
when the suite exits non-zero with at least one named FAIL/ERROR. After every restore the file
must be byte-identical and `git diff --quiet -- <file>` must hold against the index, so stage
the sources before running. Exit 0 only if the baseline passes, all mutants are killed and
every restore is clean.
"""

import argparse
import datetime
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ISSUE = "M1-TOOLING-002"
RUN = "Tools/Evidence/run_e2e.py"
VAL = "Tools/Evidence/validate_evidence.py"
SCHEMA = "MacKVM_Implementation_Package_v2/schemas/e2e-result.schema.json"
COMMAND = [sys.executable, "-I", "-m", "unittest", "discover", "-s", "Tools/Evidence/tests"]

ID = "M[1-5]-[0-9]{3}"
SUFFIX = "(?:-FOLLOWUP-[0-9]{3})?"
ISSUE_LINE = 'ISSUE_PATTERN = re.compile(r"' + ID + SUFFIX + '")'


def issue_line(tail, flags=""):
    return 'ISSUE_PATTERN = re.compile(r"' + ID + tail + '"' + flags + ")"


ARTIFACT_LINE = 'r"(?:evidence/e2e/' + ID + SUFFIX + '|Tests/Fixtures)"'


def artifact_line(tail):
    return 'r"(?:evidence/e2e/' + ID + tail + '|Tests/Fixtures)"'


MANY = "(?:-FOLLOWUP-[0-9]{3})*"
NODIGITS = "(?:-FOLLOWUP-[0-9]*)?"

# Mutant 5 (dropping the FOLLOWUP group from SCRIPT_NAME_PATTERN) is an equivalent mutant: the
# free-form name tail already matches "FOLLOWUP-001-...", so it is not run. The ids stay as is.
# (id, file, requirement, description, [(old, new)])
MUTANTS = [
    ("1", RUN, "runner accepts FOLLOWUP ids", "runner ISSUE_PATTERN loses the FOLLOWUP group",
     [(ISSUE_LINE, issue_line(""))]),
    ("2", RUN, "two suffixes rejected", "runner ISSUE_PATTERN allows repeated suffixes",
     [(ISSUE_LINE, issue_line(MANY))]),
    ("3", RUN, "FOLLOWUP without digits rejected", "runner ISSUE_PATTERN accepts zero digits",
     [(ISSUE_LINE, issue_line(NODIGITS))]),
    ("4", RUN, "lower case rejected", "runner ISSUE_PATTERN is case-insensitive",
     [(ISSUE_LINE, issue_line(SUFFIX, ", re.IGNORECASE"))]),
    ("6", RUN, "base id does not claim FOLLOWUP scripts",
     "resolve_script no longer excludes FOLLOWUP scripts for a base id",
     [('excludes_followup = "-FOLLOWUP-" not in issue', "excludes_followup = False")]),
    ("7", VAL, "validator accepts FOLLOWUP ids", "validator ISSUE_PATTERN loses the FOLLOWUP group",
     [(ISSUE_LINE, issue_line(""))]),
    ("8", VAL, "two suffixes rejected", "validator ISSUE_PATTERN allows repeated suffixes",
     [(ISSUE_LINE, issue_line(MANY))]),
    ("9", VAL, "FOLLOWUP without digits rejected", "validator ISSUE_PATTERN accepts zero digits",
     [(ISSUE_LINE, issue_line(NODIGITS))]),
    ("10", VAL, "artifact path accepts FOLLOWUP directory",
     "validator ARTIFACT_PATH_PATTERN loses the FOLLOWUP group",
     [(ARTIFACT_LINE, artifact_line(""))]),
    ("11", VAL, "artifact path rejects two suffixes",
     "validator ARTIFACT_PATH_PATTERN allows repeated suffixes",
     [(ARTIFACT_LINE, artifact_line(MANY))]),
    ("12", SCHEMA, "schema issueId accepts FOLLOWUP ids", "schema issueId pattern loses the FOLLOWUP group",
     [('"pattern": "^' + ID + SUFFIX + '$"', '"pattern": "^' + ID + '$"')]),
    ("13", SCHEMA, "schema artifact path accepts FOLLOWUP directory",
     "schema artifact path pattern loses the FOLLOWUP group",
     [("^(evidence/e2e/" + ID + SUFFIX + "|", "^(evidence/e2e/" + ID + "|")]),
]


def sh(args, cwd):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=600)


def failing(output):
    return sorted(set(re.findall(r"^(?:FAIL|ERROR): (\S+) \(([^)]+)\)", output, re.M)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    parser.add_argument("--out")
    options = parser.parse_args()
    root = pathlib.Path(options.repository).resolve()
    out = (
        pathlib.Path(options.out)
        if options.out
        else root / "evidence/issues" / ISSUE / "mutations/mutations.json"
    )
    baseline = sh(COMMAND, root)
    report = {
        "schemaVersion": 1,
        "issue": ISSUE,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "command": "python3 -I -m unittest discover -s Tools/Evidence/tests",
        "baselineExitCode": baseline.returncode,
        "mutants": [],
    }
    ok = baseline.returncode == 0
    backup_dir = pathlib.Path(tempfile.mkdtemp())
    try:
        for ident, rel, requirement, description, replacements in MUTANTS:
            path = root / rel
            original = path.read_bytes()
            backup = backup_dir / ("m" + ident)
            shutil.copyfile(path, backup)
            text = original.decode()
            applied = True
            for old, new in replacements:
                if old not in text:
                    applied = False
                    break
                text = text.replace(old, new, 1)
            entry = {
                "id": ident,
                "file": rel,
                "requirement": requirement,
                "description": description,
                "applied": applied,
            }
            if applied:
                path.write_text(text)
                try:
                    result = sh(COMMAND, root)
                finally:
                    shutil.copyfile(backup, path)
                tests = ["%s (%s)" % pair for pair in failing(result.stderr + result.stdout)]
                entry.update(
                    exitCode=result.returncode,
                    killingTests=tests,
                    killed=result.returncode != 0 and bool(tests),
                )
            else:
                entry["killed"] = False
            clean = (
                path.read_bytes() == original
                and sh(["git", "diff", "--quiet", "--", rel], root).returncode == 0
            )
            entry["restoredClean"] = clean
            ok = ok and entry["killed"] and clean
            report["mutants"].append(entry)
    finally:
        shutil.rmtree(backup_dir, ignore_errors=True)
    report["allKilled"] = ok
    out.write_text(json.dumps(report, indent=2) + "\n")
    killed = sum(1 for m in report["mutants"] if m["killed"])
    print("baseline exit %d; %d/%d killed; ok=%s" % (baseline.returncode, killed, len(MUTANTS), ok))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
