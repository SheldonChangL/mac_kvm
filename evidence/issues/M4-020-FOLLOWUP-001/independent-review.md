# M4-020-FOLLOWUP-001 Independent Review

- Reviewer: fresh-context Opus agent (Tier C), not the implementer
- Date: 2026-11-17
- Target: PR #370 at `a020ac2`
- Verdict: CHANGES REQUIRED; 0 Critical, 1 High, 1 Medium, 3 Low. All addressed at `fffb60f`.

## Review (verbatim)

Quoted from the lead's review record for PR #370; the `FIX:` notes in it were added by the lead after
the fixes and are not the reviewer's words.

> ## Tier C fresh-context review (Opus subagent): CHANGES REQUIRED -> fixed
> Ran focused LinuxClient|LinuxLifecycle in arm64 swift:6.2.3-jammy + Xvfb: 30 tests / 5 suites pass. No Barrier/Deskflow source opened.
> 1. HIGH: Xlib I/O error parks drain worker; ClientEffects.clearTransientState/shutdown joins drain -> hang (forever on 1-core pool). FIX: no join after display loss; other joins + injector close bounded 2s -> cleanupPartial; test: parked-drain run() returns 69.
> 2. MED: signals ignored during interactive trust prompt. FIX: prompt races signals/display loss (decline, store nothing; exit 0 / 69; stdin EOF 78); tests added.
> 3. LOW: bounded shutdown may exit with keys held. FIX: release sweep first with own 1s bound; status line on 5s timeout; documented.
> 4. LOW: ClientEnding.trustDeclined dead code. FIX: removed.
> 5. LOW: prepareGeneration 5ms poll unbounded. FIX: bounded 2000 polls (10s) -> superseded backoff failure; documented, no test (timing).
> Deviations accepted: LinuxInjectionDrain instead of CaptureQueue; root X error handler swallows; root exit 1; unusable trust store exit 78.

## Resolution

Fixes are at `fffb60f`; CI `verify-linux` and `build-test-manifest` passed at that head.

| Finding | Resolution |
| --- | --- |
| High: a drain worker parked by the Xlib I/O error handler makes the cleanup join hang | Fixed: no join after a display loss; the other joins and the injector close are bounded at 2 s and report `cleanupPartial`. Test `review: a drain worker parked by a display loss does not hang the cleanup; exit 69`; mutant M35 killed. |
| Medium: signals ignored during the interactive trust prompt | Fixed: the prompt races signals and display loss (declines and stores nothing; exit 0 or 69; stdin EOF 78). Test `review: a signal or a display loss while the prompt waits declines and exits`; mutant M36 killed. |
| Low 3: bounded shutdown may exit with keys held | Fixed: the release sweep runs first with its own 1 s bound; a status line on the 5 s timeout; documented. |
| Low 4: `ClientEnding.trustDeclined` is dead code | Removed. |
| Low 5: the `prepareGeneration` 5 ms poll is unbounded | Bounded at 2000 polls (10 s), then a superseded backoff failure; documented. No test (timing). |
| Deviations (`LinuxInjectionDrain` instead of `CaptureQueue`; root X error handler swallows; root exit 1; unusable trust store exit 78) | Accepted by the reviewer; recorded in the component doc and `summary.md`. |
