# M1-057 Evidence Summary

## Issue / Commit

- Issue: M1-057 — `實作 Trust Policy State Machine`, GitHub #65
  (<https://github.com/SheldonChangL/mac_kvm/issues/65>); P1, risk critical,
  execution tier `C/S`, `low_model_autonomous_merge: false`; depends on
  M1-056 and M1-015; contract C-009.
- Branch: `codex/m1-057-trust-policy`
- Parent in branch history: `496551632a4667511c384bede29a6043e1aa4c7e`
  (merge commit of PR #323, M1-056).
- Implementation commit: `848eb62c20972bc8f9bcec9af1edd4a26c9788ac`
- Formatting follow-up commit: `c423e4991df67caec277cc97a3b940c4879617e1`
  (whitespace-only change to `TrustPolicyTests.swift`).
- Final implementation head: `c423e4991df67caec277cc97a3b940c4879617e1`
- Evidence commit: not yet created; no hash is recorded here.
- Status: **Commands 1-8 passed at the final implementation head.** Pending:
  repository-wide `make verify`, the evidence commit, a final-head
  `make verify`, GitHub CI, PR review comment and merge; none of these is
  claimed as passed.
- Authorship: **Claude Opus** authored all repository content (source, tests,
  component document, this evidence) using only Read, Grep, Glob, Edit and
  Write. Claude ran no build, test, validation, formatter, git mutation, push,
  PR, merge, network or runtime verification command. The **Codex root
  reviewer** executed every recorded command, performed the non-author
  five-axis review, and drove the workflow. Every result below is the
  reviewer's, transcribed. No human or independent external review is
  claimed.

## Change Summary

`MacPlatform` gains the C-009 trust decision as an internal seam:

- `TrustPolicyState`: `unknown`, `trusted(fingerprint: Data)`, `revoked`.
- `TrustPolicyDecision`: `prompt`, `allow`, `reject(SecurityErrorCode)`; no
  case carries a fingerprint.
- `TrustPolicy.decide(state:presentedFingerprint:)`: a pure, synchronous
  function. A presented fingerprint that is not exactly
  `CertificateFingerprint.sha256DigestLength` (32) bytes rejects with
  `.trustRejected` in every state; a trusted state whose stored fingerprint
  has the wrong length rejects with `.trustRejected`; otherwise unknown →
  `.prompt`, trusted + same → `.allow`, trusted + different →
  `.reject(.identityChanged)`, revoked → `.reject(.identityRevoked)`.
- All declarations are `internal`; `SecurityErrorCode` is the frozen M1-015
  type and is unchanged. The policy decides only: it never stores, prompts,
  logs, formats a fingerprint, or selects a chain certificate.

Design detail: `docs/components/M1-057-trust-policy.md`.

## Exact Files

The issue's three Exact Files:

- `Packages/MacPlatform/Sources/MacPlatform/TrustPolicy.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/TrustPolicyTests.swift`
- `docs/components/M1-057-trust-policy.md`

Evidence package: `summary.md`, `commands.json`, `environment.json`,
`security-review.md`, `tests/results.json`, `tests/review-findings.json`.
Writing this evidence changed no source, test, component document or other
evidence file.

The protected owner files `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/`
were not read, modified, staged or committed.

## Scope Mapping

| Scope item | Implementation | Tests |
| --- | --- | --- |
| unknown→prompt、trusted→allow、changed→reject、revoked→reject | `TrustPolicy.decide` state switch | `fullStateDecisionTable`, `unknownIdentityPromptsAndIsNeverAllowed`, `trustedIdentityWithTheSameFingerprintIsAllowed`, bit-flip tests, `revocationCannotBeBypassedByAnyValidFingerprint` |
| decision 純函式可測 | caseless `enum TrustPolicy` with one static function; no stored state, clock, I/O or global mutable state | determinism, non-poisoning, input-immutability and concurrency tests |
| 不得 auto-accept | `.allow` only from `.trusted` with valid equal fingerprints; `.prompt` is not acceptance | `allowAndPromptAreReachableOnlyThroughTheirOwnRows`, `rejectionsUseOnlyTheTableCodes`, `earlierCallsDoNotChangeLaterDecisions` |

## Acceptance Criteria Evidence

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met.** Each scope item maps to source and named tests (table above). | `tests/results.json` `focusMapping` |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** Swift Testing 172 passed, 0 failures at the final implementation head; existing opt-in manual Tier-H probes skipped (exact skipped count not reported). Cancel/cleanup is not applicable to a pure synchronous resource-free function; determinism, idempotency and concurrency are tested instead. | `tests/results.json`; table below |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** Behavior matches C-009 and Frozen Decision 6. All declarations `internal`; no `public` or `package` API (review finding H-1, resolved before the implementation commit). No frozen contract, ADR, wire format or `SecurityErrorCode` case changed. | component doc; `security-review.md` |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met at the final implementation head.** architecture-check, strict lint, warnings-as-errors Swift tests, xcodebuild, release build and unit tests all exit 0. Repository-wide `make verify` and GitHub CI are pending. | `commands.json` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** No logging. `TrustPolicyDecision` carries no fingerprint; a test shows decisions for different fingerprints are equal. | `decisionsForDifferentFingerprintsAreIndistinguishable` |
| 6 | Security reviewer 已檢查 fail-closed、key/secret handling、identity change 與 abuse path | **Met (non-author Codex review).** | `security-review.md` |

### Automated test categories

`TrustPolicyTests.swift` declares 28 `@Test` functions; two are parameterized
over 10 lengths each (0, 1, 16, 20, 31, 33, 48, 64, 95, 4096). The full
MacPlatform run reports 172 tests passed (package total, including other
issues' tests).

| Issue item | Evidence |
| --- | --- |
| Happy path | unknown prompts; trusted with the same fingerprint allows; independent copy matches; `Data` slices with non-zero start indices |
| Boundary / limit | exactly 32 bytes is the only accepted length; 31 and 33 reject in every state |
| Invalid input / failure | wrong presented length in every state shape (parameterized); wrong stored length (parameterized); empty against empty; concatenated digests; display text in upper, lower and bare-hex form |
| Cancel / cleanup / idempotency | cancel/cleanup not applicable (pure, synchronous, resource-free); repeated calls, earlier calls do not change later ones, rejections do not poison later calls, inputs not mutated, concurrent calls agree with serial calls |
| Fail-closed | malformed stored or presented data rejects `trustRejected` before comparison; `.allow`/`.prompt` reachable only through their own rows; revocation cannot be bypassed |
| Identity/fingerprint changed or invalid | all 256 single-bit flips of the presented fingerprint and all 256 of the stored fingerprint reject `identityChanged`; first/last byte; reversed and rotated bytes |

Fixtures are the published FIPS 180-2 B.1 and B.2 SHA-256 vectors,
transcribed byte by byte, and synthetic bytes. No real peer fingerprint or
secret appears.

## Commands

Run by the Codex root reviewer on 2026-10-27 at final implementation head
`c423e4991df67caec277cc97a3b940c4879617e1`; UTC timestamps are in
`commands.json`.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `swift test --package-path Packages/MacPlatform` | 0 | Swift Testing 172 passed, 0 failures; existing opt-in manual Tier-H probes skipped |
| 2 | `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination platform=macOS build` | 0 | `BUILD SUCCEEDED` |
| 3 | `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| 4 | `make architecture-check` | 0 | `architecture check OK` |
| 5 | `make docs-check` | 0 | `docs check OK` |
| 6 | `git diff --check 496551632a4667511c384bede29a6043e1aa4c7e HEAD` | 0 | no output |
| 7 | `make code-quality-check` | 0 | swift-format 6.2.3; strict lint exit 0; Swift tests warnings-as-errors exit 0 |
| 8 | `swift build --package-path Packages/MacPlatform -c release` | 0 | `Build complete` |

Command 2 is the shell-equivalent of the issue's quoted
`-destination 'platform=macOS'`.

### Debug history (not final results)

- An earlier final-evidence attempt at implementation commit `848eb62`:
  commands 1-6 passed; command 7 failed because swift-format reported
  `AddLines`/`Indentation` at `TrustPolicyTests.swift` lines 305-307.
- Claude made a whitespace-only fix. The Codex root reviewer reproduced lint
  success, committed `c423e49`, and reran the entire 8-command set above.

### TDD history (not final results)

- Valid RED: failed only because `TrustPolicyState`, `TrustPolicyDecision`
  and `TrustPolicy` did not exist.
- GREEN passed after the implementation; superseded by command 1 above.

## Manual Verification

None is required for M1-057, and none was performed.

## Review

Non-author Codex five-axis review, not human or independent external review.
After fixes: Critical 0, High 0, Medium 0. Resolved: H-1 (unnecessary public
API) and the formatting finding. Open: 3 Low, non-blocking. Details in
`security-review.md`.

## Known Limitations

As in the component document: comparison uses `Data` equality and is not
constant-time (fingerprints are public material); SHA-256 only; no chain
selection or certificate validation; `TrustPolicyState` can structurally hold
wrong-length data, which `decide` always rejects.

Traceability note: the component document's "Verification status" section
dates the reviewer's Required Commands run to 2026-10-23; the final
implementation-head runs recorded in this evidence are dated 2026-10-27.
The component document is outside this evidence package and was not edited.

## Scope Exclusions (not implemented)

- Prompt UI, recording the person's answer, trust store and Keychain
  persistence, revocation management (M1-058 / M1-059).
- Wiring into `MacTLSTransport` or any session; mapping `.prompt` must never
  produce `MacTLSTrustDecision.accept` (L-3).
- Protocol messages, diagnostics, logging.
- Any change to `SecurityErrorCode`, C-009 or other frozen contracts.

The three Low findings are documented boundaries; L-3 is covered by
already-planned M1-058/M1-059 integration work, so no new follow-up issue is
required.

## Rollback Instructions

Revert the M1-057 PR/commits. No caller uses `TrustPolicy`; there is no
persisted state, trust data, migration, wire format or runtime resource to
clean up.

## Reviewer Required

Tier `C/S`, risk critical: security-critical; no autonomous merge. Remaining:
repository-wide `make verify`, the evidence commit, a final-head
`make verify`, GitHub CI, PR review comment, and merge by an authorized
reviewer.
