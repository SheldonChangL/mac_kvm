"""M4-021-FOLLOWUP-001 mutation runner.

Usage:
  python3 -I evidence/issues/M4-021-FOLLOWUP-001/mutations/run_mutations.py <repository> \
      --test-command '<shell command run from <repository> that builds and runs the tests>' \
      [--out <json>]

LinuxTrustedServerStore.swift builds only on Linux, so the test command builds and runs the
trusted-server store tests in a Linux container with <repository> mounted at /src, for example:

  docker exec <container> bash -c 'cd /src && swift build --build-tests --scratch-path /scratch \
    2>&1 | tail -1 && timeout 300 swift test --skip-build --scratch-path /scratch \
    --filter "LinuxTrust|LinuxFirstUse"'

Each mutant is one or more exact text replacements; every searched text must occur exactly
once. A mutant is killed when the build succeeded and every test in its `killers` list failed
(or the run timed out, exit 124, with no killer passing). After each mutant the file is restored
from a backup and compared byte for byte. A baseline run on the unmodified tree must pass first.
Exit 0 only when the baseline passes, every mutant is killed and every restore is clean. The
JSON holds repository-relative paths only.
"""

import argparse
import datetime
import json
import pathlib
import re
import shutil
import subprocess
import sys

SOURCE = "Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxTrustedServerStore.swift"
TIMEOUT_SECONDS = 1200

WIDE_FILE = "a record file with a mode wider than 0600 is refused"
WIDE_DIR = "a directory with a mode wider than 0700 is refused"
ROUND_TRIP = "insert, load and remove round-trip through a 0600 file in a 0700 directory"
MALFORMED = "a malformed line rejects the whole file and nothing is rewritten"
FORMAT = "anything that is not exactly a list of records is refused"
FIRST_USE_EXISTING = "first use: trust never replaces a different record and reports the change"

MUTANTS = [
    {
        "id": "M1", "rule": "a directory mode wider than 0700 is refused",
        "mutation": "group and other bits allowed on the directory",
        "edits": [("directoryForbiddenBits: mode_t = 0o7077",
                   "directoryForbiddenBits: mode_t = 0o7000")],
        "killers": [WIDE_DIR],
    },
    {
        "id": "M2", "rule": "a file mode wider than 0600 is refused",
        "mutation": "group and other read bits allowed on the record file",
        "edits": [("fileForbiddenBits: mode_t = 0o7177", "fileForbiddenBits: mode_t = 0o7133")],
        "killers": [WIDE_FILE, "first use: a storage failure is a failure, never a prompt"],
    },
    {
        "id": "M3", "rule": "a symbolic link in place of the record file is refused",
        "mutation": "record file looked up and opened following links",
        "edits": [
            ("fstatat(directory, Self.fileName, &seen, AT_SYMLINK_NOFOLLOW)",
             "fstatat(directory, Self.fileName, &seen, 0)"),
            ("O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK", "O_RDONLY | O_CLOEXEC | O_NONBLOCK"),
        ],
        "killers": ["a symbolic link in place of the record file is refused"],
    },
    {
        "id": "M4", "rule": "a symbolic link in place of the directory is refused",
        "mutation": "directory checked with stat and opened following links",
        "edits": [
            ("if lstat(directoryPath, &seen) != 0 {", "if stat(directoryPath, &seen) != 0 {"),
            ("O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC", "O_RDONLY | O_DIRECTORY | O_CLOEXEC"),
        ],
        "killers": ["a symbolic link in place of the directory is refused"],
    },
    {
        "id": "M5", "rule": "another owner is refused",
        "mutation": "owner check removed",
        "edits": [("\n      && status.st_uid == environment.effectiveUserID()", "")],
        "killers": ["a record file owned by another user is refused (injected stat)",
                    "a directory owned by another user is refused (injected stat)"],
    },
    {
        "id": "M6", "rule": "an unknown line rejects the whole file",
        "mutation": "a line that is not two fields is skipped",
        "edits": [("guard fields.count == 2 else { return nil }",
                   "guard fields.count == 2 else { continue }")],
        "killers": [MALFORMED, FORMAT],
    },
    {
        "id": "M7", "rule": "a second record for one server rejects the file",
        "mutation": "duplicate keys accepted (last wins)",
        "edits": [(",\n        records[key] == nil\n", "\n")],
        "killers": [MALFORMED, FORMAT],
    },
    {
        "id": "M8", "rule": "only normalized host:port keys are accepted",
        "mutation": "a key that normalizes to another spelling is accepted",
        "edits": [("let key = PeerKey(rawValue: keyText), key.rawValue == keyText,\n"
                   "        Array(key.rawValue.utf8) == Array(fields[0]),",
                   "let key = PeerKey(rawValue: keyText),")],
        "killers": [MALFORMED, FORMAT],
    },
    {
        "id": "M9", "rule": "writes go to a temporary file, then rename",
        "mutation": "the record file is rewritten in place",
        "edits": [("      temporary,\n      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,",
                   "      Self.fileName,\n      O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,"),
                  ("renameat(directory, temporary, directory, Self.fileName) == 0", "true")],
        "killers": ["a write replaces the file by rename and leaves no temporary file"],
    },
    {
        "id": "M10", "rule": "the record file is created 0600",
        "mutation": "the new file is created 0644",
        "edits": [("      0o600\n    )", "      0o644\n    )"),
                  ("fchmod(descriptor, 0o600) == 0", "fchmod(descriptor, 0o644) == 0")],
        "killers": [ROUND_TRIP, "a write replaces the file by rename and leaves no temporary file"],
    },
    {
        "id": "M11", "rule": "the directory is created 0700",
        "mutation": "the directory is created 0755",
        "edits": [("mkdir(path, 0o700)", "mkdir(path, 0o755)")],
        "killers": [ROUND_TRIP],
    },
    {
        "id": "M12", "rule": "concurrent inserts keep one record (flock on the directory)",
        "mutation": "the directory lock is not taken",
        "edits": [("while flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) != 0 {", "while false {")],
        "killers": ["concurrent inserts for one server from separate instances keep exactly one record",
                    "concurrent inserts for different servers lose no record"],
    },
    {
        "id": "M13", "rule": "an existing record is never replaced",
        "mutation": "insert overwrites an existing record",
        "edits": [("          if let stored = records[peer] {\n"
                   "            return .success(.existing(storedFingerprint: stored))\n"
                   "          }\n", "")],
        "killers": ["a duplicate insert returns the existing record and changes nothing",
                    FIRST_USE_EXISTING],
    },
    {
        "id": "M14", "rule": "policy: a presented fingerprint that is not 32 bytes rejects",
        "mutation": "presented length not checked",
        "edits": [("    guard presented.count == LinuxFingerprintText.sha256DigestLength else {\n"
                   "      return .reject(.trustRejected)\n"
                   "    }\n"
                   "    guard let stored else { return .prompt }",
                   "    guard let stored else { return .prompt }")],
        "killers": ["the policy table"],
    },
    {
        "id": "M15", "rule": "policy: a different fingerprint is identityChanged",
        "mutation": "any stored 32-byte fingerprint allows",
        "edits": [("if stored == presented { return .allow }",
                   "if stored.count == presented.count { return .allow }")],
        "killers": ["the policy table", FIRST_USE_EXISTING],
    },
    {
        "id": "M16", "rule": "the change warning is redacted",
        "mutation": "the warning's description and mirror show the displays",
        "edits": [('package var description: String { "LinuxFingerprintChangeWarning(redacted)" }',
                   "package var description: String { trustedFingerprintDisplay }"),
                  ("Mirror(self, children: [:], displayStyle: .struct)",
                   'Mirror(self, children: ["trusted": trustedFingerprintDisplay], displayStyle: .struct)')],
        "killers": ["the change warning is redacted everywhere but its two display fields"],
    },
    {
        "id": "M17", "rule": "first use inserts if absent and re-reads",
        "mutation": "trust answers allow without re-reading",
        "edits": [("      return await evaluate(peer: peer, presentedFingerprint: presentedFingerprint)\n"
                   "    }\n  }\n}",
                   "      return .success(.allow)\n    }\n  }\n}")],
        "killers": [FIRST_USE_EXISTING],
    },
    {
        "id": "M18", "rule": "a load or insert from a cancelled task does nothing",
        "mutation": "insert skips the cancellation check",
        "edits": [("    guard !Task.isCancelled else { return .failure(Self.cancelled) }\n    let value",
                   "    let value")],
        "killers": ["load and insert from a cancelled task do nothing; remove still runs"],
    },
]


