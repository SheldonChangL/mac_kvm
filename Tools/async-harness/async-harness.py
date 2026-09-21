#!/usr/bin/env python3

"""Deterministic async test harness for MacKVM tooling tests.

The harness runs cooperative coroutines on an explicit, manually advanced
virtual clock. It never consults wall-clock time, never suspends a real
thread, and never re-attempts an operation on its own, so event ordering and
cancellation are reproducible byte for byte.
"""

import argparse
import inspect
import json
import re
import signal
import sys
from collections import deque
from pathlib import Path
from typing import Any, Dict, List, NamedTuple, Optional, Tuple


REPORT_SCHEMA_VERSION = 1

EXIT_FAILURE = 1
EXIT_USAGE = 64
EXIT_NOT_FOUND = 66
EXIT_CANCELLED = 130

MAX_TASK_COUNT = 64
MAX_STEP_COUNT = 10000
MAX_EVENT_COUNT = 1024
MAX_SLEEP_NANOSECONDS = 3600 * 1000 * 1000 * 1000
MAX_CLOCK_NANOSECONDS = 24 * 3600 * 1000 * 1000 * 1000

TERMINAL_STATES = frozenset({"completed", "failed", "cancelled", "closed"})

_NAME_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_DETAIL_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\Z")

_SELF_CHECK_FINAL_CLOCK_NANOSECONDS = 40


class HarnessError(Exception):
    """A typed, recoverable harness rejection carrying a stable code."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class HarnessLimitError(BaseException):
    """A budget violation that must not be swallowed by scenario code."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class TaskCancelled(BaseException):
    """Delivered into a task at its suspension point when cancelled."""


class Event(NamedTuple):
    sequence: int
    time_nanoseconds: int
    kind: str
    task: str
    detail: str


class _Request:
    """An awaitable that hands one scheduler request to the harness."""

    def __init__(self, payload: Tuple[Any, ...]) -> None:
        self._payload = payload

    def __await__(self):
        yield self._payload
        return None


class _Task:
    def __init__(self, name: str, coroutine: Any, sequence: int) -> None:
        self.name = name
        self.coroutine = coroutine
        self.sequence = sequence
        self.state = "runnable"
        self.value = None  # type: Any
        self.failure = None  # type: Optional[BaseException]
        self.cancel_requested = False
        self.cancel_delivered = False
        self.pending_throw = None  # type: Optional[BaseException]
        self.deadline = None  # type: Optional[int]
        self.sleep_sequence = None  # type: Optional[int]


