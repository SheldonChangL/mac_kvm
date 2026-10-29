# M1-060 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ReconnectManager.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ReconnectManagerTests.swift`,
`docs/components/M1-060-reconnect-manager.md`.

## RED

Before the implementation existed: `cannot find type 'ReconnectManager' in scope`.

## GREEN

`swift test --filter ReconnectManager`: 9 tests passed. It also passed 20 runs in a row,
twice: before and after the barriers were made cancellation-aware.

## Mutation checks

| Mutation | Result |
| --- | --- |
| an established connection does not reset the backoff | failed: the reset test |
| every failure is retried | failed: the non-retryable test (time limit) |
| the generation guard after an attempt is removed | failed: the manual disconnect test |

The first run of these checks hung instead of failing, because the test barriers
did not respond to cancellation. The barriers now respect it, and the suite has a
one-minute time limit.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| 1/2/4/8/15... capped backoff | `standardBackoff`, `retriesUntilConnected`, `capsAtFifteenSeconds` |
| Manual disconnect does not reconnect | `manualDisconnectNeverReconnects`, `disconnectIdempotent` |
| A new connect generation cancels the old task | `newGenerationCancelsOld` |
| Invalid input | `invalidBackoff`, `standardBackoff` (retry below 1) |
| Error, cancellation and cleanup | `nonRetryableStops`, `manualDisconnectNeverReconnects` |

Full gates are in `commands.json`.

## Review

Pending independent review.
