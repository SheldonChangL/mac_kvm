# M1-059 Fingerprint Change Warning and Reject Flow

## Outcome

`MacPlatform` provides `FingerprintChangeFlow`, the warning and reject flow for
a trusted device that presents a different certificate fingerprint. Over the
M1-058 `KeychainTrustStore`:

- the same device presenting a changed fingerprint is rejected at once, and
  the rejection carries a warning that shows the trusted and presented
  fingerprints to the owner;
- nothing is overwritten or accepted automatically: the changed fingerprint is
  never stored by an evaluation, and a warning is only ever presentation data;
- the only way to trust the presented fingerprint is the owner's explicit
  re-pair decision, which replaces the trusted record in a fixed, verified
  order and fails closed on every Keychain failure and on cancellation.

No frozen contract, ADR, or wire format is changed, and neither `KVMContracts`
nor any M1-055 to M1-058 file is edited. Changes are limited to the three Exact
Files:

- `Packages/MacPlatform/Sources/MacPlatform/FingerprintChangeFlow.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/FingerprintChangeFlowTests.swift`
- `docs/components/M1-059-fingerprint-change-flow.md`

## Contract alignment

- **C-009** (`CONTRACT_CATALOG.md`): unknown→prompt; trusted+same
  fingerprint→allow; changed/revoked→reject; no auto-accept. Every decision is
  the M1-057 `TrustPolicy.decide`; the flow only attaches a warning to its
  `identityChanged` rejection.
- **Frozen Decision 6**: TLS/security fails closed, and an unknown or changed
  identity is never accepted automatically.
- **Frozen Decision 8 and the M1-011 logging policy**: logs and diagnostics
  carry no reconstructable content, and M1-011 lists certificate and trust
  fingerprints as prohibited diagnostic content. The flow emits nothing, and
  its only fingerprint-bearing value redacts every rendering.
- **Security baseline and guardrails**: trust records stay in OS secure storage
  (only through the M1-058 store), identity change fails closed, and
  diagnostics carry allowlisted metadata only.
- The Issue's scope: abort on a changed fingerprint for the same device; show
  the old and new fingerprints without overwriting; an explicit re-pair
  action.
- Error values are the frozen M1-015 `CoreError` taxonomy. No case is added.

## API

Nothing is `public`. The `package` surface is:

| Declaration | Purpose |
| --- | --- |
| `package enum FingerprintChangeOwnerDecision: Equatable, Sendable` | `repair`, `reject`: the owner's explicit answer to a warning |
| `package struct FingerprintChangeWarning: Equatable, Sendable` | the warning presentation model |
| `trustedFingerprintDisplay: String` | the trusted fingerprint as canonical display text |
| `presentedFingerprintDisplay: String` | the presented fingerprint as canonical display text |
| `package enum FingerprintChangeOutcome: Equatable, Sendable` | `prompt`, `allow`, `reject(SecurityErrorCode)`, `identityChanged(FingerprintChangeWarning)` |
| `package struct FingerprintChangeFlow: Sendable` | the flow |
| `package init(store:)` | wraps a `KeychainTrustStore`; performs no Keychain work |
| `evaluate(deviceID:presentedFingerprint:) async -> CoreResult<FingerprintChangeOutcome>` | reads only |
| `apply(ownerDecision:warning:) async -> CoreResult<FingerprintChangeOutcome>` | writes only on `.repair` |

Internal only, reached by the tests through `@testable import`: the warning's
`deviceID`, `trustedFingerprint`, and `presentedFingerprint` (the raw digests a
re-pair acts on) and its failable `init?(deviceID:trustedFingerprint:presentedFingerprint:)`.
Package callers therefore receive a warning only from the flow and cannot
build one, so a re-pair always names the exact device and fingerprints the
owner was shown. The warning is not `Codable`, so it cannot be persisted and
decoded into a re-pair request later.

Only `.allow` lets a connection proceed. `.prompt`, `.reject`, and
`.identityChanged` all leave the connection at hand rejected; for example a
TLS caller answers `MacTLSTrustDecision.reject(.identityChanged)` for
`.identityChanged`. No caller in the repository uses the flow yet; wiring it
into a UI or `MacTLSTransport` is not part of this Issue.

## Evaluation: reject a changed identity immediately

`evaluate` performs at most one Keychain read and never writes.

| Presented | Stored record | Outcome |
| --- | --- | --- |
| not exactly 32 bytes | not read | `.reject(.trustRejected)` |
| 32 bytes | missing | `.prompt` |
| 32 bytes | the same 32 bytes | `.allow` |
| 32 bytes | different 32 bytes | `.identityChanged(warning)` |
| 32 bytes | malformed (any other length) | `.reject(.trustRejected)`, no warning |
| 32 bytes | unreadable, or read failure | `.failure` |

