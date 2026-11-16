"""M4-026 mutation runner.

Usage:
  python3 -I evidence/issues/M4-026/mutations/run_mutations.py <repository> \
      --test-command '<shell command run from <repository> that builds and runs the tests>' \
      [--out <json>]

LinuxX11Clipboard.swift builds only on Linux and its behavior tests need an X server, so the
test command runs the LinuxX11Clipboard tests in a Linux container under Xvfb with
MACKVM_X11_TESTS=1, for example:

  docker exec <container> bash -c 'cd /src && swift build --build-tests --scratch-path /scratch \
    && MACKVM_X11_TESTS=1 xvfb-run -a -s "-screen 0 1600x900x24" timeout 90 \
       swift test --skip-build --scratch-path /scratch --filter LinuxX11Clipboard'

with <repository> mounted at /src. Each mutant is an exact text replacement whose searched
text must occur exactly once. A mutant is killed when the build succeeded and every test in its
`killers` list failed: it printed a failure line, or it started and never finished because the
mutant made it wait forever and the `timeout` in the test command ended the run (exit 124,
recorded as `timedOut`; the output of a killed run can be lost in the pipe buffer, so a
timed-out run counts when no killer printed a pass). After each
mutant the file is restored from a backup and compared byte for byte. A baseline run on the
unmodified tree must pass first. Exit 0 only when the baseline passes, every mutant is killed
and every restore is clean. The JSON holds repository-relative paths only.
"""

import argparse
import datetime
import json
import pathlib
import re
import shutil
import subprocess
import sys

SOURCE = "Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Clipboard.swift"
TIMEOUT_SECONDS = 900

