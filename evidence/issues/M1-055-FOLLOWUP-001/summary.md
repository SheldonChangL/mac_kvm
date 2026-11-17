# M1-055-FOLLOWUP-001 Evidence Summary

## Scope

Files: `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxTLSTransport.swift`,
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxTLSTransportTests.swift`,
`docs/platform/linux/M1-055-FOLLOWUP-001-linux-tls-transport.md`, and this directory.

`LinuxTLSTransport` is the Linux client's conformer of the C-002 `Transport` contract, built on
swift-nio-ssl. It pins the server's identity through the C-009 trust policy: the certificate
verification callback hashes the leaf DER with SHA-256 and asks a trust evaluator once per connect.
Any outcome but accept fails the handshake before any application byte is sent (`identityUnknown`,
`identityChanged`, or `trustRejected` for a malformed digest). The connection uses at least TLS 1.2
and sets `TCP_NODELAY`. Connect has one deadline covering TCP and the handshake, an instance is used
once, `disconnect` is idempotent and bounded even when cancelled, and the incoming buffer is bounded.
The presented fingerprint is kept only after a rejection, so the command line can display it; it is
never logged. The pinning policy is first-party, built from the repository's contracts (C-002, C-009);
no Barrier behavior is involved. Tier C/S, risk critical (issue #347, PR #369).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| What is pinned? | The SHA-256 of the leaf certificate DER (`certificates[0]`); an empty chain or one longer than 10 is rejected without asking the evaluator. | Component doc, Pinning; mutant M3; security review. |
| Is the hostname verified? | No (`.noHostnameVerification`): the pin is the identity, and the verification callback still runs. The validity dates are not checked, as on the Mac. | Component doc, Why `.noHostnameVerification`, Known limitations. |
| Minimum TLS version | TLS 1.2; the cipher suites are the swift-nio-ssl defaults and were not changed. Changing the pin or the version needs a security check. | Mutant M2; component doc; security review Info 3. |
| Is a connection reused? | No: an instance is single-use; a second `connect` is `internalFailure(.preconditionFailed)`, retry never. | Mutant M8. |
| What bounds incoming data? | `bufferingOldest(16)` chunks, each at most 16 KiB (`maximumChunkLength` 16384); each read is split in order and a full buffer fails closed with `transport(.resourceExhausted)`. There is no backpressure. | Review resolution; mutants M12, M14. |
| How does the stream end? | Only a TLS `close_notify` is a clean end. A bare FIN or a TLS error after the handshake is `transport(.reset)` with back-off; a TLS error before it is `trustRejected`. | Review resolution; mutants M13, M15. |
| Fingerprint on a rejection | Kept as `presentedFingerprint` for display only; never logged or sent. | Security review Info 2; component doc. |
| First task | Prove pinning against the real Mac server identity (P-256 self-signed, TLS 1.3) on loopback. It passed, so the OpenSSL fallback of M4-001 is not needed. | `commands.json` (`mac-loopback-pin`). |
| Security reviewer | The owner decided on 2026-11-17 that a fresh-context security review replaces the designated Codex Security Reviewer for Tier S PRs. | `security-review.md`. |
| Which tests does `make verify-linux ISSUE=M1-055-FOLLOWUP-001` mean? | The Linux suite run in `swift:6.2.3-jammy` (linux/arm64, native), plus the CI `verify-linux` job, which is the gate of record. | `commands.json` toolchain note. |

## RED

Against a compiling stub, the focused run (`commands.json`, `red-stub`, exit 1, recorded as an
expected failure) ended: `✘ Test run with 19 tests in 2 suites failed after 37.336 seconds with 29
issues.` The implementation was restored afterwards.

## GREEN

Linux, `swift:6.2.3-jammy`, linux/arm64, after the review notes (`b05a56d`), built with
`-warnings-as-errors`:

- Focused `LinuxTLSTransport`: `✔ Test run with 19 tests in 2 suites passed after 1.424 seconds.`
- 30 repeats of the focused run: `30 ✔ Test run with 19 tests in 2 suites passed`.
- Full package under Xvfb with `MACKVM_X11_TESTS=1`: `✔ Test run with 416 tests in 42 suites passed
  after 6.308 seconds.` The XML report's header reads `tests="415"`, `failures="0"`, `skipped="1"`;
  it counts differently from the Swift Testing line above, and both are recorded as found.

macOS and the Mac loopback proof:

- `mac-loopback-pin`: the Mac smoke server ran with a throwaway identity and the optional loopback
  suite ran against it from the Linux container; `✔ Test run with 1 test in 1 suite passed`. The
  handshake was `TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384`, `Peer signature type: ECDSA`,
  `Server public key is 256 bit`. The pin was passed in the environment and not recorded, and the
  identity was removed afterwards.
- Full root package: `✔ Test run with 301 tests in 28 suites passed after 0.140 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 301 tests in 28 suites passed after 0.142
  seconds.`
- Both format lints (the two files, and the repository) exit 0; `docs check OK`; `architecture
  check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `make verify` exit 0 (`commands.json`
  keeps its last 4 lines, three `[PASSED]` lines and the report path; the review resolution counts
  24 of 24 gates).
- CI at `b05a56d`: both jobs passed (recorded in the review resolution; the run id is not recorded).
- The machine-readable report is `tests/swift-testing-xunit-swift-testing.xml`.

## Mutation checks