def run(command, repository):
    completed = subprocess.run(
        command, shell=True, cwd=repository, capture_output=True, text=True,
        timeout=TIMEOUT_SECONDS)
    return completed.returncode, completed.stdout + completed.stderr


def failed_tests(output):
    failed = set(re.findall(r'✘ Test "([^"]+)"', output))
    started = set(re.findall(r'◇ Test "([^"]+)" started', output))
    finished = set(re.findall(r'[✔✘] Test "([^"]+)" (?:passed|failed|with)', output))
    return failed | (started - finished)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    parser.add_argument("--test-command", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()
    repository = pathlib.Path(args.repository).resolve()
    source = repository / SOURCE
    original = source.read_bytes()
    text = original.decode()

    code, output = run(args.test_command, repository)
    baseline = {"exitCode": code, "passed": code == 0 and "✘" not in output,
                "failedTests": sorted(failed_tests(output)), "tail": output[-1500:] if code else ""}
    results = []
    ok = baseline["passed"]
    for mutant in MUTANTS:
        counts = [text.count(find) for find, _ in mutant["edits"]]
        entry = {k: mutant[k] for k in ("id", "rule", "mutation", "killers")}
        entry["file"] = SOURCE
        if any(count != 1 for count in counts):
            entry.update(killed=False, error=f"searched texts occur {counts} times")
            ok = False
            results.append(entry)
            print(f'{mutant["id"]}: searched texts occur {counts} times', flush=True)
            continue
        backup = source.with_suffix(".swift.mutation-backup")
        shutil.copyfile(source, backup)
        try:
            mutated = text
            for find, replace in mutant["edits"]:
                mutated = mutated.replace(find, replace)
            source.write_text(mutated)
            code, output = run(args.test_command, repository)
        finally:
            shutil.copyfile(backup, source)
            backup.unlink()
        built = "Build complete" in output
        failed = failed_tests(output)
        passed = set(re.findall(r'✔ Test "([^"]+)" (?:passed|with)', output))
        timed_out = code == 124 and not any(k in passed for k in mutant["killers"])
        killed = built and code != 0 and (
            timed_out or all(k in failed for k in mutant["killers"]))
        restored = source.read_bytes() == original
        entry.update(
            exitCode=code, built=built, killed=killed, timedOut=timed_out, restoredCleanly=restored,
            failedKillers=sorted(k for k in mutant["killers"] if k in failed))
        ok = ok and killed and restored
        results.append(entry)
        print(f'{mutant["id"]}: killed={killed} restored={restored}', flush=True)

    report = {
        "schemaVersion": 1,
        "issue": "M4-021-FOLLOWUP-001",
        "date": datetime.date.today().isoformat(),
        "baseline": baseline,
        "mutants": results,
        "allKilled": ok,
    }
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"baseline": baseline, "allKilled": ok}))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
