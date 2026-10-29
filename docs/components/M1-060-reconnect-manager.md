# M1-060 Reconnect Backoff and Manual Disconnect

## Outcome

`KVMCore` now has `ReconnectBackoff`, `ReconnectState` and the `ReconnectManager`
actor. Declarations are `package`. M1-018 left the reconnect sequence and cap to
this Issue.

## Backoff

`ReconnectBackoff.standard` waits 1, 2, 4 and 8 seconds, then 15 seconds for every
later retry. A custom schedule must be non-empty, positive and non-decreasing, with
a cap of at least its last delay; otherwise its initializer returns `nil`.
`delay(beforeRetry:)` counts retries from 1 and returns `nil` below 1.

## Manager

| Call | Effect |
| --- | --- |
| `connect()` | Starts a new generation at once. A running generation is cancelled, whether it is waiting or in the middle of an attempt; its outcome is ignored and it never attempts again. |
| `disconnect()` | Manual disconnect: cancels the current generation and sets `idle`. Nothing reconnects until the next `connect()`. Idempotent. |
| `state` | `idle`, `connecting`, `connected`, `waiting(retry:delay:)` or `stopped(code)` |
| `waitUntilSettled()`, `waitForState(_:)` | Test scheduling barriers that also return when the waiting task is cancelled |

An attempt is a closure supplied by the owner. It connects, awaits `established`
once the connection is up, and returns when the connection ends cleanly or throws
the error that ended it. It must stop promptly when its task is cancelled.

After an attempt:

- A clean end, or a failure with retry disposition `backoff`, is retried after the
  next delay.
- An established connection resets the backoff to the first delay.
- `never` and `userActionRequired` stop the generation with `stopped(code)`.
  `immediateAfterStateChange` also stops it; the owner of that state change
  (M1-061) calls `connect()` again.

Every wait goes through `KVMClock`. Nothing here logs.

## Tests

`ReconnectManagerTests` has 9 tests under a one-minute time limit:

- the standard schedule and its boundaries;
- invalid schedules;
- retries after 1, 2 and 4 s until a connection;
- the 15 s cap;
- the reset after an established connection, and the retry of a clean end;
- a stop on each non-backoff disposition;
- a manual disconnect while waiting and while attempting;
- an idempotent disconnect followed by a fresh connect;
- a new generation cancelling the old one.

The scripted attempts and the barriers respect cancellation. A regression
therefore fails within the time limit instead of hanging.

## Required command note

The Issue lists `swift test --package-path Packages/KVMCore`. `KVMCore` has no
package manifest of its own, so the tests run from the root package with
`--filter ReconnectManager`, as M2-029 did.

## Rollback

Revert the three M1-060 files and their evidence.
