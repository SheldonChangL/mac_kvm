# M1-020 Evidence Summary

Base commit: `adf6030969f5ecc9f65de0ec768868e42888797d`
Implementation commit: `ac93145fb04d313a01ab2ad590df5d4be7432dee`
Evidence commit (round 0): `a8ce83cc1973eba396bd5a2087b8553c8e9e9e0a`
Review-fix commit (round 1): this commit, parented on
`a8ce83cc1973eba396bd5a2087b8553c8e9e9e0a`

Status: **passed**. Every command in `commands.json` was re-executed in the
round-1 session on this machine against the fixed working tree; each exit
code, timestamp, test count and gate count recorded there and below comes
from that run's output and replaces the round-0 numbers. The gate sequence
was first run against the fixed but uncommitted working tree, and
`make verify` was then re-run once against the committed fix as
`dff9081a6858187330441db0d122612f3f0adab7`: 18/18 gates passed both times,
and `artifacts/ci/m1-020-implementation-report.json` now carries that commit
SHA rather than the parent's.

## Deliverables

- `Tools/async-harness/async-harness.py`
- `Tools/async-harness/tests/test_async_harness.py`
- `docs/tooling/M1-020-async-harness.md`
- This evidence package (`summary.md`, `commands.json`,
  `tests/red-phase.json`, `tests/async-harness-tests.json`).

No other tracked file was created or modified, so the Issue stayed inside its
Exact Files list and no follow-up scope expansion was needed.

## Prior draft, and what was changed

A previous session wrote a draft of all three files but could not execute any
command, so its claims were unverified. The draft was reviewed critically and
then corrected; none of its claimed results were trusted or reused.

Defects found in the draft by running it, and fixed here:

- Rejected `spawn` calls leaked the coroutine they were handed. Running the
  draft suite emitted three `RuntimeWarning: coroutine ... was never awaited`
  reports at interpreter shutdown. `spawn` now closes the coroutine on every
  rejection path, and the suite runs clean under
  `python3 -W error::RuntimeWarning`.
- A fatal `HarnessLimitError` broke scheduling but left pending coroutines,
  sleepers and queued tasks behind. A budget violation now tears the harness
  down first: every unfinished coroutine is closed and the queues are cleared
  before the error propagates.
- There was no teardown hook at all, so any scenario ending with a suspended
  task leaked it. `Harness.close()` was added, tests route every harness
  through a closing factory (`HarnessTestCase.make_harness` with
  `addCleanup`), and `result` on a closed task fails closed with
  `task-closed`.
- Cancellation was delivered more than once: a `sleep` awaited during cleanup
  re-threw `TaskCancelled`, which a cleanup block could then swallow.
  Cancellation is now delivered exactly once, recorded once as
  `cancel-delivered`, and a cancelled task's `sleep` is elided with the clock
  frozen so cleanup always finishes inside the current `run_until_blocked`.
- `unsupported-await` and the sleep-time `clock-overflow` rejection were
  thrown back into the task, so scenario code could catch a harness contract
  violation and keep running. Both now fail the task closed without being
  thrown back, and close the task's coroutine.
- Equal sleep deadlines were tie-broken on spawn sequence, which is wrong
  whenever sleeps are scheduled in a different order than tasks are spawned.
  The tie-breaker is now the actual sleep-scheduling sequence, and
  `OrderingTests.test_equal_deadlines_follow_sleep_order_not_spawn_order`
  pins a scenario where the two orders differ.
- A task raising `TaskCancelled` without having been cancelled was reported
  as `cancelled`; it now fails closed with `spurious-cancellation`.
- The CLI defined `EXIT_USAGE` but never used it, and argparse exited `2` on a
  bad flag. Unknown arguments, a `--report` path that is a directory and a
  `--report` path that is a symlink now all exit `64`; `--help` exits `0`; the
  report write is inside the SIGTERM-handling scope.
- The draft documentation claimed the detail allowlist made the log unable to
  "carry typed text, clipboard payload, key material or any other
  reconstructable content". That is an overclaim: the allowlist bounds the
  shape of a label, not its meaning. The documentation now states exactly what
  the allowlist does and does not guarantee.

Test count went from 34 draft cases to 46.

## Review round 1: two High findings, both closed

An independent reviewer read the round-0 implementation and reproduced two
High findings. Both are real, both were reproduced locally before being
fixed, and both now have regression tests. Test count went from 46 to 56.

### High 1 - fail-fast cleanup ran outside the mutation guard

