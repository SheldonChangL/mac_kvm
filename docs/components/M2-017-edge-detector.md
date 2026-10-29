# M2-017 EdgeDetector Activation Delay and Dead Zone

## Outcome

`KVMCore` now has `EdgeDetector`, a pure value that turns local pointer
samples (logical points, monotonic timestamps) into `idle`, `pending(edge)` or
`activated(edge, offset)` signals. All declarations are `package`.

## Rules

- Configuration is accepted only inside the baseline ranges: activation delay
  50...100 ms and corner dead zone 20...40 points; otherwise `nil`.
- Only edges in `linkedEdges` (from the M2-016 topology) can activate.
- An edge activates once the pointer has stayed on it for the delay, either on
  a new sample or on `tick(at:)` driven by the owner's `KVMClock`.
- Moving off the edge, into a corner dead zone, or to another edge cancels the
  pending dwell. After an activation the pointer must leave the edge to re-arm.
- Non-finite samples, degenerate screen sizes and timestamps that run
  backwards cancel and return `idle` (fail safe: no switch).
- Coordinates outside the screen are clamped; `offset` is the clamped
  normalized position along the edge with the `(size − 1)` denominator
  shared by capture normalization and the M2-019/M2-020 mappers.

## Tests

`EdgeDetectorTests` (9): configuration bounds, activation, tick activation,
cancellation, re-arm, unlinked edges, all four edges with corners, invalid
samples, reset idempotency. All timing uses explicit `Duration` timestamps; no
sleep.

## M2-018 note

M2-018's corner exclusion and cancellation cases are covered here. Its Exact
Files name `Packages/KVMCore/Sources/KVMCore/EdgeDetectorTests.swift`, a test
file under `Sources`, which would ship test code in the production module;
that file was not created and the anomaly is recorded for M2-018 review.

## Rollback

Revert the three M2-017 files.
