# M1-WIRE-002 Attempt 6 Manual Log

All entries use UTC.

## Pre-window

- `2026-10-07T04:45:04Z` — Checkpoint 1 approved section 15 for one sixth bounded attempt.
- `2026-10-07T04:46Z` — Analyzer copied to `role-capture`.
- `2026-10-07T04:46Z` — Deterministic synthetic Barrier config generated with `3000`
  synthetic screens, byte length `849708`, SHA-256
  `a6fd0eb521adc7d188e6a76218edc3ff649868fef9d371e77abc31051ebd1746`.

## Capture window

- `2026-10-07T04:46Z` — Existing owner Barrier server/client processes were stopped with
  graceful termination before the disposable evidence configuration started.
- `2026-10-07T04:46Z` — Disposable macOS Barrier server started with the synthetic config.
- `2026-10-07T04:46Z` — macOS-initiated SSH remote forward established a Linux loopback-only
  listener.
- `2026-10-07T04:46Z` — Linux loopback tcpdump capture started before the Barrier client.
- `2026-10-07T04:46Z` — Disposable Linux Barrier client started and connected through the
  remote-forward listener.
- `2026-10-07T04:47Z` — Disposable Linux Barrier client was stopped gracefully, followed by the
  server, forward and tcpdump.

## Analysis and restoration

- `2026-10-07T04:47Z` — Analyzer ran on `role-capture`; sanitized output was copied into the
  repository, raw capture stayed on `role-capture`.
- `2026-10-07T04:47Z` — Owner macOS Barrier server and Linux Barrier client were restored.
- `2026-10-07T04:48Z` — A duplicate restored Linux Barrier client process was removed; the
  remaining Linux Barrier client showed an established connection to the restored owner server.

## Result

- Analyzer result: `STOP-BOTH-SUCCEED`.
- Width-4 and width-2 both succeeded on every complete stream.
- No fixture, register entry, width ADR or `M1-025` unblock is produced.
