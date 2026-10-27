# M1-058 Evidence Summary

## Issue / Commit

- Issue: M1-058 — `實作 Keychain Trust Store 與 First-use Coordinator`,
  GitHub #69 (<https://github.com/SheldonChangL/mac_kvm/issues/69>); P1, risk
  critical, execution tier `C/S/H`, `low_model_autonomous_merge: false`;
  depends on M1-057 (merged/closed); behavior per C-009.
- Branch: `codex/m1-058-keychain-trust-store`
- Parent: `2bfbb0fdeadb1f783abe75a057b6a4774f04fc3a` (merge of PR #324,
  M1-057).
- Implementation commit (final implementation head):
  `5c87ba53a45d3312c282b41702138522b36e3c57`
  (`feat(mac-platform): add keychain trust store`); 3 files, 2605
  insertions.
- Evidence commit: **pending** (not yet created; no hash is claimed).
- Status: **Implementation, commands 1-8, manual real-Keychain probe and
  non-author review pass.** Pending: evidence commit, repository-wide
  `make verify` at the final head, GitHub CI, PR review comment and merge.
  M1-058 is **not** claimed merged or complete.
- Authorship and roles:
  - **Claude Opus** authored all repository content (source, tests,
    component document, formatting fix, the temporary probe source, and this
    evidence) using file read/search/write/edit tools only. Claude ran no
    build, test, validation, formatter, git, signing, Keychain, network or
    runtime command.
  - The **Codex root reviewer** executed every recorded command, performed the
    non-author five-axis/security review, signing setup and diagnosis, and
    drove the workflow.
  - The **human Product Owner** executed the final signed real-Keychain probe.
    Codex reviewed its exact output without executing it, so Codex is both
    non-author and non-executing reviewer for the manual evidence.
  - No second independent external engineer reviewed the source.

## Change Summary

`MacPlatform` gains a native Swift Keychain trust store and a two-phase
first-use coordinator built on the M1-057 `TrustPolicy` (C-009). No Barrier,
network or input dependency.

- **Storage:** one generic-password item per `DeviceID` in the
  data-protection Keychain; fixed service
  `mackvm.trust-store.peer-fingerprint.v1`; account is the canonical
  lowercase UUID; `synchronizable` false; no hard-coded access group;
  `WhenUnlockedThisDeviceOnly`; only the raw 32-byte SHA-256 digest is
  stored. Nothing goes to UserDefaults, plist, JSON or logs.
- **Insert-only:** atomic `SecItemAdd`; never `SecItemUpdate` or a silent
  overwrite. A duplicate reloads the winning record; races resolve safely to
  same (allow), changed (`identityChanged`) or malformed (`trustRejected`).
- **Two-phase flow:** `evaluate` — missing → `prompt` (no write); same →
  `allow`; changed → `identityChanged`; malformed presented or stored →
  `trustRejected`. `apply(ownerDecision:)` — explicit owner reject →
  `trustRejected`, no write; explicit trust → insert. Nothing is accepted
  automatically.
- **Concurrency/cancellation:** blocking Keychain calls run off the caller /
  main actor. Cancellation before I/O fails with `cancellation.requested`;
  once the add is issued its actual result is reported. Cleanup
  (`removeFingerprint`) runs despite cancellation; a missing record is
  idempotent success.
- **Errors:** storage failures map fail-closed to
  `security.secureStorageUnavailable`, preserving only the numeric
  `OSStatus` as `UnderlyingDiagnosticCode`. No logging.
- **Surface:** production APIs are package-scoped; the environment seam is
  internal; no public API.

Design detail: `docs/components/M1-058-keychain-trust-store.md`.

## Exact Files

| File | SHA-256 at `5c87ba5` |
| --- | --- |
| `Packages/MacPlatform/Sources/MacPlatform/KeychainTrustStore.swift` | `5b411a659e45866917a5dbb86cff759550a7da73ade072ac133dfa72733bfa09` |
| `Packages/MacPlatform/Tests/MacPlatformTests/KeychainTrustStoreTests.swift` | `0c6eaa9ff3bc479018f7381cd74cc9ebffee10088286f312acdf85f2012d4729` |
| `docs/components/M1-058-keychain-trust-store.md` | `9ceb3df1e8409ffbfc200f7b4157008638e906fb1a3c4135578817507be5e827` |

Evidence package (the only additional scope): `summary.md`, `commands.json`,
`environment.json`, `manual.md`, `security-review.md`, `tests/results.json`,
`tests/review-findings.json`. Writing this evidence changed no source, test,
component document, issue file or manifest.

