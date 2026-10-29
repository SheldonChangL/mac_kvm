# M2-022 Addendum: Punctuation Keys and Clipboard Transfer

## Capture

- Tool: `tools/capture_punctuation_clipboard.py` (committed in `6578b49`; the copy that
  ran is byte-identical), run on the owner-approved Ubuntu 22.04.5 x86_64 host from
  2026-10-29T00:38:05Z to 00:38:17Z (the run's `barriers` log, +0800 converted to UTC).
- Peer tools (Ubuntu packages, installed before the capture): barrier 2.4.0+dfsg-2,
  xvfb 2:21.1.4-2ubuntu1.7~22.04.16, xdotool 1:3.20160805.1-4, xclip 0.13-2; kernel
  6.8.0-138-generic; Python 3.10.16.
- Topology: same as the main M2-022 capture. `barriers` and `barrierc` 2.4.0-release
  (protocol 1.6) run on separate Xvfb displays and talk through a byte-logging loopback
  relay with TLS disabled.
- Input was synthetic (xdotool on the server display). Clipboard text was set with xclip
  to the fixed probe strings in the tool.
- The tool's own checks passed:
  - after the enter, the client clipboard matched the server probe;
  - after the leave, the server clipboard matched the client probe.
- Raw stream: 181 frames, SHA-256
  `07c968ef836652e711edda57f3d19929072877ea668cffa1b39b5123041f2d65`. Not committed.
- Independent review on 2026-10-29: `evidence/issues/M2-022/independent-review.md`;
  register entry BARRIER-EVID-0008.
- Fixture: `Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/` (181 observations,
  23530 bytes). Built by `tools/make_punctuation_clipboard_fixture.py`, which zero-fills
  every clipboard format's content and keeps the clipboard structure.

## Punctuation (server to client)

The key id is the produced character. The mask carries Shift as `0x0001`. The button is
the physical key position, the same with and without Shift.

| Key | Plain id | Shifted id | Button |
|---|---|---|---|
| minus | `0x002D` `-` | `0x005F` `_` | 20 |
| equal | `0x003D` `=` | `0x002B` `+` | 21 |
| bracketleft | `0x005B` `[` | `0x007B` `{` | 34 |
| bracketright | `0x005D` `]` | `0x007D` `}` | 35 |
| backslash | `0x005C` `\` | `0x007C` `\|` | 51 |
| semicolon | `0x003B` `;` | `0x003A` `:` | 47 |
| apostrophe | `0x0027` `'` | `0x0022` `"` | 48 |
| grave | `0x0060` `` ` `` | `0x007E` `~` | 49 |
| comma | `0x002C` `,` | `0x003C` `<` | 59 |
| period | `0x002E` `.` | `0x003E` `>` | 60 |
| slash | `0x002F` `/` | `0x003F` `?` | 61 |

A shifted press is sent as these four frames:

1. `DKDN` Shift (`0xEFE1`, mask 0, button 50)
2. `DKDN` shifted id (mask `0x0001`)
3. `DKUP` Shift (mask `0x0001`)
4. `DKUP` plain id (mask 0)

The release of the punctuation key comes after Shift is up, so its id is recomputed from
the modifier state at that moment. This is the same rule as letters in the main capture.

## Clipboard

### `DCLP` frame

`DCLP` is followed by these fields:

| Field | Type | Meaning |
|---|---|---|
| id | u8 | 0 or 1. The probes moved through id 0; id 1 was always empty, and its meaning is not observed |
| sequence | u32 | |
| mark | u8 | 1 = start, 2 = chunk, 3 = end |
| data | string | u32 length, then the bytes |

What the data string holds depends on the mark:

| Mark | Data |
|---|---|
| start | The total size as a decimal ASCII string, for example `118` |
| chunk | Marshalled clipboard bytes |
| end | Empty |

The marshalled clipboard is:

- a u32 format count;
- for each format, a u32 format id, a u32 size, then the content.

Format 0's size equaled the UTF-8 byte length of the probe in both directions, and the
clipboard checks above (and the M2-035 smoke runs against a real `barrierc`) show text
placed in format 0 arriving as the peer's clipboard text; it is used as UTF-8 text. The
meaning of formats 1 and 2 is not observed: format 1 was 54 bytes for both probes
although they differ in length, and format 2 was always empty. All integers are
big-endian.

### Server to client, on enter

The server sent both clipboard ids right after `CINN`. Each id was sent as start, chunk
and end, always with sequence 0.

| Id | Start size | Formats |
|---|---|---|
| 0 | 118 | format 0: 36 bytes (the probe's UTF-8 length), format 1: 54 bytes, format 2: 0 bytes |
| 1 | 4 | no formats (empty) |

### Client to server, around a leave

- **On the client copy:** `CCLP` with id 0 and sequence 1, the sequence of the current enter.
- **On the leave:** start, chunk and end for id 0, all with sequence 1, total size 119.
  Format 0 was 37 bytes (the probe's UTF-8 length), format 1 54 bytes, format 2 0 bytes.
- **On the second enter:** the server sent no `DCLP`. The server-input session, with no
  client copy and an unchanged server clipboard, shows none either, so whether this is
  about clipboard ownership or an unchanged clipboard is not discriminated.

### Further observations a client must handle

- A server `CALV` was interleaved inside each `DCLP` start/chunk/end sequence sent at
  enter (observation 10 and 14 in all three fixtures).
- Caps Lock toggle-off carried mask `0x1000` on both its down and up, so a lock key's
  release does not reveal the resulting lock state (server-input observations 523 and 525).
- A server-to-client `CCLP` was seen once during the chunk measurement but is in no
  fixture; its layout is not observed.
- Right-hand modifiers were only ever observed with the left one already down
  (an xdotool artifact).

### Withdrawn labels

An earlier version of this addendum called format 1 "HTML", format 2 "bitmap" and
clipboard id 1 "primary selection", and the decode tool called the fifth `DINF` field
"warp". No observation produces these names; they came from the producing agent's
background knowledge, not from evidence. They are withdrawn here and in the code
comments and documents that repeated them; see
`evidence/issues/M2-022/incident-001-unobserved-labels.md`.

### Chunk sizes (measured 2026-10-29)

`tools/measure_clipboard_chunks.py` (committed in `2b8f14e`) ran the same topology on the
same host; the last `barriers` log line was at 2026-10-29T01:31:05Z. Synthetic ASCII text
of several sizes was copied with xclip, first on the client while it was not the active
screen, then on the server before an enter. The relay parsed the frames and kept only
codes, DCLP ids, marks and lengths; no payload byte was stored. The output is retained as
`chunks.json` (SHA-256 `4144d20e3d59f10a81fde0cd7e8129946eedbd86dd0312cc4c40715da9e6406c`).

| Direction | Text | Transfer | Chunks | Largest chunk | Peer clipboard |
|---|---|---|---|---|---|
| client → server | 100,000 B | 250,028 B | 8 | 32,768 B | matched |
| server → client | 600,000 B | 1,500,028 B | 46 | 32,768 B | matched |

- Both peers split a transfer into chunks of at most 32 KiB, so the largest `DCLP` frame
  payload was 32,782 bytes. The transfer was about 2.5 times the text: the other formats
  carried the rest, and what they hold is not observed.
- A client copy sent while the client is not the active screen is transferred at once.
- Larger copies did not transfer, for reasons inside Barrier or xclip: the client never
  announced copies of 600,000 and 3,000,000 bytes, and the server's 3,000,000-byte copy
  failed with `ICCCM violation by clipboard owner` in the `barriers` log.
