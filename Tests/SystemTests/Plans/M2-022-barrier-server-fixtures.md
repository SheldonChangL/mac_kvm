# M2-022 Barrier Server-side Fixture Capture Plan

## Purpose

Record, as black-box evidence, the bytes a real Barrier server sends to a real
Barrier client while it forwards pointer, button, wheel, key, enter, leave and
keepalive traffic, so the M2 Mac server encoders (M2-026, M2-027) and the
proposed M2-023 contract are derived from observed frames, never from guessed
bytes or upstream source code.

## Authorization and scope

- The Product Owner approved operating the Ubuntu test host for capture on
  2026-10-28 (stop or restart Barrier processes, capture on loopback, use
  xdotool), and decided that M2 validation is Linux-only.
- Peers: Barrier server `barriers` and client `barrierc`, both 2.4.0-release,
  protocol 1.6, on Ubuntu 22.04 x86_64. The server is the Linux Barrier server:
  the frame layout is server-platform independent, but key `button` values are
  that server's X keycodes. A macOS Barrier server capture is not part of this
  run. Windows is not executed.

## Topology

All on the test host's loopback, on throwaway virtual displays, so the
operator's desktop and any running Barrier client are untouched:

```text
barriers (Xvfb :91, 1920x1080, 127.0.0.1:24910)
   <- byte-logging relay 127.0.0.1:24911 <- barrierc (Xvfb :92, 1600x900)
```

TLS is disabled on both peers for these observations only, so the plaintext
protocol can be recorded. The product's TLS default is unchanged.

## Sessions

1. **Server input** (`capture_server_input.py`): handshake; enter; pointer
   moves; buttons 1, 3, 2, 8, 9; a drag; wheel up, down, left and right; a key
   sweep (letters, digits, editing and navigation keys, F1–F12, punctuation,
   keypad Enter, volume keys); modifier combinations; every modifier on both
   sides and Caps Lock; a held key for auto-repeat; leave; a second enter and
   leave; ten seconds idle for keepalive.
2. **Client clipboard and keepalive** (`capture_client_clipboard_keepalive.py`):
   handshake; enter; a synthetic clipboard change on the client display; leave;
   then the server process is paused (SIGSTOP) for fifteen seconds to observe
   when the client gives up on keepalive.

Input is synthetic only (xdotool on the server display; xclip with a fixed
probe string on the client display). No user content is involved.

## Sanitization

- Only complete frames in capture order are kept; timestamps, ports and
  addresses never enter a fixture.
- Client-to-server DCLP data is zero-filled at its original length.
- Screen names are synthetic (`capserver`, `capclient`).

## Replay

```sh
Tests/SystemTests/Scripts/M2-022-barrier-server-fixtures.sh <ssh-host-alias> <work-dir>
```

The script copies the capture drivers to a fresh temporary directory on the
host, runs both sessions, fetches the streams, rebuilds both fixtures with
`make_fixtures.py`, and removes the remote directory. It needs Xvfb, xdotool,
xclip, python3, barriers and barrierc on the host and no root access.

## Outputs

- `Tests/Fixtures/Barrier/m2-022-linux-server-input/`
- `Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/`
- `evidence/e2e/M2-022/README.md` and `result.json`