The protected owner artifacts `MacKVM_M1-001_unblock.zip` and
`mackvm-unblock/` were not read, modified, staged or committed. Temporary
signing/probe work happened outside the repository and never modified it.

## Scope Mapping

| Scope item | Implementation | Evidence |
| --- | --- | --- |
| trust record 不進 UserDefaults/plist | Data-protection Keychain generic-password item; raw 32-byte digest only; non-sync, ThisDeviceOnly | query-contract tests; manual signed real-Keychain probe |
| first-use decision 必須由 UI/owner 提供 | `evaluate` returns `prompt` with no write; only `apply(ownerDecision: trust)` inserts | `missingRecordPromptsAndPromptingNeverPersists`, `explicitRejectRejectsAndNeverWrites`, `explicitTrustInsertsOnceAndLaterEvaluationAllows`; manual `absent=prompt`, `explicitReject`, `afterReject=prompt` |
| Keychain error 可診斷且 fail closed | Every storage failure → `security.secureStorageUnavailable` + numeric `OSStatus` only | storage-error tests; diagnostic manual attempts 1 and 3 failed closed |
| Exact Files only | Three Exact Files plus evidence | `git diff --check`, `make architecture-check` |
| E07 / Architecture Guardrails | Native Swift MacPlatform; no Barrier/Protocol/Core/Input change | `make architecture-check` |
| 成功、邊界、錯誤與 cancellation/cleanup 測試 | — | `tests/results.json` categories |

## Acceptance Criteria Evidence

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met.** Every scope item maps to source, named tests and manual output. | table above; `tests/results.json` `focusMapping` |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** 228 package tests passed, 0 failures; 56 M1-058 `@Test` declarations cover every category. | `tests/results.json` |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** C-009 and Frozen Decisions (Keychain, fail-closed) followed via M1-057 `TrustPolicy`; package/internal only, no public API. | component doc; `security-review.md` |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met at implementation head.** Commands 1-8 exit 0, including strict lint and warnings-as-errors tests. Repository-wide `make verify` at the final head and GitHub CI are **pending**. | `commands.json` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** No logging; errors carry only numeric `OSStatus`; manual output is closed vocabulary. | privacy tests; `manual.md` |
| 6 | Security reviewer 已檢查 fail-closed、key/secret handling、identity change 與 abuse path | **Met (non-author Codex review).** Critical 0, High 0, Medium 0, Low 4 open non-blocking. | `security-review.md` |
| 7 | Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證 | **Met.** Human Product Owner executed the signed real-Keychain probe; Codex (non-author, non-executing) verified exact output; cleanup verified absent. | `manual.md` |

### Automated Tests checklist

| Issue item | Evidence |
| --- | --- |
| 至少一個 happy-path test | `insertAddsTheFingerprintWhenNoRecordExists`, `explicitTrustInsertsOnceAndLaterEvaluationAllows`, `sameStoredFingerprintAllowsByContentNotStorage` |
| 至少一個 boundary/limit test | `exactlyThirtyTwoBytesIsTheOnlyAcceptedLength`, `loadReturnsTheStoredBytesUnchanged` (0, 1, 31, 32, 33, 64) |
| 至少一個 invalid input 或 failure test | `invalidPresentedLengthRejectsWithoutKeychainIO`, `insertRefusesAWrongLengthFingerprintWithoutKeychainIO`, add/read/delete failure tests |
| cancel/cleanup/idempotency test | `cancellationBeforeStartPerformsNoKeychainIO`, `cancelledExplicitRejectNeverAllowsOrWrites`, `cancellingDuringTheOwnersAddReportsTheAddsRealResult`, `removeIsIdempotentAndTreatsAMissingRecordAsSuccess`, `manualKeychainProbeCleansUpOnEveryFailurePath` |
| Fail-closed test | `readFailureMapsToSecureStorageUnavailableWithOnlyTheStatus`, `readSuccessWithoutDataFailsClosed`, `duplicateWhoseRecordVanishedFailsClosedWithoutRetrying`, `malformedStoredValueRejectsEvenAgainstIdenticalBytes` |
| identity/signature/fingerprint changed or invalid test | `changedFingerprintRejectsAndLeavesTheRecord`, all single-bit-flip tests, `duplicateTrustWithADifferentFingerprintRejectsAndKeepsTheOriginal` |

Concurrency/race (`concurrentTrustOf…`), main-actor offloading, query
contract and privacy are covered additionally; see `tests/results.json`.

## Commands

