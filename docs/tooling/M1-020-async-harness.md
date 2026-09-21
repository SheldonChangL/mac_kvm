# M1-020 Deterministic Async Test Harness

## Outcome

`Tools/async-harness/async-harness.py` provides a deterministic cooperative
scheduler with an explicitly advanced fake clock, so tooling tests can assert
exact event ordering, cancellation and cleanup without any wall-clock wait,
timing tolerance, polling loop or repeated attempt.

The harness is repository tooling written with the Python standard library
only. It adds no production contract, no protocol or wire value, no Barrier
token, no UI or platform behavior, and no TLS or trust behavior.

## Interface

The module exposes exactly one control object plus its typed errors.

```text
Harness(max_tasks=64, max_steps=10000, max_events=1024)

  now                          -> int      virtual nanoseconds, starts at 0
  events                       -> tuple    append-only ordered log
  pending_sleep_count          -> int      tasks waiting on the clock
  is_idle                      -> bool     no runnable task remains
  active_task_names            -> tuple    non-terminal tasks, spawn order
  dropped_teardown_event_count -> int      notes dropped during teardown

  spawn(name, coroutine)        -> str
  sleep(duration_nanoseconds)   -> awaitable
  yield_now()                   -> awaitable
  record(label, task="")        -> None
  run_until_blocked()           -> None
  advance(duration_nanoseconds) -> None
  cancel(name)                  -> None
  close()                       -> None
  state(name)  -> "runnable" | "sleeping" | "completed" | "failed"
                | "cancelled" | "closed"
  result(name) -> value, or raises the stored failure
```

`Event` is a named tuple of `sequence`, `time_nanoseconds`, `kind`, `task`
and `detail`. Event kinds are `spawned`, `sleep-scheduled`, `sleep-expired`,
`sleep-elided`, `cancel-requested`, `cancel-delivered`, `cancelled`,
`completed`, `failed`, `closed`, `cleanup-failed` and `note`.

Terminal states are `completed`, `failed`, `cancelled` and `closed`.

## Exact semantics

- Time only moves inside `advance`. Nothing in the harness reads wall-clock,
  monotonic or calendar time, and nothing suspends a real thread.
- `run_until_blocked` drains the runnable queue in first-in, first-out order
  until every task is terminal or waiting on the clock. `advance` moves the
  clock first and then drains.
- Sleepers due at the same clock value are woken ordered by
  `(deadline, sleep-scheduling sequence)`. The tie-breaker is the order in
  which the sleeps were actually scheduled, which is not always spawn order: a
  task that yields before sleeping schedules its sleep later than a task that
  sleeps immediately, and therefore wakes after it. The ordering never depends
  on dictionary or set iteration order.
- `sleep(0)` still suspends the task, but its deadline is already reached, so
  it resumes inside the same `run_until_blocked` call without any advance.
- `cancel` records `cancel-requested` once, removes the task from the sleeper
  set, and delivers `TaskCancelled` at the task's suspension point on the next
  scheduling turn. The delivery is recorded once as `cancel-delivered` and
  happens exactly once per task. Cancelling an unknown task raises
  `task-not-found`; cancelling an already cancelled, already requested or
  terminal task is a no-op, so `cancel` is idempotent.
- Cleanup after cancellation may await `yield_now` and may await `sleep`. The
  clock is frozen for a cancelled task: its `sleep` resolves immediately and
  is recorded as `sleep-elided` with the requested duration, so cleanup always
  finishes inside the current `run_until_blocked` call and can never stall on
  a clock that the test never advances. Cancellation is not re-delivered at
  those suspension points.
- A task that catches `TaskCancelled` and returns normally fails closed with
  `cancellation-suppressed` instead of being reported as completed. A task
  that raises `TaskCancelled` without having been cancelled fails closed with
  `spurious-cancellation`.
- A task that raises is isolated: it becomes `failed`, its exception is stored
  for `result`, and every other task keeps running.
- Awaiting anything other than `sleep` or `yield_now` fails that task closed
  with `unsupported-await`. A sleep whose deadline would leave the clock range
  fails that task closed with `clock-overflow`. Neither rejection is thrown
  back into the task, and the task's coroutine is closed immediately, so
  scenario code cannot catch a harness contract violation and keep running.
  That immediate close runs under the same mutation guard as `close()`, so the
  rejected task's `finally` block cannot advance the clock, spawn, drain the
  runnable queue or cancel an unrelated task on its way out: those calls are
  rejected with `harness-tearing-down` exactly as during teardown. A rejected
  task therefore cannot wake, complete or cancel any other task, and its own
  stored failure stays the rejection code even if its cleanup block raises.

## Resource ownership and teardown

- `spawn` closes the coroutine it was handed on every rejection path, so a
  rejected `spawn` never leaves a coroutine that "was never awaited".
- `close()` closes every unfinished coroutine, marks those tasks `closed`,
  records one `closed` event each, clears the runnable queue and the sleeper
  set, and is safe to call repeatedly. `result` on a closed task raises
  `task-closed`. Tests are expected to call it, for example through
  `addCleanup`, so no scenario can leak a suspended coroutine.
- A `HarnessLimitError` budget violation performs the same teardown before it
  propagates, so a broken harness leaves no pending coroutine, sleeper or
  queued task behind. Every later call then raises `harness-broken`.
