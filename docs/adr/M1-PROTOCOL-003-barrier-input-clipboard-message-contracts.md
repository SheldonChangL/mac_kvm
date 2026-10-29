# M1-PROTOCOL-003 Barrier Input and Clipboard Message Contracts

## Status

Proposed on 2026-10-29. Acceptance requires review by a protocol reviewer who is not the
implementing agent, and the Product Owner's merge.

Once accepted, these contracts may be consumed by:

- the Barrier client decoders M1-032, M1-033, M1-034 and M1-041;
- the key mapper M1-043;
- the client session M1-029-FOLLOWUP-001 ([`M4-SCOPE-001`](M4-SCOPE-001-linux-client-first.md)).

The first-party Mac server's existing encoders, which were implemented from the same
evidence before review, also become formally backed by these contracts.

## Context

[`M1-PROTOCOL-002`](M1-PROTOCOL-002-barrier-control-message-contracts.md) froze the
setup, enter, leave and keepalive frames. It left pointer, button, wheel, keyboard and
clipboard frames unfrozen and kept M1-032, M1-033, M1-034 and M1-041 blocked.
[`M2-023`](M2-023-barrier-server-wire-contract.md) listed the same frames as
unsupported until a server-side capture was approved and a contract entry was accepted.

That capture is M2-022. It was reviewed independently on 2026-10-29 and registered as
`BARRIER-EVID-0006`, `0007` and `0008`
(`evidence/issues/M2-022/independent-review.md`). This ADR is the contract entry. It
freezes only what those entries establish, and it marks every first-party convention
that goes beyond them.

## Decision

### Common frame

Unchanged from M1-025 and M1-PROTOCOL-002:

- a 4-byte unsigned big-endian payload length;
- a 4-byte ASCII token;
- a token-specific body.

Every multi-byte field below is big-endian.

### Pointer: `DMMV` (server to client)

| Field | Width | Frozen rule |
| --- | ---: | --- |
| x | 2 bytes | unsigned; the absolute pointer x in the client's `DINF` coordinate space |
| y | 2 bytes | unsigned; the absolute pointer y in the same space |

Each observed value equals the previous client position plus the server's relative
move, starting from the `CINN` point. Only values below `0x8000` were observed. Values
at or above `0x8000` are outside this contract, and a decoder rejects such a frame
without moving the pointer. Evidence: `BARRIER-EVID-0006-CLAIM-001`.

### Buttons: `DMDN` and `DMUP` (server to client)

The body is 1 byte, a button number. The observed pairs were:

| Server X button | Wire value |
| --- | --- |
| 1 | 1 |
| 2 | 2 |
| 3 | 3 |
| 8 | 4 |
| 9 | 5 |

Each press is a `DMDN`/`DMUP` pair with equal values, and a held button can span pointer
moves. Values other than 1 to 5 are outside this contract: a decoder rejects a `DMDN`
with such a value. A `DMUP` with such a value still releases any matching pressed
button, so a release is never lost. Evidence: `BARRIER-EVID-0006-CLAIM-002`.

### Wheel: `DMWM` (server to client)

| Field | Width | Frozen rule |
| --- | ---: | --- |
| x delta | 2 bytes | signed |
| y delta | 2 bytes | signed |

One notch was observed per direction:

| Notch | Body |
| --- | --- |
| up | (0, +120) |
| down | (0, −120) |
| left | (−120, 0) |
| right | (+120, 0) |

Evidence: `BARRIER-EVID-0006-CLAIM-003`.

**First-party convention, not a capture claim.** The first-party Mac server sends
multiples of 120 for several notches, saturated to 16 bits. A first-party client
converts each axis by integer division by 120, toward zero, and drops the remainder.
The M2-035 smoke against a real `barrierc` validates the multiple-notch case: a scroll
of −2 produced two X button-5 events.

### Keys: `DKDN`, `DKUP` and `DKRP` (server to client)

| Token | Body | Fields |
| --- | ---: | --- |
| `DKDN`, `DKUP` | 6 bytes | key identifier u16, modifier mask u16, button u16 |
| `DKRP` | 8 bytes | key identifier u16, modifier mask u16, count u16, button u16 |

