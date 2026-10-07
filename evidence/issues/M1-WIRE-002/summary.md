# M1-WIRE-002 Summary

## Status

STOPPED. The approved bounded attempts did not produce discriminating Barrier length-prefix
evidence.

A second attempt was proposed in `discrimination-plan.md` section 11, independently approved
for one bounded attempt, and stopped during pre-window checks before capture opened. See
"Attempt 2 (pre-window stop)" below.

A third attempt was proposed in `discrimination-plan.md` section 12, independently approved
for one bounded attempt, and executed. It stopped with a non-discriminating
`STOP-BOTH-SUCCEED` result. See "Attempt 3 (non-discriminating stop)" below.

A fourth attempt was proposed in `discrimination-plan.md` section 13, independently approved
for one bounded attempt, and executed. It stopped with a non-discriminating
`STOP-BOTH-SUCCEED` result. See "Attempt 4 (non-discriminating stop)" below.

A fifth attempt was proposed in `discrimination-plan.md` section 14, independently approved
for one bounded attempt, and stopped before analyzable stream construction because Barrier
drag-and-drop/file-transfer is not implemented in the tested runtime path. See
"Attempt 5 (runtime unsupported stop)" below.

A sixth attempt is proposed in `discrimination-plan.md` section 15 and has a new Checkpoint 1
approval in `independent-review.md`. It has not opened a capture window yet.

## Attempt 1 (historical)

The sections "Stop reason", "Evidence handling", "Restoration" and "Outcome" below record
attempt 1 and are kept unchanged.

## Stop reason

- UTC: `2026-10-05T07:09:55Z`
- Fixed stop label: `client-not-connected`
- Meaning: the required Barrier runtime connection did not succeed inside the bounded attempt.
- Consequence: no retry or reconnect was performed under the approved one-attempt plan.

## Evidence handling

- Raw capture stayed on `role-capture`.
- The retained raw file was only a pcap header (`24` bytes).
- No sanitized artifact, privacy-scanned fixture, register entry, or width ADR was produced.
- No raw deletion was performed because Checkpoint 2 was not reached.

## Restoration

The owner Barrier session was restored after the failed attempt:

- macOS role: `barriers running`, `server listener up`
- Linux role: `barrierc running`, `connection established`

## Outcome

M1-WIRE-002 remains stopped without accepted width evidence. `M1-025` remains blocked.

## Attempt 2 (pre-window stop)

- Plan: `discrimination-plan.md` section 11 (repository documentation only).
- New independent Checkpoint 1 decision: recorded in `independent-review.md` at
  `2026-10-06T09:00:59Z`, approving one second bounded attempt only after all section 11.4
  pre-window checks pass.
- Pre-window check time: `2026-10-06T09:02:48Z`.
- Fixed stop label: `baseline-direction-mismatch`.
- Meaning: fresh check 11.4(2) required the unmodified owner baseline to be Linux Barrier
  server to macOS Barrier client. The Linux role instead reported a Barrier client process
  connected to a remote server. That matches the attempt-1 restoration direction rather than
  the approved section-11 baseline.
- Consequence: STOP before the capture window opens. No capture, SSH evidence configuration,
  disposable cleartext leg, fixture, register entry or width ADR was produced for attempt 2.
- Unchanged boundaries: no Windows, no Barrier or Deskflow source, no production Swift, no
  MacKVM production TLS or default change, no byte prediction, and no capture before reviewer
  approval.
- `M1-025` remains blocked until accepted discriminating evidence exists.

## Attempt 6 (approved, not yet started)

- Plan: `discrimination-plan.md` section 15 (repository documentation only).
- New independent Checkpoint 1 decision: recorded in `independent-review.md` at
  `2026-10-07T04:45:04Z`, approving one sixth bounded attempt only after all section 15.5
  pre-window checks pass.
- Added trigger: disposable large synthetic Barrier server configuration with many non-personal
  screen entries, aliases and links, using normal config parsing only.
- Unchanged boundaries: no Windows, no Barrier or Deskflow source, no production Swift, no
  MacKVM production TLS or default change, no byte prediction, no capture before reviewer
  approval, and no `M1-025` unblock without accepted discriminating evidence.
- `M1-025` remains blocked until accepted discriminating evidence exists.

## Attempt 3 (non-discriminating stop)

- Plan: `discrimination-plan.md` section 12 (repository documentation only).
- New independent Checkpoint 1 decision: recorded in `independent-review.md` at
  `2026-10-06T09:13:06Z`, approving one third bounded attempt only after all section 12.5
  pre-window checks pass.