`_fail_fast` marked a task `failed` for `unsupported-await` (or the
sleep-deadline `clock-overflow`) and then called `task.coroutine.close()`
*outside* the teardown guard. The failing task's `finally` block therefore
still held full control of the harness. Reproduced locally before the fix
with a victim sleeping until clock 10 and an attacker awaiting an
unsupported awaitable whose `finally` called `advance(10)`; after
`run_until_blocked` the observed state was `now == 10` and
`victim == "completed"`, and the trace contained `sleep-expired`, the
victim's `victim-woke` note and `completed` - all produced during another
task's fail-fast cleanup. That broke fail-closed deterministic isolation and
contradicted the documented promise that cleanup cannot mutate the harness.

Fix: the single-coroutine close is now performed by one shared helper,
`Harness._close_coroutine`, which holds `_teardown_depth` for the duration of
`coroutine.close()`. Both `_fail_fast` and the `close()`/`limit-break`
teardown loop call it, so there is exactly one set of cleanup rules for every
path that closes a coroutine. `spawn`, `advance`, `run_until_blocked` and
`cancel` are all rejected with `harness-tearing-down` during a fail-fast
close; `record` keeps following the documented teardown rule. A cleanup
failure is recorded as `cleanup-failed` with the exception type name and
never replaces the task's primary failure.

Regression tests (`FailFastCleanupTests`):

- `test_unsupported_await_cleanup_cannot_mutate_the_harness` - the reviewer's
  exact probe. Asserts the reentrant `advance` observes
  `harness-tearing-down`, `now == 0`, the unrelated victim is still
  `sleeping` with `pending_sleep_count == 1` and no `victim-woke` note, and
  the attacker's `result` still raises `unsupported-await`.
- `test_clock_overflow_cleanup_cannot_mutate_the_harness` - the same probe on
  the sleep-deadline `clock-overflow` fail-fast path, which shares the
  mechanism.
- `test_fail_fast_cleanup_rejects_every_control_entry_point` - all four
  mutating entry points are rejected from one cleanup block, while `record`
  is still accepted.
- `test_fail_fast_cleanup_failure_keeps_the_primary_task_failure` - a
  `ValueError` from cleanup is recorded as `cleanup-failed` and the stored
  failure stays `unsupported-await`; an unrelated task still completes.
- `test_fail_fast_cleanup_does_not_swallow_a_budget_violation` - a cleanup
  `HarnessLimitError` is recorded and still propagates.

### High 2 - one cleanup `BaseException` abandoned the rest of teardown

`_teardown` explicitly re-raised `HarnessLimitError` from `coroutine.close()`
and otherwise caught only `Exception` and `TaskCancelled`. A cleanup block
raising `HarnessLimitError`, `KeyboardInterrupt` or `SystemExit` therefore
aborted the teardown loop, leaving every later coroutine unclosed and the
runnable queue uncleared - a direct violation of "close every unfinished
coroutine" and of the limit-break cleanup promise.

Fix: `_close_coroutine` catches `BaseException`, records `cleanup-failed`
with the type name only, and *returns* the failure instead of propagating it,
so no cleanup block can abort the caller's loop. `_teardown` keeps the first
returned failure, finishes closing every remaining task, and clears the
runnable queue and the sleeper set in a `finally`. `close()` re-raises that
first failure only after teardown is complete. `_break` discards cleanup
failures so a budget violation always propagates as its original budget
error; the discarded failures stay visible as `cleanup-failed` events.
Nothing is silently swallowed on the `close()` path, so a `KeyboardInterrupt`
or `SystemExit` raised by scenario cleanup still reaches the test runner.

Regression tests (`TeardownCleanupFailureTests`), each with two pending
coroutines where the first one's cleanup raises:

- `test_limit_error_cleanup_still_closes_the_remaining_task`
- `test_keyboard_interrupt_cleanup_still_closes_the_remaining_task`
- `test_system_exit_cleanup_still_closes_the_remaining_task`

  Each asserts both coroutines are closed, both tasks are `closed`,
  `pending_sleep_count == 0`, `active_task_names == ()`, `is_idle`, the second
  task's `closed` event is present, the first failure is recorded as
  `cleanup-failed` by type name, and `close()` re-raises that first failure.

- `test_close_reports_only_the_first_cleanup_failure` - with two raising
  cleanups, `close()` raises the first and records the second.
- `test_limit_break_preserves_its_budget_error_over_cleanup_failure` - a
  step-limit break whose first cleanup raises `HarnessLimitError` still
  propagates `step-limit-exceeded`, still closes every pending coroutine and
  still clears the queues.

