# M2-029-FOLLOWUP-001 Barrier Server Protocol Session

## Why this follow-up exists

No M2 Issue lists a file that binds the M2-025 handshake and M2-028 encoder to
a `Transport` behind `KVMProtocolSession` (C-003), yet M2-029's
`ServerSession` needs exactly that to talk to a Barrier client without seeing
Barrier tokens. This follow-up adds it as a new file only; no existing file is
changed. It is outside every Issue's Exact Files and needs explicit reviewer
acceptance or a backlog Issue.

## Outcome

`BarrierServerProtocolSession` (`package`, in `BarrierCompatibility`):

- `connect()`: writes hello, answers HelloBack with `QINF` and `DINF` with the
  setup frames, then returns; fails within `handshakeTimeout` (`KVMClock`),
  on identity mismatch (`security.trustRejected`) or malformed input. Any
  failure disconnects the transport.
- `send(_:)`: `enterScreen` → `CINN` (once, inside the `DINF` rectangle),
  `leaveScreen` → `COUT`. Mouse, button, scroll, key and clipboard fail closed
  with `protocol.unsupportedMessage` and write no bytes (M2-023).
- After setup, client `CALV`/`CNOP`/screen-info frames are accepted silently;
  any other client frame ends the session with a typed error.
- `disconnect(reason:)` is idempotent and does not wait for the peer.
- No periodic keepalive is sent: keepalive timing is not frozen (M2-023).

## Tests

- `BarrierServerProtocolSessionTests` (8): handshake order, split chunks,
  enter/leave golden bytes, input fail-closed with no bytes, client frames,
  handshake timeout, identity rejection, idempotent disconnect. Five repeated
  runs passed.
- `Tests/Integration/M2ServerControlPathIntegrationTests` (1): reducer edge
  activation → `ServerSession.enter` → `CINN` bytes; an unencodable key
  fails closed, the session closes, the reducer returns to `local` with
  suppression disabled first, and `ServerFailSafe.recoverAll` restores local
  input before closing sessions.

## Known limitations

The session cannot deliver input until M2-026/M2-027 wire contracts are
frozen; the first forwarded input event ends the session by design.

## Clipboard (2026-10-29)

- `send(.clipboard)` writes the M2-028 `DCLP` transfer of clipboard 0;
  `canSend` refuses text over `clipboardByteLimit` (1 MiB).
- Client `CCLP` is accepted and ignored: the data follows. Client `DCLP`
  frames for clipboard 0 go to a `BarrierClipboardAssembler` (transfers up to
  4 MiB); a complete transfer with text of at most 1 MiB becomes one
  `.clipboard` event on `events` (origin `.remote` with a per-session device
  ID, empty `contentHash`). Malformed or oversized transfers and transfers
  without text are dropped, clipboard 1 frames are ignored, and the session
  stays up.
- Inbound frames may be up to 64 KiB for Barrier's 32 KiB clipboard chunks;
  every other client frame still meets the 4 KiB decoder limit. A single
  frame over 64 KiB still ends the session: the bound rests on the Barrier
  2.4.0 measurement, and a client that chunks differently is not supported.
- Tests in `BarrierServerProtocolSessionTests`: `clipboardSends`,
  `clipboardReceives`, `largeClipboardReceives` (a 600,001-byte text with a
  900,000-byte second format in 32 KiB chunks, after a clipboard 1 transfer),
  `oversizedClipboardDropped`, and the renamed client-clipboard test (frames
  without usable text are dropped and the session stays usable).

## Rollback

Revert this file, the adapter, its unit tests and the integration test.