- The rejection is immediate: no owner interaction, retry, or second read is
  needed to reject the connection. Repeating the evaluation repeats the same
  rejection and still writes nothing.
- A malformed stored record never produces a warning, so it can never be
  re-paired through this flow; it fails closed as `trustRejected`.
- `.prompt` is the first-use case and belongs to `FirstUseTrustCoordinator`.

## Warning presentation model

`FingerprintChangeWarning` is the one deliberate presentation of both
fingerprints:

- It exists only for two different raw SHA-256 digests; the failable
  initializer refuses any other length and identical digests.
- `trustedFingerprintDisplay` and `presentedFingerprintDisplay` are
  `CertificateFingerprint.canonicalDisplay` text (32 uppercase hex pairs joined
  by colons) for the owner to compare.
- `description`, `debugDescription`, string interpolation, `dump`, and
  reflection are all redacted to `FingerprintChangeWarning(redacted)` with no
  mirror children, so printing a warning, an outcome, or a result by accident
  shows neither fingerprint nor the device. This follows the M1-053
  `MacPasteboardText` precedent.
- Both digests are copied by content, so a warning never keeps a caller's
  larger buffer alive.
- No error, failure, or other outcome carries a fingerprint, account, or device
  identifier.

## The owner's decision and the re-pair transition

`apply(ownerDecision:warning:)` records the owner's explicit answer:

- **`.reject`** answers `.reject(.trustRejected)` and performs no Keychain
  work, even from a cancelled task. The trusted record is kept, and a later
  evaluation still answers `.identityChanged`.
- **`.repair`** is the only path that writes. It moves through these states,
  in this order:

| Step | Action | If it does not succeed |
| --- | --- | --- |
| 1. Check | Read the record. | Read failure → `.failure`; nothing changed. The record no longer holds the warning's trusted fingerprint → nothing changed, and the outcome judges the presented fingerprint against the record as read (see below). |
| 2. Last point without change | Observe cancellation. | Cancelled → `cancellation.requested`; nothing changed. |
| 3. Remove | Delete the trusted record. | Failure → `.failure`; nothing is inserted, and the trusted record is not known to be removed. |
| 4. Insert | Insert the presented fingerprint if no record exists. Issued even if the task was cancelled after removal was issued. | Keychain failure → `.failure`; the device is left with no record. |
| 5. Verify | Read the record again. | The outcome is the presented fingerprint judged against this read; a failed read, or one the store refuses because the task was cancelled before it was issued, is `.failure`. |

**Success is reported only from a read that allows the presented
fingerprint**: step 5, or step 1 when the presented fingerprint is already
stored. No other path answers `.allow`.

Stale warnings (step 1) change nothing:

| Record at the check | Outcome |
| --- | --- |
| the presented fingerprint | `.allow`, with no write: a repeated re-pair is idempotent |
| missing | `.prompt`: the device is unknown and needs first-use pairing |
| another 32-byte fingerprint | `.identityChanged` with a new warning for that record |
| malformed | `.reject(.trustRejected)` |
| unreadable | `.failure` |

### The trust gap

The M1-058 store is insert-only, with one record per device and no update, so
a replacement is a removal followed by an insert. Between steps 3 and 4 the
device has **no record**:

- Anything that evaluates the device then gets `.prompt`, which is never an
  acceptance. Neither fingerprint is allowed during the gap.
- Cancellation never leaves the gap open. It is honored at step 2, before
  anything changes, because removal deliberately runs even for a cancelled
  task (M1-058). Once removal has been issued, the insert of the fingerprint
  the owner approved is issued too, in a task of its own that cancelling the
  caller does not cancel, as M1-058 completes an issued add.
- Only a Keychain failure of the insert leaves the device without a record.
  The flow then reports the failure. It **never restores** the replaced
  fingerprint: trusting again an identity the owner chose to replace (possibly
  because its key was compromised) is the owner's decision alone, through
  first-use. It **never retries**. Until the owner decides again, a later
  connection, an impostor's included, gets a first-use `.prompt` rather than
  an `.identityChanged` warning.
- If another writer stores a record during the gap, the insert finds it and
  never replaces it. Step 5 then reports it: `.allow` if it is the presented
  fingerprint, `.identityChanged` with a new warning for another fingerprint,
  and `.reject(.trustRejected)` for a malformed one. If that record disappears
  before the store reads it back (for example, removed by a concurrent re-pair
  of the same warning), the insert fails closed with the store's
  `secureStorageUnavailable` failure carrying `errSecItemNotFound`.

A failure says why the flow stopped, not what the record holds. After any
failure, and any outcome other than `.allow`, the caller must keep the
connection rejected and call `evaluate` again to learn the current state.

## Races and concurrency