Run by the Codex root reviewer on 2026-10-27 at implementation commit
`5c87ba53a45d3312c282b41702138522b36e3c57`; UTC timestamps in
`commands.json`.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `swift test --package-path Packages/MacPlatform` | 0 | Build complete 0.53s; Swift Testing 228 passed, 0 failures, 0.027s; 4 opt-in Tier-H probes skipped (including the M1-058 probe) |
| 2 | `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 | `** BUILD SUCCEEDED **`; no warning line in the captured run |
| 3 | `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| 4 | `make architecture-check` | 0 | `architecture check OK` |
| 5 | `make docs-check` | 0 | `docs check OK` |
| 6 | `git diff --check HEAD^ HEAD` (HEAD `5c87ba5`, HEAD^ `2bfbb0f`) | 0 | no output |
| 7 | `make code-quality-check` | 0 | swift-format 6.2.3; strict lint exit 0; warnings-as-errors tests exit 0 |
| 8 | `swift build --package-path Packages/MacPlatform -c release` | 0 | Build complete 0.56s |

Repository-wide `make verify` has **not** yet been run at the evidence
commit or final head; it is pending.

### TDD and debug history (not final results)

- Valid RED: `swift test --package-path Packages/MacPlatform` failed because
  `KeychainTrustStore`, `KeychainTrustStoreEnvironment`,
  `FirstUseTrustCoordinator`, `FirstUseOwnerDecision`,
  `FirstUseTrustOutcome`, `KeychainTrustInsertOutcome` and
  `KeychainItemReadReply` did not exist; secondary inference failures were
  cascades.
- GREEN after implementation: 228 package tests passed.
- First code-quality attempt failed only on strict swift-format `LineLength`
  at 11 lines in `KeychainTrustStoreTests.swift`. Claude made
  whitespace/line-wrap-only edits; the reviewer reran the gate successfully.
  No behavior change.

## Manual Verification

**PASS.** The human Product Owner ran a development-signed, provisioned app
host on the local data-protection Keychain (device unlocked); Codex reviewed
the exact output. Closed output:

```text
M1-058 manual probe: action=keychain-first-use-round-trip initialCleanup=removed absent=prompt explicitReject=reject.trustRejected afterReject=prompt explicitTrust=allow same=allow changed=reject.identityChanged finalCleanup=removed afterCleanup=absent
exit=0
```

Expected equals actual field by field; the fixed synthetic record was removed
and verified absent. Build provenance (not a test result): the final signed
probe executable was built outside the repository by linking the temporary
probe main source with the production MacPlatform object files for
`KeychainTrustStore`, `TrustPolicy`, `CertificateFingerprint`, `CoreErrors`
and `DomainIdentifiers` produced at implementation commit
`5c87ba53a45d3312c282b41702138522b36e3c57`. Three earlier
unsigned/unprovisioned attempts failed
closed and are recorded as diagnostic (not passing) evidence. Details,
hashes and signature facts: `manual.md`.

## Review

Non-author Codex five-axis/security review: Critical 0, High 0, Medium 0.
Open: 4 Low, non-blocking, no follow-up issue required now. Resolved: the
strict-lint formatting finding. Details: `security-review.md`,
`tests/review-findings.json`.

## Known Limitations

- L-1: the production data-protection Keychain requires a correctly
  signed/provisioned host; unsigned or entitlement-less tools fail closed.
  Deployment signing is outside this issue.
- L-2: `removeFingerprint` intentionally ignores pre-start cancellation
  because cleanup withdraws trust; integrators must not treat cleanup
  failure as success.
- L-3: prompt UI, TLS wiring and re-pair/revocation workflows are
  follow-on integration. Callers must never map `.prompt` to accept.
- L-4: the test file is large (1785 lines, 56 declarations), raising
  maintenance cost; it is deterministic, partitioned and strict-lint clean.

## Rollback Instructions

1. **Before reverting**, remove any existing M1-058 Keychain records through
   the owner-driven `removeFingerprint` cleanup path, using a build that
   still contains `removeFingerprint`.
2. Revert the M1-058 implementation and evidence commits.

After revert, any record that was not removed stays inert (no caller reads
it), but the `removeFingerprint` API is no longer available to remove it. The
fixed manual probe record is already absent (removed and verified
`afterCleanup=absent`).

## Pending / Reviewer Required

Tier `C/S/H`, risk critical; no autonomous merge. Pending, none claimed as
passed: evidence commit, repository-wide `make verify` at the final head,
GitHub CI, PR review comment, and merge by an authorized reviewer.
