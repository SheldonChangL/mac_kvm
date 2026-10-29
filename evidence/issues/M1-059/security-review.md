# M1-059 Security Review

- Issue: M1-059, GitHub #71
  (<https://github.com/SheldonChangL/mac_kvm/issues/71>); risk critical,
  execution tier `B/S/H`, `low_model_autonomous_merge: false`; behavior per
  C-009; dependency M1-058 (#69) closed.
- Implementation commit: `59f83da8535255aee174e1c508724fcec6c4a09c` on base
  `963638036cfbea39933a7c611afbeddf14ec0bfc` (merge of PR #325, M1-058).
- Author: **Claude Opus**, sole author of the implementation, tests, component
  document and this evidence, and executor of every recorded command.

## Status

**Independent security review: PENDING.** Acceptance Criterion 6 requires a
security reviewer who checks fail-closed behavior, key/secret handling,
identity change and abuse paths, and the Issue forbids autonomous merge.
Nothing in this file is that review, and no part of it may be counted as one.

What exists now:

1. A fresh-context adversarial review by a separate Claude Opus subagent. It
   shared no conversation context with the author, but it is the same model
   family and was launched by the author's session, so it is **not** an
   independent review for Acceptance Criteria 6 or 7.
2. The author's security checklist below, with evidence pointers, for the
   independent reviewer to verify or refute.

## Fresh-context review (not independent)

All eight frozen behaviors from the brief were reported as holding. Findings:
Critical 0, High 0, Medium 1, Low 4, Nit 4. All were addressed before the
implementation commit; none is open. Machine-readable detail:
`tests/review-findings.json`.

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| M1 | medium, confirmed | Concurrency test flaky; documented claim "concurrent re-pairs answer only allow or prompt" false: a duplicate removed by a concurrent re-pair before it is read back fails closed in the store | Test now accepts exactly the three possible results; deterministic test added; document corrected; 40000 repeated runs of the concurrency tests and 2000 repetitions of all 41 tests passed |
| L1 | low, confirmed | Hold-based tests would hang, not fail, after a regression | Cancellable waits, release-first passthrough, one-minute time limits |
| L2 | low | One cancellation value for three different record states | Documented on the API: evaluate again after any failure; known limitation |
| L3 | low, design | Cancellation during removal left the device with no record | Design change, test first: the approved insert is issued once removal is issued; still reported as cancellation |
| L4 | low | No compare-and-delete between the check and the removal | Documented and pinned by a test |
| N1–N4 | nit | Attribution, wording, and probe-selection accuracy | Corrected |

### Review-driven design change (L3) for the independent reviewer

Before: a task cancelled while the removal was running was refused the
insert by the store, so the device was left with no record, and a later
connection, an impostor's included, would get a first-use prompt instead of an
identity-change warning.

After: cancellation is honored only before removal (step 2). Once removal has
been issued, the insert of the fingerprint the owner explicitly approved is
issued too, in a task of its own that cancelling the caller does not cancel.
The verifying read still refuses a cancelled task, so the result is
`cancellation.requested`, never `.allow`.

Rationale: this mirrors M1-058, where an issued owner-approved add completes
despite cancellation; it removes the only cancellation path to the trust gap;
and it never stores anything the owner did not approve. Trade-off: a
cancellation that arrives after removal cannot withdraw the owner's decision.
The reviewer should confirm or reject this trade-off; reverting it is the
single change identified as mutation M9 in `tests/mutation.json`.

## Author's security checklist (to be verified independently)

| Area | Claim | Evidence |
| --- | --- | --- |
| Immediate rejection | Same device, different 32-byte fingerprint → `.identityChanged(warning)` with one read and no write; never `.allow` | `fingerprintChangeEvaluationTable`, `changedFingerprintRejectsImmediatelyWithAWarningAndNeverWrites`, all 256 single-bit changes |
| No auto-overwrite or auto-accept | `evaluate` never writes; the only writes are in `.repair`; the store has no update and inserts only if absent | evaluation tests check `mutations.isEmpty`; source audit (flow never names the store's environment); mutation M5 killed by 15 tests |
| Fingerprint exposure | Only the warning's two display fields carry fingerprints; every rendering of the warning, an outcome, or a result is redacted; failures carry no fingerprint or device | `changeWarningIsRedactedInEveryRenderingButItsDisplayFields`, `fingerprintChangeFailuresCarryNoDeviceOrFingerprintPayload`, mutation M4 |
| No logging | The flow source names no print, dump, logging, persistence, or direct Keychain API | `fingerprintChangeFlowSourceNeverLogsOrBypassesTheStore` (static audit, self-checked) |
| Explicit owner action | Writes only on `FingerprintChangeOwnerDecision.repair`; `.reject` does no Keychain work even when cancelled; package callers cannot build a warning | `ownerRejectKeepsTheTrustedRecordWithoutKeychainIO`, `repairCancelledBeforeStartPerformsNoKeychainIO`, mutation M6 |
| Stale decisions | A re-pair acts only while the record still holds the fingerprint the owner saw; otherwise nothing changes | `staleWarningRepairChangesNothingAndJudgesTheRecordAsRead`, mutation M3 |
| Fail closed | Check-read, removal, insert and verification failures all return the store's failure; nothing becomes a prompt or an acceptance | the four parameterized status tests, `repairSucceedsOnlyWhenTheFinalReadAllowsThePresentedFingerprint` |
| Verified success only | `.allow` only from a read that allows the presented fingerprint | fixed-order test (read, delete, add, read), mutation M2 killed by 7 tests |
| Trust gap | During the gap both fingerprints prompt; cancellation never leaves it open; a Keychain insert failure leaves no record, never restores, never retries; another writer's record is never replaced | gap, insert-failure, gap-writer, vanished-duplicate and cancellation tests; mutation M9 |
| Malformed input | Wrong presented length rejected before any read; malformed stored record rejects with no warning and no write; a warning cannot hold a malformed or identical pair | parameterized length tests, warning initializer tests, mutation M7 |
| Concurrency | Off the caller's main actor; concurrent re-pairs store only the presented fingerprint; concurrent evaluations never write | main-actor test; repeated concurrency runs |
| Inputs | Caller buffers are not mutated; slices are compared and stored by content | `fingerprintChangeInputsAreNotMutatedAndSlicesAreCopiedByContent`, mutation M8 |
| Real Keychain | Not yet exercised; the opt-in probe is ready | `manual.md` (pending) |

## Open risks for the independent reviewer

- **R-1 Trust gap on a Keychain insert failure.** After a successful removal, a
  failed insert leaves the device without a record; it prompts and is never
  allowed, but an impostor would then see a first-use prompt rather than an
  identity-change warning until the owner decides again. Unavoidable without a
  store-level atomic replace, which would change M1-058's frozen output.
- **R-2 No compare-and-delete.** A record replaced between the check and the
  removal is removed; only owner-approved fingerprints are ever stored.
- **R-3 Late cancellation (L3 trade-off).** See above.
- **R-4 One failure value for different states.** Callers must evaluate again.
- **R-5 Real Keychain only through the manual probe,** which needs a signed,
  provisioned host (M1-058 D-1 to D-4).
- **R-6 Test file size.** 1799 lines and 41 declarations, close in length to
  M1-058's 1785-line test file; deterministic and strict-lint clean.

## Pending

Independent security review (AC 6), Tier-H manual probe verified by a
non-executing reviewer (AC 7), GitHub CI, PR review, and merge by an
authorized reviewer. No model may merge autonomously. M1-059 is not claimed
complete.
