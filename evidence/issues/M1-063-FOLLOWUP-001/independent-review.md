# M1-063-FOLLOWUP-001 Independent Review

- Reviewer: fresh-context Opus agent, Tier C strong review
- Date: 2026-11-17
- Target: PR #368 at `559a911c`
- Verdict: APPROVE WITH CHANGES; Critical 0, High 0, Medium 1, Low 3

## Review (verbatim)

> PR #368 (M1-063-FOLLOWUP-001 ClientCoordinator) Tier C strong review — fresh-context Opus, 2026-11-17, head 559a911c
> Verdict: APPROVE WITH CHANGES. Critical 0, High 0, Medium 1, Low 3. Nothing injects after cleanup, leaves a key held, runs cleanup twice, lets old-generation events reach a new session, or puts identifiers in diagnostics.
> MEDIUM M1 ClientCoordinator.swift:201 — `guard current.claimed, !current.cleaning` in beginSession() untested; reviewer mutant removing `!current.cleaning` passed all 29 tests. newGenerationStartsOnlyAfterTheOldCleanup (tests:579) only calls beginSession before terminate and after it returns. Without the guard N's clearLedger could wipe N+1's ledger.
> LOW L1 :284-291 — second terminate during in-flight cleanup returns .skipped immediately; caller awaiting terminate before reconnect regains control before release finished. Mitigated by beginSession refusing while cleaning.
> LOW L2 :249-260 — run(_:) on a closed generation drops events but keeps reading until the stream ends.
> LOW L3 :171-174 — ledgerSnapshot doc says no identities but InputStateSnapshot includes clipboardTransaction UUID (InputStateLedger.swift:52-53); not in diagnostics.
> Declared deviations judged: (1) handle returns outcome, fails closed synchronously — acceptable, superset of b.8; (2) run(_:) maps stream ends via CleanupHooks.trigger(for:) — acceptable; (3) coordinator across generations with beginSession() — consistent with h.5, see M1; (4) inbound clipboard applied while inactive — acceptable per a.8. Limitation (failed-release only swept by injector) consistent with h.1/a.3.
> Checked no issue: terminate/handle race (claim+close under lock :284-289); old generation check :321; leave plan order then reset, failed inject keeps ledger; inbound clipboard loop guard; diagnostics counts only; scope = Exact Files + evidence; commands.json masked, Swift 6.2.3, date present.
> Reviewer runs: detached worktree, `timeout 900 swift test --filter ClientCoordinator` 29 tests/1 suite pass; swift format lint --strict exit 0. 6 mutants: M1 no close on claim killed; M2 no generation check killed; M3 beginSession allowed while cleaning SURVIVED; M4 leave without ledger reset killed; M5 no inbound loop guard killed; M6 run ignores fail-closed killed. Not verified: full KVMCore suite/cigates (relied on PR evidence), b.16 adapter, RED vs committed suite.

The reviewer's mutants M1 to M6 are its own numbering. Reviewer M3 (`beginSession()` allowed while
cleaning) is the repository mutant M15 below; the repository's `mutations.json` numbers M1 to M16
separately.

## Resolution

Fixes are at `a9a0ec5`. CI passed on both jobs, per the implementer's resolution note (no run
identifier recorded).

| Finding | Resolution |
| --- | --- |
| Medium M1 (`:201`): the `!current.cleaning` guard in `beginSession()` is untested | Fixed: new test `beginSessionWaitsForAnInFlightCleanup` holds the cleanup in the injector sweep; a late `terminate` returns `ran == false`, `beginSession()` returns false, and after the release it returns true. The reviewer's surviving mutant is repository mutant M15 and is now killed. |
| Low L1 (`:284-291`): a second `terminate` returns `.skipped` without waiting | Documented: the `terminate` doc and the component doc say a later `terminate` returns skipped without waiting; the composition root must await its own `terminate` and treat `beginSession() == false` as wait, then retry. Listed as a known limitation. |
| Low L2 (`:249-260`): `run(_:)` keeps reading a closed generation's stream | Fixed: `run` stops once its generation is closed; new test `runStopsReadingOnceItsGenerationIsClosed` kills mutant M16. |
| Low L3 (`:171-174`): the `ledgerSnapshot` doc says no identities but it carries the clipboard transaction ID | Fixed: the comment and the doc now say there are no key or button identities and that it carries an opaque clipboard transaction ID that must not be logged. |

Gates after the fixes: `ClientCoordinator` filter 31 of 31 tests; full `swift test` 332 tests in 29
suites in both modes (plain and `-Xswiftc -warnings-as-errors`); mutations 16 of 16 killed (the
runner now records a timeout as killed); `make verify` 24 of 24; `swift format lint --strict`, `make
docs-check`, `make architecture-check`, `python3 Tools/Backlog/validate_package.py` and `xcodebuild`
exit 0.

Not re-run by a second reviewer: the fixes were not reviewed again after `a9a0ec5`. The reviewer's
own 6-mutant batch was not re-run; the repository's 16-mutant batch was.
