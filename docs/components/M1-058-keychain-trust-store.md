# M1-058 Keychain Trust Store and First-use Coordinator

## Outcome

`MacPlatform` provides `KeychainTrustStore`, which keeps one raw SHA-256
certificate fingerprint per device in the macOS data-protection Keychain, and
`FirstUseTrustCoordinator`, a two-phase first-use flow over it. An unknown
identity prompts and writes nothing; only the owner's explicit trust stores a
fingerprint, and only if no record exists. A stored record is never updated or
silently overwritten. Every Keychain failure fails closed as
`security.secureStorageUnavailable`.

No frozen contract, ADR, or wire format is changed, and `KVMContracts` is not
edited. Changes are limited to the three Exact Files:

- `Packages/MacPlatform/Sources/MacPlatform/KeychainTrustStore.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/KeychainTrustStoreTests.swift`
- `docs/components/M1-058-keychain-trust-store.md`

## Contract alignment

- **C-009** (`CONTRACT_CATALOG.md`): unknown→prompt; trusted+same
  fingerprint→allow; changed/revoked→reject; no auto-accept. The coordinator
  derives every decision from the M1-057 `TrustPolicy.decide`, so the C-009
  table has one implementation.
- **Frozen Decision 5**: macOS uses Keychain. **Frozen Decision 6**: security
  fails closed, and an unknown or changed identity is never accepted
  automatically.
- **Security baseline and guardrails**: trust records live in OS secure
  storage, identity change fails closed, and diagnostics carry allowlisted
  metadata only.
- The Issue's scope: trust records never go to UserDefaults or a plist; the
  first-use decision comes from the UI/owner; Keychain errors are diagnosable
  and fail closed.
- Error values are the frozen M1-015 `CoreError` taxonomy. No case is added.

## API

Nothing is `public`. The `package` surface is:

| Declaration | Purpose |
| --- | --- |
| `package enum FirstUseOwnerDecision: Equatable, Sendable` | `trust`, `reject`: the owner's explicit answer |
| `package enum FirstUseTrustOutcome: Equatable, Sendable` | `prompt`, `allow`, `reject(SecurityErrorCode)` |
| `package enum KeychainTrustInsertOutcome: Equatable, Sendable` | `inserted`, `existing(storedFingerprint: Data)` |
| `package struct KeychainTrustStore: Sendable` | the store |
| `package init()` | production initializer: the live environment; performs no Keychain work |
| `loadFingerprint(for:) async -> CoreResult<Data?>` | stored bytes as found, `nil` when missing |
| `insertFingerprintIfAbsent(_:for:) async -> CoreResult<KeychainTrustInsertOutcome>` | one atomic add; never overwrites |
| `removeFingerprint(for:) async -> CoreResult<Void>` | idempotent delete |
| `package struct FirstUseTrustCoordinator: Sendable` | the two-phase flow |
| `package init(store:)` | wraps a store |
| `evaluate(deviceID:presentedFingerprint:) async -> CoreResult<FirstUseTrustOutcome>` | phase one; never writes |
| `apply(ownerDecision:deviceID:presentedFingerprint:) async -> CoreResult<FirstUseTrustOutcome>` | phase two; writes only on `.trust` |

The store and coordinator methods are `package`. Internal only, reached by the
tests through `@testable import`: `KeychainItemReadReply` (`data`, `nonData`,
`status(OSStatus)`), `KeychainTrustStoreEnvironment` (the `readItem`,
`addItem`, `deleteItem` closures, `live`, `productionService`,
`account(for:)`, and the three query builders), and
`KeychainTrustStore.init(environment:)`.

No outcome case carries a fingerprint, account, or device identifier.
`KeychainTrustInsertOutcome.existing` returns the stored digest to the
coordinator, which reduces it to an outcome; fingerprints are public material,
but they are never logged or rendered by this component.

No caller in the repository uses the store yet; wiring it into a prompt UI or
`MacTLSTransport` is not part of this Issue.

## Keychain schema

One generic-password item per device in the data-protection Keychain:

| Attribute | Value |
| --- | --- |
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `mackvm.trust-store.peer-fingerprint.v1` (fixed, versioned) |
| `kSecAttrAccount` | `DeviceID.rawValue.uuidString.lowercased()` |
| `kSecUseDataProtectionKeychain` | `true` |
| `kSecAttrSynchronizable` | `false` |
| `kSecAttrAccessible` (add only) | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| `kSecValueData` (add only) | the raw 32-byte SHA-256 digest, nothing else |
| `kSecAttrAccessGroup` | not set; the platform's default group applies |

- **Read** adds `kSecReturnData: true` and `kSecMatchLimit:
  kSecMatchLimitOne`. **Delete** uses only the common attributes, so it
  addresses only the one record.
