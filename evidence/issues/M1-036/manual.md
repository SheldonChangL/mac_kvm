# M1-036 Manual Verification

**Status: PENDING REVIEWER. Nothing in this document has been performed.**

The author executed no real injection, moved no cursor, and observed no OS
behavior. Every "Actual" field below is deliberately empty. The Acceptance
Criterion *Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證* is OPEN.

## Why a manual step exists at all

M1-036 adds no application wiring, so nothing in an app build can call these
`package`-level methods, and no automated test may post a `CGEvent` — posting is
the one operation that moves the real cursor. The Tier-H probe in the Exact Test
File is the executable entry point for the real path.

## Reviewer metadata to record

Date, build commit, OS product and build version, CPU architecture,
display/layout. Keyboard layout is not applicable: this Issue introduces no
keyboard behavior. Network and peer are not applicable: no connection is opened.

Do not record device unique identifiers, the user name, absolute home paths, or
any raw coordinate.

## Step 1 — `read-origin`

```sh
MACKVM_M1_036_MANUAL_PROBE=read-origin \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction
```

**Expected:** exit 0, one line `M1-036 manual probe: action=read-origin
origin=readable preparation=notAttempted move=notAttempted restore=notAttempted
cleanup=notRequired cursor=notObserved`. The cursor does not move: this action
reads the current position and injects nothing.

**Actual:**

## Step 2 — `move-and-restore`

```sh
MACKVM_M1_036_MANUAL_PROBE=move-and-restore \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction
```

**Expected, when the test process holds Accessibility trust:** exit 0, one line
`M1-036 manual probe: action=move-and-restore origin=readable
preparation=eventsPrepared move=postRequested restore=postRequested
cleanup=notRequired cursor=<observation>`. The reviewer may see a brief 24-point
nudge on both components and the cursor back where it started; the two posts
are requested back to back with no wait, so the nudge may be too brief to see.

**Expected, when it does not hold trust:** exit 1 with
`move=permission.accessibilityDenied restore=notAttempted cleanup=notRequired`,
and the cursor does not move at all. That is the fail-closed path working, not a
product defect; note it and record the trust state.

**If the line reports `cleanup=fallbackPostRequested`:** the target post was
requested but the injector's restore requested none, so the probe's cleanup-only
fallback requested the pre-created origin restore directly. The run exits 1.
Record the `restore=` value, check with your own eyes where the cursor is, and
treat it as a finding against the injector path.

**If the line reports `preparation=eventCreationFailed`:** the run stopped
before any post. The cursor did not move. The run exits 1.

**Actual:**

**Reviewer's own eyes:** did the cursor return to its original position?

## Step 3 — unknown action fails closed

```sh
MACKVM_M1_036_MANUAL_PROBE=bogus-action \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction
```

**Expected:** exit 1 with `unknown manual probe action; expected read-origin or
move-and-restore`. The unrecognized value is not echoed back, and no injection
is attempted.

**Actual:**

This step is optional for the reviewer: the same fail-closed parsing is already
covered by the always-running automated test
`manualProbeSelectionFailsClosedAndIsSkippedByDefault`, which asserts that
unset, empty and whitespace select nothing, that both exact names are accepted,
and that unknown, partial and differently-cased values are refused.

## Known limitations the reviewer should expect

1. **`cursor=` is an observation, not an assertion.** `CGEventPost` returns
   `void` and posting is asynchronous, so the probe reads the position back
   immediately and may legitimately see the pre-restore value.
   `cursor=differsFromOrigin` is therefore an expected outcome of reading too
   early and is **not** treated as a failure. Adding a sleep to make the
   read-back stable is prohibited. What the probe guarantees instead is
   ordering: both events are created before anything is posted, and once the
   target post is requested the last post it requests is the origin restore —
   through the injector, or else through the recorded cleanup-only fallback.
   That sequencing is covered by always-running automated tests that never
   post; see `tests/results.json`.
2. **Residual window.** If the test process is terminated between the target
   post request and the restore request, no probe code runs any more. The
   window is two consecutive synchronous calls with no wait between them.
3. **Edge clamping is harmless.** If the cursor starts within 24 points of a
   display edge the window server clamps it. The restore posts the exact
   original position afterwards, which was a real cursor location a moment
   earlier, so no display knowledge is needed for the restore to be correct.
4. **The probe supplies its own position resolver**, because M1-039 owns the
   real mapping. The domain point handed to `inject` is a placeholder, and
   nothing observed here is evidence about coordinate mapping, normalization,
   multi-display behavior, or Retina scaling.
5. **Identity scope.** These runs validate the production seams inside the
   SwiftPM test process, not the final application's signing identity. macOS
   Accessibility authorization is identity-specific, so a grant held by the test
   process does not transfer to a signed app bundle. That belongs to the Issue
   that wires this injector into the application shell.

## Where to record results

- `manual-result.json` — machine-readable, closed vocabulary only. It declares
  the permitted values and currently has `status: pending_reviewer` and an empty
  `runs` array.
- `manual-output.log` — create it with the probe's output lines verbatim. It does
  not exist yet, because no run has produced output; an empty placeholder is
  deliberately not committed.
