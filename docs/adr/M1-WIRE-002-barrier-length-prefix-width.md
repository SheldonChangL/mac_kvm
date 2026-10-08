# M1-WIRE-002 Barrier Length-Prefix Width

## Status

Accepted.

## Context

`BARRIER-EVID-0001` and `BARRIER-EVID-0002` left the exact Barrier length-prefix width unknown:
both the candidate 4-byte big-endian reading and the narrower 2-byte big-endian reading
partitioned the retained streams. M1-025 could not freeze the exact client wire contract until
separately approved discriminating evidence existed.

## Decision

For the Barrier compatibility adapter, within the candidate set established by
M1-WIRE-001 and GitHub Issue #279, the top-level frame prefix established by
`BARRIER-EVID-0003` is:

- width: `4` bytes
- byte order: unsigned big-endian
- value: number of payload bytes following the prefix

This decision is limited to resolving the previously approved ambiguity between the 4-byte and
2-byte unsigned big-endian readings on complete captured streams. It establishes the prefix
width, byte order and payload-length meaning for M1-025's client wire contract. It does not
evaluate every possible framing variant, non-candidate prefix width, little-endian variant, or
transport behavior. It also does not establish Barrier message codes, field layout beyond the
prefix, optional fields, chunking policy, version negotiation, maximum accepted length,
cross-version compatibility, Windows behavior, or production TLS behavior.

## Evidence

- Evidence ID: `BARRIER-EVID-0003`
- Fixture:
  `Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/sanitized.json`
- Fixture SHA-256:
  `6b5049bb34694130186dd147353c14c072820825c98a2ede942a49f6bab674f1`
- Analyzer result: `DISCRIMINATING`
- Width 4: succeeded on every complete stream
- Width 2: failed on `connection-1`, `client-to-server`, offset `57514`, reason `overrun`,
  declared `24929`, available `12503`
- Runtime limitation: the observation was an explicit protocol-error close accepted under the
  section-17 gate, not successful interoperability. Peer runtime logs are retained only as
  summarized evidence because the temporary raw-log directory was unavailable for re-fetch on
  `2026-10-08T02:19:12Z`; the deterministic, machine-checkable evidence is the sanitized stream
  fixture and width-walk result.
- Fixture note: the analyzer fixture's own non-claim text says it is not itself a width
  decision or register entry; the accepted decision is this ADR plus `BARRIER-EVID-0003`.

## Consequences

- M1-025 may freeze the exact length-prefix width as 4-byte unsigned big-endian using
  `BARRIER-EVID-0003`.
- M1-021 and M1-022 remain dependent on M1-025 for the codec and reassembler contract.
- The implementation remains independent: no Barrier or Deskflow source, header, constant table,
  source-derived writeup, decompiled output, packet injection, binary patching or
  instrumentation is used.

## Rollback

Do not rewrite accepted evidence. If this decision is later rejected, add a superseding ADR and
append a reviewed register disposition rather than editing this ADR or deleting
`BARRIER-EVID-0003`.