- The query builders are pure and are the single source of every dictionary
  the live environment hands to the platform.
- The value is the raw digest, never display text, hex, JSON, or a plist. No
  trust data goes to UserDefaults, a plist, a file, or a log.
- `ThisDeviceOnly` and non-synchronizable mean the record is not migrated to
  another device by backup or iCloud Keychain.
- The `.v1` suffix versions the record format. A future format takes a new
  service version rather than reinterpreting `.v1` records.

## Store behavior

| Operation | Platform reply | Result |
| --- | --- | --- |
| load | success with data | `.success(bytes)`, unchanged, whatever their length |
| load | item-not-found | `.success(nil)` |
| load | success without data, or a non-data result | unreadable failure |
| load | any other status | storage failure with that status |
| insert | wrong-length input | `security.trustRejected`, no Keychain call |
| insert | add success | `.inserted` |
| insert | add duplicate-item, then read data | `.existing(storedFingerprint:)`, record untouched |
| insert | add duplicate-item, then read item-not-found | storage failure (`errSecItemNotFound`), no second add |
| insert | add duplicate-item, then read unreadable or failing | the read's failure |
| insert | any other add status | storage failure with that status, never retried |
| remove | success or item-not-found | `.success(())` |
| remove | any other status | storage failure with that status |

The store does not judge stored length; it returns a malformed value unchanged
so the coordinator can fail closed on it. A non-data record is still
removable, so a corrupt record never blocks cleanup.

## Two-phase first-use flow

The owner flow is two explicit phases. The coordinator never stores anything
on a prompt, and never treats a prompt, cancellation, timeout, or failure as
consent.

1. **`evaluate`** reads only.
   - Presented fingerprint not exactly `CertificateFingerprint.sha256DigestLength`
     (32) bytes: `.reject(.trustRejected)` with no Keychain call.
   - Missing record: `.prompt`. The same unknown identity keeps prompting until
     the owner decides; prompting is not trust-on-first-use.
   - Same stored fingerprint: `.allow`.
   - Different stored fingerprint: `.reject(.identityChanged)`.
   - Malformed stored fingerprint: `.reject(.trustRejected)`, even against
     identical bytes.
   - Storage failure: `.failure`, never a prompt.
2. **The UI asks the owner**, showing the digest with
   `CertificateFingerprint.canonicalDisplay`. This UI is out of scope.
3. **`apply`** records the owner's explicit answer.
   - Wrong presented length: `.reject(.trustRejected)` with no Keychain call,
     for either decision.
   - `.reject`: `.reject(.trustRejected)`. Never writes, and a later
     `evaluate` still prompts.
   - `.trust`: one insert-if-absent. `.inserted` → `.allow`. An existing
     record is never replaced: same → `.allow`; different →
     `.reject(.identityChanged)`; malformed → `.reject(.trustRejected)`.
     Storage failure → `.failure`.

`.prompt` is not acceptance. Until the owner trusts the fingerprint and
`apply` answers `.allow`, the caller must reject the current connection, for
example with `MacTLSTrustDecision.reject`.

Re-pairing a device whose identity changed requires removing the old record
first (`removeFingerprint`) through an owner-driven flow; this Issue provides
the primitive but no such flow.

## Insert races and concurrency

- Insert-if-absent is one atomic `SecItemAdd`; it is never a read followed by
  a write. The platform add is the concurrency boundary: concurrent inserts
  for one device produce exactly one record, and every other caller observes
  duplicate-item.
- On duplicate-item the store reads the winning record and the coordinator
  judges it, so every caller's outcome agrees with the one stored record:
  callers that presented the winner get `.allow`, the others
  `.reject(.identityChanged)`.
- If the duplicate record has vanished by the time it is read, the call fails
  closed instead of adding again. Nothing sleeps, polls, or retries.
- There is no update operation in the environment, so no code path can
  overwrite a record.
- The store and coordinator are immutable `Sendable` structs with no cache or
  lock; every read goes to the Keychain.

## Execution context and cancellation

- **Off the caller.** The three store methods are `@concurrent`, so they never
  run on the caller's actor, including the main actor. The live environment
  additionally runs each blocking `SecItem` call on a global dispatch queue
  (`qos: .userInitiated`) and resumes the awaiting task with the result, so no
  Swift concurrency cooperative thread is blocked.
- **Before I/O.** `loadFingerprint` and `insertFingerprintIfAbsent`, and so
  `evaluate` and `apply(.trust)`, observe cancellation once, before any
  Keychain call, and fail with `cancellation.requested` (`info`, `never`,
  `notRequired`) having read and written nothing. Length validation is pure
  and runs first.
- **After I/O is issued.** Once an add has been issued, its actual result is
  reported even if the task is cancelled meanwhile, including the follow-up
  read after a duplicate. The store never compensates with a delete and never
  retries.
