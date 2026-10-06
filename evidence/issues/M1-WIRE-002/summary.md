# M1-WIRE-002 Summary

## Status

STOPPED. The approved bounded attempts did not produce discriminating Barrier length-prefix
evidence.

A second attempt was proposed in `discrimination-plan.md` section 11, independently approved
for one bounded attempt, and stopped during pre-window checks before capture opened. See
"Attempt 2 (pre-window stop)" below.

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