MUTANTS = [
    {
        "id": "M1",
        "rule": "STRING is served only for Latin-1 text",
        "mutation": "TARGETS always lists STRING",
        "find": "      if content.latin1 != nil {\n        list.append(atoms.string)",
        "replace": "      if true {\n        list.append(atoms.string)",
        "killers": ["TARGETS lists STRING only when the text is Latin-1, and STRING carries Latin-1"],
    },
    {
        "id": "M2",
        "rule": "Latin-1 check",
        "mutation": "scalars up to U+FFFF count as Latin-1",
        "find": "guard scalar.value <= 0xFF else { return nil }",
        "replace": "guard scalar.value <= 0xFFFF else { return nil }",
        "killers": ["Latin-1 conversion accepts U+0000 to U+00FF and refuses anything above"],
    },
    {
        "id": "M3",
        "rule": "INCR stated size over the limit is refused before any chunk",
        "mutation": "the stated INCR size is not checked",
        "find": "      guard stated <= current.limit else {",
        "replace": "      guard stated <= current.limit || true else {",
        "killers": ["a read over the limit is refused before the content is transferred"],
    },
    {
        "id": "M4",
        "rule": "INCR reassembly is bounded by the limit",
        "mutation": "received chunks are not checked against the limit",
        "find": "    guard received.count + header.byteCount <= current.limit else {",
        "replace": "    guard received.count + header.byteCount <= current.limit || true else {",
        "killers": ["a read over the limit is refused before the content is transferred"],
    },
    {
        "id": "M5",
        "rule": "a whole property over the limit is refused before it is fetched",
        "mutation": "the property size is not checked",
        "find": "    guard header.byteCount <= current.limit else {",
        "replace": "    guard header.byteCount <= current.limit || true else {",
        "killers": ["a read over the limit is refused before the content is transferred"],
    },
    {
        "id": "M6",
        "rule": "ownerChanges never fires for our own window (loop prevention)",
        "mutation": "the own-window filter is dropped",
        "find": "&& notify.owner != window",
        "replace": "",
        "killers": ["ownerChanges stays quiet for our own writes"],
    },
    {
        "id": "M7",
        "rule": "ownerChanges fires for another application's copy",
        "mutation": "ownerChanges never yields",
        "find": "        ownerChanges.yield()\n",
        "replace": "        _ = ()\n",
        "killers": ["ownerChanges fires for another application's copy"],
    },
    {
        "id": "M8",
        "rule": "2 s read deadline",
        "mutation": "the read deadline is 5 s",
        "find": "package static let readTimeout: Duration = .seconds(2)",
        "replace": "package static let readTimeout: Duration = .seconds(5)",
        "killers": [
            "the read deadline is 2 seconds",
            "an owner that never answers times out within the deadline",
        ],
    },
    {
        "id": "M9",
        "rule": "a write over the limit is refused and changes nothing",
        "mutation": "the write size check is dropped",
        "find": "    guard text.utf8.count <= limit.byteCount else {",
        "replace": "    guard text.utf8.count <= limit.byteCount || true else {",
        "killers": ["a write over the limit is refused and leaves the clipboard as it was"],
    },
    {
        "id": "M10",
        "rule": "a call from a cancelled task fails with cancellation.requested",
        "mutation": "writePlainText ignores cancellation",
        "find": (
            "  package func writePlainText(_ text: String, limit: ClipboardByteLimit) async"
            " -> CoreResult<Void> {\n    guard !Task.isCancelled else {"
        ),
        "replace": (
            "  package func writePlainText(_ text: String, limit: ClipboardByteLimit) async"
            " -> CoreResult<Void> {\n    guard !Task.isCancelled || true else {"
        ),
        "killers": ["a call from a cancelled task fails with cancellation and changes nothing"],
    },
    {
        "id": "M11",
        "rule": "stop ends a read in progress (cleanup)",
        "mutation": "shutdown does not answer the read in progress",
        "find": "    read?.reply(.failure(unavailable))\n",
        "replace": "",
        "killers": ["stop while a read waits on a silent owner ends the read"],
    },
    {
        "id": "M12",
        "rule": "contentHash is lowercase SHA-256 hex",
        "mutation": "hex digits are not zero-padded",
        "find": 'return byte < 0x10 ? "0" + hex : hex',
        "replace": "return hex",
        "killers": [
            "the content hash is the lowercase SHA-256 hex of the UTF-8 bytes, and stable",
        ],
    },
    {
        "id": "M13",
        "rule": "content above a quarter of the maximum request goes out with INCR",
        "mutation": "INCR is never used",
        "find": "    byteCount > chunkByteCount\n",
        "replace": "    false\n",
        "killers": [
            "content larger than a quarter of the maximum request is sent with INCR",
            "1 MiB goes out through INCR",
        ],
    },
    {
        "id": "M14",
        "rule": "an abandoned transfer never lands in the next read",
        "mutation": "every read uses the same property",
        "find": "      readPropertyIndex = (readPropertyIndex + 1) % atoms.readProperties.count\n",
        "replace": "",
        "killers": ["an abandoned INCR transfer does not leak into the next read"],
    },
    {
        "id": "M15",
        "rule": "malformed UTF-8 fails with invalidUTF8 and is never repaired",
        "mutation": "bytes are decoded with replacement characters",
        "find": "let text = try ClipboardTextCodec.decode(Data(bytes), limit: byteLimit)",
        "replace": "let text = String(decoding: bytes, as: UTF8.self)",
        "killers": ["malformed UTF-8 fails with invalidUTF8 and is never repaired"],
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
    finished = set(re.findall(r'[✔✘] Test "([^"]+)" (?:passed|failed)', output))
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
        count = text.count(mutant["find"])
        entry = {k: mutant[k] for k in ("id", "rule", "mutation", "killers")}
        entry["file"] = SOURCE
        if count != 1:
            entry.update(killed=False, error=f"searched text occurs {count} times")
            ok = False
            results.append(entry)
            continue
        backup = source.with_suffix(".swift.mutation-backup")
        shutil.copyfile(source, backup)
        try:
            source.write_text(text.replace(mutant["find"], mutant["replace"]))
            code, output = run(args.test_command, repository)
        finally:
            shutil.copyfile(backup, source)
            backup.unlink()
        built = "Build complete" in output
        failed = failed_tests(output)
        passed = set(re.findall(r'✔ Test "([^"]+)" passed', output))
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
        "issue": "M4-026",
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