Rules:

- **The button field is an opaque pairing token** (the server's key code). A decoder
  pairs each up with its down by button. The key identifier of an up may differ from
  its down: 0x0041 down and 0x0061 up after Shift was released, and likewise
  0x0021/0x0031 and 0x005F/0x002D. Evidence: `BARRIER-EVID-0006-CLAIM-004`.
- **Repeats:** `DKRP` was observed only with count 1. A count other than 1 is outside
  this contract and is treated as one repeat.
- **Key identifiers:** the frozen set is exactly the values in
  `BARRIER-EVID-0006-CLAIM-005` (letters, digits, space, the US punctuation keys,
  Return, Escape, Tab, BackSpace, Delete, Insert, arrows, Home, End, Page Up and Down,
  keypad Enter, F1–F12, volume up, down and mute, left and right Shift, Control, Alt and
  Super, Caps Lock, and the shifted letter, exclamation and underscore values) and
  `BARRIER-EVID-0008-CLAIM-001` (the eleven punctuation keys, plain and shifted). Any
  other identifier is outside this contract: the decoder does not inject it, but it
  still records the button, so the matching up releases cleanly.
- **Shifted press:** a shifted press is four frames: `DKDN` Shift, `DKDN` with the
  shifted identifier and mask 0x0001, `DKUP` Shift, then `DKUP` with the plain
  identifier and mask 0. Evidence: `BARRIER-EVID-0008-CLAIM-001`.
- **Modifier mask:** the frozen bits are 0x0001 Shift, 0x0002 Control, 0x0004 Alt,
  0x0010 Super and 0x1000 Caps Lock. A modifier's own `DKDN` carries the mask before
  the modifier took effect, and its `DKUP` carries the mask including it. Both frames
  of a Caps Lock toggle-off carry 0x1000. Other bits are outside this contract: a
  decoder ignores them and still decodes the event. Evidence:
  `BARRIER-EVID-0006-CLAIM-006`.

Failing safe outweighs completeness (Frozen Decision 7): no unknown identifier, button,
mask bit or count may cause a decoder to drop a key or button release.

### Enter, leave and keepalive

| Frame | Rule |
| --- | --- |
| `CINN` | Layout as in M1-PROTOCOL-002. Observed sequences were 1, then 3 for the enter after one leave, with mask 0x0000 here. The increment rule is not frozen, so a client must not validate it; it keeps the latest value for `CCLP` and `DCLP` (`BARRIER-EVID-0006-CLAIM-007`). |
| `COUT` | no body |
| `CALV` | no body, both directions. A client answers each server `CALV` with a `CALV`. |
| `CNOP` | no body, client to server. The real client sent one per server frame after `DSOP`. The first-party server accepts but does not require it (`BARRIER-EVID-0006-CLAIM-009`). |

### Clipboard: `DCLP` (both directions) and `CCLP` (client to server)

**`DCLP` layout:**

| Field | Width | Frozen rule |
| --- | ---: | --- |
| id | 1 byte | 0 or 1 observed |
| sequence | 4 bytes | server transfers: 0; client transfers: the sequence of the `CINN` in force |
| mark | 1 byte | 1 start, 2 chunk, 3 end, sent in that order |
| data | 4-byte length, then that many bytes | start: decimal ASCII byte length of the chunk data; chunk: the marshalled clipboard; end: empty |

Evidence: `BARRIER-EVID-0006-CLAIM-008`, `BARRIER-EVID-0008-CLAIM-002`.

**Marshalled clipboard** (`BARRIER-EVID-0008-CLAIM-003`):

- a 4-byte format count;
- per format, a 4-byte format id, a 4-byte size and that many content bytes;
- no trailing bytes.

An empty clipboard is count 0. Format ids 0, 1 and 2 were observed. **No format's
meaning is frozen.**

**Interleaving:** a server `CALV` may arrive between the frames of one transfer, as
observed at enter. A decoder must accept it.

**`CCLP` (client to server):** a 5-byte body, an id byte and a 4-byte sequence equal to
the `CINN` in force, sent at once on a client copy (`BARRIER-EVID-0007-CLAIM-001`). A
server-to-client `CCLP` was never captured, so a first-party client fails closed on one.

**First-party conventions, not capture claims:**

- The first-party peers carry UTF-8 text as format 0 of clipboard id 0, and they
  ignore other formats and ids. This rests on two facts:
  - format 0's size equaled the UTF-8 length of the probe in both captured transfers;
  - the M2-035 smoke runs against a real `barrierc` moved text both ways that way.
- Transfers may span several chunks of at most 32 KiB, as the first-party server sends
  them. The chunk measurement (`evidence/e2e/M2-022/chunks.json`) and the M2-035 smoke
  (600 KB out, 100 KB in) validate this, but no fixture captures it.

### Observed but not frozen

- No server `DCLP` followed the second enter. The cause, clipboard ownership or an
  unchanged clipboard, is not discriminated (`BARRIER-EVID-0008-CLAIM-004`).
- Right-hand modifiers were observed only with the left one already down, which is an
  artifact of the input tool.

## Non-claims

This ADR does not freeze:

- Windows, a macOS Barrier server, TLS, or full compatibility;
- the meaning of any clipboard format id or of clipboard id 1;
- multi-chunk transfers or transfer size limits, as capture claims;
- keepalive interval, latency or timeout;
- pointer values at or above 0x8000, or negative coordinates;
- wheel magnitudes other than one notch, as capture claims;
- `DKRP` counts other than 1;
- key identifiers outside the listed set, or non-US layouts;
- modifier-mask bits other than the five listed;
- the `CINN` increment rule or mask bits;
- server-to-client `CCLP`;
- any token not listed here or in M1-PROTOCOL-002, which stays fail closed.

## Evidence

| Entry | Fixture | Covers |
| --- | --- | --- |
| `BARRIER-EVID-0006` | `Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json` | pointer, button, wheel, key, repeat, mask, enter and leave sequence, empty clipboards on enter, client `CNOP`/`CALV` |
| `BARRIER-EVID-0007` | `Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json` | client `CCLP`; the count and lengths of client `DCLP` |
| `BARRIER-EVID-0008` | `Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json` | punctuation identifiers, `DCLP` layout both ways, marshalled structure |

The capture: Linux `barriers` and `barrierc` 2.4.0-release, protocol 1.6, on throwaway
Xvfb displays of the owner-approved Ubuntu 22.04 host, through a byte-logging loopback
relay with TLS disabled for the observation. Input was synthetic. Details are in
`evidence/e2e/M2-022/`.

## Security and privacy

- The fixtures hold complete frames only. Every clipboard content is zero-filled, and no
  address, host or user name is retained (independent review, section 6).
- TLS stays on by default. Nothing here is a TLS claim.
- The fail-safe rule above makes every release path independent of unknown values.

## Compatibility impact

- First-party Mac server → Barrier 2.4 Linux client: validated by M2-035, including the
  first-party conventions.
- First-party Linux client → first-party Mac server: to be validated by
  M4-036-FOLLOWUP-001.
- Nothing about Barrier servers on other platforms is claimed.

## Rejected alternatives

### Name formats and ids from memory

Rejected: incident 001 (`evidence/issues/M2-022/incident-001-unobserved-labels.md`).
Names may come only from observation.

### Promote the first-party conventions to Barrier wire claims

Rejected: neither multi-notch wheel values nor multi-chunk transfers were captured.
They stay marked as conventions validated by interoperability runs.

## Open questions

| Question | Owner | Blocking condition |
| --- | --- | --- |
| Meaning of clipboard format ids and of id 1 | Protocol owner | Blocks any non-text clipboard support |
| A captured multi-chunk transfer (or registering `chunks.json`) | Protocol owner | Blocks a Barrier multi-chunk compatibility claim; does not block the first-party convention |
| Pointer values at or above 0x8000 and negative origins | Protocol owner | Blocks multi-monitor client layouts |
| Non-US key identifiers | M1-045 owner | Blocks any non-US layout claim |

## Rollback

Revert this ADR, the M2-023 status note, and the `frozenContractRefs` and
`consumingTests` links of `BARRIER-EVID-0006` to `0008`. The decoders return to
blocked; the first-party Mac server's encoders keep working, as they did before this
contract.