- **Explicit reject** performs no I/O and answers `.reject(.trustRejected)`
  whether or not the task is cancelled; cancellation never turns it into
  `.allow` or `.prompt`.
- **Removal runs even when cancelled.** `removeFingerprint` is cleanup and can
  only withdraw trust, so it does not skip the delete on cancellation. This
  matches the repository's cleanup precedent (M1-055 `disconnect()` completes
  from a cancelled task).

## Failure mapping and fail-safe rules

| Condition | Code | Severity | Retry | Cleanup | Diagnostic |
| --- | --- | --- | --- | --- | --- |
| Interaction or authentication status: `errSecInteractionNotAllowed`, `errSecInteractionRequired`, `errSecAuthFailed`, `errSecUserCanceled` | `security.secureStorageUnavailable` | `error` | `userActionRequired` | `notRequired` | the `OSStatus` |
| Any other failing status, including duplicate-item on read/delete and item-not-found on add | `security.secureStorageUnavailable` | `error` | `never` | `notRequired` | the `OSStatus` |
| Duplicate record vanished before it was read | `security.secureStorageUnavailable` | `error` | `never` | `notRequired` | `errSecItemNotFound` |
| Read succeeded without data, or with a non-data result | `security.secureStorageUnavailable` | `error` | `never` | `notRequired` | none |
| Store asked to insert a wrong-length value | `security.trustRejected` | `error` | `never` | `notRequired` | none |
| Cancelled before any Keychain call | `cancellation.requested` | `info` | `never` | `notRequired` | none |

- The only diagnostic carried is the raw `OSStatus` as
  `UnderlyingDiagnosticCode`. No platform error object, message, service,
  account, device identifier, or digest is attached, so failures for
  different devices and fingerprints are equal.
- No status allows automatic retry. Nothing is retried internally.
- An unreadable record never becomes "missing", so it never prompts.
- A malformed stored value never allows, even against identical bytes, and is
  never truncated, padded, or replaced.
- A failure never poisons later calls; each call starts from the Keychain.

## Privacy

- No path logs, prints, or emits a diagnostic.
- Outcomes and failures carry no fingerprint, account, service, device
  identifier, or status text; only the closed `CoreError` fields and the raw
  status code.
- The record holds only the public certificate digest. No private key,
  certificate, password, or other secret is stored.
- Caller inputs are not mutated. A `Data` slice is copied by content before it
  is stored, so later changes to the caller's buffer cannot reach the record.

## Automated tests

`KeychainTrustStoreTests.swift` declares 56 `@Test` functions: 55 run in every
ordinary run, and one is the opt-in Tier-H probe described below. Eight are
parameterized over wrong lengths, stored lengths, or `OSStatus` lists. Valid
fingerprints are the FIPS 180-2 B.1 and B.2 SHA-256 vectors, transcribed byte
by byte.

Every ordinary test uses `FakeKeychain`, an in-memory, lock-guarded,
insert-only fake with scripted replies, a held add for cancellation timing, and
a call log that records each operation's account and whether it ran on the
main thread. **No ordinary test touches the real Keychain.** Coverage:

- **Types:** closed, `Equatable`, `Sendable`; the production initializer's
  shape, referenced but never called.
- **Query contract:** fixed versioned service, canonical lowercased account,
  exact key sets for read/add/delete, data-protection Keychain,
  non-synchronizable, no access group, `WhenUnlockedThisDeviceOnly`, raw digest
  value.
- **Store:** missing as `nil`; stored bytes unchanged; insert, never
  overwrite; wrong-length insert refused without I/O; idempotent remove;
  unreadable record removable; only the given device's account addressed.
- **First-use tables:** full evaluate and apply tables, including malformed
  stored values, wrong presented lengths, and non-data records.
- **Identity changed:** every single-bit flip of the presented and stored
  fingerprint, and on duplicate trust.
- **Owner flow:** explicit reject never writes; explicit trust inserts once;
  duplicate trust same/different/malformed; vanished and unreadable duplicates
  fail closed; add failures never retried; fixed operation ordering.
- **Failures:** read/add/delete status mapping, user-action vs never,
  unreadable success, no device or fingerprint payload, indistinguishable
  outcomes, no poisoning.
- **Concurrency and cancellation:** inputs not mutated; operations off the
  main actor; 32 concurrent trusts of one fingerprint insert exactly once; 32
  competing trusts have exactly one consistent winner; concurrent evaluations
  agree with serial ones; cancellation before start performs no I/O; cancelled
  reject never allows; cancellation during an issued add reports the add's
  real result.
- **Probe harness:** the probe's selection parsing, sequence, cleanup on every
  failure path, and closed-vocabulary output, all on the fake; and a static
  source audit proving only the Tier-H live region names the production
  environment.