- The flow is an immutable `Sendable` struct with no cache or lock; every
  decision comes from a fresh read.
- Concurrent re-pairs of one warning only ever store the presented
  fingerprint and, absent Keychain failures, end with it stored. Each answers
  `.allow`; `.prompt` when its check or verification read lands in another
  re-pair's gap; or the store's fail-closed failure when its insert finds a
  duplicate that another re-pair removes before it is read back. A test runs
  16 at once and accepts exactly these three results.
- Concurrent evaluations never write and agree with serial ones.
- The store has no compare-and-delete. If another writer replaces the record
  between step 1 and step 3, the removal deletes that record and the presented
  fingerprint is stored instead. Only explicitly owner-approved fingerprints
  are ever stored, so this cannot store an unapproved fingerprint; it can
  supersede a concurrent owner decision for the same device. Serializing owner
  decisions per device is the caller's job. A test pins this behavior.

## Execution context and cancellation

- Every Keychain call goes through the store's `@concurrent` methods, so none
  runs on the caller's actor, including the main actor.
- **Before any I/O:** a cancelled task gets `cancellation.requested` (`info`,
  `never`, `notRequired`) from `evaluate` and from `apply(.repair)`, with no
  Keychain call. A wrong-length presented fingerprint is still rejected first,
  because validation is pure.
- **After the check, before removal:** `cancellation.requested`; the trusted
  record is untouched.
- **During removal:** the removal completes and the insert is still issued,
  so the presented fingerprint is stored; the verifying read is refused, and
  the result is `cancellation.requested`, never success.
- **During the insert:** the issued insert completes and stores the presented
  fingerprint (M1-058 semantics); the verifying read is refused, and the
  result is `cancellation.requested`, never success.
- **During the verifying read:** an issued read completes and its outcome is
  reported, as for every store call.
- The caller learns the stored state by evaluating again. Nothing sleeps,
  polls, retries, or compensates.

## Failure mapping and fail-safe rules

| Condition | Result |
| --- | --- |
| Presented fingerprint of the wrong length (`evaluate`) | `.reject(.trustRejected)`, no Keychain call |
| Malformed stored record | `.reject(.trustRejected)`, no warning, no write |
| Changed fingerprint | `.identityChanged(warning)`, no write |
| Keychain read, delete, or insert failure | the store's `security.secureStorageUnavailable` failure, carrying only the `OSStatus` |
| Read success without data | the store's unreadable failure (no diagnostic code) |
| Cancellation | `cancellation.requested` |

- No failure is turned into a prompt or an acceptance.
- No failure carries a fingerprint, account, or device identifier; the only
  diagnostic is the store's raw `OSStatus`.
- A failure never poisons later calls; each call starts from the Keychain.

## Privacy

- The flow logs, prints, and emits nothing; a static audit test confirms its
  source names no logging, printing, persistence, or direct Keychain API.
- Fingerprints reach only the warning's two display fields, and only for an
  identity change.
- Caller inputs are not mutated; slices are compared and stored by content.

## Automated tests

`FingerprintChangeFlowTests.swift` declares 41 `@Test` functions: 40 run in
every ordinary run, and one is the opt-in Tier-H probe below. Seven are
parameterized over wrong lengths or `OSStatus` lists. Valid fingerprints are
the FIPS 180-2 B.1 and B.2 SHA-256 vectors, transcribed byte by byte, and
their display text is written out by hand.

Every ordinary test uses an in-memory, lock-guarded, insert-only fake Keychain
with scripted replies, one held call (read, add, or delete) for exact
cancellation and gap timing, and a call log. The seven tests that hold a call
have a one-minute time limit, and waiting for a hold ends when the test is
cancelled, so a regression fails instead of hanging the run. **No ordinary
test touches the real Keychain.** Coverage:

- **Types and warning:** closed, `Equatable`, `Sendable`; display text;
  wrong-length and identical digests refused; redaction of every rendering.
- **Evaluation:** full table; immediate rejection with a warning and no
  write; every single-bit change of the presented fingerprint; wrong presented
  length without I/O; malformed stored record; read failures.
- **Owner decision:** explicit reject without I/O; re-pair in the fixed order
  read, delete, add, read; idempotent repeat; device scoping.
- **Stale warnings:** missing, other, malformed, and unreadable records change
  nothing.
- **Fail closed:** check-read, removal, insert, and verification failures; the
  gap allows neither fingerprint; another writer's record is never replaced;
  a duplicate that vanishes before it is read back fails closed; a record
  replaced between the check and the removal is superseded (the documented
  limitation).
- **Cancellation:** before start, after the check, during removal (the
  approved fingerprint is still stored), during the insert.
