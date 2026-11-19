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

## Setup

The Linux machine needs no Swift toolchain: the client is built on the Mac in a
container and copied over.

1. Check the Linux machine's architecture: `uname -m`. The owner's PC is `x86_64`, which
   is what the supported build targets.
2. On the Mac, at the commit under test: `make dist-linux`. It builds a release
   `mackvm-client` with the static Swift standard library in the pinned
   `swift:6.2.3-jammy` linux/amd64 image and writes `artifacts/linux/mackvm-client`,
   `artifacts/linux/mackvm-client.service` and `artifacts/linux/SHA256SUMS`. An arm64
   (`aarch64`) Linux machine has no supported release build yet; do not improvise one
   for this run.
3. Copy the three files to the Linux machine, then as the desktop user (never root):

   ```sh
   sha256sum -c SHA256SUMS
   install -D -m 755 mackvm-client ~/.local/bin/mackvm-client
   install -D -m 644 mackvm-client.service ~/.config/systemd/user/mackvm-client.service
   ```

   Edit `<host>` (the Mac's address, with `:port` if not 24800) and `<name>` (the screen
   name, equal to the Mac's `--client`) in the unit's `ExecStart`. Install the
   X11 runtime libraries if missing: `sudo apt-get install libx11-6 libxtst6 libxrandr2
   libxfixes3`.
4. Trust the Mac once from a terminal (P3): `mackvm-client fingerprint trust <host>[:port]
   <sha256>` with the value the Mac prints, read by eye.
5. Enable the unit for X8 and X9: `systemctl --user import-environment DISPLAY
   XAUTHORITY`, then `systemctl --user daemon-reload && systemctl --user enable --now
   mackvm-client`. For the cases before X8, either use the unit or run `mackvm-client
   connect <host>[:port] --name <name>` in a terminal; do not run both.
6. The Mac server (P2): build `swift build -c release --product MacKVM`, then run
   `.build/release/MacKVM serve --client <name> [--edge right|left|top|bottom]
   [--port <port>]` in a terminal (default port 24800; Accessibility and Input
   Monitoring must be granted, otherwise it exits 77). It prints the fingerprint, then
   `Control+Option+Command+Return returns input to this Mac at any time` once
   listening. Ctrl-C stops it.

## Run record

| Field | Value |
| --- | --- |
| Date (UTC) | |
| Repository commit (40 hex) | |
| Mac: macOS version / build | |
| Linux: distribution / X server | |
| `mackvm-client` install (binary + `systemd --user` unit) | |
| Operator | owner |
| Operator initials and date (UTC), confirming the results below are as observed | |

## Preconditions

| # | Check | Done (y/n) | Notes |
| --- | --- | --- | --- |
| P1 | `barrierc` stopped and disabled (no autostart; `pgrep barrierc` empty) | | |
| P2 | Mac server running from the release build: `.build/release/MacKVM serve --client <name>` (Setup step 6) | | |
| P3 | Trust established from the fingerprint the Mac displays (compared by eye, not copied from a log) | | |
| P4 | Emergency chord known: **Control+Option+Command+Return** (as the server prints); a second way to reach the Mac (e.g. its own keyboard) at hand | | |

## Cases

Result is `pass`, `fail` or `not run`.

| # | Case | Expected | Result | Notes |
| --- | --- | --- | --- | --- |
| C1 | Handshake | client `connected`; server ready; TLS pinned | | |
| C2 | Identity | with the unit stopped, run `mackvm-client connect <host>[:port] --name wrong-name --non-interactive`: the server prints `client handshake failed: …` and no `client ready`; no input moves | | |
| C3 | Enter/leave | pointer crosses the edge and back; Mac cursor restored inside the edge | | |
| C4 | Mouse | move, left/right/middle click, vertical and horizontal scroll (trackpad) act on Linux only | | |
| C5 | Keyboard | fixed probe string and modifiers reach Linux; none on the Mac | | |
| C6 | Escape | Control+Option+Command+Return while remote restores Mac input at once (the detector also accepts Delete, but macOS does not deliver Delete with all three modifiers to the tap; use Return) | | |
| C7 | Held input | hold a key and a button, kill the client: nothing stuck on either side; Mac local | | |
| C8 | Network loss | disable the Linux network while remote: Mac local within 12 s (server keepalive: 3 silent 3 s intervals); fail if longer than 15 s | | |
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

When the verdict is `accept`, the reviewer promotes `result.json` exactly as described
in `Tests/SystemTests/Plans/M4-036-FOLLOWUP-001-linux-client-e2-e.md`, "Sign-off".
