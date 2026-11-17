"""M1-055-FOLLOWUP-001 mutation runner.

Usage:
  python3 -I evidence/issues/M1-055-FOLLOWUP-001/mutations/run_mutations.py <repository> \
      --test-command '<shell command run from <repository> that builds and runs the tests>' \
      [--out <json>]

LinuxTLSTransport.swift builds only on Linux, so the test command runs the LinuxTLSTransport
tests in a Linux container with openssl installed, for example:

  docker exec <container> bash -c 'cd /src && swift build --build-tests --scratch-path /scratch \
    && timeout 120 swift test --skip-build --scratch-path /scratch --filter LinuxTLSTransport'

with <repository> mounted at /src. Each mutant is an exact text replacement whose searched
text must occur exactly once. A mutant is killed when the build succeeded and every test in its
`killers` list failed: it printed a failure line, or it started and never finished because the
mutant made it wait and the `timeout` in the test command ended the run (exit 124, recorded as
`timedOut`, counted when no killer printed a pass). After each mutant the file is restored from
a backup and compared byte for byte. The suites carry `.timeLimit(.minutes(1))`, so a mutant that
makes a test wait now fails that test; `killedByTimeLimit` records which runs hit the limit. A baseline run on the unmodified tree must pass first.
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

SOURCE = "Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxTLSTransport.swift"
TIMEOUT_SECONDS = 900

UNKNOWN = "an unknown identity fails closed with identityUnknown and no application byte"
CHANGED = "a changed identity fails closed with identityChanged"
WRONG_LENGTH = "a wrong digest length from the evaluator fails closed with trustRejected"
MATCHING = "a matching pin connects and carries bytes both ways in order"
LEAF = "the evaluator receives the SHA-256 of the leaf DER, not of the chain"
TLS11 = "a server limited to TLS 1.1 is refused and the evaluator is never asked"
EOF_TEST = "the end of the server's stream finishes the incoming bytes once, after the data"
SLOW = "a slow consumer ends the stream with resourceExhausted, keeping the buffered order"
SINGLE_USE = "a second connect is refused: the instance is single-use"
CANCEL = "cancelling the task during connect fails with cancellation and closes the socket"
TIMEOUT = "a handshake that never completes times out"
DISCONNECT_TWICE = "disconnect twice is idempotent and finishes the stream once, normally"
CHUNK = "a large read is yielded in chunks of at most 16 KiB, in order"
POST_HANDSHAKE = "a TLS error after the handshake ends the stream with reset and back-off"
SEND_EARLY ="send before connect is a precondition failure and sends nothing"

MUTANTS = [
    {
        "id": "M1",
        "rule": "any evaluator outcome but accept fails the handshake (required mutant)",
        "mutation": "the verify callback answers certificateVerified on a reject",
        "find": "promise.succeed(self.verifyPeer(certificates) ? .certificateVerified : .failed)",
        "replace": (
            "promise.succeed(self.verifyPeer(certificates) ? .certificateVerified"
            " : .certificateVerified)"
        ),
        "killers": [UNKNOWN, CHANGED, WRONG_LENGTH],
    },
    {
        "id": "M2",
        "rule": "minimum TLS 1.2 (required mutant)",
        "mutation": "the minimum TLS version is lowered to TLS 1.0",
        "find": "configuration.minimumTLSVersion = .tlsv12",
        "replace": "configuration.minimumTLSVersion = .tlsv1",
        "killers": [TLS11],
    },
    {
        "id": "M3",
        "rule": "the pin is the SHA-256 of the leaf DER (required mutant)",
        "mutation": "the digest covers the whole presented chain instead of the leaf",
        "find": "guard let leafDER = try? certificates[0].toDERBytes() else {",
        "replace": "guard let leafDER = try? certificates.flatMap({ try $0.toDERBytes() }) else {",
        "killers": [LEAF],
    },
    {
        "id": "M4",
        "rule": "the presented fingerprint is kept after a rejection",
        "mutation": "the fingerprint is not kept on a reject",
        "find": "        state.presentedFingerprint = fingerprint\n",
        "replace": "",
        "killers": [UNKNOWN, CHANGED],
    },
    {
        "id": "M5",
        "rule": "the presented fingerprint is kept only after a rejection",
        "mutation": "the fingerprint is also kept on accept",
        "find": "        state.verification = .accepted\n",
        "replace": (
            "        state.verification = .accepted\n"
            "        state.presentedFingerprint = fingerprint\n"
        ),
        "killers": [MATCHING],
    },
    {
        "id": "M6",
        "rule": "TCP_NODELAY is set",
        "mutation": "TCP_NODELAY is set to 0",
        "find": ".channelOption(.tcpOption(.tcp_nodelay), value: 1)",
        "replace": ".channelOption(.tcpOption(.tcp_nodelay), value: 0)",
        "killers": [MATCHING],
    },
    {
        "id": "M7",
        "rule": "connect has a timeout that covers the handshake",
        "mutation": "the connect deadline is one hour",
        "find": "eventLoop.scheduleTask(in: timeoutAmount)",
        "replace": "eventLoop.scheduleTask(in: .hours(1))",
        "killers": [TIMEOUT],
    },
    {
        "id": "M8",
        "rule": "an instance is used once",
        "mutation": "a second connect is not refused",
        "find": "      guard case .idle = state.phase else { return false }\n      state.phase = .connecting",
        "replace": "      state.phase = .connecting",
        "killers": [SINGLE_USE],
    },
    {
        "id": "M9",
        "rule": "send before connect fails closed",
        "mutation": "send before connect is treated as connected",
        "find": "      case .idle, .connecting: return .failure(Self.misuseFailure)",
        "replace": "      case .idle, .connecting: return .success(nil)",
        "killers": [SEND_EARLY],
    },
    {
        "id": "M10",
        "rule": "disconnect and every terminal path close the channel",
        "mutation": "terminate does not close the channel",
        "find": "    released.channel?.close(promise: nil)\n",
        "replace": "",
        "killers": [DISCONNECT_TWICE],
    },
    {
        "id": "M11",
        "rule": "cancellation during connect ends it promptly and closes the socket",
        "mutation": "task cancellation is ignored during connect",
        "find": "      self?.terminate(.failed(Self.cancellationFailure))",
        "replace": "      _ = self",
        "killers": [CANCEL],
    },
    {
        "id": "M12",
        "rule": "the incoming buffer is bounded",
        "mutation": "the incoming stream buffer is unbounded",
        "find": "bufferingPolicy: .bufferingOldest(Self.incomingChunkBufferLimit)",
        "replace": "bufferingPolicy: .unbounded",
        "killers": [SLOW],
    },
    {
        "id": "M13",
        "rule": "the end of stream finishes incomingBytes once, normally",
        "mutation": "the peer's close fails the stream",
        "find": "    } else {\n      terminate(.finished)\n    }",
        "replace": (
            "    } else {\n"
            "      terminate(.failed(Self.networkFailure(.transport(.disconnected))))\n"
            "    }"
        ),
        "killers": [EOF_TEST],
    },
    {
        "id": "M14",
        "rule": "one yielded chunk is at most 16 KiB (review condition 1)",
        "mutation": "large reads are not split",
        "find": "data.index(offset, offsetBy: Self.maximumChunkLength, limitedBy: data.endIndex)",
        "replace": "data.index(offset, offsetBy: Int.max / 2, limitedBy: data.endIndex)",
        "killers": [CHUNK],
    },
    {
        "id": "M15",
        "rule": "a TLS error after the handshake is transport(.reset) with back-off (review note 2)",
        "mutation": "a TLS error after the handshake keeps the security code",
        "find": "if case .security = failure.code {",
        "replace": "if case .security = failure.code, false {",
        "killers": [POST_HANDSHAKE],
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
            exitCode=code, built=built, killed=killed, timedOut=timed_out,
            killedByTimeLimit="Time limit was exceeded" in output, restoredCleanly=restored,
            failedKillers=sorted(k for k in mutant["killers"] if k in failed))
        ok = ok and killed and restored
        results.append(entry)
        print(f'{mutant["id"]}: killed={killed} restored={restored}', flush=True)

    report = {
        "schemaVersion": 1,
        "issue": "M1-055-FOLLOWUP-001",
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
