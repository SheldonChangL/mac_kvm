# M1-055-FOLLOWUP-001 Security Review

- Reviewer: fresh-context Opus agent, not the implementer
- Date: 2026-11-17
- Target: PR #369 at `989ccaa`
- Verdict: APPROVE WITH CONDITIONS; 0 Critical, 0 High, 1 Low, 3 Info

## Reviewer designation

This is a Tier S PR (risk critical). On 2026-11-17 the Product Owner decided that a fresh-context
security review replaces the designated Codex Security Reviewer for Tier S PRs. The review below is
that fresh-context security review, done by a model that did not implement the change. It is
separate from the Tier C review in `independent-review.md`.

## Review (verbatim)

> Security review PR #369 (M1-055-FOLLOWUP-001 LinuxTLSTransport), fresh-context Opus. Verdict: APPROVE WITH CONDITIONS (no critical/high).
> Verified: leaf-only SHA-256 (L353-360); callback not skipped (.noHostnameVerification L228); error paths reject (no self -> .failed L259, empty/>10 chain, DER read failure); evaluator once, result latched (L338-374), single event loop; .ready still fails unless verification .accepted (L304-308); no app data before verdict (received yields only after .connected L383-388, send before connected misuse, server handshakeCount 0); TLS 1.2 minimum, NIOSSL default ciphers, no renegotiation; one scheduled timeout covers TCP+handshake; terminate once; late channel closed in whenComplete (L286); no logging, CoreError strips NIO/TLS details, underlyingDiagnosticCode nil; rejected fingerprint only in presentedFingerprint (L129).
> Findings: LOW1 L55, L389-396 no backpressure; 16-chunk buffer full -> resourceExhausted (fail closed, DoS not bypass); the comment's 16 KiB-per-chunk / 256 KiB bound is unverified, NIOSSL may coalesce. INFO2 presentedFingerprint is handed to the caller; the CLI must only display it. INFO3 cipher suites/version not pinned; consider TLS 1.3 minimum. INFO4 L521-522 all TLS errors -> trustRejected, the user cannot tell a version mismatch from trust.
> Attacks (Docker arm64, PR 17 tests + 5 attack tests, 22 pass): intermediate-cert pin with CA->leaf chain -> identityChanged, evaluator saw leaf only, handshakeCount 0; server floods 4x100 bytes on connect -> 0 bytes on reject, 400 on accept; plain TCP non-TLS server -> fails in 2 s, evaluator never called; error description/reflection contain no host or fingerprint. Covered by PR tests: unknown, changed, TLS 1.1 server, never-completing handshake, cancel/disconnect during connect, slow consumer. Not run: renegotiation via s_server (relies on NIOSSL default), wrong-key impersonation (TLS signature prevents).
> Condition: fix or verify the L53-55 256 KiB comment; confirm the CLI only displays presentedFingerprint.

## Resolution

Fixes are at `b05a56d`; CI at that commit passed on both jobs.

| Finding | Resolution |
| --- | --- |
| Low 1 and the condition (`L55`, `L389-396`): the 256 KiB bound is unverified, no backpressure | Enforced, not only reworded: `received()` splits each read into chunks of at most `maximumChunkLength` 16384, in order; a full buffer mid-read fails closed with `resourceExhausted`. The comment and doc are corrected. Test: one 200,000-byte write arrives as chunks of at most 16 KiB, intact. Mutant M14 (no split) is killed, which shows NIOSSL does coalesce. The absence of backpressure stays a known limitation. |
| Info 2: the caller receives `presentedFingerprint` | Documented: the component doc says it is for display only and is never logged or sent. The command line that uses it is a later issue and must follow that rule. |
| Info 3: the cipher suites and version are not pinned | Documented: the suites are the swift-nio-ssl defaults and only the TLS 1.2 minimum is set; changing the pin or the version needs a security check. |
| Info 4: every TLS error is `trustRejected` | Accepted: this fails closed. |

Gates after the fixes: focused Linux 19 of 19 pass and 30 of 30 repeats; full Linux 416 tests in 42
suites; macOS 301 tests in 28 suites; the Mac loopback proof passed; `make verify` 24 of 24; 15 of 15
mutants killed; CI at `b05a56d` passed on both jobs.
