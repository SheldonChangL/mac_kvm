# M1-055 Security Review

- Issue: M1-055, GitHub #54; risk critical, execution tier `C/S`,
  `low_model_autonomous_merge: false`.
- Reviewed commit: `1c7ad3f99a3cb53772ec46078800ce624c00c22a`
  (base `17687e505c45ab7bb8e9b813bffc0b9ba953de8e`).
- Reviewer: **Codex root reviewer.** This is a **non-author Codex review, not
  a human or independent external review.** Claude Opus authored the
  repository content and this document, and ran no commands.

## Disposition

**Critical 0, High 0, Medium 0 unresolved.** Three High and one Medium were
found during review and resolved before the implementation commit. Eight Low
risks remain open and non-blocking. Machine-readable detail is in
`tests/review-findings.json`.

## Five-axis review

1. **Source validity and traceability: pass.** The implementation conforms to
   the frozen M1-017 `Transport` contract and M1-015 `CoreError` taxonomy
   unchanged. The certificate-order claim was corrected against the SDK header
   and Apple's documentation
   (<https://developer.apple.com/documentation/security/sec_protocol_metadata_access_peer_certificate_chain%28_%3A_%3A%29>),
   neither of which guarantees leaf-first order.
2. **Product and architecture: pass.** Nothing is `public`; the surface is
   `package` only, and the backend seam is internal. `KVMContracts`, ADRs and
   wire formats are unchanged. `make architecture-check` passed.
3. **Security, fail-safe and compatibility: pass.** See the checks below.
4. **Tests, validation and acceptance: pass at the implementation commit.**
   Commands 1-8 exited 0 (`commands.json`). `make verify` at the evidence
   commit, PR, GitHub CI and merge are **pending**.
5. **Scope, hygiene and rollback: pass.** The implementation commit contains
   exactly the three Exact Files. The protected owner files
   `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were not read, modified,
   staged or committed. Rollback is a revert with no state to clean up.

## Security checks (AC 6)

| Area | Finding |
| --- | --- |
| Fail-closed | System trust is not consulted and nothing is auto-accepted; the injected evaluator is the sole authority. Empty chain, more than 10 certificates, or more than 262,144 bytes rejects as `security.trustRejected` without evaluation. Ready without an accepted verify callback fails closed. Any connect, send or receive failure is terminal. |
| Repeated verify callbacks | Each valid callback is evaluated once in order; the first rejection is sticky and wins over earlier acceptance (H-1 fix). |
| Identity change | `reject(.identityChanged)` surfaces as exactly `security.identityChanged`, distinct from `trustRejected`, including on a later callback after an earlier accept. No identity-change policy is implemented here. |
| Abuse paths | Chain count and byte bounds (H-2 fix); 64 KiB read cap; 16-chunk receive buffer with overflow reported as `resourceExhausted`; single-use connect; send before connect or after termination fails closed. Outbound size is uncapped (L-6). |
| Plaintext isolation | The plaintext path exists only inside `#if DEBUG`, must be selected explicitly, and has no fallback from TLS. A static source audit test and the release build (command 7) confirm it is compiled out of release. |
| Key/secret handling | No key, client identity, password or storage behavior is implemented. Nothing is written to UserDefaults, plist, JSON, Keychain or a log. Certificate DER is not retained. |
| Logging/privacy | Production has no logging. Errors carry only the fixed taxonomy fields, with no host, payload, certificate or platform detail. This evidence contains no secret, credential, private key, payload or certificate bytes. |

## Open Low risks (non-blocking)

- L-1: no real network or peer handshake is exercised.
- L-2: the evaluator is synchronous and may stall the handshake.
- L-3: no transport-owned connect/read/write timeout.
- L-4: `.waiting` fails immediately as `unavailable`.
- L-5: a clean peer EOF is a `disconnected` failure.
- L-6: outbound `Data` has no transport size cap.
- L-7: the platform callback gives no documented certificate index meaning;
  later fingerprint work must not assume element zero is the leaf.
- L-8: source and tests are large (826 + 1174 lines before any later
  evidence-only edit), which costs maintainability.

## Pending

Evidence commit, `make verify` at that commit, PR, GitHub CI and merge. A
reviewer must still perform the merge; no model may merge autonomously.
