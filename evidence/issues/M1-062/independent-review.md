# M1-062 Independent Review

- Reviewer: a fresh-context review agent (Opus), started by the lead, not the implementer,
  2026-11-15.
- Target: PR #358 at `6ff5368` (the first head), in a read-only detached worktree.
- The client master plan, including its amendments h.1 and h.6, is the lead's planning document
  and is not in the repository. The decisions it settled for this issue are restated in the
  component doc and `summary.md`.

## Report

The report is verbatim, in English, as the reviewer wrote it.

> Reviewer: fresh-context Opus agent, 2026-11-15, target PR #358 first head 6ff5368.
> Verdict: mergeable after fixes. 0 Critical / 0 High / 2 Medium / 2 Low.
> MEDIUM 1 InputStateLedger.swift:151-158: an overflowed key (not recorded) pressed again is injected again and counted again; its repeat (line 160) is dropped as .dropUnheldRepeat, so autorepeat silently dies under overflow.
> MEDIUM 2 :162 and :180: releasing an overflowed key does not decrement overflowedKeyCount, so hasOverflowed stays true until reset(); every later cleanup reports cleanupPartial. Matches plan b.2 "counted overflow" but undocumented.
> LOW 3 :97-103: init bounds/defaults beyond plan API (plan says init()). Removing max(0, …) clamp survives (equivalent mutant); the line 96 claim is untested.
> LOW 4 :39-42, 50: extra snapshot fields overflowedKeyCount, overflowedButtonCount, hasOverflowed are counts only, no identity, FD8 not violated; plan b.2 asks the snapshot to flag overflow; suggest recording them as an amendment.
> OK: only .inject/.injectUnheldRelease key events reach the modifier ledger (line 110); thread-safety claim consistent with b.2; doc carries h.1/h.6 queue note (75-77); commands.json has no user paths.
> Ran (detached worktree of pull/358/head): swift test --filter InputStateLedger 20 tests passed incl. property test; mutants M1 bound < to <= killed (400 issues), M2 modifiers applied regardless killed (1), M3 clamp removed survived (equivalent), M4 overflow not counted killed (6); swift format lint --strict exit 0.
> Not verified: RED vs committed tests, scope limited to Exact Files, per-AC pass/fail.

## Resolution (`44da49d`, and the lead's finishing commit)

| Finding | Resolution |
| --- | --- |
| Medium 1: an overflowed key pressed again is injected and counted again; its repeat is dropped | Fixed in `44da49d`: overflowed keys and buttons are kept in a separate overflow set with the same bound. A duplicate down gives `dropDuplicateDown`, a repeat is injected. Mutants R-M1a and R-M1b are recorded and killed. |
| Medium 2: releasing an overflowed key does not decrement the overflow count, so `hasOverflowed` stays true until `reset()` | Fixed in `44da49d`: a release is injected and removed from the overflow set, and `hasOverflowed` clears. Presses beyond the overflow set are counted in `untrackedKeyCount` and `untrackedButtonCount` until `reset()`, which the doc now documents. Mutants R-M2 and R-M2b are recorded and killed. |
| Low 3: init bounds and defaults go beyond the plan's `init()`; the clamp mutant survives | `aNegativeBoundBehavesAsZero` was added; mutant R-L3 is recorded and killed. The doc lists the init as deliberate. |
| Low 4: extra snapshot fields beyond the plan | The doc notes the fields as deliberate: counts only, no identity, as the plan's bound rule requires the snapshot to flag overflow. |
| Not verified by the reviewer: RED against the committed tests, scope limited to the Exact Files, per-criterion pass or fail | Covered by `summary.md` (RED, Acceptance mapping) from the lead's finishing commit. 20 of 20 mutants killed at `44da49d`. |
