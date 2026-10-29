# M1-PROTOCOL-003 Barrier Input and Clipboard Message Contracts

## Status

Proposed on 2026-10-29. Acceptance requires review by a protocol reviewer who is not the
implementing agent, and the Product Owner's merge.

Once accepted, these contracts may be consumed by:

- the Barrier client decoders M1-032, M1-033, M1-034 and M1-041;
- the key mapper M1-043;
- the client session M1-029-FOLLOWUP-001 ([`M4-SCOPE-001`](M4-SCOPE-001-linux-client-first.md)).

The first-party Mac server's existing encoders, which were implemented from the same
evidence before review, also become formally backed by these contracts. Revised on
2026-10-29 after an independent protocol review; see "Review record".

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
| x | 2 bytes | big-endian; signedness not frozen; accepted only in `0x0000…0x7FFF` |
| y | 2 bytes | big-endian; signedness not frozen; accepted only in `0x0000…0x7FFF` |

The values are absolute pointer positions in client pixels. Each observed value equals
the previous position plus the server's relative move, starting from the `CINN` point
(`BARRIER-EVID-0006-CLAIM-001`). A value outside `0x0000…0x7FFF`, or outside the client's
own `DINF` rectangle, is dropped (see "Rejection semantics"). It is not clamped, because
clamping was never observed. The `DINF` origin was (0, 0) in every capture, so how
`DMMV` relates to a non-zero origin is an open question.

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
moves: in the capture, `DMDN` 1, a `DMMV`, then `DMUP` 1. Values other than 1 to 5 are
outside this contract, and such a `DMDN` is dropped. A `DMUP` with such a value is
dropped too: its `DMDN` was dropped, so nothing is held. Evidence:
`BARRIER-EVID-0006-CLAIM-002`.

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

Frozen from evidence:

- **The button field is an opaque pairing token** (the server's key code). A decoder
  pairs each up with its down by button. The key identifier of an up may differ from
  its down: 0x0041 down and 0x0061 up after Shift was released, and likewise
  0x0021/0x0031 and 0x005F/0x002D. Evidence: `BARRIER-EVID-0006-CLAIM-004`.
- **Key identifiers:** the frozen set is exactly the values in
  `BARRIER-EVID-0006-CLAIM-005` (letters, digits, space, the US punctuation keys,
  Return, Escape, Tab, BackSpace, Delete, Insert, arrows, Home, End, Page Up and Down,
  keypad Enter, F1–F12, volume up, down and mute, left and right Shift, Control, Alt and
  Super, Caps Lock, and the shifted letter, exclamation and underscore values) and
  `BARRIER-EVID-0008-CLAIM-001` (the eleven punctuation keys, plain and shifted). The
  driver's key order fixes which identifier belongs to which key, and the contract
  test pins that order.
- **Modifier mask:** 0x0001 Shift, 0x0002 Control, 0x0004 Alt, 0x0010 Super and 0x1000
  Caps Lock; Control with Shift gave 0x0003. A modifier's own `DKDN` carries the mask
  before the modifier took effect, and its `DKUP` carries the mask including it. A Caps
  Lock toggle-on was `DKDN` 0x0000 then `DKUP` 0x1000; a toggle-off carried 0x1000 on both
  frames. Evidence: `BARRIER-EVID-0006-CLAIM-006`.
- **Observed shifted-press sequence (driver order):** `DKDN` Shift, `DKDN` with the
  shifted identifier and mask 0x0001, `DKUP` Shift, then `DKUP` with the plain
  identifier and mask 0 (`BARRIER-EVID-0008-CLAIM-001`). This is the input tool's order.
  A decoder must not depend on it; it pairs by button only.

**Decoder policy (first-party, not a capture claim).** These cover fields the register
marks unknown and infer no meaning from them:

- `DKRP` was observed only with count 1. Another count is treated as one repeat.
- An identifier outside the frozen set and the convention below is not injected, but
  its button is recorded, so the matching up releases cleanly.
- Mask bits other than the five are ignored, and the event still decodes.
- A decoder does not derive lock state from the mask and does not synthesize modifier
  presses from it. The modifiers' own `DKDN`/`DKUP` frames carry that. The first-party
  server's Caps Lock toggle (`DKDN` without the bit, `DKUP` with it) differs from the
  captured toggle-off, which this rule makes harmless.

Failing safe outweighs completeness (Frozen Decision 7): no unknown identifier, button,
mask bit or count may cause a decoder to drop a key or button release.

**First-party convention, not a capture claim: shifted identifiers.** The first-party
server sends the produced character for a shifted key. That includes 34 identifiers
that were never captured:

- 0x0042–0x005A: B–Z with Shift or Caps Lock. 0x0041 is captured.
- The US shifted digits 0x0029 `)`, 0x0040 `@`, 0x0023 `#`, 0x0024 `$`, 0x0025 `%`,
  0x005E `^`, 0x0026 `&`, 0x002A `*` and 0x0028 `(` for 0 and 2–9. 0x0021 `!` for 1 is
  captured.

A first-party client injects them like their captured counterparts. Only Shift+B was
validated against a real `barrierc`, in the M2-035 smoke. A test enumerates every
identifier the first-party encoder can emit and requires it to be in the frozen set or
in this list.

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
| data | 4-byte length, then that many bytes | start: decimal ASCII total byte length of the transfer's mark-2 data (one chunk was observed, so it equaled that chunk's length); chunk: the marshalled clipboard, or the next part of it; end: empty |

