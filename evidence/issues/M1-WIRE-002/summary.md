# M1-WIRE-002 Summary

## Status

STOPPED. The approved one bounded runtime attempt did not produce discriminating Barrier
length-prefix evidence.

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
