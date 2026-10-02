# M1-WIRE-001 Evidence Summary

GitHub Issue: #278 (corrective Issue authorized by the Product Owner on
2026-10-02; outside the canonical 70-entry manifest)

Repository head at author time: `99c9cbb` on branch
`feat/m1-wire-001-contract-unblock`. The author changes are uncommitted;
nothing was staged, committed or pushed.

## Trigger and correction

The packaged plan put M1-025 (freeze the Barrier client wire contract) after
M1-021 and M1-022, while both of those require a frozen wire contract before
they start. `BARRIER-EVID-0001` also keeps every byte-level fact unknown, so
M1-025 had no evidence from which to freeze anything.

This corrective Issue adds:

- the accepted ADR
  `docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`;
- the deterministic derived artifact
  `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`;
- the appended `BARRIER-EVID-0002` entry in `evidence/registers/M1-023.json`,
  initially `pending-review` in the author change and subsequently `approved`
  for candidate-only claims by the independent review;
- the reordered M1-WIRE-001 → M1-025 → M1-021 → M1-022 sequence in the M1-021,
  M1-022 and M1-025 Issue files, `issues_manifest.json`, `issues_index.csv` and
  `EXECUTION_ORDER.md`;
- the traceability section in `SOURCE_TRACEABILITY.md` and the register
  documentation update; and
- the contract test `Tests/Contracts/test_m1_wire_001_contract_sequence.py`.

No capture was made, no Barrier peer was operated, and no Swift source, parser
or encoder was added.

## Acceptance criteria mapping

- `BARRIER-EVID-0001` unchanged: the test pins its exact serialized text and
  requires it to appear once, first, at its original indent, and to equal the
  pinned object. It is not rewritten, upgraded or marked `superseded`. Mutations
  that rewrite a byte, supersede it, drop an unknown field, add a consumer or
  reorder the entries are rejected.
- Distinct `BARRIER-EVID-0002`: appended after `BARRIER-EVID-0001`, category
  `sanitized-conformance-vector`, validated by the unchanged M1-023 validator,
  pinned to the same fixture path, SHA-256 and byte length, with empty consumer
  lists and its own unknown fields.
- Derived artifact: its `derived` section must equal `derive_conformance`
  applied to the fixture bytes, and the file must be canonical two-space JSON.
  It holds only the partition under one candidate interpretation (a candidate
  4-byte unsigned big-endian length prefix, which does not prove the width),
  the candidate prefix values and offsets of all 11 candidate frames, the 7
  marker bytes, the 4 bytes `00 01 00 06` after the marker, the alternative
  readings, totals, limits and non-claims. Fixture mutations (a changed version byte, a broken length
  prefix, swapped runs, a removed marker, a relabelled direction) and artifact
  mutations are rejected.
- Version behavior: only the observed bytes plus the
  `exact-supported-version-fail-closed` proposal, owned by M1-025. The test
  requires the proposed bytes to equal the observed bytes and rejects any
  version negotiation claim.
- Honest limit: a narrower 2-byte big-endian reading also partitions all 7
  runs, because every candidate length value is below 256. The candidate
  interpretation therefore only partitions the retained bytes. The artifact
  records that, the derived entry keeps the prefix width unknown, and the test
  rejects any document sentence that states a prefix width without that
  qualification. The exact width stays blocked pending separately approved
  discriminating evidence.
- Claim-to-byte mapping: each of the three claims must establish exactly its
  field ids, cite exactly the derived fixture and artifact pointers, resolve
  every pointer, and restate the derived counts, length values, marker bytes,
  version bytes and offsets.
- Review gate: `BARRIER-EVID-0002` may be `approved` only when
  `evidence/issues/M1-WIRE-001/independent-review.md` exists and the reviewer
  is independent and named; M1-025 may not freeze a contract while that entry
  is not approved.
- Sequence: M1-025 `depends_on` is `M1-024` only, M1-021 is `M1-015`,
  `M1-025`, and M1-022 keeps `M1-019`, `M1-020`, `M1-021`. The
  `topological_order` values rotate to 22, 36 and 38 among those three slots
  only. M1-WIRE-001 stays outside the manifest and outside every `depends_on`;
  its prerequisite is in the M1-025 Preconditions, `EXECUTION_ORDER.md` and
  `SOURCE_TRACEABILITY.md`. M1-021 and M1-022 name the frozen M1-025 ADR in
  their Preconditions.
- No secrets, identifiers or GPL-derived material: the test rejects payload
  text other than the marker, encoded payloads, addresses, user paths, emails,
  host names, tokens, key material, certificate fingerprints and GPL-derived
  markers in the new documents and the derived entry.
- Windows was not executed in M1, and no Windows result or compatibility is
  claimed; the test rejects such claims.
- The production TLS default stays enabled and fail-closed; the test checks
  the canonical specification digest, frozen decision 6 and the M1-001
  production TLS statement.
- No Swift or parser files: the test rejects any Barrier Swift source other
  than the module boundary file before the M1-025 ADR exists, and any Swift
  file in this evidence directory.

## Verification status

None of the required commands has been run by the author. Every command
execution in the author session (including `python3`, `make`, `shasum` and
`git hash-object`) was denied by the session permission policy, so no test
result, exit code or timing is recorded, and nothing is claimed to pass. The
exact commands that must still run are listed in `commands.json`, and
`tests/results.json` records the not-run state.

Static checks the author could make without executing code:

- every one of the 179 interior lines of the pinned `BARRIER-EVID-0001` text in
  the test matches the corresponding register line exactly, and the pin spans
  181 lines, the same as the register entry; and
- the moved manifest entries sit at positions 22, 36 and 38 between neighbours
  ordered 21 and 23, 35 and 37, and 37 and 39.

The derived artifact was written by hand from a byte-level decoding of the
fixture, so the first test run is the first machine check of it.

## Remaining gates

- Author or reviewer run of every command in `commands.json`, recorded with
  exit codes and times.
- Independent review is recorded in
  `evidence/issues/M1-WIRE-001/independent-review.md` by a reviewer who is not
  the implementation author; `BARRIER-EVID-0002` has moved from
  `pending-review` to `approved` for its candidate-only claims.
- GitHub CI on the pull request.
- M1-025 remains blocked until this change merges and `BARRIER-EVID-0002` is
  `approved`. Even then its Preconditions require it to stop before freezing
  an exact length-prefix width unless separately approved discriminating
  evidence uniquely establishes that width; this evidence is not sufficient
  for it.
- That discriminating evidence is tracked by the owner in GitHub Issue #279
  (M1-WIRE-002, Acquire discriminating Barrier length-prefix evidence), which
  depends on #278 and blocks M1-025 from completing the exact prefix width
  freeze. #279 is not complete. Like M1-WIRE-001 it stays outside the
  canonical 70-entry manifest and every `depends_on`; this change does not add
  it to the package.

## Not changed

`MacKVM_Implementation_Package_v2_Combined.md` and
`MacKVM_Implementation_Package_v2.zip` are bootstrap snapshots. No repository
tool regenerates them and the earlier corrective Issues left them unchanged, so
they are not edited here; the Issue files and `issues_manifest.json` are
authoritative.

## Rollback

Revert every file listed above together in one change and keep M1-025, M1-021
and M1-022 blocked. `BARRIER-EVID-0001` needs no rollback because it is
unchanged.
