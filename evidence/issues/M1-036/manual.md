# M1-036 Manual Verification

**Status: REVIEWER VERIFIED.** The root reviewer executed the Tier-H probe on
real macOS at implementation commit
`dbc45d4e04942a03a6e73b86420801802369673f` and reported the results below. The
author, Claude Opus 5, executed no real injection, moved no cursor, observed no
OS behavior, and only transcribed the reviewer's report. The Acceptance
Criterion *Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證* is met.

Machine-readable result: `manual-result.json`. Sanitized output:
`manual-output.log`.

## Why a manual step exists at all

M1-036 adds no application wiring, so nothing in an app build can call these
`package`-level methods, and no ordinary test creates or posts a `CGEvent` —
posting is the one operation that moves the real cursor. The Tier-H probe in the
Exact Test File is the executable entry point for the real path.

## Metadata

| Field | Value |
| --- | --- |
| Date (UTC evidence time, after both probes) | `2026-09-23T01:34:27Z` |
| Build commit | `dbc45d4e04942a03a6e73b86420801802369673f` |
| Branch | `feat/m1-036-mac-mouse-move-injector` |
| OS / build | macOS 26.6.2, build 25G83 |
| CPU architecture | arm64, Apple M4 Pro |
| Display / layout | unavailable: `system_profiler` returned no per-display entries; not reconstructed |
| Keyboard layout | not applicable: this Issue introduces no keyboard behavior |
| Network / peer | not applicable: no connection is opened and no peer participates |
| Reviewer | root reviewer (the separate executor that reviews, validates and commits; not an independent external model) |

No device unique identifier, user name, absolute home path or raw coordinate is
recorded.

## Step 1 — `read-origin`

```sh
MACKVM_M1_036_MANUAL_PROBE=read-origin \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction
```

**Expected:** exit 0, one line `M1-036 manual probe: action=read-origin
origin=readable preparation=notAttempted move=notAttempted restore=notAttempted
cleanup=notRequired cursor=notObserved`. The cursor does not move.

**Actual (root reviewer):** exit 0; probe test passed in 0.025 s. Line:

```text
M1-036 manual probe: action=read-origin origin=readable preparation=notAttempted move=notAttempted restore=notAttempted cleanup=notRequired cursor=notObserved
```

**Verdict:** passed. Matches the expected line exactly.

## Step 2 — `move-and-restore`

```sh
MACKVM_M1_036_MANUAL_PROBE=move-and-restore \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction
```

**Expected, when the test process holds Accessibility trust:** exit 0, one line
`M1-036 manual probe: action=move-and-restore origin=readable
preparation=eventsPrepared move=postRequested restore=postRequested
cleanup=notRequired cursor=<observation>`.

**Actual (root reviewer):** exit 0; probe test passed in 0.057 s. Line:

```text
M1-036 manual probe: action=move-and-restore origin=readable preparation=eventsPrepared move=postRequested restore=postRequested cleanup=notRequired cursor=matchesOrigin
```

**Reviewer's own observation:** the cursor was restored, and the immediate
closed read-back also matched the original position. No cleanup fallback was
required.

**Verdict:** passed. Both events were created by the live seam before any post;
`move=postRequested` shows the injector's Accessibility trust read passed; the
origin restore was requested through the injector; `cleanup=notRequired`.

**What this does not show:** delivery. `CGEventPost` returns `void` and posting
is asynchronous, so `postRequested` is a post request and `matchesOrigin` is an
immediate observation, not a delivery guarantee.

## Step 3 — unknown action fails closed (optional)

```sh
MACKVM_M1_036_MANUAL_PROBE=bogus-action \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction
```

**Actual:** not executed. The same fail-closed parsing is covered by the
always-running ordinary test
`manualProbeSelectionFailsClosedAndIsSkippedByDefault`, which ran and passed in
the reviewer's ordinary suite (31 declared, 29 ran, 2 manual probes skipped,
0 failures).

## Cleanup and fail-safe confirmation

- The cursor ended at its original position, as observed by the reviewer.
- `cleanup=notRequired`: the injector's own restore post was requested, so the
  cleanup-only fallback did not run.
- Fail-closed denial and event-creation failure are covered by ordinary tests
  and were confirmed in the reviewer's five-axis review; they were not
  re-created on real hardware.

## Known limitations

1. **`cursor=` is an observation, not an assertion.** The probe reads the
   position back immediately; a `differsFromOrigin` read-back would be an
   expected outcome of reading too early. Adding a sleep is prohibited. This run
   observed `matchesOrigin`.
2. **Residual window.** If the test process is terminated between the target
   post request and the restore request, no probe code runs any more. The
   window is two consecutive synchronous calls with no wait between them.
3. **Edge clamping is harmless.** Near a display edge the window server clamps
   the 24-point nudge; the restore posts the exact original position.
4. **The probe supplies its own position resolver**, because M1-039 owns the
   real mapping. Nothing observed here is evidence about coordinate mapping,
   normalization, multi-display behavior or Retina scaling.
5. **Identity scope.** These runs validate the production seams inside the
   SwiftPM test process, not the final application's signing identity. macOS
   Accessibility authorization is identity-specific; that belongs to the Issue
   that wires this injector into the application shell.
6. **Live creation boundary.** Live CoreGraphics creation and posting are
   exercised only by this opt-in probe, not by ordinary unit tests, to avoid the
   clean-process CoreGraphics/TCC initialization deadlock recorded in
   `summary.md`. This is the one retained Low item.
