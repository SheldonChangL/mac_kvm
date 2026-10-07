# M1-WIRE-002 Attempt 4 Manual Log

All entries use UTC.

## Pre-window

- `2026-10-07T00:41:22Z` — Checkpoint 1 approved section 13 for one fourth bounded attempt.
- `2026-10-07T00:42Z` — Baseline direction observed as macOS Barrier server to Linux Barrier
  client.
- `2026-10-07T00:42Z` — Linux package, capture capability and clipboard request tools checked.
- `2026-10-07T00:43Z` — A pre-capture clipboard probe using normal mouse movement and normal
  desktop clipboard APIs matched by SHA-256 outside the disposable evidence session.
- `2026-10-07T00:46Z` — Analyzer copied to `role-capture`; raw working directory remained on
  `role-capture`.

## Capture window

- `2026-10-07T00:47Z` — Existing owner Barrier server/client processes were stopped with
  graceful termination before the disposable evidence configuration started.
- `2026-10-07T00:47Z` — Disposable macOS Barrier server started with a loopback SSH
  destination.
- `2026-10-07T00:47Z` — macOS-initiated SSH remote forward established a Linux loopback-only
  listener.
- `2026-10-07T00:47Z` — Linux loopback tcpdump capture started before the Barrier client.
- `2026-10-07T00:47Z` — Disposable Linux Barrier client started and connected through the
  remote-forward listener.
- `2026-10-07T00:47Z` — Synthetic `200000`-byte clipboard value was placed on the macOS
  clipboard, then normal mouse movement was used to move Barrier focus toward the Linux client.
- `2026-10-07T00:47Z` — Linux clipboard read-back returned `0` bytes, so the trigger hash did
  not match.
- `2026-10-07T00:48Z` — Disposable Linux Barrier client, macOS Barrier server, SSH forward and
  tcpdump were terminated gracefully enough to produce FIN-complete streams for analysis.

## Analysis and restoration

- `2026-10-07T00:48Z` — Analyzer ran on `role-capture`; it wrote sanitized output and returned
  nonzero because the result was non-discriminating.
- `2026-10-07T00:48Z` — Sanitized output was copied into the repository; raw capture stayed on
  `role-capture`.
- `2026-10-07T00:48Z` — Owner macOS Barrier server and Linux Barrier client were restored.
- `2026-10-07T00:49Z` — A duplicate restored Linux Barrier client process was removed; the
  remaining Linux Barrier client showed an established connection to the restored owner server.

## Result

- Analyzer result: `STOP-BOTH-SUCCEED`.
- Width-4 and width-2 both succeeded on every complete stream.
- No fixture, register entry, width ADR or `M1-025` unblock is produced.
