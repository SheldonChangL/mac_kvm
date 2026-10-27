# M1-057 Security Review

- Issue: M1-057, GitHub #65
  (<https://github.com/SheldonChangL/mac_kvm/issues/65>); risk critical,
  execution tier `C/S`, `low_model_autonomous_merge: false`; contract C-009.
- Reviewed commits: implementation `848eb62c20972bc8f9bcec9af1edd4a26c9788ac`
  and formatting follow-up `c423e4991df67caec277cc97a3b940c4879617e1`
  (final implementation head), on parent
  `496551632a4667511c384bede29a6043e1aa4c7e`.
- Evidence commit: `8943a5fdbe9343526dfa984312fff1a437441b8f`, at which the
  reviewer ran repository-wide `make verify` (exit 0, 24 of 24 gates).
- Reviewer: **Codex root reviewer.** This is a **non-author Codex review, not
  a human or independent external review.** Claude Opus authored the
  repository content and this document using only Read, Grep, Glob, Edit and
  Write; it ran no build, test, validation, formatter, git mutation, push, PR,
  merge, network or runtime verification command. The Codex root reviewer
  executed every recorded command.

## Disposition

**After fixes: Critical 0, High 0, Medium 0.** Two findings resolved (H-1 and
the formatting finding). Three Low findings remain open, all non-blocking; no
new follow-up issue is required. Machine-readable detail is in
`tests/review-findings.json`.

## Resolved findings

- **H-1 (High, resolved):** the initial draft declared unnecessary `public`
  API, contradicting the issue's internal seam and minimal surface (AC 3:
  沒有新增隱含 API). Fixed by removing the `public` modifiers before the
  implementation commit; every declaration in `TrustPolicy.swift` is now
  `internal` by default.
- **Formatting (resolved):** at `848eb62`, `make code-quality-check` failed
  because swift-format reported `AddLines`/`Indentation` at
  `TrustPolicyTests.swift` lines 305-307. Claude made a whitespace-only fix;
  the reviewer reproduced lint success, committed `c423e49`, and reran all
  eight commands, which exited 0.

## Five-axis review

1. **Source validity and traceability: pass.** Behavior traces to C-009 in
   `CONTRACT_CATALOG.md` (unknown→prompt; trusted+same fingerprint→allow;
   changed/revoked→reject; no auto-accept) and Frozen Decision 6 (TLS/security
   fails closed; unknown or changed identity is never accepted
   automatically). Rejection codes are the frozen M1-015 `SecurityErrorCode`
   cases; the 32-byte length is M1-056's
   `CertificateFingerprint.sha256DigestLength`. Fixtures are the published
   FIPS 180-2 B.1 and B.2 SHA-256 vectors, transcribed byte by byte.
2. **Product and architecture: pass.** All declarations are `internal` after
   H-1; no `public` or `package` API, frozen contract, ADR, wire format or
   `SecurityErrorCode` case is added or changed. No Barrier token or type
   appears. `make architecture-check` passed.
3. **Security, fail-safe and compatibility: pass.** See the checks below.
4. **Tests, validation and acceptance: pass.** 28 `@Test` functions cover
   every issue test category; AC 1-6 are mapped explicitly in `summary.md`.
   Commands 1-8 exited 0 at the final implementation head (`commands.json`).
   Repository-wide `make verify` (command 9) exited 0 at evidence commit
   `8943a5fdbe9343526dfa984312fff1a437441b8f`; the generated
   `artifacts/ci/m1-008-report.json` reports status passed, 24 of 24 gates,
   SHA-256 `d03573487903e0376c4225672777bfdcc3f41a667135db03b4542ae59bd3da11`.
   This metadata update will be a later commit, so a final-head
   `make verify` and GitHub CI are **pending**.
5. **Scope, hygiene and rollback: pass.** Changes are the three Exact Files
   plus this evidence package. `git diff --check` over the parent..head range
   produced no output. The protected owner artifacts
   `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were not read, modified,
   staged or committed. Rollback is a revert with no persisted data or
   resource to clean up.

## Security checks (AC 6)

| Area | Finding |
| --- | --- |
| Fail-closed | A presented fingerprint that is not exactly 32 bytes rejects `trustRejected` in every state, before any state is consulted. A trusted state with a wrong-length stored fingerprint rejects `trustRejected` even when the bytes compare equal (two empty values never match). Nothing is truncated, padded, rehashed or parsed. |
| No auto-accept | `.allow` is reachable only from `.trusted` with a valid stored fingerprint equal to a valid presented one; `.prompt` only from `.unknown` with a valid presented fingerprint. `.prompt` is not acceptance. The policy keeps no memory: prompting is not trust-on-first-use and allowing is not learning. Tested exhaustively over state and input pools. |
| Identity change | Every one of the 256 single-bit flips of the presented fingerprint and of the stored fingerprint rejects `identityChanged`; first/last byte, reversed and rotated bytes likewise. Comparison is whole-value `Data` equality with no prefix, suffix or truncated match. |
| Revocation | `.revoked` rejects `identityRevoked` for every valid fingerprint, including the one once trusted. |
| Abuse paths | Concatenated digests, display text (upper, lower, bare hex) and empty-versus-empty all reject `trustRejected`. Only `identityChanged`, `identityRevoked` and `trustRejected` are ever returned. |
| Key/secret handling | No private key, identity, password or other secret is handled. Nothing is written to UserDefaults, plist, JSON, Keychain, a log or any store. No state is retained between calls. |
| Logging/privacy | No logging. `TrustPolicyDecision` carries no fingerprint; decisions for different fingerprints are equal, so a rendered decision exposes no digest bytes. |
| Concurrency / determinism | Pure synchronous function over value types; repeated, interleaved and concurrent calls agree; inputs are not mutated. Cancellation and cleanup are not applicable because the function owns no task or resource. |
| Compatibility | No existing caller, contract, wire format or persisted data is affected. |
| Evidence privacy | This evidence contains only published test vectors and synthetic bytes; no real peer fingerprint, certificate, secret, credential or private key. |

## Open Low risks (non-blocking)

- L-1: comparison uses `Data` equality and is not constant-time. Acceptable
  because fingerprints are public material; timing reveals no secret.
- L-2: `TrustPolicyState.trusted(fingerprint:)` can structurally carry
  wrong-length `Data`. `decide` always rejects it with `trustRejected` before
  any comparison, and tests cover 10 wrong stored lengths.
- L-3: prompt UI, persistence and TLS wiring are outside M1-057. Integrators
  must never map `.prompt` to `MacTLSTrustDecision.accept`. Covered by the
  already-planned M1-058/M1-059 integration work; no new follow-up issue is
  required.

## Pending

A final-head `make verify` (required because this metadata update will be a
later commit than evidence commit `8943a5f`), GitHub CI, PR review comment,
and merge by an authorized reviewer. No model may merge autonomously.
Repository-wide `make verify` at the evidence commit is complete.
