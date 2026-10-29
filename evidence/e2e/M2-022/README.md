# M2-022 Barrier Server-side Fixtures — Evidence

**Status: captured, sanitized and independently reviewed on 2026-10-29**
(`evidence/issues/M2-022/independent-review.md`; register entries BARRIER-EVID-0006 to
0008). Earlier status, kept for the record: **captured and sanitized; independent review
pending.** Two controlled
black-box sessions ran on 2026-10-28 between 06:26:52Z and 06:30:02Z on the
owner-approved Ubuntu 22.04 x86_64 test host, per
`Tests/SystemTests/Plans/M2-022-barrier-server-fixtures.md`. The executing
agent (Claude Opus) ran them and decoded the frames; a non-executing reviewer
must still verify this evidence before M2-023 can be accepted.

`result.json` records `sanitizationReviewed: false` and the artifacts as
`pending-review`, so `Tools/Evidence/validate_evidence.py` rejects it with
`privacy_violation` by design. The reviewer who verifies the sanitization sets
those values; the executing agent does not mark its own sanitization reviewed.

## What was observed

- Peers: `barriers` and `barrierc` 2.4.0-release, protocol 1.6, each on its own
  virtual X display, through a byte-logging loopback relay; TLS disabled for the
  observation only.
- The server is the Linux Barrier server, the only server platform observed;
  whether frame layouts depend on the server platform is not established. The key
  `button` field carries that server's X keycodes. No macOS-server capture and no
  Windows run (M2 is Linux-only by owner decision).
- Input was synthetic: xdotool on the server display, and a fixed probe string
  copied with xclip on the client display. No user content.

| Session | Frames | Both directions | Leftover bytes |
| --- | --- | --- | --- |
| Server input | 579 | yes | 0 |
| Client clipboard and keepalive | 36 | yes | 0 |

## Decoded frames (all multi-byte integers big-endian)

Every frame is a 4-byte length prefix followed by a 4-byte ASCII code and its
fields. Each layout below held for every observed frame of that code.

| Code | Direction | Fields after the code | Observed meaning |
| --- | --- | --- | --- |
| `CINN` | server→client | x u16, y u16, sequence u32, mask u16 | enter at a client point; sequence 1 for the first enter, 3 for the next; sequence 2 was never on the wire, so the increment rule is not established |
| `COUT` | server→client | none | leave |
| `CALV` | both | none | keepalive; server every 3.0 s (12 intervals 3.002–3.036 s); client answers within about 1 ms (timing from raw streams, see below) |
| `CNOP` | client→server | none | one per server frame after the handshake (279 for 279), each within 3.2 ms |
| `DMMV` | server→client | x u16, y u16 | absolute pointer position in client pixels; each value equals the previous position plus the relative move, and no clamping was observed |
| `DMDN` / `DMUP` | server→client | button u8 | 1 left, 2 middle, 3 right, 4 and 5 for X buttons 8 and 9 |
| `DMWM` | server→client | xDelta s16, yDelta s16 | ±120 per notch: up (0, +120), down (0, −120), left (−120, 0), right (+120, 0) |
| `DKDN` / `DKUP` | server→client | key u16, mask u16, button u16 | key down / up |
| `DKRP` | server→client | key u16, mask u16, count u16, button u16 | auto-repeat while held, count 1 each |
| `DCLP` | both | id u8, sequence u32, mark u8, then a length-prefixed chunk | clipboard transfer in start/chunk/end parts; the server sent two empty clipboards on enter. The client-to-server layout rests on the punctuation fixture only: this session's fixture zero-fills the whole client `DCLP` body after the code |
| `CCLP` | client→server | id u8, sequence u32 | client took clipboard ownership (sent at once on copy) |

Key identifiers observed for the sweep (`button` omitted):

- Printable keys carry the produced character's code: `a`–`z` 0x0061–0x007A,
  `0`–`9` 0x0030–0x0039, space 0x0020, `-` 0x002D, `=` 0x003D, `[` 0x005B,
  `]` 0x005D, `\` 0x005C, `;` 0x003B, `'` 0x0027, `` ` `` 0x0060, `,` 0x002C,
  `.` 0x002E, `/` 0x002F. With Shift the shifted character is sent (`A`
  0x0041, `!` 0x0021, `_` 0x005F); with Caps Lock on, `a` is sent as 0x0041.
- Editing and navigation: Return 0xEF0D, Escape 0xEF1B, Tab 0xEF09, BackSpace
  0xEF08, Delete 0xEFFF, Insert 0xEF63, Left 0xEF51, Up 0xEF52, Right 0xEF53,
  Down 0xEF54, Home 0xEF50, End 0xEF57, Page Up 0xEF55, Page Down 0xEF56, keypad
  Enter 0xEF8D; F1–F12 0xEFBE–0xEFC9.
- Modifiers (left, right): Shift 0xEFE1, 0xEFE2; Control 0xEFE3, 0xEFE4; Alt
  0xEFE9, 0xEFEA; Super 0xEFEB, 0xEFEC; Caps Lock 0xEFE5.
- Media: volume up 0xE0AF, volume down 0xE0AE, mute 0xE0AD.
- Mask bits: Shift 0x0001, Control 0x0002, Alt 0x0004, Super 0x0010, Caps Lock
  0x1000. A modifier's own down carries the mask before it; its up carries the
  mask including it. Key-up frames may carry a different key identifier than
  the matching key-down (for example lowercase after Shift was released); the
  `button` value is identical for each down/up pair.

## Keepalive and client behavior

- With the server paused, the client reported "server is dead" and closed
  9.02 s after the last server `CALV` (8.63 s after the last server frame).
- Timing values in this README (the keepalive interval, reply delays and this close)
  come from the producer's raw streams, which are not committed. The independent
  reviewer re-measured them from those streams before deletion
  (`evidence/issues/M2-022/independent-review.md`, F7); the fixtures carry no time.
- Copying on the client display produced `CCLP` at once; leaving the client
  screen produced three client `DCLP` frames carrying the clipboard.

## Artifacts

- `Tests/Fixtures/Barrier/m2-022-linux-server-input/` (`metadata.json`,
  `server-input-capture.json`)
- `Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/`
  (`metadata.json`, `client-clipboard-keepalive-capture.json`)
- `Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/` (`metadata.json`,
  `punctuation-clipboard-capture.json`) and `chunks.json`, from the 2026-10-29 addendum
  (`punctuation-clipboard.md`)
- `tools/` — the two capture drivers, the decoder and the fixture builder;
  `Tests/SystemTests/Scripts/M2-022-barrier-server-fixtures.sh` replays both
  sessions and rebuilds the fixtures.
- Raw streams are not committed. Their SHA-256 values were
  `6db39890e3000c6b7b445ad23a7c756691f5d9e1a538017d94ac469591e2781e` (server
  input) and `acb55a3b4145b60b43c776e22556fd0b9e07887e2a1959c07a0386a7744dc372`
  (client clipboard and keepalive).

## Host state

The capture used throwaway displays, a dedicated port and a temporary
directory; the operator's existing Barrier client kept running throughout. No
capture process or display remained afterwards, and both temporary directories
were removed.
