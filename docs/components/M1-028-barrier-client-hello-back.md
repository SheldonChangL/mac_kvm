# M1-028 Barrier Client HelloBack

## Outcome

`BarrierCompatibility` writes the complete length-prefixed client HelloBack frame
defined by the frozen M1-PROTOCOL-001 contract. The module-internal
`BarrierClientHelloBackWriter` validates the screen name against the conservative
M1 support policy and either returns the exact frame bytes or fails closed with a
typed `BarrierClientHelloBackError` that carries no screen-name bytes.

## Frozen input source

`docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md` (evidence entry
`BARRIER-EVID-0004`) freezes the frame:

| Field | Width | Encoding |
|---|---:|---|
| Frame length | 4 bytes | unsigned big-endian payload byte count |
| Marker | 7 bytes | ASCII `42 61 72 72 69 65 72` (`Barrier`) |
| Version | 4 bytes | opaque `00 01 00 06` |
| Screen-name length | 4 bytes | unsigned big-endian UTF-8 byte count |
| Screen-name bytes | variable | exactly that many UTF-8 bytes |

The golden frames are the client-to-server runs of both attempts in
`Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/sanitized.json`
(`m1-client`, 28 bytes; `m1x`, 22 bytes).

## Screen-name policy

The ADR limits M1 support to non-empty, privacy-safe ASCII identifiers whose byte
count fits a configured writer bound, and states that the bound is a MacKVM
fail-closed policy rather than a Barrier maximum. The writer applies it as:

- the screen name must have at least one byte;
- its UTF-8 byte count must not exceed `maximumScreenNameByteCount`, which the
  caller configures (1 through `largestSupportedMaximumScreenNameByteCount`,
  `UInt32.max - 15`, so the payload always fits the 4-byte length prefix);
- every byte must be an ASCII letter, digit, `-` or `_`.

The identifier set is the MacKVM reading of "privacy-safe ASCII identifier": it
admits both frozen synthetic names and excludes separators commonly found in
host names, user names, paths and addresses (`.`, `@`, `/`, `\`, `:`, space),
control bytes and every non-ASCII byte. It does not claim that Barrier rejects
other names. No default bound is chosen here; the caller (M1-029 or later
configuration) supplies it.

## Types

All declarations are module-internal; no public API or contract is added.

- `BarrierClientHelloBackWriter` (`Sendable`):
  - `init(maximumScreenNameByteCount:) throws(BarrierClientHelloBackError)`;
  - `frame(screenName:) throws(BarrierClientHelloBackError) -> [UInt8]`;
  - `markerBytes`, `versionBytes` and
    `largestSupportedMaximumScreenNameByteCount` are the frozen/derived constants;
  - stores only `maximumScreenNameByteCount`.
- `BarrierClientHelloBackError` (`Equatable`, `Sendable`):
  - `invalidMaximumScreenNameByteCount`;
  - `emptyScreenName`;
  - `screenNameTooLong(byteCount:limit:)`;
  - `unsupportedScreenNameCharacter`;
  - `frameEncodingFailed` (defensive; unreachable after the bound checks).

Errors carry at most a byte count and the configured limit. No KVM Core, KVMEvent
or platform dependency is added.

## Behavior

`frame(screenName:)` checks, in order, and stops at the first failure:

1. empty name: `emptyScreenName`;
2. UTF-8 byte count above the bound: `screenNameTooLong`; this runs before any
   byte is inspected or copied;
3. any byte outside the identifier set: `unsupportedScreenNameCharacter`.

It then writes the payload (marker, version, big-endian name length, name bytes)
and the frame envelope through `BarrierBinaryWriter` (M1-021), whose integer
writes emit explicit big-endian bytes and never use platform byte order. Each
writer is capped at the exact validated size.

The writer is a pure synchronous function of the screen name. It owns no
resource, mutable state, threading or I/O, so there is nothing to cancel or clean
up; repeated writes return identical bytes and a failed write cannot affect a
later one. It performs no logging.

## Security and privacy logging

- The writer performs no logging, printing or diagnostics output of any kind; it
  imports no logging facility.
- A screen name is host-identifying data. No error case carries it or any slice
  of it: `screenNameTooLong` carries only the UTF-8 byte count and the configured
  limit, and every other case carries nothing.
  `helloBackErrorsCarryOnlyAllowlistedMetadata` pins this.
- The writer stores only `maximumScreenNameByteCount`, never a screen name
  (`writerCarriesOnlyTheConfiguredLimit`).
- The identifier set rejects the separators commonly found in host names, user
  names, paths and addresses, so the supported M1 names cannot embed them.
- Tests use only the synthetic `m1-client`/`m1x` names from the sanitized fixture
  and generated ASCII strings; no real host or user name is used.
- Whether a caller may log the frame or the screen name is decided by the caller
  (M1-029 or later) under the project logging policy; this writer adds no log
  site.

## Scope boundaries

- Fragmentation, coalescing and stream truncation belong to
  `BarrierFrameReassembler` (M1-022). Tests feed written frames through it, one
  byte at a time and coalesced, and truncate a written frame at every length to
  pin the hand-off.
- No handshake sequencing or reaction to server tokens (M1-029); no `QINF`,
  `CIAK`, `CROP`, `DSOP` or other message handling (M1-031 and later).
- No socket, transport, TLS, logging, threading or KVM Core dependency.
- No Barrier/Deskflow source was consulted or copied; only the frozen ADR and the
  sanitized fixture bytes are used.

## Validation coverage

`BarrierClientHelloBackTests` (21 tests) verifies:

- happy path: both golden frames written byte-for-byte; constants equal the
  golden marker/version bytes; the six-byte delta between the frames; written
  frames reassembled by M1-022 yield exactly the golden payloads;
- boundaries: name at exactly the bound, one byte over, 1-byte name at bound 1,
  a 300-byte name proving big-endian length fields, every allowed character
  class, invalid and largest supported bounds;
- failures: empty name, non-ASCII names, ASCII separators and control bytes,
  length checked before characters, errors carrying only `byteCount`/`limit`,
  writer carrying only its bound, truncation reported by the reassembler at
  every length;
- cleanup/idempotency: repeated writes are byte-identical; failed writes do not
  affect later writes.

## Rollback

Revert the M1-028 change. The writer owns no runtime resource, persisted data or
migration, and no production code consumes it yet.
