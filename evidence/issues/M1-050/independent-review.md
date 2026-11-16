# M1-050 Independent Review

- Reviewer: a fresh-context review agent (Opus), started by the lead, not the implementer,
  2026-11-15.
- Target: PR #357 at `48c7125` (the first head), read-only.
- The client master plan, including its amendments h.6 and h.7, is the lead's planning document
  and is not in the repository. The decisions it settled for this issue are restated in the
  component doc and `summary.md`.

## Report

The report is verbatim, in English, as the reviewer wrote it.

> Reviewer: fresh-context Opus agent, 2026-11-15, target head 48c7125 (PR #357).
> Verdict: approve with fixes. 0 Critical, 0 High, 1 Medium, 2 Low.
> Logic correct against plan b.3/h.6/h.7: order non-modifier keys -> buttons -> modifier keys, newest first; press-time modifiers carried; every step attempted after failure; disposition empty->notRequired, no failure->completed, all failed->failed, else partial; exhaustive switch, no logging.
> MEDIUM test gap: ReleaseAllKeys.swift:68 mutant `failed == attempted` -> `failed > 0 && failed + 1 >= attempted` survived all 22 tests; only 1-of-5 and 1-step failures covered. Fix: 2-step 1-failure and 3-step 2-failure plans expecting .partial.
> LOW evidence: summary.md missing (Expected Evidence); environment.json/manual.md absent, accepted via plan e.4.
> LOW evidence: commands.json lacks the issue's required xcodebuild build command.
> Ran: swift test --filter ReleaseAllKeys -> 22 tests passed; swift format lint --strict exit 0; commands.json has no user paths. Own mutants: M1 capsLock as ordinary key killed; M2 key-up drops modifiers killed; M3 threshold survived; M4 execute dedupes/re-sorts killed.
> Not verified: full swift test, make verify, architecture/docs checks, xcodebuild.

## Resolution (`124c3e7`, and the lead's finishing commit)

| Finding | Resolution |
| --- | --- |
| Medium: `failed == attempted` mutant survived | Fixed in `124c3e7`: `oneFailureInATwoStepPlanIsPartial` and `twoFailuresInAThreeStepPlanArePartial` were added. The reviewer's mutant is recorded as R1 and killed; 16 of 16 mutants killed. |
| Low: `summary.md` missing | Written by the lead in the finishing commit (`summary.md`). |
| Low: `environment.json` and `manual.md` absent | Accepted: the hardware half is discharged by the Product Owner's 2026-11-02 decision (plan e.4); the Xvfb test of M4-024 and the owner E2E (#351) are the evidence. The PR is `Part of #64`. |
| Low: `commands.json` lacks the `xcodebuild` build | Run: `** BUILD SUCCEEDED **`, recorded in `commands.json`. |