- Cleanup code runs while the harness is tearing down. During teardown the
  harness rejects `spawn`, `advance`, `run_until_blocked` and `cancel` with
  `harness-tearing-down`, still accepts `record`, and if the event budget is
  already exhausted it counts the dropped note in
  `dropped_teardown_event_count` instead of raising from inside a `finally`
  block. The same guard covers the single-coroutine close that
  `unsupported-await` and `clock-overflow` perform, so there is exactly one
  set of cleanup rules for every path that closes a coroutine.
- A cleanup block that itself raises is recorded as `cleanup-failed` with the
  exception type name only, never a message. No cleanup failure — not an
  `Exception`, not a `HarnessLimitError`, not a `KeyboardInterrupt` or
  `SystemExit` — can abort the teardown loop: the remaining coroutines are
  still closed and the runnable queue and sleeper set are still cleared.
  `close()` then re-raises the *first* cleanup failure, after teardown is
  complete. A `limit-break` teardown discards cleanup failures instead, so a
  budget violation always propagates as its original budget error; the
  discarded failures remain visible as `cleanup-failed` events.
- A fail-fast close reports differently, because the task already has a
  primary failure to preserve: an ordinary `Exception` or `TaskCancelled` from
  its cleanup block is recorded and dropped, while a cleanup `BaseException`
  is recorded and then propagates out of `run_until_blocked` or `advance`, so
  a budget violation or a keyboard interrupt is never swallowed. Either way
  the task's stored failure remains the original rejection code.
- `spawn` closes a rejected coroutine before it has run a single line, so that
  close cannot execute scenario cleanup and needs no guard.

## Limits and fail-closed validation

| Bound | Value | Violation |
|---|---|---|
| Tasks per harness | 64 | `task-limit-exceeded` |
| Scheduler steps per harness | 10000 | `step-limit-exceeded` |
| Events per harness | 1024 | `event-limit-exceeded` |
| Single sleep | 3600000000000 ns | `invalid-duration` |
| Clock value | 86400000000000 ns | `clock-overflow` |
| Task name | `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` | `invalid-name` |
| Event detail | `[A-Za-z0-9][A-Za-z0-9._:-]{0,63}` | `invalid-detail` |

`HarnessError` is a recoverable rejection carrying a stable `code`.
`HarnessLimitError` derives from `BaseException` so a budget violation cannot
be swallowed by scenario code.

Durations and limits must be plain `int`. `bool`, `float`, `str` and `None`
are rejected, so an accidental `True` is never read as `1`.

## What the detail allowlist does and does not claim

The event detail allowlist bounds the *shape* of every recorded label: at most
64 characters, no whitespace, and only `A-Z a-z 0-9 . _ : -`. That makes the
log unable to carry prose, base64 or JSON payloads, multi-line content or
arbitrary punctuation, and it makes the trace comparable byte for byte.

It is not a content classifier. A caller that deliberately passes a short
secret-shaped token as a label would still have it recorded. Scenario authors
own what they put in a label; the harness only guarantees the label is short,
single-line and character-restricted. The harness itself never records a
task's return value, an exception message, a path, a host name or any caller
data: internal details are limited to fixed codes, exception type names,
integer deadlines and durations.

## Command line

```bash
python3 Tools/async-harness/async-harness.py [--report PATH]
```

The tool runs a fixed self-check scenario twice in two independent harnesses
and compares the two event traces plus the end-state invariants, then closes
both harnesses. Exit codes: `0` deterministic, `1` trace or invariant
mismatch or report write failure, `64` unknown argument or a `--report` path
that is a directory or a symlink, `66` report parent directory missing, `130`
cancelled by SIGINT or SIGTERM. With `--report` it writes the
machine-readable trace as sorted, indented JSON; the trace is bounded by the
event budget, so the report size is bounded too.

## Test discovery

`Tools/async-harness/tests/test_async_harness.py` matches the existing
`Tools/*/tests/**/test_*.py` contract documented in
`docs/tooling/M1-CI-002-tool-test-discovery.md`, so `make verify` picks it up
as gate `tool-test:async-harness/tests/test_async_harness.py` without any CI
change.

## Limitations

- The harness runs its own scheduler and does not use `asyncio`. A task may
  only await `Harness.sleep` and `Harness.yield_now`; awaiting an `asyncio`
  primitive, a thread, a subprocess or real I/O is rejected as
  `unsupported-await`. This is deliberate: real I/O would reintroduce
  nondeterminism.
- Time is integer nanoseconds. There is no duration type, no calendar time
  and no timezone handling.
- There is no task-joins-task primitive: a task cannot await another task's
  completion. Tests express dependencies through the clock and the event log.
- The harness is single-threaded and not safe to share across threads.
- It is a tooling test double only; it is not linked into the application and
  states nothing about Swift concurrency behavior. The Swift side keeps using
  `TestKVMClock` from M1-018.

## Rollback

Delete `Tools/async-harness/` and `docs/tooling/M1-020-async-harness.md`, or
revert the M1-020 commits. Nothing else depends on the harness, tool test
discovery is count-driven rather than name-driven, and no production target,
contract or CI configuration is touched, so rollback is a clean removal.
