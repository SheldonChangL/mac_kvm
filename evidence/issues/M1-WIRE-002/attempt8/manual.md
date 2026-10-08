# M1-WIRE-002 Attempt 8 Manual Log

- Checkpoint 1 approval: `2026-10-07T05:53:56Z`.
- Attempt started: `2026-10-07T05:55:28Z`.
- Attempt completed: `2026-10-07T05:55:54Z`.
- Trigger: deterministic synthetic `70000`-byte client screen name, generated from the recorded
  recipe in `metadata.json`.
- Client restart behavior: disabled with `--no-restart`.
- Runtime observation: explicit protocol-error close, accepted by section 17 only for this fresh
  attempt and not retroactively applied to attempt 7.
- Peer runtime log limitation: the original remote temporary directory was no longer available
  when rechecked on `2026-10-08T02:19:12Z`, so peer log evidence is recorded only as the
  sanitized runtime summary in `runtime-log-excerpts.json`; no raw log hash is claimed.
- Raw capture location: `role-capture` only.
- Raw capture current-availability limitation: the recorded raw pcap hash and length are kept
  as producer runtime evidence, but the original pcap was not independently re-fetched after the
  temporary directory became unavailable.
- Sanitized fixture: committed under `Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/`.
- Production code changes: none.
- Windows: not run.
- Barrier/Deskflow source: not consulted.
