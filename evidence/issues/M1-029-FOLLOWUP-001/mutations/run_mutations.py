"""M1-029-FOLLOWUP-001 mutation runner for BarrierClientProtocolSession and
BarrierClientControlEncoder.

Usage (from anywhere):
  python3 -I evidence/issues/M1-029-FOLLOWUP-001/mutations/run_mutations.py <repository>
      [--out <json>] [--only <id> ...]

For each mutant the runner edits one production source by exact text replacement, runs the two
M1-029-FOLLOWUP-001 suites, records which tests failed, and restores the source from a backup
copy. A mutant is killed when the suites exit non-zero with at least one named failing test and
no compile error. Before the mutants it runs the suites once unmodified (the baseline, which
must pass). After every restore it checks that the source is byte-for-byte the original and
that `git diff --exit-code` on it returns 0, so stage the sources before running.

The JSON report holds repository-relative paths only. It defaults to
evidence/issues/M1-029-FOLLOWUP-001/mutations/mutations.json inside the repository. The exit
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

ISSUE = "M1-029-FOLLOWUP-001"
SESSION = "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClientProtocolSession.swift"
ENCODER = "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClientControlEncoder.swift"
TESTS = (
    "Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/"
    "BarrierClientProtocolSessionTests.swift",
    "Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/"
    "BarrierClientControlEncoderTests.swift",
)
COMMAND = [
    "swift", "test", "--package-path", "Packages/BarrierCompatibility",
    "--filter", "BarrierClient(ProtocolSession|ControlEncoder)Tests",
]
TIMEOUT_SECONDS = 900

UNPAIRED_REPEAT_GUARD = "    if event.phase == .repeatKey, event.pairing == .unpaired {\n"

MUTANTS = [
    {
        "id": "1",
        "file": SESSION,
        "requirement": "control decoder consulted before the input decoders",
        "description": "route() offers every BarrierControlToken (DKDN, DKUP and DCLP among "
                       "them) to BarrierControlDecoder before the input and clipboard decoders",
        "replacements": [(
            "    if BarrierMouseMoveToken(payloadPrefix: payload) != nil { return "
            "pointerFrame(payload) }\n",
            "    if BarrierControlToken(payloadPrefix: payload) != nil { return "
            "controlFrame(payload) }\n"
            "    if BarrierMouseMoveToken(payloadPrefix: payload) != nil { return "
            "pointerFrame(payload) }\n",
        )],
    },
    {
        "id": "1b",
        "file": SESSION,
        "requirement": "control decoder consulted before the input decoders",
        "description": "DKRP, which BarrierControlToken does not know, falls through to "
                       "BarrierControlDecoder instead of the key decoder",
        "replacements": [(
            "    if BarrierKeyboardToken(payloadPrefix: payload) != nil { return "
            "keyFrame(payload) }\n",
            "    if BarrierKeyboardToken(payloadPrefix: payload) != nil,\n"
            "      BarrierControlToken(payloadPrefix: payload) != nil\n"
            "    {\n"
            "      return keyFrame(payload)\n"
            "    }\n",
        )],
    },
    {
        "id": "2",
        "file": SESSION,
        "requirement": "unpaired repeat yielded",
        "description": "the M1-041 consumer check is missing: a DKRP of a key that is not held "
                       "is composed into a .repeatKey event",
        "replacements": [(
            UNPAIRED_REPEAT_GUARD + "      count(.unpairedRepeat)\n"
            "      return .success(Step())\n    }\n",
            "",
        )],
    },
    {
        "id": "3",
        "file": SESSION,
        "requirement": "extra: no release is ever dropped",
        "description": "every unpaired key event is dropped, so an unpaired DKUP release is "
                       "dropped too",
        "replacements": [(UNPAIRED_REPEAT_GUARD, "    if event.pairing == .unpaired {\n")],
    },
    {
        "id": "4",
        "file": SESSION,
        "requirement": "CALV not echoed",
        "description": "a server CALV is accepted without the CALV answer",
        "replacements": [(
            "      let reply = Write(bytes: BarrierClientControlEncoder.keepalive(), ticket: "
            "reserveTicket())\n      return .success(Step(write: reply))\n",
            "      return .success(Step())\n",
        )],
    },
    {
        "id": "5a",
        "file": SESSION,
        "requirement": "wrong CINN sequence used for CCLP/DCLP",
        "description": "the first CINN's sequence stays in force after later enters",
        "replacements": [(
            "      enterSequence = enter.sequence.rawValue\n",
            "      enterSequence = enterSequence ?? enter.sequence.rawValue\n",
        )],
    },
    {
        "id": "5b",
        "file": SESSION,
        "requirement": "wrong CINN sequence used for CCLP/DCLP",
        "description": "the client sends the server's sequence 0 instead of the CINN in force",
        "replacements": [(
            "marshalled: BarrierClipboard.marshal(text: payload.utf8Text), sequence: sequence)",
            "marshalled: BarrierClipboard.marshal(text: payload.utf8Text), sequence: 0)",
        )],
    },
    {
        "id": "6",
        "file": SESSION,
        "requirement": "keepalive timeout not enforced",
        "description": "nine silent checks in a row no longer end the session",
        "replacements": [(
            "        await fail(Self.timeoutError(.keepalive))\n        return\n",
            "",
        )],
    },
    {
        "id": "7",
        "file": SESSION,
        "requirement": "server-to-client CCLP accepted",
        "description": "a server-to-client CCLP is ignored instead of failing closed",
        "replacements": [(
            "      // M1-PROTOCOL-003: a first-party client fails closed on a server-to-client "
            "CCLP.\n      return .failure(Self.protocolError(.unsupportedMessage))\n",
            "      return .success(Step())\n",
        )],
    },
    {
        "id": "8a",
        "file": SESSION,
        "requirement": "DINF not rebuilt after updateScreen",
        "description": "the pointer decoder is built for the first DINF only, so pointer "
                       "frames keep the old rectangle after a screen update",
        "replacements": [(
            "    pointer = BarrierMouseMoveDecoder(screen: info)\n",
            "    pointer = pointer ?? BarrierMouseMoveDecoder(screen: info)\n",
        )],
    },
    {
        "id": "8b",
        "file": SESSION,
        "requirement": "DINF not rebuilt after updateScreen",
        "description": "an updated DINF is written but not fed to the control decoder, so "
                       "enters are still checked against the old rectangle",
        "replacements": [(
            "      let outcome = try control.decode(\n"
            "        payload: Array(frame.dropFirst(4)), direction: .clientToServer)\n",
            "      var outcome = BarrierControlOutcome.event(.screenInfo(info))\n"
            "      if pointer == nil {\n"
            "        outcome = try control.decode(\n"
            "          payload: Array(frame.dropFirst(4)), direction: .clientToServer)\n"
            "      }\n",
        )],
    },
    {
        "id": "9",
        "file": SESSION,
        "requirement": "a broken DCLP transfer ending the session instead of dropping it",
        "description": "an assembler failure ends the session with protocol.malformed",
        "replacements": [(
            "      count(error == .oversized ? .clipboardOversized : .clipboardMalformed)\n"
            "      return .success(Step())\n",
            "      count(error == .oversized ? .clipboardOversized : .clipboardMalformed)\n"
            "      return .failure(Self.protocolError(.malformed))\n",
        )],
    },
    {
        "id": "10",
        "file": SESSION,
        "requirement": "extra: send of input fails closed",
        "description": "send(_:) returns silently for input events instead of failing",
        "replacements": [(
            "    guard case .clipboard(let payload) = event else {\n"
            "      throw Self.refusal(.protocolViolation(.unsupportedMessage))\n    }\n",
            "    guard case .clipboard(let payload) = event else { return }\n",
        )],
    },
    {
        "id": "11",
        "file": SESSION,
        "requirement": "extra: inbound clipboard text limit",
        "description": "server text up to 2 MiB is yielded instead of dropped over 1 MiB",
        "replacements": [(
            "    guard text.utf8.count <= Self.clipboardByteLimit else {\n",
            "    guard text.utf8.count <= Self.clipboardByteLimit * 2 else {\n",
        )],
    },
    {
        "id": "12",
        "file": SESSION,
        "requirement": "extra: only clipboard 0 is shared",
        "description": "clipboard 1 transfers are handled like clipboard 0",
        "replacements": [(
            "    guard payload[4] == BarrierClientControlEncoder.sharedClipboardID else {\n",
            "    guard payload[4] <= 1 else {\n",
        )],
    },
    {
        "id": "13",
        "file": SESSION,
        "requirement": "extra: frames leave in composition order",
        "description": "a composed frame never waits for an earlier write",
        "replacements": [(
            "        guard servingTicket != ticket else { return (true, []) }\n",
            "        guard servingTicket == UInt64.max else { return (true, []) }\n",
        )],
    },
    {
        "id": "14",
        "file": SESSION,
        "requirement": "updateScreen deferral",
        "description": "a screen update while entered is reported at once instead of after "
                       "COUT",
        "replacements": [(
            "        if case .active = control.state {\n"
            "          deferredScreen = info == screen ? nil : info\n"
            "          return .success(nil)\n        }\n",
            "",
        )],
    },
    {
        "id": "15",
        "file": SESSION,
        "requirement": "extra: enter position",
        "description": "the enter's x position is computed from its y coordinate",
        "replacements": [(
            "        pixel: enter.x, origin: screen.originX, extent: screen.width),\n",
            "        pixel: enter.y, origin: screen.originX, extent: screen.width),\n",
        )],
    },
    {
        "id": "16",
        "file": SESSION,
        "requirement": "extra: error taxonomy (plan a.5)",
        "description": "a frame over 64 KiB is reported as protocol.malformed, not oversized",
        "replacements": [(
            "    case .oversize: protocolError(.oversized)\n",
            "    case .oversize: protocolError(.malformed)\n",
        )],
    },
    {
        "id": "17",
        "file": SESSION,
        "requirement": "extra: error taxonomy (plan a.5)",
        "description": "protocol violations carry retry disposition never instead of backoff",
        "replacements": [(
            "      code: .protocolViolation(code), severity: .error, retryDisposition: .backoff,\n",
            "      code: .protocolViolation(code), severity: .error, retryDisposition: .never,\n",
        )],
    },
    {
        "id": "18",
        "file": SESSION,
        "requirement": "cancellation during connect",
        "description": "a cancelled handshake wait counts as setup completed",
        "replacements": [(
            "          // disables the timeout.\n          return .failure(error)\n",
            "          // disables the timeout.\n          return .success(())\n",
        )],
    },
    {
        "id": "E1",
        "file": ENCODER,
        "requirement": "golden DINF bytes",
        "description": "the DINF cursor fields are written y first",
        "replacements": [(
            "    payload += bigEndian(screen.cursorX)\n    payload += bigEndian(screen.cursorY)\n",
            "    payload += bigEndian(screen.cursorY)\n    payload += bigEndian(screen.cursorX)\n",
        )],
    },
    {
        "id": "E2",
        "file": ENCODER,
        "requirement": "golden CCLP bytes",
        "description": "CCLP is written without its clipboard id byte",
        "replacements": [("    payload.append(id)\n", "")],
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
    parser.add_argument("--out", default=f"evidence/issues/{ISSUE}/mutations/mutations.json")
    parser.add_argument("--only", action="append", default=[],
                        help="run only the mutant with this id; repeat for more")
    arguments = parser.parse_args()
    repository = pathlib.Path(arguments.repository).resolve()
    selected = [mutant for mutant in MUTANTS
                if not arguments.only or mutant["id"] in arguments.only]
    if arguments.only and len(selected) != len(set(arguments.only)):
        raise SystemExit("--only names a mutant that does not exist")
    sources = (SESSION, ENCODER)
    for path in (*sources, *TESTS):
        if not is_tracked(repository, path):
            raise SystemExit("stage the sources and the tests first: the git diff restore "
                             "check needs them tracked")
    originals = {path: (repository / path).read_bytes() for path in sources}
    hashes = {path: sha256(data) for path, data in originals.items()}
    tests_hashes = {path: sha256((repository / path).read_bytes()) for path in TESTS}
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m1-029-fu-mutations-"))
    backups = {}
    for index, path in enumerate(sources):
        backups[path] = backup_directory / f"source-{index}.swift.backup"
        shutil.copyfile(repository / path, backups[path])

    results = []
    clean = True
    try:
        baseline = run_suite(repository)
        print(f"baseline: exit {baseline['exitCode']}, {baseline['summary']}", flush=True)
        for mutant in selected:
            path = mutant["file"]
            source_path = repository / path
            for checked in sources:
                if sha256((repository / checked).read_bytes()) != hashes[checked]:
                    raise SystemExit("a source changed before a mutant was applied")
            text = originals[path].decode("utf-8")
            for old, new in mutant["replacements"]:
                if text.count(old) != 1:
                    raise SystemExit(f"mutant {mutant['id']}: the text to replace is not unique")
                text = text.replace(old, new)
            source_path.write_text(text, encoding="utf-8")
            try:
                outcome = run_suite(repository)
            finally:
                shutil.copyfile(backups[path], source_path)
            restored = sha256(source_path.read_bytes()) == hashes[path]
            diff_exit = git_diff_exit_code(repository, path)
            clean = clean and restored and diff_exit == 0
            killed = (outcome["exitCode"] not in (0, "timeout") and bool(outcome["failingTests"])
                      and not outcome["compileError"])
            result = {
                "id": mutant["id"],
                "file": path,
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
        for path in sources:
            shutil.copyfile(backups[path], repository / path)
        shutil.rmtree(backup_directory, ignore_errors=True)
    tests_unchanged = all(sha256((repository / path).read_bytes()) == tests_hashes[path]
                          and git_diff_exit_code(repository, path) == 0 for path in TESTS)
    sources_restored = all(sha256((repository / path).read_bytes()) == hashes[path]
                           and git_diff_exit_code(repository, path) == 0 for path in sources)
    clean = clean and tests_unchanged and sources_restored

    baseline_ok = baseline["exitCode"] == 0 and not baseline["failingTests"]
    all_killed = all(result["killed"] for result in results)
    report = {
        "schemaVersion": 1,
        "issue": ISSUE,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": {path: hashes[path] for path in sources},
        "tests": {path: tests_hashes[path] for path in TESTS},
        "command": " ".join(COMMAND),
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
