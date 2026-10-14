# M1-PROTOCOL-002 Barrier Control Message Contracts

## Status

Proposed for M1-031 consumption; pending independent review. M1-031, M1-032,
M1-033, M1-034 and M1-041 remain blocked until `BARRIER-EVID-0005` records an
approved independent review. Nothing here freezes pointer, button, wheel or
keyboard semantics.

## Context

GitHub Issue #315 was opened because M1-031 (GitHub Issue #42) requires frozen
Barrier control-message contracts and the accepted M1-PROTOCOL-001 ADR keeps
`QINF`, `CIAK`, `CROP`, `DSOP` and all enter/leave/keepalive semantics as
observation-only. M1-031 needs the screen-info request/response, setup
acknowledgement, enter, leave and keepalive/no-op control frames.

## Decision

Add `BARRIER-EVID-0005` as a consumable, narrow black-box evidence entry for the
Barrier control messages listed below. M1-031 may implement only these
contracts.

### Common frame

| Field | Width | Encoding | Frozen rule |
|---|---:|---|---|
| Frame length | 4 bytes | unsigned big-endian | Number of payload bytes after this prefix |
| Payload token | 4 bytes | ASCII | First 4 payload bytes |
| Body | frame length - 4 | per token below | Bytes after the token |

### Token-only control frames

`QINF`, `CIAK`, `CROP`, `CALV`, `CNOP` and `COUT` have a payload length of
exactly 4: the token with no body.

| Direction | Token | Frame bytes | M1-031 meaning |
|---|---|---|---|
| server-to-client | `QINF` | `00 00 00 04 51 49 4e 46` | Server requests client screen info; client answers with `DINF` |
| server-to-client | `CIAK` | `00 00 00 04 43 49 41 4b` | Setup control frame; no body |
| server-to-client | `CROP` | `00 00 00 04 43 52 4f 50` | Setup control frame observed before `DSOP`; no body |
| server-to-client | `CALV` | `00 00 00 04 43 41 4c 56` | Keepalive control frame |
| client-to-server | `CALV` | `00 00 00 04 43 41 4c 56` | Keepalive control frame |
| client-to-server | `CNOP` | `00 00 00 04 43 4e 4f 50` | No-op control frame |
| server-to-client | `COUT` | `00 00 00 04 43 4f 55 54` | Leave: client screen is no longer active |

`CALV` and `CNOP` are keepalive/no-op control frames and must not enter the KVM
input pipeline.

### DSOP

| Direction | Frame bytes |
|---|---|
| server-to-client | `00 00 00 08 44 53 4f 50 00 00 00 00` |

Body: one 4-byte unsigned big-endian value, observed as `0`. M1-031 may accept
and ignore exactly this observed no-option value during setup. No general
option semantics are frozen; a non-zero value is unsupported.

### DINF (client-to-server response to QINF)

| Frame bytes |
|---|
| `00 00 00 12 44 49 4e 46 f8 80 00 00 0e 40 04 5d 00 00 03 04 02 52` |

| Body offset | Field | Width | Encoding | Observed |
|---:|---|---:|---|---:|
| 0 | Screen origin x | 2 bytes | signed big-endian | -1920 (`f8 80`) |
| 2 | Screen origin y | 2 bytes | signed big-endian | 0 (`00 00`) |
| 4 | Width | 2 bytes | unsigned big-endian | 3648 (`0e 40`) |
| 6 | Height | 2 bytes | unsigned big-endian | 1117 (`04 5d`) |
| 8 | Reserved/unknown | 2 bytes | big-endian, meaning unknown | 0 (`00 00`) |
| 10 | Cursor x | 2 bytes | unsigned big-endian | 772 (`03 04`) |
| 12 | Cursor y | 2 bytes | unsigned big-endian | 594 (`02 52`) |

The body is exactly 14 bytes. The values match the server log line
`received client "m1-control" info shape=-1920,0 3648x1117 at 772,594`.
M1-031 may consume only this field layout and bounds. The observed display
values are capture facts, not defaults, and must not be treated as display
identity. The reserved field stays unknown; writers emit `0`.

### CINN (server-to-client enter)

| Frame bytes |
|---|
| `00 00 00 0e 43 49 4e 4e 03 04 02 52 00 00 00 01 20 00` |

| Body offset | Field | Width | Encoding | Observed |
|---:|---|---:|---|---:|
| 0 | Enter x | 2 bytes | unsigned big-endian | 772 |
| 2 | Enter y | 2 bytes | unsigned big-endian | 594 |
| 4 | Sequence | 4 bytes | unsigned big-endian | 1 |
| 8 | Modifier mask | 2 bytes | unsigned big-endian | `0x2000` |

