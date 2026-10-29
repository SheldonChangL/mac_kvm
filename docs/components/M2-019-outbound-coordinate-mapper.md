# M2-019 Outbound Coordinate Mapper

## Outcome

`KVMCore` now has `OutboundCoordinateMapper` and `RemotePointerTracker`
(C-008). All declarations are `package`.

- `entryPoint(leaving:offset:)` maps a local edge activation to the opposite
  remote edge, `entryInset` points inside it, at the same normalized offset
  along the edge.
- `normalized(_:)` converts a remote logical point to the `NormalizedPoint`
  carried by `KVMEvent`.
- `tracker(entering:at:)` returns a `RemotePointerTracker` that applies local
  relative motion (current local position minus the re-anchor point) one
  logical point per logical point, clamps to the remote screen, and reports
  `returned(offset:)` when pushed past the arrival edge.

## Scaling and bounds

Only logical point sizes are used; backing-pixel ratios are never consulted,
so Retina and non-Retina peers move at the same point speed. Remote sizes must
be finite, `2...65535` points, with an inset that fits inside the screen.
Rotation is represented by the logical size the peer reports, so no separate
rotation input exists.

## Tests

`OutboundCoordinateMapperTests` (8): entry points on all edges, normalized
form, offset clamping, invalid configuration, tracking and clamping, return on
the arrival edge, clamping on other edges, invalid local size.

## Known limitations

The re-anchoring of the local cursor (warp to anchor) is a platform effect
owned by M2-013/M2-021.

## Rollback

Revert the three M2-019 files.
