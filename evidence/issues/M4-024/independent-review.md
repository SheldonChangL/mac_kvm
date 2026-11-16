# M4-024 Independent Review

- Reviewer: fresh-context Opus agent, Tier H (STRONG_REVIEW_PROMPT)
- Date: 2026-11-17
- Target: PR #362 at `402c795`
- Verdict: APPROVE, nothing blocking; 2 Low, 2 Nit

## Review (verbatim)

> PR #362 (M4-024 LinuxX11Injector) Tier H review, fresh-context Opus, head 402c7957
> Verdict: APPROVE, nothing blocking.
> Verified correct: keysym table (:28-78) vs keysymdef.h/XF86keysym.h; release uses press-time keycode (:365-373) and buttons (:334-341); .repeatKey never injected (:362); wheel sign/axis order/32-notch cap, buttons beyond pointer mapping -> .unsupported (:119-126); pixel math round(v*(extent-1)) clamped, NaN/extent<=1 -> 0 (:99-103); sweep order keys->buttons->modifiers->XFlush, releaseRemaining XSync, close() idempotent (:377-398); XTest absence -> permission.capabilityUnavailable (:171); no XInitThreads / X error handler in source (h.8); no logging; drain on dedicated Thread, bounded FIFO, non-blocking enqueue, terminal failure reported once, no self-join, no deadlock (:424-519); extras justified.
> Findings: LOW :485 clear-from-worker in onFailure untested; LOW :324 screen() callback under injector lock (doc); NIT :4 XInitThreads only documented; NIT :241 deinit does not sweep.
> Reviewer runs: arm64 swift:6.2.3-jammy + Xvfb, MACKVM_X11_TESTS=1, filter LinuxX11Injector: 36 tests/4 suites pass. 6 own mutants all detected (release keycode: 2 issues; wheel sign: 7; keys not released: 7; notch cap 1000: 3; XFlush removed: 1; join removed: hang, killed).
> CI heads reviewed: runs 43872500432, 43869297081 (verify-linux pass).

## Resolution

Fixes are at `5286139`; CI run 43978839484 passed on both jobs.

| Finding | Resolution |
| --- | --- |
| Low (`:485`): clear-from-worker in `onFailure` is untested | Fixed: new test `clearFromWorker`, with a 5 s limit. |
| Low (`:324`): the `screen()` callback runs under the injector lock | Documented: the rule (return promptly, never call back into the injector) is stated in both inits and in the component doc's Known limitations. |
| Nit (`:4`): `XInitThreads` is only documented | Accepted: it is the composition root's call (M4-020-FOLLOWUP-001), as the component doc states. |
| Nit (`:241`): `deinit` does not sweep | Documented in the source and the component doc: callers sweep with `releaseRemaining()` or `close()` first. |
| Extra: `joinsInFlight` could hang | A 5 s limit on the join wait; the reviewer's mutant M20 (join removed) now fails in 5.004 s instead of hanging. |

Gates after the fixes: Linux 52 of 52 tests, three runs with Xvfb; on macOS the lints, `make
docs-check`, architecture check, `validate_package.py`, `swift test`, the `-warnings-as-errors`
run and `make verify` (24 of 24) all pass.

Not re-run: the full 29-mutant batch (only M20); there is no mutant for `clearFromWorker`; the
committed xunit report is the earlier 51-test run. `mutations/mutations.json` records 28 killed
and 1 killed by timeout.
