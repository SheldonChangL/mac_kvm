# M1-055-FOLLOWUP-002 Evidence Summary

## Scope

Files: `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxTLSTransport.swift`,
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxTLSTransportTests.swift`,
`Tests/Integration/LinuxClientRuntimeTests.swift`, `Package.swift`,
`docs/platform/linux/M1-055-FOLLOWUP-001-linux-tls-transport.md`, and this directory.
Issue #372, PR #373, Tier C/S (TLS transport). Base `4c2f042`; reviewed at `a769b94`; review
fixes at `656ef69`; E2E rerun recorded at `e3d367d`.

The first-party Linux client ended the session with `connection ended (transport.resourceExhausted)`
when the server sent a 600 KB clipboard on enter (found by #351 / PR #371, case
`clipboard-large-to-client`, 6 of 6 runs).

## Root cause

`LinuxTLSTransport` (M1-055-FOLLOWUP-001) yielded 16 KiB chunks into an `AsyncThrowingStream` with
`.bufferingOldest(16)` (about 256 KiB) and applied no backpressure. A 600 KB clipboard arriving faster
than the client protocol session consumed it overflowed the buffer, and the transport failed closed
with `resourceExhausted`. The RED runs below confirm it at the transport and client-runtime levels.

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| How is inbound memory bounded? | `incomingBytes` is pull-driven over a byte-counted queue. At 256 KiB queued the inbound handler holds the channel `read` event (TCP flow control slows the peer); reads resume below 64 KiB. | PR #373 body; mutants 1 and 2. |
| Hard ceiling | 1 MiB stays a defensive `resourceExhausted`, checked under the lock before append. Clipboard and protocol limits are unchanged. | Security review. |
| Overshoot past the high-water mark | One read event (`maxMessagesPerRead` 4 x up to 64 KiB) plus NIOSSL's own `context.read()`, bounded by the 1 MiB cap. Documented; `maxMessagesPerRead` unchanged. | Tier C Low 1 / security Low 1. |
| Consumer drops `incomingBytes` | The connection stays open with reads paused until `disconnect`. Documented as intended. | Tier C Low 2. |
| Security reviewer | The owner decided on 2026-11-17 that a fresh-context security review replaces the Codex Security Reviewer for Tier S. | `security-review.md`. |

## RED

`red-base` in `commands.json` (exit 1, expected failure): `origin/main`'s `LinuxTLSTransport.swift`
with the new tests.

- `M1-055-FOLLOWUP-002: a slow consumer receives a 1 MiB payload in order, unended` failed after
  0.621 seconds with `CoreError(... transport(...`.
- `a 600 KB server clipboard on enter reaches the local clipboard with no reconnect` exceeded the
  60-second time limit, the clipboard writes were `[]`, and the runtime output had 1 line containing
  `connection ended (transport.resourceExhausted)`.

## GREEN

Linux `swift:6.2.3-jammy`, linux/arm64 container:

- `linux-focused` (`-warnings-as-errors`, `LinuxTLSTransport|LinuxClient`): `✔ Test run with 49 tests in
  7 suites passed`; again after the review notes (`review-notes-linux-focused`), same line.
- `linux-repeat-10`: `10 ✔ Test run with 5 tests in 2 suites passed`.
- `linux-full-xvfb` (`MACKVM_X11_TESTS=1`): `✔ Test run with 520 tests in 54 suites passed`. The XML
  header reads `tests="519"`, `failures="0"`, `skipped="1"` (see Discrepancies).
- `linux-full-xvfb-repeat-3` (exit 1): run 1 failed one test, `events are injected in order on the
  drain's own thread` (`LinuxX11InjectorTests.swift:544`, thread name, a pre-existing M4-024 flake);
  runs 2 and 3 passed 520.

macOS: `swift test` `✔ Test run with 332 tests in 29 suites passed` (before and after the review
notes); `make verify` exit 0 (three `[PASSED]` lines recorded); `docs check OK`;
`PACKAGE OK: 217 issues, 5 milestones, 17 epics`. CI at `656ef69`: build-test-manifest and
verify-linux SUCCESS (from the review record; run id not recorded).

## Mutation checks

`mutants` in `commands.json` (filter `slowConsumerLargePayload|stalledConsumerIsBounded|largeClipboardOnEnter`):

| Mutant | Killed by |
| --- | --- |
| 1 no-pause: the read gate never holds reads | `M1-055-FOLLOWUP-002: a stalled consumer holds socket reads; queued bytes stay bounded` (`CoreError ... transport`, 1 of 3 tests failed) |
| 2 no-resume: `resumeReading` never re-issues the read | `a slow consumer receives a 1 MiB payload` (time limit; `received.count` 376832 of 1048576) and `a 600 KB server clipboard on enter ...` (time limit, no clipboard write) |

Both killed. No mutation runner or `mutations.json` is committed for this issue.

## Acceptance mapping

| Criterion (issue #372) | Evidence | Status |
| --- | --- | --- |
| RED: a test reproduces `resourceExhausted` on a large inbound payload at the transport level | `slowConsumerLargePayload` in `red-base` | Met |
| RED: the same in a two-process or client-runtime test | `largeClipboardOnEnter` (ClientRuntime over the real TLS transport and an in-process server) in `red-base` | Met |
| GREEN: the 600 KB clipboard is delivered | `largeClipboardOnEnter` passes in `linux-focused`, `linux-repeat-10`; mutant 2 | Met (in-process) |
| GREEN: memory stays bounded | `stalledConsumerIsBounded` (4 MiB on the wire, peak <= high-water + 512 KiB after the review notes); mutant 1 | Met |
| The #351 case `clipboard-large-to-client` passes when rerun | `e2e-rerun` at `656ef69`: `clipboard-large-to-client=fail`, `automated=1 failed of 22` | **NOT met** |

**The last acceptance item is not met.** The E2E rerun shows the transport defect is gone: the
client log has no `connection ended` and no `resourceExhausted` during the case, the session stayed
up, and the server logged the 600 KB clipboard as sent. But the case still fails on the X11 clipboard
side: `xclip` on the client display did not return the 600 KB text's SHA-256 within the script's
3-second window. The root cause is undiagnosed (candidates: X11 INCR serving of 600 KB under Xvfb, or
the 3 s window being too short). A follow-up issue is needed. For that reason PR #373 says
`Part of #372`, not `Closes #372`.

## Independent review

- Tier C, fresh-context Opus, at `a769b94`: APPROVE with minor notes (static only; Docker was
  degraded at the time): 3 Low, 2 Nit (`independent-review.md`).
- Security, fresh-context Opus under the owner's 2026-11-17 waiver: APPROVE (static only): 2 Low,
  3 Info (`security-review.md`).
- Fixes at `656ef69`.

## Merge

Pending owner authorization. Not to be read as closing #372.

## Known limitations

- `clipboard-large-to-client` still fails end to end on the X11 side (above); needs a follow-up.
- Per-chunk overhead is not counted in the 1 MiB cap; many tiny records can hold a few MiB, bounded.
- Overshoot past the 256 KiB high-water mark is one read event plus NIOSSL's own read, bounded by
  1 MiB.
- A consumer that stops reading `incomingBytes` leaves the connection open with reads paused until
  `disconnect`; a silent peer is caught by the protocol session's keepalive (`timeout(.keepalive)`
  after 9 silent one-second checks), not by the transport.
- The `LinuxX11InjectorTests` thread-name flake (M4-024) appeared in 1 of 3 full runs.
- No reviewer executed tests (both reviews static).

## Discrepancies

Recorded as found, not resolved:

1. `linux-full-xvfb` prints 520 tests in 54 suites; the XML header says `tests="519"`, `skipped="1"`.
   The same counting difference was seen in M1-055-FOLLOWUP-001.
2. `commands.json` names the report `tests/swift-testing-xunit.xml`; the committed file is
   `tests/swift-testing-xunit-swift-testing.xml`.
3. The top-level `note` in `commands.json` says the E2E rerun "was started but not completed", while
   the `e2e-rerun` entry records a completed run (22 cases, 1 failed). The entry is the later record
   (`e3d367d`).
4. `e2e-rerun` has `exitCode` 0 although one automated case failed.
5. The PR body's Verification section still says the E2E rerun was not verified (stopped after
   about 52 minutes); that refers to an earlier attempt. The rerun at `656ef69` completed and is
   recorded in `commands.json`.
6. The host clock jumped during the E2E run (log gaps of about 17 minutes), so its timings are
   unreliable. Raw E2E logs are not committed.
7. The full 520-test Linux runs were at `a769b94`; after the review notes only the focused 49 tests
   ran on Linux locally (CI verify-linux passed at `656ef69`).

Full gates are in `commands.json`; the machine-readable report is in `tests/`.
