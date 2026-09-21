import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPOSITORY_ROOT / "Tools/async-harness/async-harness.py"


def load_tool():
    specification = importlib.util.spec_from_file_location(
        "async_harness", TOOL_PATH
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


async_harness = load_tool()


def projection(harness):
    return tuple(
        (event.kind, event.task, event.detail) for event in harness.events
    )


def notes(harness):
    return tuple(
        event.detail for event in harness.events if event.kind == "note"
    )


class HarnessTestCase(unittest.TestCase):
    """Closes every harness a test builds, so no coroutine can leak."""

    def make_harness(self, **keywords):
        harness = async_harness.Harness(**keywords)
        self.addCleanup(harness.close)
        return harness

    def assertCoroutineClosed(self, coroutine):
        self.assertIsNone(coroutine.cr_frame)


class BogusAwaitable:
    def __await__(self):
        yield ("bogus-request",)
        return None


async def record_then_yield(harness, name, count):
    for index in range(count):
        harness.record("{0}-{1}".format(name, index), task=name)
        await harness.yield_now()


async def sleep_then_record(harness, name, duration_nanoseconds):
    await harness.sleep(duration_nanoseconds)
    harness.record("{0}-woke".format(name), task=name)


async def yield_then_sleep(harness, duration_nanoseconds):
    await harness.yield_now()
    await harness.sleep(duration_nanoseconds)
    harness.record("spawned-woke", task="spawned")


class FakeClockTests(HarnessTestCase):
    def test_clock_starts_at_zero_and_only_moves_on_explicit_advance(self):
        harness = self.make_harness()
        harness.spawn("waiter", sleep_then_record(harness, "waiter", 10))

        self.assertEqual(harness.now, 0)
        harness.run_until_blocked()
        self.assertEqual(harness.now, 0)
        self.assertEqual(harness.pending_sleep_count, 1)
        self.assertEqual(notes(harness), ())

        harness.advance(10)
        self.assertEqual(harness.now, 10)
        self.assertEqual(notes(harness), ("waiter-woke",))

    def test_partial_advance_does_not_wake_a_later_deadline(self):
        harness = self.make_harness()
        harness.spawn("waiter", sleep_then_record(harness, "waiter", 10))
        harness.run_until_blocked()

        harness.advance(5)

        self.assertEqual(harness.now, 5)
        self.assertEqual(harness.pending_sleep_count, 1)
        self.assertEqual(notes(harness), ())
        self.assertEqual(harness.state("waiter"), "sleeping")

    def test_zero_duration_sleep_completes_without_any_advance(self):
        harness = self.make_harness()
        harness.spawn("waiter", sleep_then_record(harness, "waiter", 0))

        harness.run_until_blocked()

        self.assertEqual(harness.now, 0)
        self.assertEqual(harness.state("waiter"), "completed")
        self.assertEqual(notes(harness), ("waiter-woke",))

    def test_maximum_sleep_is_accepted_and_one_nanosecond_more_fails(self):
        accepted = self.make_harness()
        accepted.spawn(
            "at-limit",
            sleep_then_record(
                accepted, "at-limit", async_harness.MAX_SLEEP_NANOSECONDS
            ),
        )
        accepted.run_until_blocked()

        self.assertEqual(accepted.state("at-limit"), "sleeping")

        rejected = self.make_harness()
        rejected.spawn(
            "over-limit",
            sleep_then_record(
                rejected,
                "over-limit",
                async_harness.MAX_SLEEP_NANOSECONDS + 1,
            ),
        )
        rejected.run_until_blocked()

        self.assertEqual(rejected.state("over-limit"), "failed")
        with self.assertRaises(async_harness.HarnessError) as captured:
            rejected.result("over-limit")
        self.assertEqual(captured.exception.code, "invalid-duration")

    def test_clock_fails_closed_at_the_maximum_representable_time(self):
        harness = self.make_harness()
        harness.advance(async_harness.MAX_CLOCK_NANOSECONDS)

        self.assertEqual(harness.now, async_harness.MAX_CLOCK_NANOSECONDS)

        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.advance(1)
        self.assertEqual(captured.exception.code, "clock-overflow")

        harness.spawn("overflow", sleep_then_record(harness, "overflow", 1))
        harness.run_until_blocked()

        self.assertEqual(harness.state("overflow"), "failed")
        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.result("overflow")
        self.assertEqual(captured.exception.code, "clock-overflow")

    def test_invalid_sleep_and_advance_durations_fail_closed(self):
        harness = self.make_harness()

        for duration in (-1, 1.0, True, "10", None):
            with self.assertRaises(async_harness.HarnessError) as captured:
                harness.sleep(duration)
            self.assertEqual(captured.exception.code, "invalid-duration")

            with self.assertRaises(async_harness.HarnessError) as captured:
                harness.advance(duration)
            self.assertEqual(captured.exception.code, "invalid-duration")


class OrderingTests(HarnessTestCase):
    def test_runnable_tasks_interleave_in_deterministic_spawn_order(self):
        harness = self.make_harness()
        harness.spawn("alpha", record_then_yield(harness, "alpha", 2))
        harness.spawn("beta", record_then_yield(harness, "beta", 2))

        harness.run_until_blocked()

        self.assertEqual(
            notes(harness), ("alpha-0", "beta-0", "alpha-1", "beta-1")
        )
        self.assertEqual(harness.state("alpha"), "completed")
        self.assertEqual(harness.state("beta"), "completed")

    def test_sleepers_wake_in_deadline_order_not_spawn_order(self):
        harness = self.make_harness()
        harness.spawn("slow", sleep_then_record(harness, "slow", 20))
        harness.spawn("fast", sleep_then_record(harness, "fast", 10))
        harness.run_until_blocked()

        harness.advance(20)

        self.assertEqual(notes(harness), ("fast-woke", "slow-woke"))
        self.assertEqual(
            tuple(
                event.task
                for event in harness.events
                if event.kind == "sleep-expired"
            ),
            ("fast", "slow"),
        )

    def test_equal_deadlines_wake_in_scheduling_order(self):
        harness = self.make_harness()
        harness.spawn("first", sleep_then_record(harness, "first", 10))
        harness.spawn("second", sleep_then_record(harness, "second", 10))
        harness.run_until_blocked()

        harness.advance(10)

        self.assertEqual(notes(harness), ("first-woke", "second-woke"))

    def test_equal_deadlines_follow_sleep_order_not_spawn_order(self):
        harness = self.make_harness()
        harness.spawn("spawned", yield_then_sleep(harness, 10))
        harness.spawn("slept", sleep_then_record(harness, "slept", 10))
        harness.run_until_blocked()

        harness.advance(10)

        self.assertEqual(
            tuple(
                event.task
                for event in harness.events
                if event.kind == "sleep-expired"
            ),
            ("slept", "spawned"),
        )
        self.assertEqual(notes(harness), ("slept-woke", "spawned-woke"))

    def test_identical_scenarios_produce_identical_event_traces(self):
        def build():
            harness = self.make_harness()
            harness.spawn("slow", sleep_then_record(harness, "slow", 20))
            harness.spawn("fast", sleep_then_record(harness, "fast", 10))
            harness.spawn("looper", record_then_yield(harness, "looper", 3))
            harness.run_until_blocked()
            harness.advance(10)
            harness.advance(10)
            return harness

        self.assertEqual(projection(build()), projection(build()))

    def test_event_log_records_sequence_and_clock_for_every_event(self):
        harness = self.make_harness()
        harness.spawn("waiter", sleep_then_record(harness, "waiter", 10))
        harness.run_until_blocked()
        harness.advance(10)

        sequences = [event.sequence for event in harness.events]

        self.assertEqual(sequences, list(range(len(sequences))))
        self.assertEqual(
            projection(harness),
            (
                ("spawned", "waiter", ""),
                ("sleep-scheduled", "waiter", "10"),
                ("sleep-expired", "waiter", "10"),
                ("note", "waiter", "waiter-woke"),
                ("completed", "waiter", ""),
            ),
        )


class LimitTests(HarnessTestCase):
    def test_task_limit_fails_closed(self):
        harness = self.make_harness(max_tasks=2)
        harness.spawn("one", record_then_yield(harness, "one", 1))
        harness.spawn("two", record_then_yield(harness, "two", 1))

        overflow = record_then_yield(harness, "three", 1)
        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.spawn("three", overflow)
        self.assertEqual(captured.exception.code, "task-limit-exceeded")
        self.assertCoroutineClosed(overflow)

    def test_step_limit_fails_closed_and_breaks_the_harness(self):
        async def forever(harness):
            while True:
                await harness.yield_now()

        harness = self.make_harness(max_steps=4)
        harness.spawn("forever", forever(harness))

        with self.assertRaises(async_harness.HarnessLimitError) as captured:
            harness.run_until_blocked()
        self.assertEqual(captured.exception.code, "step-limit-exceeded")

        with self.assertRaises(async_harness.HarnessLimitError) as captured:
            harness.run_until_blocked()
        self.assertEqual(captured.exception.code, "harness-broken")

    def test_event_limit_fails_closed(self):
        harness = self.make_harness(max_events=2)
        harness.record("one")
        harness.record("two")

        with self.assertRaises(async_harness.HarnessLimitError) as captured:
            harness.record("three")
        self.assertEqual(captured.exception.code, "event-limit-exceeded")

    def test_constructor_limits_are_bounded_and_validated(self):
        for keyword, value in (
            ("max_tasks", 0),
            ("max_tasks", async_harness.MAX_TASK_COUNT + 1),
            ("max_steps", -1),
            ("max_steps", async_harness.MAX_STEP_COUNT + 1),
            ("max_events", 0),
            ("max_events", async_harness.MAX_EVENT_COUNT + 1),
            ("max_tasks", 1.5),
            ("max_tasks", True),
        ):
            with self.assertRaises(async_harness.HarnessError) as captured:
                self.make_harness(**{keyword: value})
            self.assertEqual(captured.exception.code, "invalid-limit")


class InvalidInputTests(HarnessTestCase):
    def test_invalid_task_names_fail_closed(self):
        harness = self.make_harness()
        for name in ("", "bad name", "-leading", "x" * 65, 7, None):
            coroutine = record_then_yield(harness, "probe", 1)
            with self.assertRaises(async_harness.HarnessError) as captured:
                harness.spawn(name, coroutine)
            self.assertEqual(captured.exception.code, "invalid-name")
            self.assertCoroutineClosed(coroutine)

    def test_duplicate_task_names_fail_closed(self):
        harness = self.make_harness()
        harness.spawn("worker", record_then_yield(harness, "worker", 1))

        duplicate = record_then_yield(harness, "worker", 1)
        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.spawn("worker", duplicate)
        self.assertEqual(captured.exception.code, "duplicate-task-name")
        self.assertCoroutineClosed(duplicate)

    def test_spawning_a_non_coroutine_fails_closed(self):
        harness = self.make_harness()

        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.spawn("worker", lambda: None)
        self.assertEqual(captured.exception.code, "invalid-coroutine")

    def test_unknown_task_lookups_fail_closed(self):
        harness = self.make_harness()

        for operation in (harness.cancel, harness.state, harness.result):
            with self.assertRaises(async_harness.HarnessError) as captured:
                operation("missing")
            self.assertEqual(captured.exception.code, "task-not-found")

        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.record("label", task="missing")
        self.assertEqual(captured.exception.code, "task-not-found")

    def test_event_details_are_restricted_to_allowlist_metadata(self):
        harness = self.make_harness()

        for label in ("", "typed secret text", "payload=abc", "x" * 65, 3):
            with self.assertRaises(async_harness.HarnessError) as captured:
                harness.record(label)
            self.assertEqual(captured.exception.code, "invalid-detail")

    def test_unsupported_await_fails_the_task_closed(self):
        async def bogus(harness):
            await BogusAwaitable()

        harness = self.make_harness()
        harness.spawn("bogus", bogus(harness))
        harness.run_until_blocked()

        self.assertEqual(harness.state("bogus"), "failed")
        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.result("bogus")
        self.assertEqual(captured.exception.code, "unsupported-await")

    def test_task_failure_is_isolated_and_reported(self):
        async def failing(harness):
            harness.record("about-to-fail", task="failing")
            raise ValueError("boom")

        harness = self.make_harness()
        harness.spawn("failing", failing(harness))
        harness.spawn("healthy", record_then_yield(harness, "healthy", 1))
        harness.run_until_blocked()

        self.assertEqual(harness.state("failing"), "failed")
        self.assertEqual(harness.state("healthy"), "completed")
        with self.assertRaises(ValueError):
            harness.result("failing")
        self.assertIn(("failed", "failing", "ValueError"), projection(harness))

    def test_result_requires_a_terminal_task(self):
        async def returns_value(harness):
            await harness.sleep(10)
            return 42

        harness = self.make_harness()
        harness.spawn("worker", returns_value(harness))
        harness.run_until_blocked()

        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.result("worker")
        self.assertEqual(captured.exception.code, "task-not-finished")

        harness.advance(10)

        self.assertEqual(harness.result("worker"), 42)


class CancellationTests(HarnessTestCase):
    def test_cancelling_a_sleeping_task_runs_cleanup_deterministically(self):
        async def worker(harness):
            try:
                await harness.sleep(100)
                harness.record("unreachable", task="worker")
            except async_harness.TaskCancelled:
                harness.record("observed-cancel", task="worker")
                raise
            finally:
                harness.record("cleanup", task="worker")

        harness = self.make_harness()
        harness.spawn("worker", worker(harness))
        harness.run_until_blocked()

        harness.cancel("worker")
        harness.run_until_blocked()

        self.assertEqual(harness.state("worker"), "cancelled")
        self.assertEqual(harness.pending_sleep_count, 0)
        self.assertEqual(harness.active_task_names, ())
        self.assertTrue(harness.is_idle)
        self.assertEqual(
            projection(harness),
            (
                ("spawned", "worker", ""),
                ("sleep-scheduled", "worker", "100"),
                ("cancel-requested", "worker", ""),
                ("cancel-delivered", "worker", ""),
                ("note", "worker", "observed-cancel"),
                ("note", "worker", "cleanup"),
                ("cancelled", "worker", ""),
            ),
        )

    def test_cancel_is_idempotent(self):
        harness = self.make_harness()
        harness.spawn("worker", sleep_then_record(harness, "worker", 100))
        harness.run_until_blocked()

        harness.cancel("worker")
        harness.cancel("worker")
        harness.run_until_blocked()
        harness.cancel("worker")

        requests = [
            event for event in harness.events if event.kind == "cancel-requested"
        ]
        terminations = [
            event for event in harness.events if event.kind == "cancelled"
        ]

        self.assertEqual(len(requests), 1)
        self.assertEqual(len(terminations), 1)
        self.assertEqual(harness.state("worker"), "cancelled")

    def test_cancelling_before_the_first_step_still_cancels(self):
        harness = self.make_harness()
        harness.spawn("worker", record_then_yield(harness, "worker", 1))

        harness.cancel("worker")
        harness.run_until_blocked()

        self.assertEqual(harness.state("worker"), "cancelled")
        self.assertEqual(notes(harness), ())
        self.assertEqual(
            projection(harness),
            (
                ("spawned", "worker", ""),
                ("cancel-requested", "worker", ""),
                ("cancel-delivered", "worker", ""),
                ("cancelled", "worker", ""),
            ),
        )

    def test_suppressing_cancellation_fails_closed(self):
        async def swallowing(harness):
            try:
                await harness.sleep(100)
            except async_harness.TaskCancelled:
                harness.record("swallowed", task="swallowing")

        harness = self.make_harness()
        harness.spawn("swallowing", swallowing(harness))
        harness.run_until_blocked()
        harness.cancel("swallowing")
        harness.run_until_blocked()

        self.assertEqual(harness.state("swallowing"), "failed")
        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.result("swallowing")
        self.assertEqual(captured.exception.code, "cancellation-suppressed")

    def test_cleanup_sleep_after_cancellation_is_elided_not_awaited(self):
        async def stubborn(harness):
            try:
                await harness.sleep(100)
            finally:
                await harness.sleep(1)
                harness.record("cleanup-finished", task="stubborn")

        harness = self.make_harness()
        harness.spawn("stubborn", stubborn(harness))
        harness.run_until_blocked()
        harness.cancel("stubborn")
        harness.run_until_blocked()

        self.assertEqual(harness.state("stubborn"), "cancelled")
        self.assertEqual(harness.pending_sleep_count, 0)
        self.assertEqual(harness.now, 0)
        self.assertEqual(notes(harness), ("cleanup-finished",))
        self.assertIn(
            ("sleep-elided", "stubborn", "1"), projection(harness)
        )

    def test_cancellation_is_delivered_exactly_once(self):
        async def worker(harness):
            try:
                await harness.sleep(100)
            finally:
                await harness.yield_now()
                await harness.sleep(5)
                harness.record("cleanup-done", task="worker")

        harness = self.make_harness()
        harness.spawn("worker", worker(harness))
        harness.run_until_blocked()

        harness.cancel("worker")
        harness.cancel("worker")
        harness.run_until_blocked()
        harness.cancel("worker")

        deliveries = [
            event
            for event in harness.events
            if event.kind == "cancel-delivered"
        ]

        self.assertEqual(len(deliveries), 1)
        self.assertEqual(harness.state("worker"), "cancelled")
        self.assertEqual(notes(harness), ("cleanup-done",))

    def test_raising_task_cancelled_without_a_request_fails_closed(self):
        async def impostor(harness):
            await harness.yield_now()
            raise async_harness.TaskCancelled()

        harness = self.make_harness()
        harness.spawn("impostor", impostor(harness))
        harness.run_until_blocked()

        self.assertEqual(harness.state("impostor"), "failed")
        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.result("impostor")
        self.assertEqual(captured.exception.code, "spurious-cancellation")

    def test_cleanup_may_yield_after_cancellation(self):
        async def worker(harness):
            try:
                await harness.sleep(100)
            finally:
                await harness.yield_now()
                harness.record("late-cleanup", task="worker")

        harness = self.make_harness()
        harness.spawn("worker", worker(harness))
        harness.run_until_blocked()
        harness.cancel("worker")
        harness.run_until_blocked()

        self.assertEqual(harness.state("worker"), "cancelled")
        self.assertEqual(notes(harness), ("late-cleanup",))
        self.assertTrue(harness.is_idle)

    def test_cancelling_a_completed_task_is_a_no_op(self):
        harness = self.make_harness()
        harness.spawn("worker", record_then_yield(harness, "worker", 1))
        harness.run_until_blocked()
        before = projection(harness)

        harness.cancel("worker")

        self.assertEqual(harness.state("worker"), "completed")
        self.assertEqual(projection(harness), before)

    def test_no_task_or_sleep_leaks_after_a_mixed_scenario(self):
        harness = self.make_harness()
        harness.spawn("fast", sleep_then_record(harness, "fast", 10))
        harness.spawn("slow", sleep_then_record(harness, "slow", 40))
        harness.spawn("looper", record_then_yield(harness, "looper", 2))
        harness.run_until_blocked()
        harness.advance(10)
        harness.cancel("slow")
        harness.run_until_blocked()

        self.assertEqual(harness.pending_sleep_count, 0)
        self.assertEqual(harness.active_task_names, ())
        self.assertTrue(harness.is_idle)
        self.assertEqual(harness.now, 10)


class TeardownTests(HarnessTestCase):
    def test_close_closes_unfinished_coroutines_and_is_idempotent(self):
        async def waiter(harness):
            try:
                await harness.sleep(100)
            finally:
                harness.record("closed-cleanup", task="waiter")

        harness = self.make_harness()
        coroutine = waiter(harness)
        harness.spawn("waiter", coroutine)
        harness.spawn(
            "suspended", sleep_then_record(harness, "suspended", 50)
        )
        harness.run_until_blocked()

        harness.close()
        harness.close()

        self.assertCoroutineClosed(coroutine)
        self.assertEqual(harness.state("waiter"), "closed")
        self.assertEqual(harness.state("suspended"), "closed")
        self.assertEqual(harness.pending_sleep_count, 0)
        self.assertEqual(harness.active_task_names, ())
        self.assertTrue(harness.is_idle)
        self.assertEqual(harness.dropped_teardown_event_count, 0)
        self.assertIn(("closed", "waiter", "teardown"), projection(harness))
        self.assertIn(
            ("note", "waiter", "closed-cleanup"), projection(harness)
        )

    def test_closed_tasks_have_no_result(self):
        harness = self.make_harness()
        harness.spawn("waiter", sleep_then_record(harness, "waiter", 100))
        harness.run_until_blocked()

        harness.close()

        with self.assertRaises(async_harness.HarnessError) as captured:
            harness.result("waiter")
        self.assertEqual(captured.exception.code, "task-closed")

    def test_mutating_the_harness_during_teardown_fails_closed(self):
        observed = []

        async def reentrant(harness):
            try:
                await harness.sleep(100)
            finally:
                try:
                    harness.advance(1)
                except async_harness.HarnessError as error:
                    observed.append(error.code)

        harness = self.make_harness()
        harness.spawn("reentrant", reentrant(harness))
        harness.run_until_blocked()

        harness.close()

        self.assertEqual(observed, ["harness-tearing-down"])

    def test_limit_break_closes_every_pending_coroutine(self):
        async def forever(harness):
            while True:
                await harness.yield_now()

        harness = self.make_harness(max_steps=3)
        spinner = forever(harness)
        harness.spawn("spinner", spinner)
        pending = sleep_then_record(harness, "pending", 100)
        harness.spawn("pending", pending)

        with self.assertRaises(async_harness.HarnessLimitError) as captured:
            harness.run_until_blocked()
        self.assertEqual(captured.exception.code, "step-limit-exceeded")

        self.assertCoroutineClosed(pending)
        self.assertEqual(harness.state("pending"), "closed")
        self.assertEqual(harness.pending_sleep_count, 0)
        self.assertTrue(harness.is_idle)


class CommandLineTests(HarnessTestCase):
    def run_tool(self, arguments):
        return subprocess.run(
            [sys.executable, str(TOOL_PATH)] + list(arguments),
            cwd=str(REPOSITORY_ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )

    def test_self_check_succeeds_and_emits_a_deterministic_report(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            first_report = Path(temporary_directory) / "first.json"
            second_report = Path(temporary_directory) / "second.json"

            first = self.run_tool(["--report", str(first_report)])
            second = self.run_tool(["--report", str(second_report)])

            self.assertEqual(first.returncode, 0)
            self.assertEqual(second.returncode, 0)

            first_payload = json.loads(first_report.read_text())
            second_payload = json.loads(second_report.read_text())

            self.assertEqual(first_payload["schemaVersion"], 1)
            self.assertTrue(first_payload["deterministic"])
            self.assertEqual(first_payload, second_payload)

    def test_missing_report_directory_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            target = Path(temporary_directory) / "missing" / "report.json"

            result = self.run_tool(["--report", str(target)])

            self.assertEqual(result.returncode, async_harness.EXIT_NOT_FOUND)
            self.assertFalse(target.exists())


    def test_unknown_argument_fails_with_a_usage_exit_code(self):
        result = self.run_tool(["--not-an-option"])

        self.assertEqual(result.returncode, async_harness.EXIT_USAGE)
        self.assertEqual(result.stdout, b"")

    def test_help_succeeds_without_writing_a_report(self):
        result = self.run_tool(["--help"])

        self.assertEqual(result.returncode, 0)

    def test_report_path_that_is_a_directory_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            result = self.run_tool(["--report", temporary_directory])

            self.assertEqual(result.returncode, async_harness.EXIT_USAGE)
            self.assertEqual(
                sorted(Path(temporary_directory).iterdir()), []
            )

    def test_report_path_that_is_a_symlink_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            target = root / "target.json"
            target.write_text("{}\n")
            link = root / "link.json"
            link.symlink_to(target)

            result = self.run_tool(["--report", str(link)])

            self.assertEqual(result.returncode, async_harness.EXIT_USAGE)
            self.assertEqual(target.read_text(), "{}\n")

    def test_report_is_bounded_by_the_event_budget(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            report_path = Path(temporary_directory) / "report.json"

            result = self.run_tool(["--report", str(report_path)])

            self.assertEqual(result.returncode, 0)
            payload = json.loads(report_path.read_text())
            self.assertTrue(payload["invariantsHold"])
            self.assertLessEqual(
                len(payload["events"]), async_harness.MAX_EVENT_COUNT
            )
            self.assertTrue(
                all(
                    event["timeNanoseconds"]
                    <= async_harness.MAX_CLOCK_NANOSECONDS
                    for event in payload["events"]
                )
            )


class SourcePolicyTests(HarnessTestCase):
    def test_harness_uses_no_wall_clock_sleep_retry_or_randomness(self):
        source = TOOL_PATH.read_text()

        for forbidden in (
            "time.sleep",
            "import time",
            "import asyncio",
            "import threading",
            "import random",
            "import socket",
            "import subprocess",
            "import urllib",
            "time.monotonic",
            "asyncio.",
            "retry",
            "poll",
        ):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
