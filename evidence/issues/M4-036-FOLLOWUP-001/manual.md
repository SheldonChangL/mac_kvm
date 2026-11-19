# M4-036-FOLLOWUP-001 Owner-Hardware Run (TEMPLATE, NOT RUN)

Status: **not run**. This is the checklist for the owner at both machines. A reviewer
who is not the agent verifies it and signs below. Until then `result.json` stays not
passed and `barrierc` stays in use.

## Rules

- **Stop at the first safety failure**: a stuck key or button on either machine, Mac
  input not restored, input reaching the wrong machine, or a client that cannot be
  stopped. Mark that case `fail`, mark every later case `not run`, write why in its
  notes, and stop.
- Each case is bounded to 2 minutes.
- Notes use closed vocabulary only: pass/fail, counts, status lines as printed. Never
  write typed text, clipboard content, addresses, host names, user names or
  fingerprints.
- Probe text must be a fixed non-personal string chosen before the run.

## Run record

| Field | Value |
| --- | --- |
| Date (UTC) | |
| Repository commit (40 hex) | |
| Mac: macOS version / build | |
| Linux: distribution / X server | |
| `mackvm-client` install (binary + `systemd --user` unit) | |
| Operator | owner |

## Preconditions

| # | Check | Done (y/n) | Notes |
| --- | --- | --- | --- |
| P1 | `barrierc` stopped and disabled (no autostart; `pgrep barrierc` empty) | | |
| P2 | Mac server running in release mode with the client's screen name | | |
| P3 | Trust established from the fingerprint the Mac displays (compared by eye, not copied from a log) | | |
| P4 | Emergency chord known; a second way to reach the Mac (e.g. its own keyboard) at hand | | |

## Cases

Result is `pass`, `fail` or `not run`.

| # | Case | Expected | Result | Notes |
| --- | --- | --- | --- | --- |
| C1 | Handshake | client `connected`; server ready; TLS pinned | | |
| C2 | Identity | a client with an unexpected screen name is rejected; no session | | |
| C3 | Enter/leave | pointer crosses the edge and back; Mac cursor restored inside the edge | | |
| C4 | Mouse | move, left/right/middle click, vertical and horizontal scroll (trackpad) act on Linux only | | |
| C5 | Keyboard | fixed probe string and modifiers reach Linux; none on the Mac | | |
| C6 | Escape | Control+Option+Command+Delete while remote restores Mac input at once | | |
| C7 | Held input | hold a key and a button, kill the client: nothing stuck on either side; Mac local | | |
| C8 | Network loss | disable the network while remote: Mac local within the timeout | | |
| C9 | Sleep | Mac sleeps while remote, then wakes: Mac local; no suppression | | |
| C10 | Termination | quit MacKVM while remote: Mac input restored; tap released | | |
| C11 | Clipboard | UTF-8 text both ways (see X3) | | |
| X1 | Shifted punctuation | `! @ # $ % ^ & * ( ) _ + { } \| : " < > ?` arrive as typed | | |
| X2 | Shift held at enter | hold Shift, cross to Linux, release: no Shift stuck on Linux or Mac | | |
| X3 | Clipboard Linux → Mac | copy a fixed probe on Linux, paste on the Mac: equal | | |
| X4 | Clipboard Mac → Linux | copy a fixed probe on the Mac, paste on Linux: equal | | |
| X5 | Linux suspend/resume, pointer local | client logs `the system resumed; reconnecting` and reconnects; no input sent while away | | |
| X6 | Mac sleep and wake | client reconnects after the Mac wakes; nothing stuck | | |
| X7 | Unknown fingerprint, first run | with no trust record: interactive prompt shows the fingerprint; `trust` stores it; anything else exits 78 and stores nothing; `--non-interactive` exits 78 | | |
| X8 | `systemd --user` start and stop | `systemctl --user start mackvm-client` connects; `stop` exits 0 and releases input | | |
| X9 | Reconnect after a Linux reboot | after reboot and login the unit starts and reconnects without action | | |
| X10 | Large clipboard to Linux | a ~600 KB Mac copy pastes on Linux (automated case `clipboard-large-to-client` passes since #373 and #376) | | |

Stopped early? (case number and reason): ______

## Reviewer sign-off

The reviewer is not the agent and did not run the cases.

| Field | Value |
| --- | --- |
| Reviewer | |
| Date (UTC) | |
| Commit reviewed | |
| All cases above have a result and notes follow the rules | yes / no |
| No personal data in this file | yes / no |
| Verdict | accept / reject |
| Signature | |
