# M1-013 Canonical KVMEvent Domain Model

## Outcome

`KVMContracts` now defines the platform-neutral event language shared by
protocol adapters, KVM Core, and platform backends. It implements canonical
specification §60–62 and frozen contract C-001 without introducing protocol
message codes, platform key codes, networking objects, or operating-system
input types.

## Event surface

`KVMEvent` is a closed, `Codable`, `Equatable`, and `Sendable` enum containing:

- normalized mouse movement;
- mouse button and phase;
- signed 32-bit horizontal/vertical scroll deltas;
- virtual key, key phase, and complete modifier state;
- clipboard payload;
- screen enter with normalized position;
- screen leave.

The names describe product-domain meaning only. They do not encode Barrier,
Deskflow, macOS, Windows, Linux, socket, frame, TLS, or wire representation.

## Value invariants

- `NormalizedPoint` clamps each decoded or directly initialized coordinate to
  the closed `0...1` range. Positive/negative infinity clamp to the respective
  endpoint. NaN normalizes to `0`, preserving finite, serializable and reflexive
  value semantics without crashing on an untrusted coordinate.
- `MouseButton`, `ButtonPhase`, and `KeyPhase` are closed raw-value enums;
  decoding an unknown raw value fails instead of silently selecting a case.
- `VirtualKey.unknown(UInt32)` preserves an unmapped platform/protocol value in
  a platform-neutral representation. The exact keyboard catalog and mapping
  rules remain owned by C-005 and their designated Issues.
- Strong `DeviceID`, `ScreenID`, and `ClipboardTransactionID` wrappers prevent
  accidental UUID mixing at the event boundary. M1-014 owns the complete
  identifier catalog, including `SessionID`, and may extract shared identifier
  declarations without changing these semantics.
- Clipboard text and hash are data, never diagnostic metadata. M1-052 and
  M1-054 own the validated UTF-8 codec, payload bounds, origin/hash loop guard,
  and runtime rejection behavior. This model does not authorize sending an
  unbounded payload before those gates exist.

## Validation coverage

The issue-scoped child-package tests verify:

- every KVMEvent variant round-trips through Codable;
- all nested payloads satisfy the event's Sendable/Equatable contract;
- Int32/UInt32 extrema and screen/mouse coordinate endpoints;
- direct and decoded coordinate clamping;
- explicit unknown virtual keys;
- rejection of invalid closed-enum raw values;
- deterministic non-finite coordinate normalization and Codable round-trip.

The model owns no async work, process, file, network connection, input state, or
other resource. Cancellation, cleanup, and idempotency behavior are therefore
not applicable to this Issue; later state/resource owners must test those paths.

## Privacy and security

No production logging is added. Typed text and clipboard payload/hash values
must never be logged or copied into diagnostics. Raw external bytes remain
untrusted until their protocol adapter validates bounds and converts them to
these value types. TLS default-on, identity trust, and input fail-safe behavior
are unchanged and remain owned by their designated Issues.

## Scope boundaries

This Issue does not implement a protocol session, codec, transport, Core
router, platform mapper, input engine, clipboard adapter, or UI. It also does
not define Barrier bytes, message identifiers, `CGKeyCode`, Windows VK/scan
codes, Linux input codes, or Native Protocol encoding.

## Rollback

Revert the M1-013 PR. Keep every dependent contract, protocol, Core, and
platform Issue blocked until C-001 and its tests are restored. No persisted
data, runtime session, key/button state, trust state, or migration requires
cleanup.
