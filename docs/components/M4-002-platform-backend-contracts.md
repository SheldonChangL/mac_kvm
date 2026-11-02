# M4-002 Platform Backend Contracts (C-015)

## Outcome

`KVMContracts` now declares the six C-015 platform backend contracts as public
protocols, each with its small public values: input injection, screen,
clipboard, secure storage, lifecycle and capture. They are what the Linux
backends conform to: the X11 injector (M4-024), the screen backend (M4-027), the
X11 clipboard (M4-026), the trusted-server store (M4-021-FOLLOWUP-001) and the
lifecycle monitor (M4-020-FOLLOWUP-001).

Every input and output is a KVM contract value (`KVMEvent`, `CoreResult`,
`CoreError`, `ClipboardByteLimit`) or one of the values declared here. No
operating-system type, key code, handle or platform import appears, so C-015's
"each independent; input and output only KVM contracts" holds by construction.
The file imports only Foundation, for `Data`.

Once merged, this is frozen public API. It is kept to the API sketched in
section b.9 of the lead's Linux client plan, cited as "plan" below with its
section numbers. Anything a composition root needs beyond it goes through the
effects adapter that the planned client coordinator defines in KVMCore (plan
decision 5), not through a wider contract.

## Public surface

| Contract | Declarations |
| --- | --- |
| Input injection | `InjectionOutcome` (`injected`, `unsupported(_)`), `InjectionUnsupportedReason` (`unknownKey`, `noPlatformKeyCode`, `buttonUnavailable`, `repeatNotInjected`), `InputInjectionBackend` (`inject(_:)`, `flush()`, `releaseAllHeld()`) |
| Screen | `PlatformScreenGeometry` (`originX`, `originY`, `width`, `height`, `cursorX`, `cursorY`), `ScreenBackend` (`currentGeometry()`, `changes`, `stop()`) |
| Clipboard | `PlatformClipboardText` (`text`, `contentHash`, redacted renderings), `ClipboardBackend` (`readPlainText(limit:)`, `writePlainText(_:limit:)`, `ownerChanges`, `stop()`) |
| Secure storage | `PeerKey` (`rawValue`, `init?(host:port:)`, `init?(rawValue:)`, validating decoder), `TrustInsertOutcome` (`inserted`, `existing(storedFingerprint:)`), `SecureStorageBackend` (load, insert-if-absent, remove) |
| Lifecycle | `LifecycleSignal` (`willSuspend`, `didResume`, `networkAvailable`, `networkUnavailable`, `terminationRequested`), `LifecycleBackend` (`signals`, `stop()`) |
| Capture | `CaptureBackend` (`start()`, `stop()`, `events`) |

`releaseAllHeld()` is part of the b.9 API through the plan's amendment h.1 (see
Input injection). Beyond the sketch there are only:

- the public initializers a conformer in another module needs
  (`PlatformScreenGeometry`, `PlatformClipboardText`, `PeerKey`);
- the three redaction conformances of `PlatformClipboardText`;
- `PeerKey`'s parser `init?(rawValue:)`, which the planned trust file reads its
  `host:port` records with, and its validating `init(from:)`.

A test pins this inventory. It records every file-level line and every
non-private member, with wrapped headers joined, so a conformance added on a
continuation line, an `extension` or an attribute fails the suite until the
inventory changes on purpose. A second test checks at run time that
`PlatformClipboardText` is not `Encodable`.

The value types' conformances are exactly the sketch's:
`InjectionUnsupportedReason` is `String, Codable, CaseIterable`;
`PlatformScreenGeometry` and `PeerKey` are `Codable`; `InjectionOutcome`,
`TrustInsertOutcome` and `LifecycleSignal` are `Equatable` only.

## Rules

The protocols' documentation states their rules; they are part of the
contract. Rules taken from a frozen source name it. The others are first-party
policy, set here.

### Input injection

- Input is `.mouseMove`, `.mouseButton`, `.scroll` and `.key`. `.clipboard`,
  `.enterScreen` and `.leaveScreen` are not input: `inject(_:)` changes nothing
  and fails with `internal.preconditionFailed`. First-party, after the M1-036
  injector's refusal of non-move events.
- A `.key` whose key is `unknown`, or a `letter`, `digit` or `function` outside
  its catalog domain, is `.unsupported(.unknownKey)` in every phase, and its
  value is never used as a platform key code. This is the M1-042 unknown-key
  policy, rules 3 to 5, which is frozen.
