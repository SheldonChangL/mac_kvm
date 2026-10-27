# M2-025 Barrier Server Handshake and Session Accept

## Outcome

`BarrierCompatibility` now has `BarrierServerHandshake`, a deterministic
server-role state machine for the proposed M2-023 subset. Declarations are
module-internal; no public API is added.

## Flow

| State | Input | Output frames | Next |
| --- | --- | --- | --- |
| idle | `start()` | hello (`Barrier`, `00 01 00 06`) | awaitingHelloBack |
| awaitingHelloBack | HelloBack payload | `QINF` | awaitingScreenInfo |
| awaitingScreenInfo | `DINF` payload | `CIAK`, `CROP`, `DSOP` zero | ready(screen) |

## Validation (fail closed, sticky)

- HelloBack: exact marker and version, declared name length equal to the
  remaining payload, non-empty ASCII identifier name within the configured
  bound (1...255), and membership in the configured expected-name set
  (`unknownClientScreen` otherwise). A rejected handshake never reaches
  `ready`, so no active session can be created from it.
- `DINF`: decoded by the existing M1-031 `BarrierControlDecoder` in the
  client-to-server direction; its typed error is wrapped.
- Any other frame, out-of-order call, timeout or cancellation is terminal.
  After `ready`, further calls throw `alreadyReady` and late timeout/cancel are
  ignored; the session owner (M2-029) handles teardown.

## Privacy

Errors carry no name or payload bytes. `description`, `debugDescription` and
`customMirror` are redacted so the expected and received names cannot leak
through string interpolation.

## Tests

`BarrierServerHandshakeTests` (8) use golden bytes copied from
`BARRIER-EVID-0005`: happy path, unknown identity, nine invalid HelloBack
variants, invalid/out-of-order `DINF`, ordering, timeout/cancel, configuration
bounds, privacy.

## Known limitations

TLS identity of the client is enforced by the transport, not here. The server
TLS listener is blocked (see M2-023).

## Rollback

Revert the three M2-025 files.
