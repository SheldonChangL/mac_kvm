# M2-022 Addendum: Punctuation Keys and Clipboard Transfer

## Capture

- Tool: `tools/capture_punctuation_clipboard.py`, run on the owner-approved Ubuntu
  22.04 host on 2026-10-29.
- Topology: same as the main M2-022 capture. `barriers` and `barrierc` 2.4.0-release
  (protocol 1.6) run on separate Xvfb displays and talk through a byte-logging loopback
  relay with TLS disabled.
- Input was synthetic (xdotool on the server display). Clipboard text was set with xclip
  to the fixed probe strings in the tool.
- The tool's own checks passed:
  - after the enter, the client clipboard matched the server probe;
  - after the leave, the server clipboard matched the client probe.
- Raw stream: 181 frames, SHA-256 prefix `07c968ef836652e7`. Not committed.
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
| id | u8 | 0 = clipboard, 1 = primary selection |
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

Format 0 is UTF-8 text, 1 is HTML and 2 is bitmap. All integers are big-endian.

### Server to client, on enter

The server sent both clipboard ids right after `CINN`. Each id was sent as start, chunk
and end, always with sequence 0.

| Id | Start size | Formats |
|---|---|---|
| 0 | 118 | text (36 bytes, the probe), HTML (54), bitmap (0) |
| 1 | 4 | none (empty primary selection) |

### Client to server, around a leave

- **On the client copy:** `CCLP` with id 0 and sequence 1, the sequence of the current enter.
- **On the leave:** start, chunk and end for id 0, all with sequence 1, total size 119.
  The formats were text (37 bytes, the probe), HTML (54) and bitmap (0).
- **On the second enter:** the server did not send the clipboard back to the client that
  owned it.
