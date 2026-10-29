# M2-016 ScreenTopology and ScreenLinks Validation

## Outcome

`KVMContracts` now has `ScreenEdge`, `ScreenLink`, `ScreenTopology` and
`ScreenTopologyError` (C-008). All declarations are `package`; no public API is
added, so consumers outside the owning SwiftPM package cannot use them yet.

## Rules

- At least one and at most 16 screens; identifiers unique.
- Each link is reciprocal: `A.right → B` implies `B.left → A`.
- Rejected: self link, link to an unknown screen, two links claiming the same
  screen edge (directly or through a reciprocal), and one screen pair linked
  through more than one edge.
- Re-declaring the exact reciprocal of an existing link is accepted once.

## Serialization

Encoding writes screens sorted by identifier and canonical links (orientation
whose `from` sorts first) sorted by `from` then edge, so equal topologies
encode byte-identically with sorted keys. Decoding re-runs validation and
rejects tampered input with the same typed error.

## Tests

`ScreenTopologyTests` (7): reciprocal resolution, opposites, explicit
reciprocal, invalid inputs, conflicts, screen bound, deterministic
serialization and revalidating decode.

## Privacy

Topology holds only opaque screen identifiers; no host names or addresses.

## Rollback

Revert the three M2-016 files.