- Releasing a key or button this backend pressed releases exactly the platform
  key or button it pressed, even when the keyboard mapping or the pointer
  changed in between. Such a release is never `.unsupported`. Without this
  rule, a layout reload while a key is held (on X11, a new keymap gives the key
  another key code, or none) would strand the key, and the X server's
  autorepeat would repeat it without end: a stuck key, against Frozen
  Decision 7. First-party.
- A release of input the backend does not hold is injected like any other
  event, with the current mapping. Plan a.6.2 lets such releases through,
  because releasing what is not pressed leaves nothing held; injecting them
  also clears an injected key that a crashed earlier client process left down
  (plan a.6.5).
- `.unsupported` means nothing was injected. The planned coordinator records
  held input when it decides, before the queued injection runs (plan a.3), so
  it never sees the outcome; the release rule keeps a later release of such
  input safe anyway.
- `noPlatformKeyCode` is a catalog key the current keyboard mapping cannot
  produce, and `buttonUnavailable` a button the pointer lacks.
  `repeatNotInjected` lets a backend whose platform repeats held keys itself
  decline `.repeatKey` (plan decision 6: the X11 injector never injects a
  repeat). The four reasons are a closed set: a new reason is a contract
  change.
- Calls are synchronous and bounded. The backend hands each event to the
  platform before returning and keeps no queue of events; the caller owns
  queueing (plan a.3). Calls may come from any thread and are applied one at a
  time, because a terminal path's releases may run while the drain worker is
  mid-call. Calls made one after another take effect in that order.
- `flush()` returns once the platform has processed every event injected
  before it. Terminal paths call it after their releases, so cleanup is
  reported complete only once the releases took effect (plan a.6, point 4).
- `releaseAllHeld()` releases every key and button this backend pressed and
  has not released, with the platform code it pressed. Order: keys other than
  modifiers first, then buttons, then modifier keys, each group in reverse
  press order. The modifier keys are the C-005 catalog's modifier group
  (M1-042): `shift`, `control`, `option`, `command`, `capsLock`. It succeeds
  only when nothing this backend pressed is still pressed, and otherwise fails
  with `inputSafety.cleanupPartial`. Input whose release failed stays
  recorded for a later call. Input already released is never released again,
  so a second call after a success releases nothing.
- Why (plan amendment h.1, risk f.16): on a terminal path the caller resets
  its injection queue, and an overflow discards it too. Either can drop a
  release that the Core ledger already counted, which would leave the key
  pressed on the platform. So the backend's own record of what it pressed is
  the authority for what the platform holds. Terminal paths run the ledger's
  release plan, then `releaseAllHeld()`, then `flush()`.
- Every `.failure` is terminal for the caller, and its code tells the cases
  apart: `internal.preconditionFailed` for an event that is not input, or a
  platform code such as `lifecycle.subsystemUnavailable` when the platform
  cannot take input at all.
- A conformer never logs or persists key identities or typed text (Frozen
  Decision 8). It keeps the platform codes of the input it holds in memory
  only, for the release rule and `releaseAllHeld()`.

### Screen

`PlatformScreenGeometry` is the local desktop's top-left corner and size, plus
the pointer's position, all in platform pixel coordinates. It is a plain value:
range rules that belong to a wire, such as the Barrier `DINF` range, stay with
the backend or session that owns that wire.

- `currentGeometry()` is synchronous and bounded. It never succeeds with a
  width or height below 1; it fails instead (first-party: the client turns
  normalized positions into pixels with the size).
- `changes` is one stream for the backend's lifetime, observing from the
  backend's creation, so a consumer that reads `currentGeometry()` first misses
  no later change. A change is a change of the desktop's origin or size;
  pointer movement alone is not one (plan b.11 updates the screen information
  on a screen change, not on motion).
- `changes` never yields a geometry without area. It may coalesce: a consumer
  that falls behind receives the newest geometry.
- `stop()` is idempotent and bounded, also from a cancelled task. It finishes
  `changes`, and every later `currentGeometry()` fails with
  `lifecycle.subsystemUnavailable`.

### Clipboard

V1 clipboard content is UTF-8 plain text only (C-007, frozen), with the size
budget of M1-052's `ClipboardByteLimit`.