### Re-audit of every remaining close path

- `spawn`'s rejection path (`_closed_quietly`) closes a coroutine that has
  never executed a line, so that close cannot run scenario cleanup and needs
  no guard. Documented as such rather than guarded unnecessarily.
- `cancel` closes nothing; it only delivers `TaskCancelled`.
- `_resume` clears `self._current` before `_handle_request` runs, so a
  fail-fast close is never skipped by the "is current task" teardown guard.
- The CLI self-check driver had the same masking shape on its error paths:
  `_build_self_check_harness` called `harness.close()` inside
  `except BaseException` and `run_self_check` closed the two harnesses in
  sequence, so a cleanup failure could replace the real error or leak the
  second harness. Both now keep the first error and still close everything,
  via `_closed_after_failure` and a `try/finally` around the paired closes.
  This is the fail-fast/teardown audit the reviewer asked for, not unrelated
  refactoring.

## Red phase

`tests/red-phase.json` records the genuine failing run. The suite was copied,
unchanged, into a temporary directory outside the repository at the same
relative path (`Tools/async-harness/tests/test_async_harness.py`) with
`Tools/async-harness/async-harness.py` deliberately absent. The repository
working tree was not modified for that run. That run predates the ten round-1
regression tests and was not repeated for them; those tests were instead
shown red by reproducing both findings against the unfixed implementation
before the fix, as described above. The command exited `1` with one
collection error: `ImportError: Failed to import test module` caused by
`FileNotFoundError` for the missing tool, raised from `load_tool()`. The
temporary directory was then removed.

The red result proves the suite cannot pass without the implementation. It
does not prove per-assertion redness, because every assertion loads the tool
by path and the module import is what fails first. That limitation is stated
in the red report rather than papered over.

## Acceptance criteria mapping

- **Focus coverage.** No arbitrary sleep: `SourcePolicyTests` asserts the tool
  source contains no `time.sleep`, `import time`, `time.monotonic`,
  `import asyncio`, `asyncio.`, `import threading`, `import random`,
  `import socket`, `import subprocess`, `import urllib`, `retry` or `poll`.
  Advanceable fake clock: `FakeClockTests`. Event ordering: `OrderingTests`.
  Cancellation: `CancellationTests`. Resource ownership: `TeardownTests`,
  `TeardownCleanupFailureTests` and `FailFastCleanupTests`.
- **Happy path.** `test_clock_starts_at_zero_and_only_moves_on_explicit_advance`,
  `test_runnable_tasks_interleave_in_deterministic_spawn_order`,
  `test_identical_scenarios_produce_identical_event_traces`,
  `test_self_check_succeeds_and_emits_a_deterministic_report`.
- **Boundary/limit.** `test_maximum_sleep_is_accepted_and_one_nanosecond_more_fails`,
  `test_clock_fails_closed_at_the_maximum_representable_time`,
  `test_zero_duration_sleep_completes_without_any_advance`, all of
  `LimitTests`, and `test_report_is_bounded_by_the_event_budget`.
- **Invalid input/failure.** All of `InvalidInputTests`, plus
  `test_unknown_argument_fails_with_a_usage_exit_code`,
  `test_report_path_that_is_a_directory_fails_closed`,
  `test_report_path_that_is_a_symlink_fails_closed` and
  `test_missing_report_directory_fails_closed`.
- **Cancel/cleanup/idempotency.** `test_cancellation_is_delivered_exactly_once`,
  `test_cancel_is_idempotent`,
  `test_cancelling_a_sleeping_task_runs_cleanup_deterministically`,
  `test_cleanup_sleep_after_cancellation_is_elided_not_awaited`,
  `test_cleanup_may_yield_after_cancellation`,
  `test_suppressing_cancellation_fails_closed`,
  `test_raising_task_cancelled_without_a_request_fails_closed`,
  `test_close_closes_unfinished_coroutines_and_is_idempotent`,
  `test_limit_break_closes_every_pending_coroutine`,
  `test_mutating_the_harness_during_teardown_fails_closed`, and all of
  `FailFastCleanupTests` and `TeardownCleanupFailureTests`.
- **No new public contract.** The harness is a repository tool. It adds no
  Swift target, no product, no protocol or wire value, no Barrier token, no
  frame, no socket, no TLS or trust behavior and no platform permission
  behavior. `Package.swift`, the workspace, every `Packages/` target and every
  CI configuration file are untouched; the new `make verify` gate appears
  purely through the pre-existing count-driven `Tools/*/tests/test_*.py`
  discovery contract.
