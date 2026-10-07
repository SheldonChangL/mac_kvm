# M1-WIRE-002 Attempt 6 Sanitized Stop Evidence

## Status

STOP. Attempt 6 opened one bounded capture window using a large synthetic Barrier server
configuration, but it did not discriminate the candidate Barrier length-prefix readings.

## Outcome

- Sanitized artifact: `sanitized.json`
- Sanitized artifact SHA-256:
  `2907fbda2b8e7d25e2cd005ce821214c1506831bae3a38b9d1fe66be25af195c`
- Sanitized artifact byte length: `15085`
- Analyzer result: `STOP-BOTH-SUCCEED`
- Connections analyzed: `1`
- Direction streams analyzed: `client-to-server` and `server-to-client`
- `client-to-server` stream byte length: `120`, retained byte count: `40`
- `server-to-client` stream byte length: `187`, retained byte count: `36`
- Width-4 result: success on every stream.
- Width-2 result: success on every stream.

## Trigger result

- Synthetic config screen count: `3000`
- Synthetic config byte length: `849708`
- Synthetic config SHA-256:
  `a6fd0eb521adc7d188e6a76218edc3ff649868fef9d371e77abc31051ebd1746`
- Runtime connection: succeeded.

The large config did not produce a large captured application stream. This attempt therefore
does not approve a prefix width or a fixture.

## Raw handling

- Raw capture stayed on `role-capture` and was not committed.
- Raw capture SHA-256 on `role-capture`:
  `57a6299efa5b0de97ea10daf86ae3be1709a546bcf88108d31bff9a2405ffbe2`
- Raw capture byte length: `2561`
- Raw capture packet-counter summary: `27 packets captured`, `54 packets received by filter`,
  `0 packets dropped by kernel`

## Consequence

No register entry, width ADR, fixture acceptance or `M1-025` unblock is produced by this
attempt. GitHub Issue #279 remains open.