15 mutants in `mutations/mutations.json`, run by `mutations/run_mutations.py` (the baseline passes,
`allKilled` is true): 15 killed, of which 13 by a failing test and 2 (M7, M12) by the 1-minute time
limit; none by the runner's timeout.

| Ids | Area | Killing tests |
| --- | --- | --- |
| M1, M4 | a reject accepted; the fingerprint not kept on a reject | `an unknown identity fails closed with identityUnknown and no application byte`; `a changed identity fails closed with identityChanged`; `a wrong digest length from the evaluator fails closed with trustRejected` |
| M2 | minimum TLS lowered to 1.0 | `a server limited to TLS 1.1 is refused and the evaluator is never asked` |
| M3 | the digest covers the chain, not the leaf | `the evaluator receives the SHA-256 of the leaf DER, not of the chain` |
| M5, M6 | the fingerprint also kept on accept; `TCP_NODELAY` set to 0 | `a matching pin connects and carries bytes both ways in order` |
| M7 | connect deadline one hour (killed by the time limit) | `a handshake that never completes times out` |
| M8 | a second connect not refused | `a second connect is refused: the instance is single-use` |
| M9 | send before connect treated as connected | `send before connect is a precondition failure and sends nothing` |
| M10 | terminate does not close the channel | `disconnect twice is idempotent and finishes the stream once, normally` |
| M11 | cancellation ignored during connect | `cancelling the task during connect fails with cancellation and closes the socket` |
| M12 | the incoming buffer unbounded (killed by the time limit) | `a slow consumer ends the stream with resourceExhausted, keeping the buffered order` |
| M13 | the peer's close fails the stream | `the end of the server's stream finishes the incoming bytes once, after the data` |
| M14 | large reads not split (added after the review) | `a large read is yielded in chunks of at most 16 KiB, in order` |
| M15 | a TLS error after the handshake keeps the security code (added after the review) | `a TLS error after the handshake ends the stream with reset and back-off` |

## Acceptance mapping

| Criterion (issue #347) | Tests and evidence |
| --- | --- |
| `LinuxTLSTransport` implements C-002 `Transport`; the leaf DER is hashed with SHA-256 and the evaluator asked once | The matching-pin and leaf-digest tests; mutants M3, M5 |
| Any outcome but accept fails before any application byte: unknown, changed, malformed digest | The unknown, changed and wrong-length tests; mutants M1, M4 |
| At least TLS 1.2 | The TLS 1.1 server test; mutant M2 |
| `TCP_NODELAY` | The matching-pin test; mutant M6 |
| Connect timeout, single use, idempotent bounded `disconnect`, cancellation | The never-completing handshake, second-connect, second-disconnect and cancel-during-connect tests; mutants M7, M8, M10, M11 |
| Bounded incoming buffer; end of stream | The slow-consumer, large-read and end-of-stream tests; mutants M12 to M14 |
| A send before connect fails | `send before connect is a precondition failure and sends nothing`; mutant M9 |
| The presented fingerprint kept only after a rejection, never logged | The rejection tests; mutants M4, M5; security review |
| First task: pinning against the real Mac server identity | `commands.json` `mac-loopback-pin` |
| Required mutants: accept on a reject, lowered TLS minimum, digest over the chain | M1, M2, M3, all killed |
| Required commands and the Tier C/S reviews | `commands.json`: Linux 416 tests in 42 suites, `make verify`, `validate_package.py`, architecture check; `independent-review.md` and `security-review.md` |

## Independent review

- A fresh-context Opus reviewer (Tier C) approved PR #369 at `989ccaa` with nits: no blockers, 2 Low,
  1 Low/Medium, 2 Nit (`independent-review.md`). The reviewer ran 17 tests in 2 suites on arm64
  `swift:6.2.3-jammy` and 7 mutants of its own, 5 killed (two survived, two of the five only by a
  hang).
- A fresh-context Opus security review (the owner's 2026-11-17 decision, see `security-review.md`)
  approved with conditions and no Critical or High finding: 1 Low and 3 Info. It ran 5 attack tests
  beside the PR's 17; 22 passed.
- The security condition and every Tier C finding were addressed in `b05a56d`, except that the
  unreachable fail-closed guard (Low 2) is documented, not tested. The new mutants are M14 and M15.

## Merge

Pending owner authorization; the branch needs `gh pr update-branch` if main has moved.

## Known limitations

- `NIOTLS` is imported although `Package.swift` does not list its product (a transitive module of
  swift-nio); M4-020-FOLLOWUP-001 should add it.
- C-009's revoked state is not produced here; the evaluator decides it.
- The certificate's validity dates are not checked, as on the Mac: the pin is the identity.
- The incoming stream has no backpressure: a consumer that falls 16 chunks behind fails closed with
  `resourceExhausted`.
- The cipher suites and the TLS 1.3 option are left at the swift-nio-ssl defaults (TLS 1.2 minimum).
- Every TLS error before the handshake completes is `trustRejected`, so a version mismatch cannot be
  told from a trust failure.
- The fail-closed guard that refuses a `.ready` handshake without an accepted verification is
  unreachable through swift-nio-ssl and is kept as defense in depth, without a test.
- A bare FIN after the handshake ends as `reset`; only `close_notify` is a clean end.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3; Linux `swift:6.2.3-jammy`);
the machine-readable test report is in `tests/`.
