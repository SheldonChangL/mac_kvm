# M1-056 Security Review

- Issue: M1-056, GitHub #61
  (<https://github.com/SheldonChangL/mac_kvm/issues/61>); risk high,
  execution tier `A/S`, `low_model_autonomous_merge: false`.
- Reviewed commit: `27300d6dadb5506b8a0825cab2c2fb04a996e882`.
- Reviewer: **Codex root reviewer.** This is a **non-author Codex review, not
  a human or independent external review.** Claude Opus authored the
  repository content and this document using only Read, Grep, Glob and Edit;
  it ran no build, test, validation, formatter, git mutation, push, PR, merge,
  network or runtime verification command. The Codex root reviewer executed
  every recorded command.

## Disposition

**Critical 0, High 0, Medium 0.** Three Low findings, all non-blocking
documented scope boundaries; no follow-up issue is required. Machine-readable
detail is in `tests/review-findings.json`.

## Five-axis review

1. **Source validity and traceability: pass.** SHA-256 comes from the system
   CryptoKit framework. Expected digests in the tests are published vectors
   transcribed byte by byte; the reviewer independently checked the `abc`,
   single `0x00` and FIPS 56-byte vectors with `shasum`. Source priority is
   satisfied.
2. **Product and architecture: pass.** All declarations are `internal`; no
   `public` or `package` API, frozen contract, ADR or wire format is added or
   changed. Architecture guardrails remain satisfied; `make
   architecture-check` passed.
3. **Security, fail-safe and compatibility: pass.** See the checks below.
4. **Tests, validation and acceptance: pass at the implementation commit.**
   Commands 1-8 exited 0 (`commands.json`). `make verify` and GitHub CI at
   the evidence commit are **pending**.
5. **Scope, hygiene and rollback: pass.** Changes are the three Exact Files.
   Rollback is a revert with no persisted data or resource to clean up.

## Security checks (AC 6)

| Area | Finding |
| --- | --- |
| Fail-closed | Empty DER fails as `emptyCertificate` and never yields the empty-input digest. A digest that is not exactly 32 bytes fails as `invalidDigestLength`; it is not truncated, padded or rehashed. Both operations return `Result`, with no default or fallback value on failure. |
| Trust acceptance | None. The unit computes and formats only; it never accepts, prompts for, or rejects a peer. That belongs to the M1-057 / C-009 trust policy. |
| Identity change | A changed certificate yields a different fingerprint: different certificates, every single-bit flip, and appended or truncated input are tested. Identity-change policy is out of scope. |
| Raw / display separation | The raw 32-byte digest is the comparable value; the display string is only for people. Neither function calls the other, and display text offered as a digest is rejected by length. |
| Key/secret handling | No private key, identity, password or other secret is handled. Nothing is written to UserDefaults, plist, JSON, Keychain, a log or any store. No state is retained between calls. |
| Logging/privacy | No logging. Failure reasons carry no payload, so no rendering can expose certificate bytes, digest bytes or their length; a test checks this. Although fingerprints are not secrets, they may identify a peer and must not be logged by callers. |
| Abuse paths | Pure, synchronous, stateless; no network, storage or shared mutable state. This unit has no input-size cap (L-3). |
| Evidence privacy | This evidence contains only published test vectors and synthetic bytes; no real certificate, fingerprint of a real peer, secret, credential or private key. |

## Open Low risks (non-blocking)

- L-1: non-empty malformed bytes are hashed, because DER parsing and
  validation are outside scope. Callers must supply validated certificate
  DER.
- L-2: chain certificate selection is outside scope; no index is assumed to
  be the leaf.
- L-3: this unit has no input-size cap. Upstream M1-055 bounds the peer chain
  to 256 KiB; future callers must retain an equivalent bound.

## Pending

`make verify` and GitHub CI at the evidence commit, PR review, and merge by
an authorized reviewer. No model may merge autonomously.
