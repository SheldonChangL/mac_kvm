# M1-055-FOLLOWUP-001 Independent Review

- Reviewer: fresh-context Opus agent, Tier C (STRONG_REVIEW_PROMPT)
- Date: 2026-11-17
- Target: PR #369 at `989ccaa`
- Verdict: APPROVE WITH NITS; no blockers; 2 Low, 1 Low/Medium, 2 Nit

## Review (verbatim)

> PR #369 (M1-055-FOLLOWUP-001 LinuxTLSTransport) Tier C review, fresh-context Opus, head 989ccaa. Verdict: APPROVE WITH NITS (no blockers).
> Contract/lifecycle OK: single-use (:149-154, second connect internalFailure(.preconditionFailed) retry .never); disconnect synchronous, idempotent, bounded (:437-470); cancellation via withTaskCancellationHandler + early outcome (:165-181, :451-453); one deadline covers TCP+handshake -> timeout(.connect); bufferingOldest(16), yield checked, overflow -> transport(.resourceExhausted); all errors mapped to CoreError; pin = SHA-256 of certificates[0], asked once, empty or >10 chain rejected without asking, rejection wins (:301). All spec tests present.
> Deviations: (1) undeclared import NIOTLS acceptable, add product in Package.swift under M4-020-FOLLOWUP-001; (2) .noHostnameVerification correct; (3) .tcp_nodelay required, pinned by test; (4) end of stream finishes normally, conforms to contract and a.5; (5) TLS error before handshake -> trustRejected, after -> transport(.reset), matches a.5 but untested.
> Findings: LOW1 :406-414 post-handshake TLS error -> reset untested (mutant A survived). LOW2 :304-308 fail-closed guard untested (mutant E survived). LOW/MED3 no .timeLimit traits; mutants D (buffer drop, :396) and G (overall deadline dropped, :240) hang instead of failing. NIT4 :269-286 channel stored in connect completion vs phase .connected ordering. NIT5 unclean FIN after handshake ends as reset; document only close_notify as a clean end.
> Ran: Docker arm64 swift:6.2.3-jammy, -warnings-as-errors --filter LinuxTLSTransport: 17 tests/2 suites pass (1.722 s). 7 mutants: A survived; B (EOS fails disconnected) killed; C (nodelay 0) killed; D killed only by hang (>20 min); E survived; F (presentedFingerprint not stored) killed; G killed only by hang (~5 min). Not repeated: macOS run, make verify, Mac loopback, 30 repeats.

## Resolution

Fixes are at `b05a56d`; CI at that commit passed on both jobs.

| Finding | Resolution |
| --- | --- |
| Low 1 (`:406-414`): a post-handshake TLS error to `reset` is untested | Fixed: the test server writes 64 non-TLS bytes after the handshake and the stream ends with `transport(.reset)`, retry `.backoff`. Mutant M15 (the security code kept) is killed. |
| Low 2 (`:304-308`): the fail-closed guard is untested | Not fixed, by design: the guard is unreachable through swift-nio-ssl, because the handshake completes only after the callback accepts. It is documented as defense in depth; there is no test or mutant. |
| Low/Medium 3: no `.timeLimit` traits; mutants D and G hang | Fixed: both suites carry `.timeLimit(.minutes(1))`. The reviewer's D (buffer) and G (deadline) correspond to M12 and M7, which now fail by the time limit; `mutations.json` has a `killedByTimeLimit` field. |
| Nit 4 (`:269-286`): the channel is stored in the connect completion before phase `.connected` | Documented: a source comment and the component doc state the ordering. |
| Nit 5: an unclean FIN after the handshake ends as `reset` | Documented: only `close_notify` is a clean end; a bare FIN is an unclean shutdown and ends as `reset`. |
| Deviation 1: the `NIOTLS` product is not listed in `Package.swift` | Accepted; left to M4-020-FOLLOWUP-001, recorded in `summary.md` Known limitations. |

Gates after the fixes: RED stub 19 tests in 2 suites failed with 29 issues; focused Linux 19 of 19
pass and 30 of 30 repeats; full Linux under Xvfb 416 tests in 42 suites; the Mac loopback proof
passed again (TLS 1.3, ECDSA P-256), the throwaway identity deleted; macOS 301 tests in 28 suites in
both modes; `make verify` 24 of 24; lint, `docs-check`, `architecture-check` and `validate_package.py`
pass; the mutation batch is 15 of 15 killed (new M14, M15); CI at `b05a56d` passed on both jobs.