- **Architecture, lint, build, tests.** `xcodebuild ... build` succeeded,
  `make architecture-check`, `make docs-check` and `make code-quality-check`
  (which includes `swift test -Xswiftc -warnings-as-errors`) all exited `0`,
  and `make verify` reported 18/18 gates passed. Those are the round-1
  numbers, re-run against the fixed tree. No new warning was emitted: the
  Python suite runs clean under `-W error::RuntimeWarning`, which is now the
  recorded green command rather than a separate check.
- **Privacy.** The harness performs no logging. Its event log holds only fixed
  event kinds, validated task names, exception *type* names, integer deadlines
  and integer durations; no return value, exception message, path, host name
  or caller payload is ever recorded. No example, test or evidence file in
  this Issue contains typed text, clipboard content, a credential or key
  material. The detail allowlist is documented as a shape constraint, not as a
  content classifier.

## Determinism

No test and no tool code uses a wall-clock sleep, a real timer, a retry, a
timeout-based wait, a polling loop, a thread, randomness, a network call or
real I/O. The only subprocess use is in `CommandLineTests`, which invokes the
tool itself and asserts exit codes and report contents. Ordering is pinned by
explicit assertions on the event trace, not by tolerance windows.

## Scope control

Every commit staged explicit paths; `git add -A` was never used.
`MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were never touched and
remain untracked. `artifacts/ci/m1-020-self-check.json` and
`artifacts/ci/m1-020-implementation-report.json` are gate output under the
gitignored `/artifacts/` path and are not tracked changes.

## Known limitations

- A task may only await `Harness.sleep` and `Harness.yield_now`. Anything else
  is `unsupported-await`, by design.
- There is no task-joins-task primitive; a task cannot await another task's
  completion. Dependencies are expressed through the clock and the event log.
- During cancellation cleanup the clock is frozen and a `sleep` is elided.
  A scenario that needs a cancelled task to observe real elapsed virtual time
  during cleanup cannot be written with this harness.
- `close()` re-raises only the *first* failure a cleanup block raised;
  subsequent ones are recorded as `cleanup-failed` events only. A
  `limit-break` teardown re-raises none of them, because the original budget
  error must win.
- A cleanup `BaseException` raised during a *fail-fast* close propagates out
  of `run_until_blocked` or `advance`, so a scenario whose cleanup raises
  `SystemExit` will see it there rather than in `close()`.
- If the event budget is exhausted before teardown, teardown notes are counted
  in `dropped_teardown_event_count` instead of being recorded.
- The harness is single-threaded and not safe to share across threads.
- It is tooling only. It is not linked into the application and says nothing
  about Swift concurrency behavior; the Swift side keeps using `TestKVMClock`
  from M1-018.

## Remaining risks

- The red phase is an import-level failure, not a per-assertion red run, and
  it was recorded in round 0, before the ten round-1 regression tests existed.
- Round 0 shipped with both High findings present, which is direct evidence
  that the round-0 suite did not cover reentrancy from a cleanup block. The
  ten new tests close the two reported holes; other cleanup-reentrancy shapes
  may still be uncovered.
- Every gate except `make verify` was run against the fixed working tree
  before the commit and was not re-run afterwards. The tree content is
  identical, and `git diff --check` plus the post-commit `make verify` (which
  re-runs the Python suite as a gate) cover that gap, but the earlier
  timestamps in `commands.json` predate the commit.
- The self-check scenario is fixed and covers one cancellation shape; broader
  determinism confidence comes from the unit suite, not from the CLI.
- Determinism was verified on one toolchain (Python 3.9.6, arm64 macOS). The
  harness uses no dictionary-ordering-dependent logic and no hashing, so it
  should be stable elsewhere, but that was not executed here.
- No consumer uses the harness yet, so its ergonomics are unproven against a
  real M1 test.

## Reviewer requirement

Execution tier B: this Issue may not be merged by a low-capability model
autonomously and requires a full review by a stronger model or an engineer.
The reviewer should re-run every command in `commands.json`.

## Rollback

Revert the three M1-020 commits, or delete `Tools/async-harness/`,
`docs/tooling/M1-020-async-harness.md` and `evidence/issues/M1-020/`. Tool
test discovery is count-driven, so removal drops the
`tool-test:async-harness/tests/test_async_harness.py` gate automatically and
`make verify` returns to 17 gates. No production target, contract, ADR, wire
behavior, persisted state, migration, trust state or platform input state is
involved, so rollback needs no cleanup.
