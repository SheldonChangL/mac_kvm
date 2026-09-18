# M1-014 Domain Identifiers

## Outcome

`KVMContracts` defines separate `DeviceID`, `ScreenID`, and `SessionID` value
types. Each identifier wraps a `UUID` and conforms to `RawRepresentable`,
`Codable`, `Hashable`, and `Sendable`, so APIs cannot accidentally substitute a
raw UUID, string, or a different identifier domain.

## Contract

All three identifiers expose the same deliberately small surface:

- `init(rawValue: UUID)` preserves a supplied UUID exactly;
- `init()` generates a new UUID;
- `rawValue` is read-only;
- synthesized `Codable` preserves the established keyed `rawValue` shape;
- synthesized equality and hashing operate on the wrapped UUID.

`DeviceID` and `ScreenID` were moved from `KVMEvent.swift` without changing
their declarations or behavior. `SessionID` follows the same reference-package
contract. The types remain distinct at compile time even when their UUID values
are equal.

## Validation coverage

The issue-scoped tests verify:

- fixed device, screen, and session UUIDs preserve their values and round-trip
  through `Codable`;
- the required `RawRepresentable`, `Codable`, `Hashable`, and `Sendable`
  constraints hold at compile time;
- all-zero and all-maximum UUID boundary values round-trip unchanged;
- malformed UUID payloads fail decoding with `DecodingError`;
- the existing KVMEvent suite still round-trips events containing device and
  screen identifiers.

These immutable value types own no async work, resource, input state, network
connection, or lifecycle. Cancellation, cleanup, and idempotency paths are not
applicable; later owners of those behaviors must provide their own tests.

## Architecture and security

The identifiers contain no Barrier message code, native wire representation,
platform input code, networking type, trust policy, or logging behavior. No
production logs are added, and no identifier is automatically accepted as a
trusted peer identity. Protocol adapters and Core may share these domain types
without coupling Core to a protocol or platform implementation.

## Scope boundaries

This Issue does not define identifier persistence, display names, topology,
routing, protocol encoding, trust decisions, session lifecycle, or migration.
It does not alter KVMEvent cases or payload semantics.

## Rollback

Revert the M1-014 PR to remove `SessionID`, return the two existing declarations
to `KVMEvent.swift`, and keep dependent Issues blocked. No persisted state or
runtime resource requires cleanup.
