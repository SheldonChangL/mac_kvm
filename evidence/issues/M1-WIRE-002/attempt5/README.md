# M1-WIRE-002 Attempt 5 Stopped File-transfer Evidence

## Status

STOP. Attempt 5 attempted to use Barrier's documented drag-and-drop / file-transfer command
line options, but the disposable evidence session stopped before any in-scope loopback
connection or analyzable stream existed.

## Stop reason

- Fixed stop label: `file-transfer-runtime-unsupported`
- macOS Barrier server accepted `--enable-drag-drop` syntactically, then stopped with the
  runtime error `setDropTarget not implemented`.
- Linux Barrier client reported that drag-and-drop is not supported on Linux, then stopped with
  the runtime error `setDropTarget not implemented`.
- The Linux loopback capture saw no in-scope packets.
- The analyzer rejected the raw pcap with `no-in-scope-connection`.

## Raw handling

- Raw capture stayed on `role-capture` and was not committed.
- Raw capture SHA-256 on `role-capture`:
  `704e5e5b3234433c01fcfd1b20a306e77e985038120492dc53965c3edd38a4ea`
- Raw capture byte length: `24`
- Raw capture packet-counter summary: `0 packets captured`, `0 packets received by filter`,
  `0 packets dropped by kernel`
- No sanitized artifact was produced.

## Consequence

No register entry, width ADR, fixture acceptance or `M1-025` unblock is produced by this
attempt. GitHub Issue #279 remains open.