- Both directions bound content by the limit (C-007 size limits; the Security
  Baseline's "validate size and limits before allocation"). A read never holds
  more than `limit` bytes of content. It refuses as soon as the size the
  platform states, or the content received so far, would pass the limit, which
  covers a selection handed over in parts with only a lower bound stated (X11
  INCR, plan b.13). Content that a platform API hands over whole, as AppKit
  does, is measured before any of it is returned. A write measures the text
  before encoding it. Over the limit is `clipboard.oversized`, and the
  clipboard is left as it was.
- A read is bounded in time: when the clipboard's owner does not hand the
  content over in time, the read fails with `timeout.read` and changes nothing
  (plan b.13 sets a 2 s deadline).
- A read is `nil` when the clipboard holds no text. Malformed UTF-8 is
  `clipboard.invalidUTF8` and is never repaired, as in the M1-052 codec.
- After a successful write the backend owns the clipboard with exactly the
  text, until another application takes it.
- `ownerChanges` yields when another application takes the clipboard, never for
  the backend's own writes, carries no content and may coalesce. Excluding the
  backend's own writes is the first line of loop prevention (plan a.8);
  `ClipboardLoopGuard` is the second.
- `PlatformClipboardText.contentHash` is the lowercase hexadecimal SHA-256
  digest of the text's UTF-8 bytes. Plan a.8 sets SHA-256 hex, and
  lowercase is the plan's hex form for SHA-256 values (decision 9).
  `ClipboardLoopGuard` compares hashes for both directions, so they must come
  from one function: with the function frozen, a backend's hash and one
  computed elsewhere for the same text are equal. Without it, an inbound text
  re-owned by a clipboard manager would hash differently from what the guard
  remembered, and echo back to the server.
- Every rendering of `PlatformClipboardText` (`description`,
  `debugDescription`, interpolation, `dump`, reflection) is
  `PlatformClipboardText(redacted)`, so printing one by accident leaks neither
  text nor hash (Frozen Decision 8). The value is not `Encodable`. This follows
  the precedent of `MacPasteboardText` and `FingerprintChangeWarning`.
- A call from an already cancelled task fails with `cancellation.requested` and
  changes nothing. `stop()` is idempotent and bounded, finishes `ownerChanges`,
  and every later call fails with `lifecycle.subsystemUnavailable`.
- A conformer never logs clipboard text or hashes.

### Secure storage

The store is the C-009 trust state of a client. Its rules mirror M1-058's
`KeychainTrustStore`, the Mac precedent, with `PeerKey` in place of `DeviceID`.
It is the client role's trust-record store only: it holds no private key,
certificate or revocation state. Keeping a local identity, or revoked and
rotated trust (M3-014), needs a contract of its own (see Known limitations).

- It holds raw SHA-256 certificate fingerprints, one per `PeerKey`, and nothing
  else.
- Its records are kept where only the user can change them. A store that
  cannot ensure that, for example because its record file is writable by other
  users or has been replaced by a link, fails every operation with
  `security.secureStorageUnavailable` and reads or writes no record. This
  generalizes the planned trust file's refusals (plan decision 9 and a.5) and
  the Security Baseline's "trust records use secure storage".
- A load returns the stored value exactly as found and never repairs it; the
  trust policy judges its length. It is `nil` only when no record exists. A
  store that cannot read its records, or finds them malformed, fails with
  `security.secureStorageUnavailable`, never `nil`. The planned trust file
  rejects the whole file on one malformed line, which this allows. A failure
  that looked like "no record" would turn a changed identity into an unknown
  one, which prompts instead of rejecting; this rule keeps Frozen Decision 6's
  fail-closed default.
- An insert refuses anything but a 32-byte value with `security.trustRejected`
  before any storage work, also from a cancelled task. It never replaces a
  record: an existing one is reported as `.existing(storedFingerprint:)` and
  left as it was. Of concurrent inserts for one peer exactly one reports
  `.inserted`, and every other one reports `.existing` with the value that one
  stored. Replacing a fingerprint takes an explicit remove first.
- A remove is idempotent and runs even from a cancelled task, because it only
  withdraws trust. A load or insert from an already cancelled task fails with
  `cancellation.requested` and touches nothing.
- A conformer never logs a fingerprint (plan a.7).

`PeerKey` is the storage key, `host:port`. Its rules are first-party:

- A host is printable ASCII, `!` to `~`: no space, control character or
  non-ASCII letter. An internationalized name is given in its ASCII form. This
  keeps keys independent of Unicode tables, which change between versions, and
  of canonical equivalence, under which two different byte strings compare
  equal. It also keeps invisible characters out of a key a person must read.
- The host's letters are lowercased: `Server.EXAMPLE` and `server.example` are
  one key. Host names ignore ASCII case (RFC 4343).
- The port is decimal without leading zeros, and port 0 is refused.
- A host may contain colons, as an IPv6 address does. The key splits at its
  last colon, and the port never contains one, so two different
  `(host, port)` pairs never produce the same key.
- `init?(rawValue:)` and decoding apply the same rules to a stored `host:port`:
  an uppercase host is lowercased, and anything that is not a valid key is
  refused. Comparing a value with the parsed key's `rawValue` tells whether it
  was already normalized. The decoding error does not carry the value.

Only letter case is normalized. A name and an address of the same machine, or
a name with a trailing dot, are different keys. The second spelling is
therefore an unknown peer and prompts; it never borrows trust. Pinning, not the
key, protects the connection: a key only selects the fingerprint to compare.

### Lifecycle

- `signals` has one consumer and yields each change once, in the order
  observed. No signal carries data.
- Nothing is dropped silently (the Security Baseline's explicit queue limits;
  the `Transport` contract's overflow precedent). Network edges may be merged
  so that only the newest network state remains, but `willSuspend`,
  `didResume` and `terminationRequested` are never merged or dropped. A
  backend that cannot deliver a signal finishes `signals` instead, and the
  consumer treats that end as the monitor's failure. First-party.
- `stop()` is synchronous, idempotent and bounded, and finishes `signals`.

### Capture

No conformer exists in this plan: the first-party Linux client only injects.
The contract is here because C-015 names capture. Its rules follow the shipped
M2-003 capture queue and Frozen Decision 7:

- An instance is single-use: only the first `start()` can succeed. A refused
  start fails closed with a typed error, suppresses nothing and finishes
  `events`.
- `events` yields captured input in capture order. As in M2-003, pointer moves
  may be merged, and a move that does not fit may be dropped, because a later
  move carries the newer absolute position; consecutive scrolls may be summed.
  Any other event is never dropped or reordered: a backend that cannot deliver
  one stops capture, and the consumer treats the end of the stream as a
  terminal path, because a lost key release would leave a key stuck on the
  peer.
- `stop()` is synchronous, idempotent, allowed before `start()`, and ends
  capture and any suppression of local input before it returns.

## Language-neutral shape and cross-language conformance

The contracts' language-neutral part is their wire shape and their rules. The
value types have a fixed JSON form, and tests pin it:

- `InjectionUnsupportedReason` encodes as its case name, for example
  `"unknownKey"`;
- `PlatformScreenGeometry` encodes as an object with exactly the six integer
  fields;
- `PeerKey` encodes as `{"rawValue": "<host>:<port>"}`;
- `contentHash` is the lowercase hex SHA-256 of the UTF-8 bytes.

The rules above are stated in terms any implementation language can follow.

Cross-language conformance tests are deferred. M4-SCOPE-001, superseded clause
2, defers M4-002's cross-language test scope until a non-Swift backend is
chosen. That decision belongs to the Product Owner and blocks any non-Swift
backend. Until then the Swift tests are the conformance evidence. A later
runner (M4-003) can turn the pinned JSON shapes into shared vectors.

## Reference conformers and validation coverage

The test file holds one reference conformer per protocol, written against the
public API alone, with a plain `import KVMContracts`. Each runs over an
in-memory platform:

- an injector whose keyboard mapping and pointer can change at any time, which
  keeps the in-memory record of held input that the release rule and
  `releaseAllHeld()` need, and whose platform queues input until `flush()`;
- a desktop whose pointer can move on its own;
- a clipboard whose platform states a size before handing over bytes, can
  understate it and hand over in parts, and can stop answering;
- a trust store whose actor isolation makes insert-if-absent atomic, and whose
  records can become exposed to other users;
- a lifecycle relay with a bounded buffer;
- a capture source with a bounded buffer.

The conformers are test code, not product code. They show that every rule can
be met with these shapes, and they are the pattern a platform backend follows.
The tests also carry a small FIPS 180-4 SHA-256, checked against the
standard's three examples, because Foundation has no SHA-256 on every platform
this package builds for.

Fifty-four tests cover:

- Injection: input in call order with the catalog's edge members; `unknown`
  and out-of-domain keys in every phase with nothing recorded; the other three
  reasons; held input released with its pressed codes after the keyboard
  mapping and the pointer changed; a release of input not held, with the
  current mapping; `releaseAllHeld()` in its release order, for input whose
  release never arrived, idempotent, with nothing to release once all was
  released, and as partial cleanup on a lost platform; non-input events; flush
  as a barrier; a lost platform; the closed reason set and its JSON.
- Screen: geometry; no geometry without area; the newest change always
  delivered, whether or not changes coalesce; pointer movement that is not a
  change; stop from a cancelled task; the JSON shape, including a missing
  field.
- Clipboard: the SHA-256 oracle; the frozen hash on the FIPS example; the round
  trip; `nil` when empty; exactly at the limit; an oversized read refused
  before any byte is transferred; a read in parts with an understated size
  that never holds more than the limit; an oversized write refused before
  anything is encoded; malformed UTF-8; an owner that never answers; owner
  changes from others but not from own writes; cancelled calls; stop; the
  redaction of `PlatformClipboardText` in six renderings, and that it is not
  `Encodable`.
- Secure storage: insert, load and remove; no replacement; only 32-byte values,
  checked before storage work and before cancellation; unjudged loads; storage
  failure never `nil`; a store exposed to other users failing closed; remove
  from a cancelled task; cancelled load and insert; 16 concurrent inserts
  keeping one record.
- `PeerKey`: lowercasing and a store lookup under either spelling; refused
  hosts (including non-ASCII, composed and decomposed letters and invisible
  characters) and ports; the parser; round trips, normalizing and refusing
  decodes, and an error without the value.
- Lifecycle: order and stop; signals that do not fit ending the stream instead
  of vanishing.
- Capture: order while running; refused and repeated starts; stop before start
  and twice; a move that does not fit dropped while capture continues; a key or
  button that does not fit ending the stream.
- Source: the public surface inventory; the production file imports only
  Foundation and holds no logging, output, trap, unchecked state or platform
  conditional.

The suite carries a one-minute time limit, so a broken stream cannot hang it.

## Architecture and scope boundaries

- No Barrier, native protocol, socket, platform input, pasteboard, keychain or
  file type is introduced, and no existing file changes. KVMCore,
  BarrierCompatibility and MacPlatform are untouched.
- The architecture checker's contract rules (no platform imports, types or key
  codes in `Packages/KVMContracts`) cover the new files.
- Nothing logs. The only content-bearing value, `PlatformClipboardText`, has
  redacted renderings and no encoding, and `CoreError` has no free-text field.

## Known limitations

- Cross-language conformance is deferred (M4-SCOPE-001, superseded clause 2).
- `SecureStorageBackend` is only the client's trust-record part of C-015's
  secure storage. M4-005 and M4-021 store private keys and trust records under
  M3-014's revocation and rotation rules, and their issues forbid a new public
  contract. They therefore need a contract change of their own before they can
  start.
- C-009's `revoked` state has no storage representation: removing a record
  returns the peer to unknown, which prompts. The interim Linux store plan
  (M4-021-FOLLOWUP-001) records the same limitation.
- `PeerKey` normalizes letter case only. A name and an address of one machine,
  or a trailing dot, are separate keys, and each prompts once. Lowercasing
  also merges IPv6 zone names that differ only in case (`%ETH0` and `%eth0`),
  although Linux interface names are case-sensitive; pinning still decides the
  connection.
- `CaptureBackend` has no conformer in this plan, so only the reference
  conformer exercises its rules.
- The rules live in documentation and in tests of test-only reference
  conformers. Each platform backend must prove its own conformance in its own
  tests.

## Rollback

Delete `Packages/KVMContracts/Sources/KVMContracts/PlatformBackendContracts.swift`,
its test file, this document and `evidence/issues/M4-002/`, or revert the
M4-002 commit. Nothing on `main` uses the new declarations yet; no wire format,
persisted state, migration or trust state exists for them. Once a backend
conforms, a rollback must remove that backend first.