def _validated_limit(value: Any, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise HarnessError("invalid-limit")
    if value < minimum or value > maximum:
        raise HarnessError("invalid-limit")
    return value


def _validated_duration(value: Any, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise HarnessError("invalid-duration")
    if value < 0 or value > maximum:
        raise HarnessError("invalid-duration")
    return value


def _validated_name(value: Any) -> str:
    if not isinstance(value, str) or _NAME_PATTERN.match(value) is None:
        raise HarnessError("invalid-name")
    return value


def _validated_detail(value: Any) -> str:
    if not isinstance(value, str) or _DETAIL_PATTERN.match(value) is None:
        raise HarnessError("invalid-detail")
    return value


def _safe_detail(value: str) -> str:
    if _DETAIL_PATTERN.match(value) is None:
        return "unclassified"
    return value


def _closed_quietly(coroutine: Any) -> None:
    """Closes a coroutine the harness rejected before it ever ran."""
    if inspect.iscoroutine(coroutine):
        coroutine.close()


class Harness:
    """A single-threaded scheduler plus the fake clock it advances."""

    def __init__(
        self,
        max_tasks: Any = MAX_TASK_COUNT,
        max_steps: Any = MAX_STEP_COUNT,
        max_events: Any = MAX_EVENT_COUNT,
    ) -> None:
        self._max_tasks = _validated_limit(max_tasks, 1, MAX_TASK_COUNT)
        self._max_steps = _validated_limit(max_steps, 1, MAX_STEP_COUNT)
        self._max_events = _validated_limit(max_events, 1, MAX_EVENT_COUNT)
        self._now = 0
        self._steps = 0
        self._sequence = 0
        self._spawn_sequence = 0
        self._sleep_sequence = 0
        self._broken = False
        self._teardown_depth = 0
        self._dropped_teardown_events = 0
        self._current = None  # type: Optional[_Task]
        self._tasks = {}  # type: Dict[str, _Task]
        self._order = []  # type: List[str]
        self._runnable = deque()  # type: deque
        self._sleepers = []  # type: List[_Task]
        self._events = []  # type: List[Event]

    # Observation surface -------------------------------------------------

    @property
    def now(self) -> int:
        """Virtual monotonic time in nanoseconds; only `advance` moves it."""
        return self._now

    @property
    def events(self) -> Tuple[Event, ...]:
        return tuple(self._events)

    @property
    def pending_sleep_count(self) -> int:
        return len(self._sleepers)

    @property
    def is_idle(self) -> bool:
        return not self._runnable

    @property
    def active_task_names(self) -> Tuple[str, ...]:
        return tuple(
            name
            for name in self._order
            if self._tasks[name].state not in TERMINAL_STATES
        )

    @property
    def dropped_teardown_event_count(self) -> int:
        """Teardown notes dropped because the event budget was exhausted."""
        return self._dropped_teardown_events

    def state(self, name: Any) -> str:
        return self._lookup(name).state

    def result(self, name: Any) -> Any:
        task = self._lookup(name)
        if task.state not in TERMINAL_STATES:
            raise HarnessError("task-not-finished")
        if task.state == "cancelled":
            raise HarnessError("task-cancelled")
        if task.state == "closed":
            raise HarnessError("task-closed")
        if task.state == "failed":
            raise task.failure
        return task.value

    # Awaitables ----------------------------------------------------------

    def sleep(self, duration_nanoseconds: Any) -> _Request:
        """Suspends the calling task until the clock reaches its deadline."""
        duration = _validated_duration(
            duration_nanoseconds, MAX_SLEEP_NANOSECONDS
        )
        return _Request(("sleep", duration))

    def yield_now(self) -> _Request:
        """Suspends the calling task for exactly one scheduling turn."""
        return _Request(("yield",))

    # Control surface -----------------------------------------------------

    def spawn(self, name: Any, coroutine: Any) -> str:
        try:
            self._require_operational()
            validated_name = _validated_name(name)
            if not inspect.iscoroutine(coroutine):
                raise HarnessError("invalid-coroutine")
            if validated_name in self._tasks:
                raise HarnessError("duplicate-task-name")
            if len(self._tasks) >= self._max_tasks:
                raise HarnessError("task-limit-exceeded")
        except (HarnessError, HarnessLimitError):
            _closed_quietly(coroutine)
            raise

        task = _Task(validated_name, coroutine, self._spawn_sequence)
        self._spawn_sequence += 1
        self._tasks[validated_name] = task
        self._order.append(validated_name)
        self._runnable.append(task)
        self._record("spawned", validated_name, "")
        return validated_name

    def record(self, label: Any, task: str = "") -> None:
        """Appends one allowlisted metadata note to the event log."""
        if self._teardown_depth == 0:
            self._require_operational()
        detail = _validated_detail(label)
        if task != "":
            self._lookup(task)
        self._record("note", task, detail)

    def run_until_blocked(self) -> None:
        """Runs every runnable task until only clock waits remain."""
        self._require_operational()
        while True:
            self._wake_due_sleepers()
            if not self._runnable:
                return
            self._resume(self._runnable.popleft())

    def advance(self, duration_nanoseconds: Any) -> None:
        """Moves the fake clock forward, then drains newly runnable work."""
        self._require_operational()
        duration = _validated_duration(
            duration_nanoseconds, MAX_CLOCK_NANOSECONDS
        )
        if self._now + duration > MAX_CLOCK_NANOSECONDS:
            raise HarnessError("clock-overflow")
        self._now += duration
        self.run_until_blocked()

    def cancel(self, name: Any) -> None:
        """Requests cancellation once; later calls are no-ops."""
        self._require_operational()
        task = self._lookup(name)
        if task.state in TERMINAL_STATES or task.cancel_requested:
            return

        task.cancel_requested = True
        self._record("cancel-requested", task.name, "")
        if task.state == "sleeping":
            self._sleepers.remove(task)
            task.deadline = None
            task.sleep_sequence = None
        task.pending_throw = TaskCancelled()
        task.state = "runnable"
        if task not in self._runnable:
            self._runnable.append(task)

    def close(self) -> None:
        """Closes every unfinished coroutine; safe to call repeatedly."""
        failure = self._teardown("teardown")
        if failure is not None:
            raise failure

    # Internals -----------------------------------------------------------

    def _lookup(self, name: Any) -> _Task:
        if not isinstance(name, str) or name not in self._tasks:
            raise HarnessError("task-not-found")
        return self._tasks[name]

    def _require_operational(self) -> None:
        if self._teardown_depth > 0:
            raise HarnessError("harness-tearing-down")
        if self._broken:
            raise HarnessLimitError("harness-broken")

    def _consume_step(self) -> None:
        self._steps += 1
        if self._steps > self._max_steps:
            self._break("step-limit-exceeded")

    def _break(self, code: str) -> None:
        self._broken = True
        self._teardown("limit-break")
        raise HarnessLimitError(code)

    def _teardown(self, reason: str) -> Optional[BaseException]:
        self._teardown_depth += 1
        first_failure = None  # type: Optional[BaseException]
        try:
            for name in list(self._order):
                task = self._tasks[name]
                if task.state in TERMINAL_STATES or task is self._current:
                    continue
                if task in self._sleepers:
                    self._sleepers.remove(task)
                task.deadline = None
                task.sleep_sequence = None
                task.pending_throw = None
                task.state = "closed"
                self._record("closed", task.name, reason)
                try:
                    task.coroutine.close()
                except HarnessLimitError:
                    raise
                except (Exception, TaskCancelled) as error:  # noqa: BLE001
                    self._record(
                        "cleanup-failed",
                        task.name,
                        _safe_detail(type(error).__name__),
                    )
                    if first_failure is None:
                        first_failure = error
            self._runnable.clear()
        finally:
            self._teardown_depth -= 1
        return first_failure

    def _record(self, kind: str, task: str, detail: str) -> None:
        if len(self._events) >= self._max_events:
            if self._teardown_depth > 0:
                self._dropped_teardown_events += 1
                return
            self._break("event-limit-exceeded")
        self._events.append(Event(self._sequence, self._now, kind, task, detail))
        self._sequence += 1

    def _wake_due_sleepers(self) -> None:
        due = [task for task in self._sleepers if task.deadline <= self._now]
        if not due:
            return
        due.sort(key=lambda task: (task.deadline, task.sleep_sequence))
        for task in due:
            self._sleepers.remove(task)
            self._record("sleep-expired", task.name, str(task.deadline))
            task.deadline = None
            task.sleep_sequence = None
            task.state = "runnable"
            self._runnable.append(task)

    def _resume(self, task: _Task) -> None:
        self._consume_step()
        throwable = task.pending_throw
        task.pending_throw = None
        if isinstance(throwable, TaskCancelled):
            task.cancel_delivered = True
            self._record("cancel-delivered", task.name, "")

        self._current = task
        try:
            if throwable is None:
                request = task.coroutine.send(None)
            else:
                request = task.coroutine.throw(throwable)
        except StopIteration as stop:
            if task.cancel_delivered:
                self._finish_failed(
                    task,
                    HarnessError("cancellation-suppressed"),
                    "cancellation-suppressed",
                )
                return
            task.state = "completed"
            task.value = stop.value
            self._record("completed", task.name, "")
            return
        except TaskCancelled:
            if not task.cancel_delivered:
                self._finish_failed(
                    task,
                    HarnessError("spurious-cancellation"),
                    "spurious-cancellation",
                )
                return
            task.state = "cancelled"
            self._record("cancelled", task.name, "")
            return
        except HarnessError as error:
            self._finish_failed(task, error, error.code)
            return
        except Exception as error:  # noqa: BLE001 - scenario failures are data
            self._finish_failed(task, error, type(error).__name__)
            return
        finally:
            self._current = None

        self._handle_request(task, request)

    def _finish_failed(
        self, task: _Task, failure: BaseException, detail: str
    ) -> None:
        task.state = "failed"
        task.failure = failure
        self._record("failed", task.name, _safe_detail(detail))

    def _fail_fast(self, task: _Task, error: HarnessError) -> None:
        """Fails a task the scheduler refuses to resume, and closes it.

        The rejection is never thrown back into the task, so scenario code
        cannot catch a harness contract violation and keep running.
        """
        self._finish_failed(task, error, error.code)
        try:
            task.coroutine.close()
        except HarnessLimitError:
            raise
        except (Exception, TaskCancelled) as cleanup_error:  # noqa: BLE001
            self._record(
                "cleanup-failed",
                task.name,
                _safe_detail(type(cleanup_error).__name__),
            )

    def _handle_request(self, task: _Task, request: Any) -> None:
        if isinstance(request, tuple) and request == ("yield",):
            task.state = "runnable"
            self._runnable.append(task)
            return

        if (
            isinstance(request, tuple)
            and len(request) == 2
            and request[0] == "sleep"
            and isinstance(request[1], int)
            and not isinstance(request[1], bool)
        ):
            if task.cancel_delivered:
                self._record("sleep-elided", task.name, str(request[1]))
                task.state = "runnable"
                self._runnable.append(task)
                return
            deadline = self._now + request[1]
            if deadline > MAX_CLOCK_NANOSECONDS:
                self._fail_fast(task, HarnessError("clock-overflow"))
                return
            task.deadline = deadline
            task.sleep_sequence = self._sleep_sequence
            self._sleep_sequence += 1
            task.state = "sleeping"
            self._sleepers.append(task)
            self._record("sleep-scheduled", task.name, str(deadline))
            return

        self._fail_fast(task, HarnessError("unsupported-await"))


# Self-check scenario -----------------------------------------------------


async def _self_check_writer(harness: Harness) -> None:
    harness.record("start", task="writer")
    await harness.sleep(10)
    harness.record("wrote", task="writer")
    await harness.sleep(30)
    harness.record("done", task="writer")


async def _self_check_reader(harness: Harness) -> None:
    harness.record("start", task="reader")
    await harness.sleep(20)
    harness.record("read", task="reader")


async def _self_check_cleaner(harness: Harness) -> None:
    try:
        await harness.sleep(50)
    finally:
        harness.record("cleanup", task="cleaner")


def _build_self_check_harness() -> Harness:
    harness = Harness()
    try:
        harness.spawn("writer", _self_check_writer(harness))
        harness.spawn("reader", _self_check_reader(harness))
        harness.spawn("cleaner", _self_check_cleaner(harness))
        harness.run_until_blocked()
        harness.advance(10)
        harness.advance(10)
        harness.cancel("cleaner")
        harness.run_until_blocked()
        harness.advance(20)
    except BaseException:
        harness.close()
        raise
    return harness


def _event_payload(event: Event) -> Dict[str, Any]:
    return {
        "sequence": event.sequence,
        "timeNanoseconds": event.time_nanoseconds,
        "kind": event.kind,
        "task": event.task,
        "detail": event.detail,
    }


def _invariants_hold(harness: Harness) -> bool:
    return (
        harness.now == _SELF_CHECK_FINAL_CLOCK_NANOSECONDS
        and harness.pending_sleep_count == 0
        and harness.active_task_names == ()
        and harness.is_idle
        and harness.dropped_teardown_event_count == 0
        and harness.state("writer") == "completed"
        and harness.state("reader") == "completed"
        and harness.state("cleaner") == "cancelled"
    )


def run_self_check() -> Dict[str, Any]:
    first = _build_self_check_harness()
    second = _build_self_check_harness()
    first_events = [_event_payload(event) for event in first.events]
    second_events = [_event_payload(event) for event in second.events]
    report = {
        "schemaVersion": REPORT_SCHEMA_VERSION,
        "tool": "async-harness",
        "scenario": "self-check",
        "deterministic": first_events == second_events,
        "invariantsHold": _invariants_hold(first) and _invariants_hold(second),
        "clockNanoseconds": first.now,
        "events": first_events,
    }
    first.close()
    second.close()
    return report


def handle_termination_signal(signum, frame) -> None:
    del signum, frame
    raise KeyboardInterrupt


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(
        description="Run the MacKVM deterministic async harness self-check"
    )
    parser.add_argument("--report", default=None)
    return parser.parse_args(arguments)


def _write_report(report_path: Path, report: Dict[str, Any]) -> int:
    if report_path.name == "" or report_path.is_dir():
        print(
            "report path is not a writable file: {0}".format(report_path),
            file=sys.stderr,
        )
        return EXIT_USAGE
    if report_path.is_symlink():
        print(
            "report path is a symlink: {0}".format(report_path),
            file=sys.stderr,
        )
        return EXIT_USAGE
    if not report_path.parent.is_dir() or report_path.parent.is_symlink():
        print(
            "report directory does not exist: {0}".format(report_path.parent),
            file=sys.stderr,
        )
        return EXIT_NOT_FOUND
    try:
        report_path.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n"
        )
    except OSError:
        print("report write failed", file=sys.stderr)
        return EXIT_FAILURE
    return 0


def main(arguments=None) -> int:
    try:
        options = parse_arguments(arguments)
    except SystemExit as exit_request:
        if exit_request.code in (0, None):
            return 0
        return EXIT_USAGE

    previous_sigterm_handler = signal.signal(
        signal.SIGTERM, handle_termination_signal
    )
    try:
        report = run_self_check()
        if options.report is not None:
            write_status = _write_report(Path(options.report), report)
            if write_status != 0:
                return write_status
    except HarnessError as error:
        print(
            "async harness self-check failed: {0}".format(error.code),
            file=sys.stderr,
        )
        return EXIT_FAILURE
    except HarnessLimitError as error:
        print(
            "async harness self-check failed: {0}".format(error.code),
            file=sys.stderr,
        )
        return EXIT_FAILURE
    except KeyboardInterrupt:
        print("async harness self-check cancelled", file=sys.stderr)
        return EXIT_CANCELLED
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)

    if not report["deterministic"] or not report["invariantsHold"]:
        print(
            "async harness self-check failed: scenario-invariant-violated",
            file=sys.stderr,
        )
        return EXIT_FAILURE

    print(
        "async harness self-check OK: {0} events".format(len(report["events"]))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
