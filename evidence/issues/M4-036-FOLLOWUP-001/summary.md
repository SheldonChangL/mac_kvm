# M4-036-FOLLOWUP-001 Evidence Summary

## Scope

PR #371, "Part of #351", Tier C (test script, plan and evidence only; no product code changed).
Head `ca2837d`; gate of record `4378b81` (`main` merged at `a555a07`).

This evidence covers the automated half of #351 only: the Linux client against the Mac `MacKVM smoke`
server on loopback. **#351 is NOT complete.** The owner hardware half (P1 to P4, C1 to C11, X1 to X10
in `manual.md`) and the non-agent sign-off have not been run, so this PR stays `Part of #351` and
does not close it.

## Method

- `make e2e ISSUE=M4-036-FOLLOWUP-001` with `MACKVM_E2E_CONTAINER=<arm64 swift:6.2.3-jammy container>`.
  Script: `Tests/SystemTests/Scripts/M4-036-FOLLOWUP-001-linux-client-e2-e.sh`; plan:
  `Tests/SystemTests/Plans/M4-036-FOLLOWUP-001-linux-client-e2-e.md`.
- The Mac side is the smoke server on a non-default loopback port. The client is built and run in
  the container under Xvfb (`-nolisten tcp`) with a disposable TLS identity.
- Case checks read `server.log`, `client.log` and the real X event stream (`x-events.txt`).
- Evidence: `evidence/e2e/M4-036-FOLLOWUP-001/` (README, `result.json`, sanitized logs) and this
  directory (`commands.json`, `environment.json`, `manual.md`).

## Results

Verified against `result.json` at the head: commit `4378b81`, status `failed`, 24 cases.

| Group | Cases | Status |
| --- | --- | --- |
| Automated | 23 | 23 passed, exit 0 |
| `owner-hardware-half` | 1 | failed, exit 69 (pending by design) |

Passed cases: `fingerprint-changed-exit-78`, `fingerprint-changed-no-bytes`, `handshake`, `enter`,
`clipboard-to-client`, `move-1`, `move-2`, `held-key-locks`, `return`, `clipboard-from-client`,
`escape`, `clipboard-not-echoed`, `clipboard-large-from-client`, `kill-client-no-stuck-key`,
`reconnect`, `clipboard-on-reconnect`, `keepalive-13s`, `clipboard-large-to-client`,
`clipboard-later-to-client`, `quit-while-remote`, `auto-reconnect`, `client-sigterm-exit-0`,
`x-events`.

`result.json` is `failed` on purpose: the script always appends `owner-hardware-half` as failed (69).
The plan's Sign-off section defines how a non-agent reviewer promotes it to `passed`, which must pass
`validate_evidence.py --require-passed`.

Commands (`commands.json`, all exit 0 except the expected `make e2e`):

| Command | Result |
| --- | --- |
| `make e2e` | script exit 0, disposition `failed`, make exit 2 (`run_e2e.py` exits 1 for status `failed`) |
| `validate_evidence.py result.json` | `evidence valid: issue=M4-036-FOLLOWUP-001 status=failed` |
| `make verify` | exit 0, run at `4378b81` |
| `validate_package.py` | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| `make docs-check` | `docs check OK` |

## History of the earlier failure

- First run, `cc4ccb8` (2026-11-17): `clipboard-large-to-client` failed. A 600 KB server clipboard
  ended the client session with `transport.resourceExhausted`.
- PR #373 (TLS inbound backpressure) fixed the transport side.
- Rerun after #373: the session stayed up but the clipboard was not applied. The cause was inbound
  clipboards carrying an empty content hash, so the client loop guard dropped every server clipboard
  after the first in a session. PR #376 (issue #375) hashes them in `ClientRuntime`; its evidence is
  `evidence/issues/M4-026-FOLLOWUP-001/`.
- `65379c4`: 22 of 22 automated cases passed with the older checks.
- `4378b81`: checks tightened after review (see Independent review). `clipboard-large-to-client`
  now requires no `connection ended` on the client and no disconnect on the server. New case
  `clipboard-later-to-client` reads back the next server clipboard on the same session, the #376
  path. 23 of 23 passed.
- `ca2837d`: records that rerun.

## Acceptance against #351

| Criterion | Status |
| --- | --- |
| Automated half: Linux client vs Mac server, 23 cases | Met, in a local arm64 container (deviation, see Residual notes) |
| `make e2e`, `make verify` | Run and recorded at `4378b81`; `make e2e` exits non-zero by design while the hardware half is pending |
| Owner hardware half P1 to P4, C1 to C11, X1 to X10 | **Not run** |
| Non-agent sign-off; `result.json` promoted to `passed` | **Not done** |
| `summary.md`, `independent-review.md` | This file and `independent-review.md` |

Overall: **#351 is not complete.**

## Independent review

Tier C, fresh-context Opus, at `7bd9442`: APPROVE with notes; no Blocker or High, 6 Medium, 9 Low,
4 Nit. M1 to M6 and L1, L3, L5 (noted in the README), N1 to N3 were addressed at `4378b81` and
`ca2837d`. Details and per-finding disposition are in `independent-review.md`.

## Residual notes

- The automated half ran in a local arm64 container, not on the Linux host (which has no Swift
  toolchain). The owner has not confirmed this deviation, and #351 still says "on the Linux host";
  amending #351 is open.
- The `manual.md` setup steps (`make dist-linux`, x86_64 build, `~/.local/bin` plus a systemd user
  unit) were not run end to end. Local amd64 Docker emulation is known to stall on this Mac, so the
  owner may need another build host.
- C8 timeout check: the server drops a silent client after `silentIntervalsBeforeTimeout = 3`
  silent intervals of `keepaliveInterval = 3 s`
  (`Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierServerProtocolSession.swift:454-455`,
  loop at `:276-292`). That is about 9 s, up to 12 s depending on phase, so the manual's "within 12 s"
  holds. No discrepancy.
- Review findings left open (none affects the recorded results): L2 (redundant X releases not
  asserted or recorded; 2 observed), L4 (container leftovers; the working tree is copied, including
  untracked files), L6 (`escape` drives the smoke command, not chord detection; the chord is manual
  C6), L7 (sleep-based synchronisation), L8 (no operator signature field in `manual.md`), L9 (the
  summary and review files were not yet in the PR; now added), N4 (`tls` value "TLS 1.3" is a fixed
  string, not measured).
- The E2E ran at `4378b81`; the later commit `ca2837d` changes evidence only.
- CI result: see PR checks.