- **Concurrency and privacy:** off the main actor; concurrent re-pairs and
  evaluations; failures carry no device or fingerprint; inputs and slices; a
  static audit of the flow's source.
- **Probe harness:** selection parsing, sequence, cleanup on every failure
  path, and closed-vocabulary output, all on the fake; and a static audit
  proving only the Tier-H live region names the production environment.

## Tier-H manual probe

`manualFingerprintChangeProbeRunsTheRealRepairRoundTrip` is the only test that
reaches the real Keychain. **It is not an automated acceptance test, and its
result is not an automated completion claim.** It is skipped unless the
reviewer sets `MACKVM_M1_059_MANUAL_PROBE` to
`fingerprint-change-repair-round-trip` (surrounding whitespace is ignored). A
blank value leaves it skipped; any other value fails the run without echoing
the value and touches nothing.

```sh
MACKVM_M1_059_MANUAL_PROBE=fingerprint-change-repair-round-trip \
  swift test --package-path Packages/MacPlatform \
  --filter manualFingerprintChangeProbeRunsTheRealRepairRoundTrip
```

It drives `KeychainTrustStoreEnvironment.live` with one fixed synthetic device
and the two published vectors. In a fixed order it removes the synthetic
record, trusts the first vector through `FirstUseTrustCoordinator`, evaluates
the second (expect `identityChanged` with a matching warning), declines
(expect `trustRejected`), evaluates again (expect `identityChanged`), re-pairs
(expect `allow`), evaluates the second vector (expect `allow`) and the first
(expect `identityChanged`), re-pairs again (expect `allow`, no write), then
removes the record and checks it is absent. The middle steps stop at the first
unexpected result; the final removal and absence check run on every normal
path. Only the one synthetic record is ever touched. Output is one line of
closed vocabulary; the expected line is:

```text
M1-059 manual probe: action=fingerprint-change-repair-round-trip initialCleanup=removed seedTrust=allow changed=identityChanged warning=match declined=reject.trustRejected afterDecline=identityChanged repair=allow presented=allow previous=identityChanged repeatRepair=allow finalCleanup=removed afterCleanup=absent
```

- **Signed host.** M1-058 established that the data-protection Keychain
  refuses an ad-hoc-signed SwiftPM test host without the Keychain entitlement
  (`evidence/issues/M1-058/manual.md`, D-1 and D-3), and that a pass needs a
  development-signed, provisioned host. Such a run fails closed with
  `failed.security.secureStorageUnavailable.*` fields: not a pass.
- **Leftover record.** If a run reports `afterCleanup=present`, re-running the
  probe removes the record first.
- **Reviewer evidence.** Per the Issue's Acceptance Criteria and Manual
  Verification, the run must be performed or verified by a reviewer who is
  not the executing agent, on a recorded OS, build, and hardware, and
  recorded in `evidence/issues/M1-059/manual.md`.

## Verification status

Automated results, the RED runs, a mutation check of the tests, and the gate
commands are recorded in the evidence package `evidence/issues/M1-059/` that
accompanies this change. The Tier-H manual probe and the independent security
review are pending. M1-059 is risk critical,
tier B/S/H: it must not be merged autonomously.

## Known limitations

- **Trust gap on a failed insert.** A Keychain failure of the insert, after a
  successful removal, leaves the device without a record. It then prompts and
  is never allowed, and the flow reports the failure, but the owner must pair
  the device again through first-use; until then an impostor is offered a
  first-use prompt rather than an identity-change warning.
- **No compare-and-delete.** See *Races and concurrency*.
- **Late cancellation cannot withdraw the owner's decision.** Cancellation is
  honored only before removal. After that, the presented fingerprint the owner
  approved is stored even though the result is `cancellation.requested`.
- **One failure value for different states.** A failure does not say whether
  the trusted record was removed or the presented fingerprint stored; callers
  evaluate again.
- **Malformed records.** A malformed stored record cannot be re-paired through
  this flow; removing it needs the store's `removeFingerprint` from an
  owner-driven settings flow, which is not part of this Issue.
- **Real Keychain exercised only by the manual probe,** which needs a signed,
  provisioned host.

## Out of scope

- Any UI that renders the warning or collects the owner's decision; owner
  authentication.
- Wiring the flow into `MacTLSTransport` or any session.
- Revocation records, trust listing, migration, and access groups.
- Logging, diagnostics bundles, and protocol messages.
- Any change to `KeychainTrustStore`, `TrustPolicy`, `SecurityErrorCode`, C-009,
  or other frozen contracts.

## Rollback

Revert the three M1-059 Exact Files and the evidence package. No other file
depends on them, and the flow adds no Keychain schema: records it writes are
ordinary M1-058 records under service `mackvm.trust-store.peer-fingerprint.v1`
and stay valid for the M1-058 store and first-use flow after a rollback.
