# M1-EVIDENCE-001 Evidence Summary

GitHub Issue: #249

Repository head at author run: `20c6854c24604f8ab35846ff4869ffaa45c36606`

The author phase ran with the changed files uncommitted over that head. This
Issue has no packaged source under `MacKVM_Implementation_Package_v2/issues/`
and no `Exact Files` list; the live GitHub Issue body is the authoritative
source, and the file set below follows the M1-023 evidence-package pattern.

## Deliverables

- `evidence/registers/M1-023.json` — append-only registration of
  `BARRIER-EVID-0001` and the `initialized-no-approved-evidence` to `active`
  status transition the register's own contract requires once `entries` is
  non-empty.
- `docs/evidence/M1-023-barrier-evidence-register.md` — the registered state,
  the consumer boundaries, the direction-convention provenance, the deleted
  raw-capture disposition, and the narrower rollback.
- `evidence/issues/M1-023/tests/test_register.py` — the state assertions that
  described the empty register now describe the registered register; the
  status/entry-presence rule is asserted in both directions.
- `evidence/issues/M1-EVIDENCE-001/tests/test_registration.py` — the
  registration contract tests.
- `Tools/cigates/tests/test_cigates.py` — the canonical CI gate inventory
  regression, updated so that the cumulative inventory expects the
  `evidence-test:M1-EVIDENCE-001/tests/test_registration.py` gate that cigates
  auto-discovers from the file above. One expected-name line and one count
  constant; no production file and no gate behaviour changes.
