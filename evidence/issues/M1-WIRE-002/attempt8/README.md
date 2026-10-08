# M1-WIRE-002 Attempt 8 Accepted Discriminating Evidence

## Status

ACCEPTED. Attempt 8 reran the long synthetic client-name observation under the pre-approved
section-17 gate. The runtime produced an explicit protocol-error close, the TCP stream was
complete, and the analyzer found exactly one surviving reading.

## Outcome

- Fixture: `Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/sanitized.json`
- Fixture SHA-256:
  `6b5049bb34694130186dd147353c14c072820825c98a2ede942a49f6bab674f1`
- Fixture byte length: `100283`
- Evidence ID: `BARRIER-EVID-0003`
- Analyzer result: `DISCRIMINATING`
- Surviving reading: width `4`
- Rejected reading: width `2`
- Width-2 failure: `connection-1`, `client-to-server`, offset `57514`, reason `overrun`,
  declared `24929`, available `12503`.

## Runtime gate

- The server started normally and logged one accepted client connection followed by protocol
  error from client `<unknown>`.
- The client ran with `--no-restart`, logged server-reported protocol error, and stopped.
- The raw pcap had FIN-bounded complete streams and no RST.
- Peer runtime logs are retained as summarized evidence only in
  `runtime-log-excerpts.json`. The original attempt-8 temporary directory on `role-capture` was
  unavailable when rechecked on `2026-10-08T02:19:12Z`, so this attempt does not claim a
  byte-for-byte raw peer-log re-fetch or log hash.

## Raw handling

- Raw capture stayed on `role-capture` and was not committed.
- Raw capture SHA-256 on `role-capture`:
  `5ed5322b6edc0e3c8fd0a63776a25335de4a15d824769d1162361dfd05c6fabc`
- Raw capture byte length: `71230`
- Packet counters: `14 packets captured`, `28 packets received by filter`, `0 packets dropped by
  kernel`.
- Current raw-pcap availability is not independently verified. The attempt-8 remote temporary
  directory was unavailable when rechecked, so reviewers cannot currently re-run raw-pcap to
  sanitized-fixture derivation from the original pcap; the committed fixture is instead
  validated by deterministic sanitized stream walks and recorded as having this limitation.

## Consequence

This attempt appends `BARRIER-EVID-0003` and records the width decision in
`docs/adr/M1-WIRE-002-barrier-length-prefix-width.md`. `M1-025` may use this evidence to freeze
the exact length-prefix width, while all other Barrier wire fields remain limited to their own
evidence and owning Issues.