## Tier-H manual probe

`manualKeychainProbeRunsTheRealFirstUseRoundTrip` is the only test that reaches
the real Keychain. **It is not an automated acceptance test, and its result
is not an automated completion claim.** It is skipped unless the reviewer sets
`MACKVM_M1_058_MANUAL_PROBE` to exactly `keychain-first-use-round-trip`; any
other non-empty value fails the run without echoing the value and touches
nothing.

```sh
MACKVM_M1_058_MANUAL_PROBE=keychain-first-use-round-trip \
  swift test --package-path Packages/MacPlatform \
  --filter manualKeychainProbeRunsTheRealFirstUseRoundTrip
```

It drives `KeychainTrustStoreEnvironment.live`, the environment the production
initializer uses, with one fixed synthetic device and the two published
vectors. In a fixed order it removes the synthetic record, evaluates (expect
prompt), rejects (expect `trustRejected`), evaluates again (expect prompt),
trusts (expect allow), evaluates the same fingerprint (expect allow) and a
changed one (expect `identityChanged`), then removes the record and checks it
is absent.

- **Cleanup.** The initial removal discards any leftover from an interrupted
  run. The middle steps stop at the first unexpected result, and the final
  removal and absence check run on every normal path. Only the one synthetic
  record is ever read, written, or deleted. No sleep, poll, retry, or timer.
- **Closed output.** It prints one line of closed vocabulary only: enum case
  names and `CoreError` taxonomy names. It never prints the device identifier,
  service, account, status value, fingerprint, or the environment value. The
  expected line is:

  ```text
  M1-058 manual probe: action=keychain-first-use-round-trip initialCleanup=removed absent=prompt explicitReject=reject.trustRejected afterReject=prompt explicitTrust=allow same=allow changed=reject.identityChanged finalCleanup=removed afterCleanup=absent
  ```

- **Leftover record.** If the line reports `afterCleanup=present`, re-running
  the probe removes the record first. The probe's own removal is the
  supported cleanup path.
- **Entitlement.** The data-protection Keychain may refuse a process without a
  suitable code signature or entitlement (for example with
  `errSecMissingEntitlement`). The probe then reports
  `failed.security.secureStorageUnavailable.never`: the fail-closed outcome,
  not a pass. The reviewer records it as such and reruns in a suitably signed
  host if needed.
- **Reviewer evidence.** Per the Issue's Acceptance Criteria and Manual
  Verification, the run must be performed or verified by a reviewer who is
  not the executing agent, on a recorded OS, build, and hardware, and recorded
  in `evidence/issues/M1-058/manual.md`. Agent self-report is not acceptance.

## Verification status

Not yet verified. This document was written with the implementation; no
command, test run, or manual probe has been executed for it. The Required
Commands are:

```bash
swift test --package-path Packages/MacPlatform
xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build
python3 Tools/Backlog/validate_package.py
make architecture-check
```

Results, the Tier-H probe line, and the security review belong in
`evidence/issues/M1-058/` once a reviewer has produced them. M1-058 is risk
critical, tier C/S/H: it requires a security review and independent manual
evidence, and must not be merged autonomously.

## Known limitations

- **Real Keychain exercised only by the manual probe.** The live environment
  is verified automatically only through its pure query builders and by
  compilation.
- **Entitlement-dependent.** The shipping app needs a code signature and
  entitlements that grant data-protection Keychain access. Signing and
  entitlements are not part of this Issue.
- **No access group.** Records are in the application's default group and are
  not shared with other applications or extensions.
- **No revocation state.** Removing a record returns the device to unknown
  (prompt); a persistent revoked state is not stored.
- **Status classification.** Only the four listed statuses are user-action;
  every other failing status, including future ones, is `never`.
- **SHA-256 only.** Another digest length needs a new record version.

## Out of scope

- Prompt UI, owner authentication, pairing, and the re-pairing or
  identity-change recovery flow.
- Wiring the coordinator into `MacTLSTransport` or any session.
- Revocation records, trust listing or enumeration, migration, and access
  groups.
- App signing, entitlements, and keychain-access-group configuration.
- Logging, diagnostics bundles, and protocol messages.
- Any change to `SecurityErrorCode`, C-009, or other frozen contracts.

## Rollback

Revert the three M1-058 Exact Files. No other file depends on them.

Records already written by a build that includes this component stay in the
data-protection Keychain under service `mackvm.trust-store.peer-fingerprint.v1`
after a code rollback. They are inert without this code: nothing else reads
them. To remove them, run `removeFingerprint` for each affected device from a
build that still includes the store, before the rollback. A synthetic record
left by an interrupted manual probe is removed by re-running the probe.