- `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md` — the
  traceability-index section that records the
  M1-024 → M1-EVIDENCE-001 (#249) → M1-025 chain. It is index only: it freezes
  no wire contract and carries no M1-025 contract content.
- This evidence package: `summary.md`, `commands.json`, `environment.json`,
  `manual.md`, `tests/red-phase.json`, `tests/results.json`.

`evidence/issues/M1-EVIDENCE-001/independent-review.md` is deliberately absent.
It is written only by a reviewer who is neither the capture producer nor this
implementation author.

## What was registered

One entry, `BARRIER-EVID-0001`, disposition `approved`, producing Issue
`M1-024`. It registers the sanitized fixture
`Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json`,
SHA-256 `57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2`,
1079 bytes, retained on `main` since the M1-024 merge. The fixture holds seven
contiguous uninterpreted application-payload runs decoding to 15, 28, 8, 22,
36, 16 and 8 bytes, 133 bytes in total, across both direction labels.

The entry carries three narrowly observational wire claims: the retained run
lengths and their aggregate, the contiguous observed ordering, and the
direction-label provenance. None of them asserts a field, a message code, a
message boundary, an endianness, a framing rule or any compatibility.

`transport.networkScope` records what the recorder observed and nothing wider.
The recorder ran on the peer loopback interface and observed the Barrier leg
there only; the wider transport leg that reached the peer host was an encrypted
local forward whose contents the recorder did not capture, so no cleartext
Barrier payload was observed or retained outside the peer-loopback leg and the
entry claims nothing about that encrypted leg. No address, port or host name is
recorded.

## Direction convention, recorded as provenance

`source.acquisitionMethod` and `BARRIER-EVID-0001-CLAIM-003` record that every
direction label was assigned from the capture producer's selected server test
port and that no label was derived from payload content. The M1-024 independent
review established concretely that the opposite server-port selection yields a
structurally valid document of the same run count and aggregate length with all
seven labels inverted, and that only the producer-recorded role reproduces the
registered digest. Issue #249 asked for this to be registered as provenance
rather than as an inference, and that is where it sits.

## Non-claims

- No field meaning, field width, field order, message code, message type,
  message boundary, endianness, framing rule, version negotiation behavior or
  payload limit is asserted. All of them are recorded in `ambiguousFields` at
  `status: unknown`, and the validator rejects any attempt to promote one of
  those identifiers into an `establishedFieldIds` list.
- No compatibility between Barrier and MacKVM, between Barrier versions, or
  between platforms is asserted.
- Windows was not executed in M1 under
  `docs/adr/M1-SCOPE-001-linux-only-validation.md`. This change claims no
  Windows result and asserts no Windows Barrier Server compatibility, and it
  adds no Windows capture requirement.
- TLS was disabled for the single M1-024 observation. The MacKVM production TLS
  default stays enabled, fail-closed and unvalidated by this entry.
- No M1-025 work is performed here. `frozenContractRefs` and `consumingTests`
  stay empty, which is the bounded state the register defines before a frozen
  contract exists.

## Raw capture disposition

The private raw capture, the peer configuration and the private capture logs
were deleted by the capture producer after M1-024 merged. The registration does
not require them, does not recreate them, and does not claim they are retained.
The sanitized fixture retained on `main` and
`evidence/issues/M1-024/independent-review.md`, which records the pre-deletion
independent re-derivation of that fixture from the raw capture by a party that
did not produce it, are the verification record. Re-deriving the fixture from
raw bytes is no longer repeatable, and that is recorded as a limitation on the
entry.

## Acceptance criteria mapping

- AC1, M1-024 completed with at least one real sanitized Linux Barrier Server
  capture and no mock substitute: `BARRIER-EVID-0001` registers that capture.
  The M1-024 independent review verified the observation was real, re-derived
  the committed fixture from the raw capture, and recorded the external peer as
  an Ubuntu 22.04 Barrier server. Verified by
  `test_registered_entry_records_the_reviewed_linux_capture` and
  `test_registered_fixture_is_a_regular_file_with_matching_digest_and_length`.
- AC2, independent provenance/licensing/content review recorded for every
  `approved` entry: `provenance.reviewer` names
  `evidence/issues/M1-024/independent-review.md`, sets
  `independentFromProducer` true, and differs from `provenance.producer`.
  Verified by `test_approved_entries_carry_a_recorded_independent_review` and
  by the M1-023 validator's producer-self-approval rule.
- AC3, unknown fields remain unknown and cannot support established claims:
  seven `ambiguousFields` at `status: unknown`, disjoint from every
  `establishedFieldIds` list. Verified by
  `test_unknown_fields_remain_unknown_and_support_no_claim` and by the M1-023
  validator.
- AC4, registry validation, docs, architecture, package, CI and
  `git diff --check` gates pass: the register tests, the registration tests,
  `python3 Tools/Backlog/validate_package.py`, `make docs-check`,
  `make architecture-check`, both CI discovery gates, all three CI evidence-test
  gates, the CI gate inventory regression
  `Tools/cigates/tests/test_cigates.py`, the `Tools/Evidence` suite, the M1-024
  capture-readiness contract suite and `git diff --check` all exit 0 in this
  session. `make verify` as a whole has not passed here and is not claimed to
  have passed: the Swift-dependent gates and `code-quality` cannot run in this
  session, and because cigates stops at the first failure they also prevent
  `make verify` from reaching the repaired tool-test gate. Their exact exits and
  observed reasons are in `commands.json`, and `make verify` must be rerun at
  the implementation commit by root outside a SwiftPM-blocking sandbox. See
  `commands.json` and `tests/results.json`.
- AC5, no typed text, clipboard payload, hostname, IP address, credential, key,
  token, private data, GPL source/header/table or decompiled material is
  committed: no capture byte and no new fixture is added by this change. The
  registered fixture is the one already on `main`, and the entry records only
  allowlist metadata, two already-declared sanitizer digests and the already
  declared fixture digest. See `manual.md`.
- AC6, registry/review wording explicitly says Windows was not tested and makes
  no Windows compatibility claim: `limitations` and `prohibitedInferences` say
  so, and the register documentation says so. Verified by
  `test_no_windows_result_is_claimed_anywhere_in_the_registration` and
  `test_registration_records_the_windows_non_execution_disposition`.
- AC7, M1-025 remains blocked until this Issue is closed: no M1-025 file is
  created, `frozenContractRefs` and `consumingTests` stay empty, and the
  register documentation keeps workflow step 7 as the only path to a frozen
  contract. `test_consumers_remain_bounded_and_resolvable` verifies that every
  consumer reference an entry carries resolves to a real non-symlink path. That
  both lists are empty today is recorded in the entry and in the register
  documentation and is deliberately not asserted by a test, because M1-025 is
  the Issue that legitimately makes them non-empty.
- Scope item "Update M1-024/M1-025 traceability and evidence links": the
  `M1-024 → M1-EVIDENCE-001 → M1-025 Barrier Evidence Chain` section of
  `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md` records the chain,
  and `docs/evidence/M1-023-barrier-evidence-register.md` points at it. Verified
  by `test_traceability_index_records_the_m1_024_to_m1_025_chain`. The M1-025
  Issue file and its contract content are untouched.

## Review remediation

Three findings were raised against the author-phase package and are addressed
here. None of the three moves a register boundary: the entry shape, the
source-validity boundary, the non-claims, the deleted-raw-capture disposition
and the Windows and TLS boundaries are not changed by any of them.

- Traceability gap (medium). Issue #249 requires updating M1-024/M1-025
  traceability and evidence links, and
  `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md` carried no chain
  from M1-024 through this Issue to M1-025. A traceability-index section was
  added that names each stage, the artifact it records and the test that
  verifies it, and the register documentation points at it. No M1-025 contract
  content is written and no M1-025 work is performed; the section records only
  that M1-025 may consume registered `approved` evidence and that
  `frozenContractRefs` and `consumingTests` stay empty until it does.
  `test_traceability_index_records_the_m1_024_to_m1_025_chain` verifies the
  section exists, names the whole chain, and names only repository paths that
  resolve to real non-symlink files.
- Weak claim-to-fixture test (medium).
  `test_registered_claims_match_the_retained_fixture_bytes` computed the exact
  decoded lengths and directions but asserted only aggregate and count strings,
  so a claim could have been repointed or widened without failing. The check is
  now an exact total mapping: each of the three stable claim ids must establish
  exactly its intended `establishedFieldIds` and point at exactly its intended
  fixture JSON pointers, including all seven observation payload pointers in
  observed order plus the two whole-`observations` pointers for the ordering
  and direction-label claims; every pointer is resolved against the retained
  document with an RFC 6901 resolver and must resolve to the exact payload it
  names; the retained sequence must be contiguous and 1-based; the per-run
  decoded lengths must appear in observed order followed by their aggregate;
  and the recorded coverage direction must match the observed label set. The
  mapping reads no prose meaning and adds no protocol semantics: a run stays an
  opaque byte run and a direction label stays a recorded capture label.
  `test_claim_mapping_rejects_a_fixture_or_claim_that_drifts` runs twelve
  mutations — six on the fixture and six on the entry — and requires each one
  to be rejected.
- Overbroad network statement (low). `transport.networkScope` said "no wider
  network path was used" although the observation was reached through an
  encrypted local forward. It now records what the recorder observed, the
  peer-loopback Barrier leg, and records the wider leg as encrypted and not
  captured rather than as absent. A matching limitation was added, and the
  register documentation and this summary were aligned. No endpoint identifier
  is introduced, and
  `test_transport_scope_records_only_the_observed_peer_loopback_leg` rejects
  both the old blanket wording and any address, port or host name.
- `provenance.producer` additionally replaced the unstable internal label
  "root session" with the durable repository references
  `evidence/issues/M1-024/summary.md` and
  `evidence/issues/M1-024/environment.json`. The field is still a single string
  and still differs from `provenance.reviewer.identity`, so the contract shape
  and the validator's producer-self-approval rule are unchanged.
  `test_producer_identity_names_durable_repository_evidence` verifies both
  references resolve to real non-symlink files.

## Post-root-verify remediation

One blocking finding was raised after root ran `make verify` in this repository
outside the managed sandbox this session runs in. On that run `code-quality`
passed and `tool-test:cigates/tests/test_cigates.py` failed:
`test_cumulative_gate_inventory_is_the_expected_named_gates` still expected the
pre-change evidence gate list and omitted
`evidence-test:M1-EVIDENCE-001/tests/test_registration.py`, the gate cigates
auto-discovers once this Issue adds that test file. The inventory regression was
therefore stale with respect to the change it is meant to guard.

The failure was reproduced here rather than taken on report: the gate's exact
command was run against the unmodified `Tools/cigates/tests/test_cigates.py` and
exited 1 with 23 tests and that one failure, the diff showing exactly the
missing evidence gate. The fix inserts
`evidence-test:M1-EVIDENCE-001/tests/test_registration.py` once, at its
discovered sort position between the M1-023 and M1-SCOPE-001 evidence gates, and
moves `EXPECTED_CUMULATIVE_GATE_COUNT` from 21 to 22. The suite's existing
`assertEqual(len(names), len(set(names)))` is what holds the gate to exactly one
occurrence, so no new assertion was added and no other line of the file changed.
The suite reruns green at 23 tests, and the focused evidence, discovery, backlog,
docs, architecture and `git diff --check` gates were rerun green alongside it.

`make verify` itself was not rerun here and no full-verify pass is claimed. In
this session `code-quality` still fails for the environmental reason recorded in
`commands.json` and cigates stops at the first failure, so the repaired
tool-test gate would not be reached. The full `make verify` must be rerun by
root at the implementation head outside the managed sandbox before this finding
is treated as cleared. Every command, exit and reason is in `commands.json`
under `postRootVerifyRemediation`, `postRootVerifyCommands` and `notRerunHere`,
and the red run is in `tests/red-phase.json` under `postRootVerifyRedPhase`.

## Known limitations

- `peer.os.build` is recorded as `not-reported`. `entryContract.requiredFields`
  makes it mandatory and non-empty, but the capture producer did not record a
  Linux peer OS build identifier before the observation,
  `MacKVM_Implementation_Package_v2/toolchain.lock.json` pins the peer OS by
  name and version only, and the private logs that might have carried it were
  deleted. The value is recorded as unreported rather than inferred, and the
  gap is stated in the entry's `limitations`.
- `nextEvidenceIssue` still reads `M1-024`. Which Issue owns the next capture
  is a workflow decision that Issue #249 has no authority to make, so the field
  is left untouched and raised as a follow-up instead.
- The M1-023 validator's `relatedIssue` pattern is `^M[1-5]-[0-9]{3}$`, which
  `M1-EVIDENCE-001` cannot match, and `entryContract.allowedObjectKeys` is
  closed. The registering Issue is therefore traceable through this evidence
  package and the register documentation rather than through a field on the
  entry. `relatedIssue` holds the producing Issue `M1-024`, which is what the
  contract defines it to hold.
- The independent review of this registration change has not happened. No
  reviewed disposition for M1-EVIDENCE-001 itself may be inferred from this
  package. The reviewed disposition it registers is M1-024's, which exists.
- `make code-quality-check` and the Swift gates inside `make verify` cannot run
  in this session: SwiftPM's own manifest cache and sandbox are denied by the
  session environment, so those gates stop before evaluating any repository
  file. The exact exits and observed reasons are in `commands.json`. This
  change adds no Swift source, no package manifest and no build setting.
- `make verify` has not been rerun since the CI gate inventory regression was
  updated. The last full `make verify` observed in this repository is root's
  outside-sandbox run, which failed on the stale inventory this change fixes.
  No full-verify pass may be read into this package until root reruns it.

## Rollback

Revert this append-only PR. The register returns to `entries: []` and status
`initialized-no-approved-evidence`, the register documentation, the M1-023
state assertions and the CI gate inventory return with it, and M1-025 stays
blocked. No accepted entry is
rewritten by the rollback, because the only entry is the one this PR appended.
No runtime, persisted user data, trust state or input state requires cleanup.

## Follow-up

- An independent reviewer who is neither the capture producer nor this author
  writes `evidence/issues/M1-EVIDENCE-001/independent-review.md` against the
  implementation commit and reruns every gate at that head, including the Swift
  gates outside a SwiftPM-blocking sandbox.
- A separate Issue decides whether `nextEvidenceIssue` should move on from
  `M1-024` now that `BARRIER-EVID-0001` is registered, and whether the entry
  contract should gain an explicit registering-Issue field whose pattern admits
  an identifier such as `M1-EVIDENCE-001`.
- A separate Issue decides whether a missing peer OS build should be a
  recordable `not-reported` value or a hard rejection in
  `entryContract.requiredFields`, and updates the capture plan's pre-capture
  metadata checklist accordingly.
- M1-025 freezes the client wire contract only from `BARRIER-EVID-0001`, keeps
  every `ambiguousFields` identifier unsupported, and links its tests through
  workflow step 7 without touching this entry's provenance, fixture digest or
  review history.
