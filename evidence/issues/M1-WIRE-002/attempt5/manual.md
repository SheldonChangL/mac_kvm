# M1-WIRE-002 Attempt 5 Manual Log

All entries use UTC.

## Pre-window

- `2026-10-07T04:32:25Z` — Checkpoint 1 approved section 14 for one fifth bounded attempt.
- `2026-10-07T04:31Z` — Planning-source check verified that both macOS and Linux Barrier
  binaries advertise `--enable-drag-drop` and `--drop-dir`.
- `2026-10-07T04:35Z` — Analyzer copied to `role-capture`; raw working directory and
  disposable drop directory remained on `role-capture`.
- `2026-10-07T04:35Z` — A deterministic `1048576` byte synthetic file was created on
  `role-server` with SHA-256
  `30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58`.
- `2026-10-07T04:35Z` — GUI automation located the synthetic file icon in Finder by
  accessibility metadata and prepared a normal drag gesture.

## Capture window

- `2026-10-07T04:36Z` — Existing owner Barrier server/client processes were stopped with
  graceful termination before the disposable evidence configuration started.
- `2026-10-07T04:36Z` — Disposable macOS Barrier server was started with drag-and-drop enabled,
  but stopped with `setDropTarget not implemented`.
- `2026-10-07T04:36Z` — macOS-initiated SSH remote forward established a Linux loopback-only
  listener.
- `2026-10-07T04:36Z` — Linux loopback tcpdump capture started.
- `2026-10-07T04:36Z` — Disposable Linux Barrier client was started with drag-and-drop enabled,
  reported that drag-and-drop is not supported on Linux, and stopped with
  `setDropTarget not implemented`.
- `2026-10-07T04:36Z` — The normal GUI file drag was sent, but no Linux drop file was produced
  because the Barrier evidence processes had already stopped.

## Analysis and restoration

- `2026-10-07T04:36Z` — Raw pcap was only a 24-byte pcap header. Tcpdump reported zero packets
  captured, zero packets received by filter and zero packets dropped.
- `2026-10-07T04:36Z` — Analyzer ran on `role-capture` and rejected the raw pcap with
  `no-in-scope-connection`; no sanitized output was produced.
- `2026-10-07T04:36Z` — Owner macOS Barrier server and Linux Barrier client were restored.
- `2026-10-07T04:37Z` — A duplicate restored Linux Barrier client process was removed; the
  remaining Linux Barrier client showed an established connection to the restored owner server.

## Result

- Fixed stop label: `file-transfer-runtime-unsupported`.
- No analyzable stream exists.
- No fixture, register entry, width ADR or `M1-025` unblock is produced.
