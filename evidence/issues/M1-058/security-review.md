# M1-058 Security Review

- Issue: M1-058, GitHub #69
  (<https://github.com/SheldonChangL/mac_kvm/issues/69>); risk critical,
  execution tier `C/S/H`, `low_model_autonomous_merge: false`; behavior per
  C-009; dependency M1-057 merged/closed.
- Reviewed commit: implementation `5c87ba53a45d3312c282b41702138522b36e3c57`
  on parent `2bfbb0fdeadb1f783abe75a057b6a4774f04fc3a`.
- Evidence commit: `9137ab23fad2f52a7cf959e06155e6e7b87d8af4`
  (`docs(m1-058): add keychain trust store evidence`).
- Reviewer: **Codex root reviewer**, non-author. It executed every recorded
  command and reviewed — without executing — the human Product Owner's
  signed real-Keychain probe. Claude Opus authored the repository content,
  the temporary probe source and this document using file tools, plus one
  accidental inert shell command (exactly `echo skip`, during the latest
  metadata edit) that performed no repository read/write, no build, test,
  validation, formatter, git, signing, Keychain, network or runtime
  verification, and produced no evidence. **No
  second independent external engineer reviewed the source.**

## Disposition

**Critical 0, High 0, Medium 0.** Four Low findings open, all non-blocking;
no follow-up issue required now. One formatting finding resolved.
Machine-readable detail: `tests/review-findings.json`.

## Resolved finding

- **FMT-1 (formatting, resolved):** the first `make code-quality-check`
  attempt reported strict swift-format `LineLength` at 11 lines in
  `KeychainTrustStoreTests.swift`. Claude made whitespace/line-wrap-only
  edits with no behavior change; the reviewer reran the strict gate, which
  passed (command 7).

## Five-axis review

1. **Source validity and traceability: pass.** Issue #69, C-009, Frozen
   Decisions (Keychain, fail-closed), Security Baseline and Architecture
   Guardrails are mutually consistent; canonical §60–64 contains no
   contradictory Keychain/trust text. M1-057 is merged. The implementation
   uses M1-057 `TrustPolicy` and `CertificateFingerprint.sha256DigestLength`.
2. **Product and architecture: pass.** Native Swift MacPlatform component;
   production APIs package-scoped, environment seam internal, no public API.
   Protocol/Core/Input/Barrier boundaries untouched. Only the three Exact
   Files plus the required evidence; `make architecture-check` passed.
3. **Security, fail-safe and compatibility: pass.** See the table below.
4. **Tests, validation and acceptance: pass at the implementation head.**
   56 `@Test` declarations; 228 package tests passed covering happy,
   boundary, invalid, error, cancellation, cleanup, fail-closed, identity
   change, race/concurrency, query contract and privacy. The human-executed
   signed real-Keychain probe passed and was verified by the non-executing
   reviewer. Commands 1-8 exited 0. Repository-wide `make verify` passed at
   evidence commit `9137ab2` (24/24 gates, normal macOS execution
   permissions). An earlier restricted-host attempt that failed
   `code-quality` on SwiftPM's `sandbox_apply` restriction is a host
   diagnostic, not a product failure, and not acceptance evidence.
   Final-head `make verify` and GitHub CI are **pending**.
5. **Scope, hygiene and rollback: pass.** Three Exact Files in the
   implementation commit; the evidence package is the only additional scope.
   `git diff --check HEAD^ HEAD` produced no output. Protected owner artifacts
   `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were not read, modified,
   staged or committed. Rollback: before reverting, remove existing M1-058
   Keychain records via owner-driven `removeFingerprint` using a build that
   still contains it; then revert implementation and evidence. After revert,
   unremoved records are inert but the removal API is no longer available.
   The fixed probe record is already absent (removed and verified).

## Security checks (AC 6)

| Area | Finding |
| --- | --- |
| Keychain schema | Generic-password item in the data-protection Keychain; fixed service `mackvm.trust-store.peer-fingerprint.v1`; account is the canonical lowercase UUID; no hard-coded access group. Query contract tested. |
| Storage class | `synchronizable` false; `WhenUnlockedThisDeviceOnly`. Not in UserDefaults, plist, JSON or logs. |
| Stored content | Only the raw 32-byte SHA-256 digest. No secret, private key, certificate or password is stored or logged. |
| Insert-only | Atomic `SecItemAdd`; never `SecItemUpdate` or silent overwrite. A duplicate reloads the winner. |
| Explicit owner decision / no auto-accept | Missing → `prompt` with no write. Only explicit owner trust inserts; explicit reject → `trustRejected`, no write. `.prompt` is never acceptance. |
| Input validation | Full-length validation before any state or I/O; wrong-length presented values reject without Keychain I/O. |
| Identity change | Whole-`Data` equality; changed → `identityChanged`; single-bit flips of presented and stored values tested; the original record is kept. |
| Malformed data | Malformed presented or stored values → `trustRejected`, even against identical bytes. |
| Concurrency / race | Duplicate handling resolves same/changed/malformed safely; concurrent same-fingerprint trust inserts exactly once; competing fingerprints have exactly one winner. Keychain calls run off the caller's main actor. |
| Cancellation | Before I/O → `cancellation.requested` with no Keychain I/O; once the add is issued its actual result is reported. Cleanup remove runs despite cancellation; missing is idempotent success. |
| Error handling | All storage failures fail closed to `security.secureStorageUnavailable`, carrying only numeric `OSStatus` as `UnderlyingDiagnosticCode`; failures carry no device or fingerprint payload. |
| Logging / privacy | No logging. Fingerprints are public material but are never rendered or logged; outcomes for different fingerprints are indistinguishable. |
| Real host | Signed/provisioned app host passed the full round trip with cleanup verified; unsigned/entitlement-less hosts failed closed (`manual.md` D-1, D-3). |
| Evidence privacy | No Apple ID, certificate private data, UDID, profile UUID, synthetic DeviceID, account value or fingerprint bytes recorded. |

## Real-host evidence

Human Product Owner execution, Codex non-executing review (detail in
`manual.md`):

```text
M1-058 manual probe: action=keychain-first-use-round-trip initialCleanup=removed absent=prompt explicitReject=reject.trustRejected afterReject=prompt explicitTrust=allow same=allow changed=reject.identityChanged finalCleanup=removed afterCleanup=absent
exit=0
```

Executable SHA-256
`24da7eb60eef795e3cb59934de7a32975dbc945200edf5f79aaca0d353b11029`;
Apple Development signature, TeamIdentifier `4V223Y472D`, hardened runtime,
codesign deep/strict verification passed.

Build provenance (not a test result): the executable was built outside the
repository by linking the temporary probe main source with the production
MacPlatform object files for `KeychainTrustStore`, `TrustPolicy`,
`CertificateFingerprint`, `CoreErrors` and `DomainIdentifiers` produced at
implementation commit `5c87ba53a45d3312c282b41702138522b36e3c57`.

## Open Low risks (non-blocking)

- **L-1:** the production data-protection Keychain requires a correctly
  signed/provisioned host. Unsigned or entitlement-less tools fail closed;
  deployment signing is outside this issue. Manual evidence proves the signed
  path and the negative paths.
- **L-2:** `removeFingerprint` intentionally ignores pre-start cancellation
  because cleanup withdraws trust. This is documented and tested, but
  integrators must not treat cleanup failure as success.
- **L-3:** prompt UI, TLS wiring and re-pair/revocation workflows are out of
  scope and remain follow-on integration. Callers must never map `.prompt` to
  accept.
- **L-4:** the test file is large (1785 lines, 56 declarations), increasing
  maintenance cost, but it is deterministic, partitioned, strict-lint clean
  and provides exhaustive security/race/manual-harness coverage. No follow-up
  issue is required during M1 unless maintainability degrades.

## Pending

Repository-wide `make verify` at the final head (this metadata update changes
HEAD after evidence commit `9137ab2`), GitHub CI, PR review comment, and merge
by an authorized reviewer. No model may merge
autonomously. M1-058 is not claimed merged or complete.
