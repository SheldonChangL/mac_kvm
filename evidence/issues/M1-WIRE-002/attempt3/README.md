# M1-WIRE-002 Attempt 3 Sanitized Stop Evidence

## Status

STOP. Attempt 3 opened one bounded capture window and produced a sanitized analysis result,
but it did not discriminate the candidate Barrier length-prefix readings.

## Outcome

- Sanitized artifact: `sanitized.json`
- Sanitized artifact SHA-256:
  `cf781d4fdee3e97d633d3c74c28f4737300e8cf1553af9e2d1d627ba9755cbd3`
- Sanitized artifact byte length: `20077`
- Analyzer result: `STOP-BOTH-SUCCEED`
- Connections analyzed: `1`
- Direction streams analyzed: `client-to-server` and `server-to-client`
- Width-4 result: success on every stream.
- Width-2 result: success on every stream.

## Raw handling

- Raw capture stayed on `role-capture` and was not committed.
- Raw capture SHA-256 on `role-capture`:
  `778143c8feadf9c119d599222fa0a864069ae61ca0a4ff1efafca91a77681f26`
- Raw capture byte length: `4199`
- Raw deletion was not performed in this change because independent Checkpoint 2
  re-derivation and deletion review are not complete.

## Consequence

No register entry, width ADR, fixture acceptance or `M1-025` unblock is produced by this
attempt. GitHub Issue #279 remains open.
