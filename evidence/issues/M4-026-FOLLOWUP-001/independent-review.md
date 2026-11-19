# M4-026-FOLLOWUP-001 Independent Review

- Reviewer: fresh-context Opus agent, Tier C
- Date: 2026-11-19
- Target: PR #376 at `f1cd4a6`
- Verdict: APPROVE with notes; no Blocker, High or Medium; 3 Low (F1 to F3), 2 Nit (F4, F5)

## Review

Root cause confirmed by tracing the inbound path: the protocol session emits `contentHash: ""` for
every DCLP clipboard; the runtime relayed it unchanged; `ClipboardLoopGuard` rule 4 rejects an equal
hash, so every server clipboard after the first in a session is `loopRejected`. `beginSession()`
resets the guard, which explains why `clipboard-on-reconnect` passed. The fix hashes with
`LinuxX11ClipboardRules.contentHash`, the same function used for local reads, so both directions
agree; it also improves client-side echo suppression. No other inbound path was found: one `.clipboard`
producer in the client session, `ClientCoordinator` is built only by the Linux runtime, and the
macOS server rehashes in `ServerClipboardRouter`. Evidence was checked for consistency and privacy
(no addresses, home paths or user names in `commands.json`, `environment.json` or the XML).

## What the reviewer ran

Docker `swift:6.2.3-jammy`, native arm64, foreground, no ports bound, in a detached worktree at
`f1cd4a6`:

- PR head plus a temporary measurement test: `swift build --build-tests` `Build complete! (137.42s)`;
  the new test `✔ Test run with 1 test in 1 suite passed after 0.117 seconds.`
- Hash cost: 600000 bytes best 0.000292834 s; 1048576 bytes best 0.000529125 s.
- Full suite with `MACKVM_X11_TESTS=1` under xvfb-run: `✔ Test run with 522 tests in 55 suites passed
  after 6.403 seconds` (including the temporary test, so the PR itself is 521 tests in 54 suites).
- Fix reverted: `✘ Test run with 1 test in 1 suite failed after 60.021 seconds with 1 issue.` (time
  limit); restored: passed in 0.117 s.
- Not run: macOS `swift test` and the E2E (Linux-only change; the E2E script is not in this PR).

## Findings and disposition (fixes at `3c34134`)

| Finding | Severity | Summary | Disposition |
| --- | --- | --- | --- |
| F1 | Low | Nothing pins that the inbound hash equals the local-read hash | Fixed. New test `a local re-read of an applied server clipboard is not echoed`; the fake clipboard hashes reads with `LinuxX11ClipboardRules.contentHash`. A hash-swap mutant fails it (`review-followup-mutant-other-hash`). |
| F2 | Low | The runtime-supplies-the-hash contract rests on a comment | Fixed. `ClientCoordinator.applyInbound` drops an empty hash (`assertionFailure` in debug, `loopRejected` count in release). |
| F3 | Low | The client guard is not reset by a local copy made while inactive or by a failed async write | Pre-existing design, not a regression. Out of scope, still open. |
| F4 | Nit | RED failed only by the 60 s time limit with no diagnosis | Fixed. The test now fails in 5.111 s with `inbound clipboards applied 1 of 2, loopRejected 1` (`review-followup-red`). |
| F5 | Nit | The acceptance asks for an Xvfb RED; the RED uses a fake clipboard | Explained in the PR body and in `summary.md`: the failing layer is runtime plus coordinator, and the Xvfb probes ruled X11 out. |

Gates after the fixes (at `3c34134`): Linux focused 93 tests passed (`-warnings-as-errors`); Linux
full 522 passed under Xvfb; macOS `swift test` 332 passed. The E2E and `make verify` were not rerun
at `3c34134` (see `summary.md`).
