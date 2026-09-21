# M1-018 KVMClock, Timeout, and Scheduler Boundary

## Outcome

`KVMContracts` provides one replaceable monotonic delay boundary, a production
clock backed by Swift `ContinuousClock`, and a manually advanced test clock.
Timeout, deadline, and retry tests can therefore control time without arbitrary
wall-clock sleeps.

## Source authority

The contract follows the Product Owner's source priority:

1. canonical specification §60–64;
2. explicitly frozen decisions;
3. C-004 and the accepted M1-002 architecture boundary; and
4. the reference `KVMContracts` package.

C-004 freezes a replaceable production/test clock so timeout and backoff tests
do not use arbitrary sleep. The reference package supplies the public
`sleep(for:)` shape. M1-018 preserves that shape and narrows failures to the
closed M1-015 `CoreError` taxonomy. It does not add timeout categories, retry
values, deadlines, or product policy.

## Public contract

`KVMClock` is `Sendable` and has one operation:

```swift
func sleep(for duration: Duration) async throws(CoreError)
```

The duration is monotonic elapsed time, not a wall-clock or calendar value.
Callers own timeout and retry policy and pass the remaining delay into this
operation. Sequential calls can represent deterministic backoff. Concurrent
calls with different durations represent independent deadlines relative to the
same monotonic clock state.

- A positive duration suspends until its monotonic deadline is reached.
- Zero completes immediately after checking task cancellation.
- A negative duration is invalid and fails closed with
  `internal.preconditionFailed`.
- Task cancellation fails with `cancellation.requested`, `retry=never`, and
  `cleanup=completed`; it is never reported as successful timeout completion.
- Implementations must not turn clock failures into a timeout code selected on
  behalf of the caller. The owner of a connect, handshake, read, write,
  keepalive, or cleanup operation selects the corresponding timeout taxonomy.

## Production clock

`ContinuousKVMClock` delegates positive delays to Swift `ContinuousClock`.
Continuous monotonic time is unaffected by wall-clock or time-zone changes. It
maps `CancellationError` to the closed cancellation-domain `CoreError` and maps
any unexpected clock failure to `internal.unclassified` without retaining an
error description, path, payload, or platform object.

The production clock owns no task, timer handle, queue, socket, or persistent
state after `sleep(for:)` returns or throws. Cancellation therefore completes
its cleanup at the suspension boundary.

## Test clock

`TestKVMClock` is an actor with explicit elapsed time. Each positive sleep is
registered with a monotonic deadline and a stable registration order.
`advance(by:)`:

- accepts only non-negative durations;
- advances elapsed time without waiting for wall time;
- resumes every newly due sleep;
- leaves later deadlines pending.

Resuming a continuation only makes its task eligible to run. Tasks that share
a deadline, or that become due in the same `advance(by:)` call, may execute in
any order on Swift's concurrent executor. Consumers that require an observable
order must coordinate that order explicitly rather than infer it from clock
registration or continuation-resume order.

Cancellation removes and resumes the exact pending continuation with a typed
cancellation error. The internal `waitUntilPendingSleepCount` barrier exists
only for package tests, allowing deterministic scheduling assertions without
polling, retry loops, or sleeps. It is not part of the public C-004 contract.

The test clock exposes read-only elapsed time and pending-sleep count plus the
manual `advance(by:)` control required by downstream tests. It does not choose
product timeout values or retry policy.

## Deadline and backoff use

A component implementing a timeout owns its deadline policy and requests the
remaining duration through `KVMClock`. A reconnect component owns its backoff
sequence and awaits the clock once per selected delay. Injecting
`TestKVMClock` lets tests advance exactly to each requested boundary and prove
ordering or cancellation without depending on machine speed.

M1-018 intentionally does not freeze the numeric timeout or backoff values.
For example, M1-060 owns the reconnect sequence and cap; protocol handshake,
keepalive, and cleanup Issues own their corresponding limits.

## Security, privacy, and architecture

- The clock imports no networking, protocol, Barrier, UI, or platform-input
  implementation.
- It does not weaken TLS, trust, identity, or fail-safe defaults.
- It accepts no typed text, clipboard payload, raw byte, credential, key,
  fingerprint, address, path, or arbitrary error string.
- It has no logging or diagnostic sink. Durations and internal continuation
  identifiers are not emitted as diagnostics.
- Protocol adapters and KVM Core can share the abstraction without moving any
  protocol token across the `KVMEvent` boundary.

## Validation coverage

Contract tests verify:

- manual advance completes a sleep without wall-clock delay;
- distinct deadlines release only at their explicit monotonic boundaries;
- a 1/2/4 backoff sequence progresses only through explicit advances;
- zero duration is a no-op;
- negative sleep and advance durations fail closed;
- cancelling a test-clock sleep removes its continuation and throws typed
  cancellation; and
- the production clock maps task cancellation to the same typed taxonomy.

The tests contain no real sleep, timing tolerance, retry loop, or skipped case.

## Out of scope

M1-018 does not implement timeout racing, reconnect policy, numeric timeout or
backoff limits, jitter, protocol handshake behavior, transport, TLS, trust,
UI, diagnostics, input cleanup, wall-clock scheduling, or a general-purpose
scheduler. Those remain with their owning Issues.

## Rollback

Revert the M1-018 PR and keep dependent deterministic-harness and reconnect
Issues blocked. The change owns no persisted state, migration, socket, timer
handle, trust state, wire behavior, or platform input state, so rollback needs
no runtime or data cleanup.
