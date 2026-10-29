# M2-020 Return-edge Coordinate Mapper

## Outcome

`KVMCore` now has `ReturnCoordinateMapper` (C-008). It maps the
`returned(offset:)` signal from the M2-019 tracker to a local re-entry point
on the local edge the pointer originally left. All declarations are `package`.

## Rules

- Position along the edge is the returned normalized offset, clamped to
  `0...1` and then out of the corner dead zone.
- The point is `reentryInset` (≥ 1) points inside the edge, so it is never on
  an edge and the M2-017 detector must re-arm before another switch.
- Non-finite offsets use the edge center; degenerate sizes, sub-point insets,
  and insets or dead zones that do not fit are rejected at construction.

## Tests

`ReturnCoordinateMapperTests` (5): re-entry on all edges, corner clamping,
no immediate re-switch through the real `EdgeDetector`, normalized form,
invalid configuration.

## Rollback

Revert the three M2-020 files.
