# M4-036-FOLLOWUP-001 Independent Review

- Reviewer: fresh-context Opus agent, Tier C
- Date: 2026-11-19
- Target: PR #371 at `7bd9442`
- Verdict: APPROVE with notes; no Blocker or High, 6 Medium (M1 to M6), 9 Low (L1 to L9), 4 Nit (N1 to N4)

## Review

The evidence is internally consistent. `result.json` matches the committed logs: artifact SHA-256
and byte lengths match, 23 cases with 22 passed at that commit, `owner-hardware-half` failed (69),
status `failed`. The script is unchanged between the run commit `65379c4` and `7bd9442`. The PR diff
against `main` is exactly the 10 listed files. No privacy leak was found. Nothing blocks merging an
evidence PR whose status is `failed`; the PR body (M1) had to be fixed before merge and the
`manual.md` items (M2 to M4) before the owner runs the hardware half. The reviewer also judged that
no check passes vacuously when a log is missing, and that the script never binds the default port,
never touches the Mac display, and removes its disposable Keychain identity on exit.

## What the reviewer ran

Read-only; the E2E was not rerun and `make verify` was not run.

- `gh pr view` for #371, #373, #376 and `gh issue view 351`; `git show` of all 10 files at the head;
  `git diff --stat` against `65379c4`, `10685d2` and `main`.
- `shasum` and byte counts of the three artifacts, compared with `result.json`.
- Re-derived the X event "effective" list from the committed `x-events.txt` with the script's awk:
  matches (70 raw lines, 68 effective).
- Source greps for the emergency chord, client status strings and the smoke pasteboard.
- A privacy grep over the PR files: nothing found.
- `validate_evidence.py` in a detached scratch worktree at the head: `evidence valid:
  issue=M4-036-FOLLOWUP-001 status=failed`.

## Findings and disposition

Fixes are at `4378b81` (checks, manual, plan, PR body) and `ca2837d` (rerun record).

| Finding | Severity | Summary | Disposition |
| --- | --- | --- | --- |
| M1 | Medium | PR body stale (21 of 23, `make verify` claims) | Fixed: body rewritten (`4378b81` state) |
| M2 | Medium | `manual.md` names Delete; the app advertises Return | Fixed: chord is Control+Option+Command+Return (P4, C6) |
| M3 | Medium | No setup for the Linux host, P2 server command, C2 trigger or C8 figure | Fixed: Setup section (x86_64, `make dist-linux`, `~/.local/bin`, systemd user unit), P2 command, C2 via `--name wrong-name`, C8 within 12 s, signature rows |
| M4 | Medium | No path from `failed` to `passed` after sign-off | Fixed: plan Sign-off section; dry run validated to `status=passed`, then restored |
| M5 | Medium | `make verify` and `validate_package.py` dropped | Fixed: rerun and recorded in `commands.json` (`ca2837d`) |
| M6 | Medium | `clipboard-large-to-client` "session kept" check weak; later clipboard never read back | Fixed: stronger session check; new case `clipboard-later-to-client`; FIFO send times out after 5 s |
| L1 | Low | `fingerprint-changed-no-bytes` asserts only no ready session | Fixed at `4378b81` |
| L2 | Low | Redundant X releases not bounded or recorded | Open |
| L3 | Low | FIFO driver can hang | Fixed (5 s write timeout) |
| L4 | Low | Container leftovers; untracked files copied in | Open |
| L5 | Low | Container deviation from #351 not recorded | Noted in README; amending #351 still open |
| L6 | Low | `escape` uses the driver command, not chord detection | Open |
| L7 | Low | Sleep-based synchronisation | Open |
| L8 | Low | No operator signature in `manual.md` | Open |
| L9 | Low | `summary.md` and `independent-review.md` missing | Fixed by this closing commit |
| N1 | Nit | Port guard is a string compare | Fixed |
| N2 | Nit | Header list differs across files | Fixed |
| N3 | Nit | Plan says `make e2e` exits 1; it is 2 | Fixed |
| N4 | Nit | `tls` value is a fixed string | Open |

Independent check of the dispositions by the closer, at `ca2837d`: `result.json` has 23 passed
automated cases plus `owner-hardware-half` failed (69); `commands.json` contains `make verify` and
`validate_package.py` entries; `manual.md` says Return (lines 54, 76, 89); the C8 12 s figure matches
the server keepalive constants (summary.md, Residual notes).
