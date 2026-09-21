# M1-020 Evidence Summary

Base commit: `adf6030969f5ecc9f65de0ec768868e42888797d`
Implementation commit: `ac93145fb04d313a01ab2ad590df5d4be7432dee`

Status: **passed**. Every command in `commands.json` was executed in this
session on this machine; each exit code, timestamp, test count and gate count
recorded there and below comes from that run's output.

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

## Red phase

`tests/red-phase.json` records the genuine failing run. The suite was copied,
unchanged, into a temporary directory outside the repository at the same
relative path (`Tools/async-harness/tests/test_async_harness.py`) with
`Tools/async-harness/async-harness.py` deliberately absent. The repository
working tree was not modified for that run. The command exited `1` with one
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
  Cancellation: `CancellationTests`. Resource ownership: `TeardownTests`.
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
  `test_mutating_the_harness_during_teardown_fails_closed`.
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
  and `make verify` reported 18/18 gates passed. No new warning was emitted:
  the Python suite runs clean under `-W error::RuntimeWarning`.
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
  subsequent ones are recorded as `cleanup-failed` events only.
- If the event budget is exhausted before teardown, teardown notes are counted
  in `dropped_teardown_event_count` instead of being recorded.
- The harness is single-threaded and not safe to share across threads.
- It is tooling only. It is not linked into the application and says nothing
  about Swift concurrency behavior; the Swift side keeps using `TestKVMClock`
  from M1-018.

## Remaining risks

- The red phase is an import-level failure, not a per-assertion red run.
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

Revert the two M1-020 commits, or delete `Tools/async-harness/`,
`docs/tooling/M1-020-async-harness.md` and `evidence/issues/M1-020/`. Tool
test discovery is count-driven, so removal drops the
`tool-test:async-harness/tests/test_async_harness.py` gate automatically and
`make verify` returns to 17 gates. No production target, contract, ADR, wire
behavior, persisted state, migration, trust state or platform input state is
involved, so rollback needs no cleanup.
