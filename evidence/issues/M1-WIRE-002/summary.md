# M1-WIRE-002 Summary

## Status

STOPPED. The approved one bounded runtime attempt did not produce discriminating Barrier
length-prefix evidence.

A second attempt is proposed in `discrimination-plan.md` section 11. It is NOT approved and
NOT started. See "Second attempt preparation" below.

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

## Second attempt preparation

- Plan: `discrimination-plan.md` section 11 (repository documentation only).
- The attempt-1 approval is consumed. Attempt 2 needs a new independent Checkpoint 1 decision
  recorded in `independent-review.md` before any capture, SSH session or evidence
  configuration starts.
- Proposed baseline: the owner-confirmed Linux Barrier server to macOS Barrier client
  normal-use session, used only after fresh pre-window checks pass. The attempt-1 restoration
  record above lists the opposite direction; fresh check 11.4(2) must confirm the direction
  or stop.
- Unchanged boundaries: no Windows, no Barrier or Deskflow source, no production Swift, no
  MacKVM production TLS or default change, no byte prediction, and no capture before reviewer
  approval.
- No capture, fixture, register entry or ADR has been produced for attempt 2. `M1-025` remains
  blocked until accepted discriminating evidence exists.
