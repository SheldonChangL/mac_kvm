# M2-003 Real-time Capture Queue and Backpressure Policy

## Outcome

`KVMCore` now has `CaptureQueue`, a bounded single-consumer ring buffer that
hands captured `KVMEvent` values from an event-tap callback to Core. All
declarations are `package`; no public API is added.

## API

| Declaration | Purpose |
| --- | --- |
| `init?(capacity:)` | capacity `2...4096`; otherwise `nil` |
| `enqueue(_:) -> CaptureEnqueueResult` | producer side; never awaits |
| `next() async throws(CoreError) -> KVMEvent?` | single consumer; a second concurrent caller fails with `internal.preconditionFailed` |
| `drain(maximumCount:)` | synchronous batch removal |
| `reset()`, `close()` | clear overflow latch / finish; idempotent |
| `waitForPendingConsumer()` | test scheduling barrier, no sleep or polling |

## Backpressure policy

1. Order is preserved; coalescing merges only into the newest queued event.
2. Consecutive pointer moves keep the latest absolute position.
3. Consecutive scrolls sum with saturation.
4. Full + unmergeable pointer move: dropped and reported `droppedMove`.
5. Full + any other event: never silently dropped. The queue discards its
   contents, latches failed, reports `overflow`, and the consumer receives
   `inputSafety.cleanupRequired`. The capture owner must treat this as the
   M2-001/M2-008 `captureFailure` action and fail open to local.

## Real-time safety

`enqueue` takes one short `NSLock` critical section, writes into preallocated
storage and may resume a waiting continuation. It performs no await, network
I/O, logging or allocation proportional to input.

## Tests

`CaptureQueueTests` (12): invalid capacity, ordering, move and scroll
coalescing, full-queue move drop, overflow latch and reset, drain bound,
wrap-around, consumer wake-up, close idempotency, overflow after serving,
cancellation.

## Privacy

The queue never logs and never inspects key identity or text.

## Rollback

Revert the three M2-003 files.
