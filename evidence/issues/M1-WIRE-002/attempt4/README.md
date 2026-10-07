# M1-WIRE-002 Attempt 4 Sanitized Stop Evidence

## Status

STOP. Attempt 4 opened one bounded capture window and produced a sanitized analysis result,
but it did not discriminate the candidate Barrier length-prefix readings.

## Outcome

- Sanitized artifact: `sanitized.json`
- Sanitized artifact SHA-256:
  `6b9b7291c06180189b05b95ff7600a696d9d33a5198a5c58a8e956df6e0b762d`
- Sanitized artifact byte length: `419596`
- Analyzer result: `STOP-BOTH-SUCCEED`
- Connections analyzed: `1`
- Direction streams analyzed: `client-to-server` and `server-to-client`
- `client-to-server` stream byte length: `1256`, retained byte count: `568`
- `server-to-client` stream byte length: `201657`, retained byte count: `508`
- Width-4 result: success on every stream.
- Width-2 result: success on every stream.

## Trigger result

- Synthetic clipboard size: `200000` bytes
- Synthetic clipboard SHA-256:
  `3357eb5f288d9be2085180e3c97663995063b90b1599359367089d02b367c1eb`
- Linux clipboard read-back byte length: `0`
- Linux clipboard read-back SHA-256:
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- Trigger hash match: `false`

The stream still contained a large server-to-client direction, but the Linux clipboard
read-back did not match the generated value. The mismatch is recorded as part of the stop; it
does not approve a prefix width or a fixture.

## Raw handling

- Raw capture stayed on `role-capture` and was not committed.
- Raw capture SHA-256 on `role-capture`:
  `295385b65737145edc034a51d76b125a59dbcf6a7bc75599c12a0c17c72c2c5f`
- Raw capture byte length: `225585`
- Raw capture packet-counter summary: `276 packets captured`, `552 packets received by
  filter`, `0 packets dropped by kernel`
- Raw deletion was not performed in this change because independent Checkpoint 2
  re-derivation and deletion review are not complete.

## Consequence

No register entry, width ADR, fixture acceptance or `M1-025` unblock is produced by this
attempt. GitHub Issue #279 remains open.