Evidence: `BARRIER-EVID-0006-CLAIM-008`, `BARRIER-EVID-0008-CLAIM-002`.

**Marshalled clipboard** (`BARRIER-EVID-0008-CLAIM-003`):

- a 4-byte format count;
- per format, a 4-byte format id, a 4-byte size and that many content bytes;
- no trailing bytes.

An empty clipboard is count 0. Format ids 0, 1 and 2 were observed. **No format's
meaning is frozen.**

**Interleaving:** a server `CALV` arrived between the frames of each transfer at enter.
A decoder keeps transfer state per clipboard id and processes frames of other tokens
normally in between.

**`CCLP` (client to server):** a 5-byte body, an id byte and a 4-byte sequence equal to
the `CINN` in force. It was sent after the copy and before the next `COUT`
(`BARRIER-EVID-0007-CLAIM-001`). A server-to-client `CCLP` was never captured in a
retained fixture. The chunk log recorded one before an enter (code and length only, a
5-byte body), so its body is unobserved. A first-party client fails closed on one; the
first-party server never sends it.

**First-party conventions, not capture claims:**

- The first-party peers carry UTF-8 text as format 0 of clipboard id 0, and they
  ignore other formats and ids. This rests on two facts:
  - format 0's size equaled the UTF-8 length of the probe in both captured transfers;
  - the M2-035 smoke runs against a real `barrierc` moved text both ways that way.
- Transfers may span several chunks of at most 32 KiB, as the first-party server sends
  them. The chunks add up to exactly the start value: a chunk never exceeds the
  remaining size, and the end completes the transfer exactly. The chunk measurement
  (`evidence/e2e/M2-022/chunks.json`) and the M2-035 smoke (600 KB out, 100 KB in)
  validate this, but no fixture captures it.
- A first-party client accepts transfers of at least 1 MiB of text, which is the
  first-party server's limit.

### Rejection semantics

**Drop and continue.** These cases are dropped, a diagnostic is emitted and the session
continues:

- `DMMV` outside `0x0000…0x7FFF` or outside the client's `DINF` rectangle;
- `DMDN` or `DMUP` outside 1–5;
- a `DCLP` transfer that breaks the start, chunk and end rules, including a `DCLP` whose
  inner data length does not match the rest of its body.

The diagnostic carries the token, the direction, the body length and the reason, never
body bytes (M1-011).

**Fail closed.** These cases end the session with a typed protocol-violation error:

- a known token whose body length does not match its layout, for example a 5-byte
  `DMMV`;
- a server-to-client `CCLP`;
- any token not listed here or in M1-PROTOCOL-002.

On that terminal path the client's cleanup (M1-063-FOLLOWUP-001) releases every pressed
key and button before the session closes.

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
  wheel, clipboard and text conventions. Of the shifted identifiers, only Shift+B was
  validated.
- First-party Linux client → first-party Mac server: to be validated by
  M4-036-FOLLOWUP-001.
- Nothing about Barrier servers on other platforms is claimed.

## Rejected alternatives

### Name formats and ids from memory

Rejected: incident 001 (`evidence/issues/M2-022/incident-001-unobserved-labels.md`).
Names may come only from observation.

### Promote the first-party conventions to Barrier wire claims

Rejected: none of multi-notch wheel values, multi-chunk transfers or the 34 uncaptured
shifted identifiers was captured.
They stay marked as conventions validated by interoperability runs.

## Open questions

| Question | Owner | Blocking condition |
| --- | --- | --- |
| Meaning of clipboard format ids and of id 1 | Protocol owner | Blocks any non-text clipboard support |
| A captured multi-chunk transfer (or registering `chunks.json`) | Protocol owner | Blocks a Barrier multi-chunk compatibility claim; does not block the first-party convention |
| Pointer values at or above 0x8000, negative origins, and `DMMV` relative to a non-zero `DINF` origin | Protocol owner | Blocks multi-monitor client layouts |
| Non-US key identifiers | M1-045 owner | Blocks any non-US layout claim |

## Review record

An independent protocol reviewer, not the implementing agent, reviewed the first draft
on 2026-10-29. The verdict was accept with conditions. This revision addresses the
findings:

| Finding | Severity | Resolution |
| --- | --- | --- |
| H1 | High | The first-party server's 34 shifted identifiers are declared as a convention and pinned by a test. |
| M1 | Medium | "Rejection semantics" defines dropping versus failing closed. |
| M2 | Medium | `DMMV` signedness is no longer frozen, and the rectangle rule is stated. |
| M3 | Medium | The start value is the transfer total, and the multi-chunk rules are stated. |
| M4 | Medium | The contract test pins the modifier bits, the key order, Caps Lock, `CINN` and the held button. |
| L1–L6 | Low | Wording and labelling, and the register narrative section for 0006–0008. |

The same reviewer re-reviewed the revision on 2026-10-29. The verdict was accept. Its
five wording nits (the `DCLP` inner-length case, the M2-035 wording, the rejected
alternative, a test name and the register narrative) were fixed afterwards. Both
reports are in `evidence/issues/M1-PROTOCOL-003/independent-review.md`.

## Rollback

Revert this ADR, the M2-023 status note, and the `frozenContractRefs` and
`consumingTests` links of `BARRIER-EVID-0006` to `0008`. The decoders return to
blocked; the first-party Mac server's encoders keep working, as they did before this
contract.
