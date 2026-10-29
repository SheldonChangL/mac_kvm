# M2-035 Owner-operated Run (Mac server → Linux Barrier client)

## Scope

The Product Owner drove the real Mac keyboard and pointer against the real Linux
desktop on 2026-10-28 and 2026-10-29, with the agent running and instrumenting
the server. The client was `barrierc` 2.4.0-release on the owner's X11 display,
started with a temporary profile that trusted the server fingerprint over TLS;
the owner's own Barrier client configuration was left untouched. The server was
a DEBUG build of this branch; timing statistics and a chord probe were added
temporarily for diagnosis and removed in `aaaa54f`.

## Environment

| Item | Value |
|---|---|
| Server | macOS 26.6.2 (25G83), arm64, Apple keyboard, Wi-Fi 802.11ac |
| Client | Ubuntu 22.04.5, X11, 1920x1080, `barrierc` 2.4.0-release, Wi-Fi |
| Channel | TLS 1.3, server pinned by SHA-256 fingerprint |

## Cases

| Plan case | Result | Notes |
|---|---|---|
| C1 handshake | pass | `client ready (1920x1080)` after the client matched the pinned fingerprint |
| C3 enter/leave | pass | 17 enters and 17 returns across the right edge in the first session |
| C4 mouse | pass | buttons and wheel; smoothness see below |
| C5 keyboard | pass | letters, digits, Shift, Return, Backspace, arrows, F1–F12; punctuation is unsupported by design (M1-042) |
| C6 escape | pass after a fix | see "Escape chord" |
| C8 network loss | pass (unplanned) | the Mac's Wi-Fi address changed mid-run; the session ended on the 9 s keepalive timeout and input stayed local; the client then reconnected by the Mac's mDNS name |
| C10 termination | pass | each stop logged `local recovery: completed` and `stopped; input is local` |
| C7 held input, C9 sleep | not run by hand | C7 is covered by the automated smoke |

## Findings and fixes

### Escape chord

With Control, Option and Command held, macOS never delivered the Delete key
down to the event tap: a session-level tap saw neither phase in five attempts,
while Return and letters with the same modifiers arrived. At the HID level only
the Delete release arrives. Fix `d4f47ae` accepts Return as a second chord key
(announced gesture), and because every phase of the chord key escapes, the
Delete chord also works at the HID level. The owner confirmed both.

### Cursor

| Approach | Observation |
|---|---|
| Session tap, cursor warped back after every motion | tap saw gaps of about 250 ms between motion events, the length of the system's hold after a warp; the owner saw stalls and jumps |
| Session tap, warp only after 40 points of drift | the owner saw the Mac cursor move with the remote one |
| HID tap, no warp | the logical cursor stayed put (measured drift 0), but the cursor image still followed the hand |
| HID tap, no warp, cursor hidden | owner: the cursor disappears while remote and reappears on return |

Fix `aaaa54f` keeps the last row. Hiding while another app is frontmost needs
the `SetsCursorInBackground` connection property, private CoreGraphics SPI that
macOS KVM servers rely on; it is resolved at run time and the cursor stays
visible where it is missing.

### Smoothness

The remaining stalls were the Wi-Fi path between the two machines, not the
server. A plain TCP stream (no TLS, no Barrier, `TCP_NODELAY`) from the Mac to
the Linux machine every 8 ms showed the same pattern as the Barrier session.
With macOS AWDL turned off on the Mac and Wi-Fi power saving turned off on the
Linux machine (both temporary, by the owner):

| Measurement | Before | After |
|---|---|---|
| Plain TCP, 8 ms stream | 6 gaps of 30 ms or more in 3 s, max 136 ms | 0 gaps in 2 × 4 s, max 17.7 / 18.6 ms |
| Barrier session, 8 ms steady motion | 15 gaps of 90–164 ms in about 8 s | 0 gaps, max 18–20 ms |
| Linux ping to the Mac (5 Hz) | avg 20 ms, max 209 ms | avg 5.4 ms, max 39.8 ms |

`TCP_NODELAY` on accepted connections was checked separately and is in effect.
Processes started from the agent's background session ran at nice 5; the final
owner runs used the owner's Terminal at normal priority.

## Sanitization

No addresses, host names, screen names of the owner's machines, typed text or
key material are recorded; the timing statistics carry counts and durations
only.
