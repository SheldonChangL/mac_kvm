# M1-059 Evidence Summary

## Issue / Commit

- Issue: M1-059 — `實作 Fingerprint Change Warning／Reject Flow`, GitHub #71
  (<https://github.com/SheldonChangL/mac_kvm/issues/71>); P1, risk critical,
  execution tier `B/S/H`, `low_model_autonomous_merge: false`; depends on
  M1-058 (GitHub #69, closed); behavior per C-009.
- Branch: `codex/m1-059-fingerprint-change-flow`
- Base: `963638036cfbea39933a7c611afbeddf14ec0bfc` (merge of PR #325, M1-058).
- Implementation commit: `59f83da8535255aee174e1c508724fcec6c4a09c`
  (`feat(mac-platform): add fingerprint change flow`); 3 files, 2443
  insertions.
- Evidence commit: this package, committed after the implementation commit;
  its hash and the final-head re-verification are reported in the pull
  request, because a file cannot hold the hash of the commit that adds it.
- Status: **implementation, automated tests, the four required commands and
  the repository gates pass at the implementation commit.** Pending: the
  independent security review (AC 6), the Tier-H manual probe verified by a
  non-executing reviewer (AC 7), GitHub CI, PR review and merge. M1-059 is
  **not** claimed complete or merged.
- Authorship and roles:
  - **Claude Opus** is the sole author of the source, tests, component
    document and this evidence, and ran every recorded command in this
    session.
  - A **fresh-context Claude Opus subagent** reviewed the change read-only and
    adversarially. Same model family and launched by the author's session: it
    is not the independent review the Issue requires.
  - The independent security reviewer, the Tier-H manual reviewer and the
    merging reviewer are still to act. No human or Codex review has happened
    yet.

## Change Summary

`MacPlatform` gains `FingerprintChangeFlow`, the warning and reject flow for a
trusted device that presents a different certificate fingerprint, over the
M1-058 `KeychainTrustStore` and the M1-057 `TrustPolicy` (C-009).

- **Reject immediately:** `evaluate` reads once and never writes. Same device,
  different fingerprint → `.identityChanged(warning)`, a rejection. Missing →
  `.prompt`, same → `.allow`, wrong presented length or malformed stored
  record → `.reject(.trustRejected)`, storage failure → failure.
- **Warning model:** `FingerprintChangeWarning` is the only value that carries
  both fingerprints, as canonical display text; it exists only for two
  different 32-byte digests, package callers cannot build one, and its
  description, debug description, interpolation, `dump` and reflection are
  redacted.
- **Explicit re-pair:** only `apply(ownerDecision: .repair, warning:)` writes.
  The transition is fixed: check that the record still holds the fingerprint
  the owner saw (stale → nothing changes); observe cancellation; remove;
  insert-if-absent (issued even if the task is cancelled after removal, so
  cancellation never leaves the device without a record); verify with a fresh
  read. `.allow` comes only from a read that allows the presented fingerprint.
  `.reject` does no Keychain work.
- **Fail closed:** every Keychain failure and cancellation is reported as a
  failure; nothing is restored, retried or overwritten; no failure carries a
  fingerprint or device.
- **Surface:** `package` types and methods; the warning's raw digests,
  device and initializer are internal; no public API. Nothing logs.

Design detail: `docs/components/M1-059-fingerprint-change-flow.md`.

## Exact Files Changed

| File | SHA-256 at `59f83da` | Lines |
| --- | --- | --- |
| `Packages/MacPlatform/Sources/MacPlatform/FingerprintChangeFlow.swift` | `0f0c854855dff6ef09cb22f9d253528c3774de2d260b74bb5644ea2fba2da4c2` | 276 |
| `Packages/MacPlatform/Tests/MacPlatformTests/FingerprintChangeFlowTests.swift` | `278e7c050cd8337c5aa5e7df3b3faa5c7e7a55e575bb3ccea99f16e07fb7dadd` | 1799 |
| `docs/components/M1-059-fingerprint-change-flow.md` | `801356156bb57c32e3f1a2eb93e0cf366cce8ed8c38633e1581a6a41285dfa98` | 368 |

Evidence package (the only additional scope): `summary.md`, `commands.json`,
`environment.json`, `manual.md`, `security-review.md`, `tests/results.json`,
`tests/review-findings.json`, `tests/mutation.json`,
`tests/full-swift-testing.xml`, `tests/focused-swift-testing.xml`. No other
source, test, document, issue file, manifest or package file changed, and no
`KVMContracts`, M1-055, M1-056, M1-057 or M1-058 file was edited.

The protected owner artifacts `MacKVM_M1-001_unblock.zip` and
`mackvm-unblock/` exist only in the primary checkout. This work ran in a
separate worktree and never read, modified, staged or committed them.

## Acceptance Criteria Evidence

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met** for implementation and tests; manual sign-off pending (AC 7) | `tests/results.json` `focusMapping`; scope table below |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** At `59f83da` Swift Testing ran 269 package tests: 264 passed, 5 opt-in probes skipped, 0 failed; 41 M1-059 declarations cover every category; 9 of 9 mutations killed | `tests/results.json`, `tests/full-swift-testing.xml`, `tests/mutation.json` |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** Decisions are the M1-057 `TrustPolicy` (C-009); `package`/internal only; frozen files untouched | component document; `security-review.md` |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met at the implementation commit.** Commands 1-11 exit 0, including strict lint, warnings-as-errors tests, release build and `make verify` 24/24; 0 warning lines | `commands.json` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** The flow logs nothing (static audit); fingerprints reach only the warning's display fields; every rendering is redacted; failures carry no fingerprint or device | privacy tests; `tests/results.json` |
| 6 | Security reviewer 已檢查 fail-closed、key/secret handling、identity change 與 abuse path | **PENDING.** A fresh-context, non-independent review found C0/H0/M1/L4/N4, all addressed | `security-review.md`, `tests/review-findings.json` |
| 7 | Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證 | **PENDING.** Not run; command and expected closed output prepared | `manual.md` |

### Scope mapping

| Scope item | Implementation | Tests |
| --- | --- | --- |
| 同 device identity fingerprint 改變即中止 | `evaluate`: one read, `identityChanged` rejection with a warning, no write | `evaluationRejectsImmediately` category |
| 顯示 old/new fingerprints 但不自動覆蓋 | `FingerprintChangeWarning` display fields; redacted renderings; no write on evaluate | `warningPresentationModel`, `privacyAndInputs` |
| 明確 re-pair action | `apply(ownerDecision:warning:)`, writes only on `.repair`, fixed verified transition | `explicitOwnerDecision`, `staleWarning`, `transitionFailsClosed`, `trustGapAndRaces`, `cancellation` |
| 只改 Exact Files | three Exact Files plus this evidence | `git diff --check`, `make architecture-check`, diff stat |
| E07 / Architecture Guardrails | MacPlatform only; reaches the Keychain only through the M1-058 store | `make architecture-check`, source audit test |
| 成功、邊界、錯誤與 cancellation/cleanup 測試 | — | `tests/results.json` categories |

### Automated Tests checklist

| Issue item | Evidence |
| --- | --- |
| 至少一個 happy-path test | `repairReplacesTheRecordInAFixedOrderAndVerifiesBeforeAllowing`, `fingerprintChangeEvaluationTable`, `repairIsIdempotentOnceThePresentedFingerprintIsStored` |
| 至少一個 boundary/limit test | `wrongLengthPresentedFingerprintIsRejectedBeforeAnyKeychainRead` and `changeWarningRefusesAFingerprintOfAnyOtherLength` (0, 1, 16, 20, 31, 33, 48, 64, 95, 4096 bytes), every single-bit change |
| 至少一個 invalid input 或 failure test | `changeWarningRefusesIdenticalFingerprints`, read, delete and insert failure tests over 11 statuses each |
| cancel/cleanup/idempotency test | four cancellation tests, `repairIsIdempotentOnceThePresentedFingerprintIsStored`, `manualFingerprintChangeProbeCleansUpOnEveryFailurePath` |
| Fail-closed test | `repairSucceedsOnlyWhenTheFinalReadAllowsThePresentedFingerprint`, `repairFailsClosedWhenItsDuplicateVanishesBeforeItIsRead`, `repairGapBetweenRemovalAndInsertionNeverAllowsEitherFingerprint`, `staleWarningRepairChangesNothingAndJudgesTheRecordAsRead` |
| identity/signature/fingerprint changed or invalid test | `changedFingerprintRejectsImmediatelyWithAWarningAndNeverWrites`, `everySingleBitChangeOfThePresentedFingerprintCarriesAWarning`, `malformedStoredFingerprintRejectsWithoutAWarningOrAWrite` |

## Commands

Run by Claude Opus on 2026-10-28 at `59f83da8535255aee174e1c508724fcec6c4a09c`
on a clean working tree; UTC timestamps in `commands.json`.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `swift test --package-path Packages/MacPlatform` | 0 | Swift Testing ran 269 tests: 264 passed, 5 opt-in Tier-H probes skipped (the M1-059 probe included), 0 failed; 0 warnings |
| 2 | `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 | `** BUILD SUCCEEDED **`; 0 warning lines; the new source compiled for arm64 |
| 3 | `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| 4 | `make architecture-check` | 0 | `architecture check OK` |
| 5 | `make docs-check` | 0 | `docs check OK` |
| 6 | `make code-quality-check` | 0 | swift-format 6.2.3; strict lint exit 0; warnings-as-errors tests exit 0 |
| 7 | `git diff --check HEAD^ HEAD` (HEAD `59f83da`, HEAD^ `9636380`) | 0 | no output |
| 8 | `make verify` | 0 | 24 of 24 gates passed; report SHA-256 `7ff39d1505a8763bde106f62dcca8d56df6132bb6959be960308296bfe29f7b9` |
| 9 | `swift build --package-path Packages/MacPlatform -c release` | 0 | `Build complete!`; 0 warning lines |
| 10 | `swift test --package-path Packages/MacPlatform --xunit-output …` | 0 | 269 tests: 264 passed, 5 skipped; `tests/full-swift-testing.xml` |
| 11 | `swift test --package-path Packages/MacPlatform --filter '<41 M1-059 tests>' --xunit-output …` | 0 | 41 tests: 40 passed, 1 opt-in probe skipped; `tests/focused-swift-testing.xml` |

### TDD and review history (before the implementation commit)

- **RED:** with only the test file added to the base, the required command
  failed (exit 1) with 131 compile errors, all in the new test file, because
  `FingerprintChangeFlow`, `FingerprintChangeWarning`,
  `FingerprintChangeOutcome` and `FingerprintChangeOwnerDecision` did not
  exist.
- **First GREEN:** 1 of 39 failed: the static source audit's `print(` token
  matched inside `loadFingerprint(`. The audit was corrected to whole
  identifiers and checks itself; no production change. Then 38 passed and
  the opt-in probe was skipped.
- **Fresh-context review:** C0/H0, M1 (flaky concurrency test and false
  concurrency claims, confirmed), L1-L4, N1-N4. All addressed; see
  `tests/review-findings.json`.
- **Review-fix RED/GREEN (L3):** tests changed first; against the previous
  implementation exactly `repairCancelledDuringRemovalStillStoresTheApprovedFingerprint`
  failed; after the change 40 passed and the opt-in probe was skipped.
- **Stress:** 20000 repetitions of each concurrency test (40000 runs) and 2000
  repetitions of the 41 M1-059 tests passed (82000 test runs reported, the
  opt-in probe skipped in each repetition).
- **Mutation check:** 9 of 9 injected defects were caught (`tests/mutation.json`).

## Manual Verification

**PENDING — not performed.** The opt-in probe, its exact command and the
expected closed-vocabulary line are in `manual.md`:

```sh
MACKVM_M1_059_MANUAL_PROBE=fingerprint-change-repair-round-trip \
  swift test --package-path Packages/MacPlatform \
  --filter manualFingerprintChangeProbeRunsTheRealRepairRoundTrip
```

```text
M1-059 manual probe: action=fingerprint-change-repair-round-trip initialCleanup=removed seedTrust=allow changed=identityChanged warning=match declined=reject.trustRejected afterDecline=identityChanged repair=allow presented=allow previous=identityChanged repeatRepair=allow finalCleanup=removed afterCleanup=absent
```

Per M1-058, an ad-hoc-signed SwiftPM test host fails closed on the
data-protection Keychain; a pass needs a development-signed, provisioned host,
run or verified by a reviewer who is not the executing agent.

## Architecture & Security Checks

- `make architecture-check` and `make verify` pass; MacPlatform still depends
  only on `KVMContracts`; no Barrier, protocol, Core or input boundary is
  touched.
- The flow reaches the Keychain only through the M1-058 store (no update
  operation, insert-only, off the caller's actor); a static audit test proves
  the source names no Keychain, logging, printing or persistence API.
- Identity change fails closed; nothing is accepted or overwritten
  automatically; malformed values fail before any mutation; success is
  reported only from a verifying read.
- Full checklist and open risks: `security-review.md`.

## Known Limitations

- **L-1 Trust gap on a Keychain insert failure.** After a successful removal,
  a failed insert leaves the device without a record: it prompts and is never
  allowed, but an impostor would then see a first-use prompt rather than an
  identity-change warning until the owner decides again.
- **L-2 No compare-and-delete.** A record replaced between the check and the
  removal is removed; only owner-approved fingerprints are ever stored.
- **L-3 Late cancellation cannot withdraw the owner's decision.** After removal
  is issued, the approved fingerprint is stored even though the result is
  `cancellation.requested`.
- **L-4 One failure value for different record states.** Callers keep the
  connection rejected and evaluate again.
- **L-5 Real Keychain exercised only by the manual probe,** which needs a
  signed, provisioned host.
- **L-6 Test file size:** 1799 lines and 41 declarations, close in length to
  M1-058's 1785-line test file.

## Follow-up Issues

None opened by this change. Candidates for the owner to schedule, none
blocking M1-059:

- the UI that renders `FingerprintChangeWarning` and collects the owner's
  decision, serializing decisions per device;
- wiring the flow into `MacTLSTransport` connection handling;
- a store-level atomic replace or compare-and-delete, which would close L-1
  and L-2 but changes M1-058's frozen output and therefore needs its own
  ADR/contract Issue.

## Rollback Instructions

Revert the evidence commit and the implementation commit
(`59f83da8535255aee174e1c508724fcec6c4a09c`). No other file depends on them.
The flow adds no Keychain schema: any record a re-pair wrote is an ordinary
M1-058 record under service `mackvm.trust-store.peer-fingerprint.v1` and stays
valid for the M1-058 store and first-use flow after the rollback.

## Reviewer Required

- **B:** implemented by an agent; a stronger model or engineer must review it
  in full.
- **S:** security-critical; an independent security review is required (AC 6)
  and is pending.
- **H:** real-Keychain manual evidence by a non-executing reviewer is required
  (AC 7) and is pending.
- No model may merge; merge only by an authorized reviewer after the above.