- Pre-window checks recorded in `independent-review.md` passed for baseline direction, Linux
  package/capture capabilities, macOS Barrier binary hashes and SSH remote-forward loopback.
- Runtime result: `STOP-BOTH-SUCCEED`.
- Meaning: the complete sanitized attempt-3 streams were analyzed by the approved
  `walk(S, 4)` and `walk(S, 2)` predicates, and both readings succeeded on every stream.
  Therefore the attempt did not discriminate the length-prefix width.
- Sanitized stop evidence: `attempt3/sanitized.json`.
- Consequence: STOP after sanitizer analysis. No accepted fixture, register entry, width ADR
  or `M1-025` unblock was produced for attempt 3.
- Unchanged boundaries: attempts 1 and 2 remain stopped; no Windows, no Barrier or Deskflow
  source, no production Swift, no MacKVM production TLS or default change, no byte prediction,
  no capture before reviewer approval, and no `M1-025` unblock without accepted
  discriminating evidence.
- Raw capture remains on `role-capture` pending independent Checkpoint 2 re-derivation and
  deletion review. Raw capture is not committed.
- Follow-up rechecks could not find the previously recorded attempt-3 raw and sanitizer
  working files on `role-capture`. Checkpoint 2 remains incomplete; this is recorded as an
  evidence-handling limitation, not as a completed deletion/re-derivation result.

## Attempt 4 (non-discriminating stop)

- Plan: `discrimination-plan.md` section 13 (repository documentation only).
- New independent Checkpoint 1 decision: recorded in `independent-review.md` at
  `2026-10-07T00:41:22Z`, approving one fourth bounded attempt only after all section 13.6
  pre-window checks pass.
- Added trigger: deterministic synthetic macOS clipboard text must be requested from the Linux
  client through normal Barrier clipboard sharing, and only metadata such as size, SHA-256 and
  hash-match status may be recorded.
- Runtime result: `STOP-BOTH-SUCCEED`.
- Meaning: the complete sanitized attempt-4 streams were analyzed by the approved
  `walk(S, 4)` and `walk(S, 2)` predicates, and both readings succeeded on every stream.
  Therefore the attempt did not discriminate the length-prefix width.
- Trigger result: the disposable evidence session generated a `200000`-byte synthetic
  clipboard value, but Linux clipboard read-back returned `0` bytes, so the trigger hash did
  not match. This mismatch does not approve or reject either width.
- Sanitized stop evidence: `attempt4/sanitized.json`.
- Consequence: STOP after sanitizer analysis. No accepted fixture, register entry, width ADR
  or `M1-025` unblock was produced for attempt 4.
- Unchanged boundaries: no Windows, no Barrier or Deskflow source, no production Swift, no
  MacKVM production TLS or default change, no byte prediction, no capture before reviewer
  approval, and no `M1-025` unblock without accepted discriminating evidence.
- `M1-025` remains blocked until accepted discriminating evidence exists.

## Attempt 5 (runtime unsupported stop)

- Plan: `discrimination-plan.md` section 14 (repository documentation only).
- New independent Checkpoint 1 decision: recorded in `independent-review.md` at
  `2026-10-07T04:32:25Z`, approving one fifth bounded attempt only after all section 14.6
  pre-window checks pass.
- Added trigger: Barrier file drag-and-drop / file-transfer path using synthetic, non-personal
  file content, enabled only in the disposable evidence configuration. Only metadata such as
  file size, SHA-256 and hash-match status may be recorded.
- Verified planning source: both macOS and Linux Barrier binaries advertise `--enable-drag-drop`
  and `--drop-dir` in their command-line help.
- Runtime result: `file-transfer-runtime-unsupported`.
- Meaning: the advertised file-transfer options are not usable in this tested Barrier runtime
  path. macOS server stopped with `setDropTarget not implemented`; Linux client reported
  drag-and-drop is not supported on Linux and also stopped with `setDropTarget not implemented`.
- Raw capture was only a 24-byte pcap header with zero packets captured; analyzer rejected it
  with `no-in-scope-connection`; no sanitized artifact was produced.
- Consequence: STOP before stream analysis. No accepted fixture, register entry, width ADR or
  `M1-025` unblock was produced for attempt 5.
- Unchanged boundaries: no Windows, no Barrier or Deskflow source, no production Swift, no
  MacKVM production TLS or default change, no byte prediction, no capture before reviewer
  approval, and no `M1-025` unblock without accepted discriminating evidence.
- `M1-025` remains blocked until accepted discriminating evidence exists.