The body is exactly 10 bytes. It correlates with the server log line
`switch from "linux-protocol" to "m1-control" at 772,594` and the client log
line `entering screen`. The modifier mask is carried as an opaque 16-bit value;
no bit meaning, including `0x2000`, is frozen.

### COUT (server-to-client leave)

`COUT` has no body. It correlates with the server log line
`switch from "m1-control" to "linux-protocol" at 1919,540` and the client log
line `leaving screen`.

### Setup context (not re-frozen here)

The server hello and client HelloBack below are setup context only. Their
contract is owned by M1-PROTOCOL-001 and M1-025.

| Direction | Frame bytes |
|---|---|
| server-to-client | `00 00 00 0b 42 61 72 72 69 65 72 00 01 00 06` |
| client-to-server | `00 00 00 19 42 61 72 72 69 65 72 00 01 00 06 00 00 00 0a 6d 31 2d 63 6f 6e 74 72 6f 6c` |

### Observed order

Server-to-client: hello, `QINF`, `CIAK`, `CROP`, `DSOP`, `CALV`, `CINN`, then
excluded side-effect frames interleaved with `CALV`, then `COUT` and further
`CALV`.
Client-to-server: HelloBack, `DINF`, then repeated `CALV`/`CNOP`.

## Non-claims

This ADR does not freeze `DCLP`, `DKDN`, `DKUP`, mouse, button, wheel,
keyboard, clipboard, TLS, Windows, or full interoperability behavior. The hotkey
trigger produced `DCLP`, `DKDN` and `DKUP` side-effect frames; their bytes are
not committed and they are not consumable by M1-031. It also does not freeze
general `DSOP` option semantics, complete `CINN` modifier-mask semantics, the
DINF reserved field, keepalive timing or timeout behavior, or a successful full
linked-screen session.

## Evidence

Evidence entry: `BARRIER-EVID-0005`

Fixture:

- `Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/sanitized.json`
- `Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/metadata.json`

Raw pcap (not committed): SHA-256
`454eb259d8b89f1bceb72f923f26815bb7c88b875947ea93d4b7ba821bbe1d7f`, 5234
bytes, 57 records.

Capture: Linux `barriers` 2.4.0-release protocol 1.6 listened on a temporary
loopback port; macOS `Barrier.app` `barrierc` 2.4.0-release protocol 1.6
(x86_64 under Rosetta, external test peer only) connected through a temporary
SSH local forward. Screen names were synthetic: `linux-protocol` and
`m1-control`. Barrier config hotkeys `control+F2` → `switchToScreen(m1-control)`
and `control+F1` → `switchToScreen(linux-protocol)` were triggered by
`xdotool` (`ctrl+F2`, `ctrl+F1`, `ctrl+F2`) on the Linux X display. The
existing user Barrier session on port 24800 was not touched.

## Security and privacy

- TLS was disabled only for the bounded observation. Production TLS defaults
  stay unchanged and unvalidated.
- The raw pcap is not committed. The fixture retains only allowlisted complete
  frames, token counts for omitted frames, synthetic names and raw digests.
- `DCLP`, `DKDN` and `DKUP` bytes are removed; only their per-direction counts
  remain as non-consumed observation metadata.
- No typed text, clipboard payload, credential, private key, token, hostname,
  IP address or real port is committed.
- No Barrier or Deskflow source, header, generated code, constant table,
  decompiled output, packet injection, binary patching or instrumentation was
  used.

## Compatibility impact

M1-031 can decode the control frames above for observed Barrier 2.4.0 protocol
1.6 behavior. This does not unblock M1-032, M1-033, M1-034 or M1-041.

## Rejected alternatives

### Freeze every token seen in the capture

Rejected. `DCLP`, `DKDN` and `DKUP` were trigger side effects, not the subject
of this capture, and no discriminating variation was recorded for them.

### Use Barrier or Deskflow source/header constants

Rejected. The M1 independent implementation policy forbids copying or
translating GPL implementation material into the first-party adapter.

## Open questions

| Question | Owner | Blocking condition |
|---|---|---|
| General `DSOP` option semantics | Protocol compatibility owner | Does not block M1-031; non-zero values stay unsupported |
| `CINN` modifier-mask bit meanings | M1-041 / keyboard owner | Does not block M1-031; mask stays opaque |
| DINF reserved field meaning | Protocol compatibility owner | Does not block M1-031; field stays unknown |
| Keepalive interval and timeout | M1-031 implementer with reviewer | Not frozen by this evidence |

## Rollback

Revert this ADR, the M1-PROTOCOL-002 fixture, the contract test and the
`BARRIER-EVID-0005` register entry. M1-031 then returns to blocked state.
