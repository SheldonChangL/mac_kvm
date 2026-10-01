# M1-EVIDENCE-001 Manual Verification

## Scope

This H evidence verifies an append-only registry change. M1-EVIDENCE-001
operates no Barrier peer, captures no packet, and produces no fixture. The real
Linux Barrier Server observation it registers is owned by M1-024 and is already
on `main`; no mock is substituted for it, and no new capture was run, requested
or recreated here.

## Source validity

1. Read the live GitHub Issue #249 body.
   - Expected: an authoritative scope, acceptance criteria and superseding
     scope authority.
   - Actual: read read-only with `gh issue view 249`. It carries the Outcome,
     the superseding scope authority naming
     `docs/adr/M1-SCOPE-001-linux-only-validation.md`, the dependency relation
     on M1-024 and the blocking relation on M1-025, seven acceptance criteria,
     and a rollback. It carries no `Exact Files` section.
2. Looked for a packaged source for this Issue.
   - Expected: either a packaged Issue file or a documented absence.
   - Actual: `MacKVM_Implementation_Package_v2/issues/M1/` contains no
     `M1-EVIDENCE-001` file and `issues_manifest.json` contains no
     `M1-EVIDENCE-001` identifier. The live Issue is therefore the
     authoritative source, and the deliverable file set follows the M1-023
     evidence-package pattern rather than an Exact Files list.
3. Read every required source.
   - Actual: `evidence/registers/M1-023.json`,
     `evidence/issues/M1-023/tests/test_register.py`,
     `docs/evidence/M1-023-barrier-evidence-register.md`, the M1-024 fixture
     pair, `evidence/issues/M1-024/independent-review.md`,
     `evidence/issues/M1-024/summary.md`,
     `evidence/issues/M1-024/environment.json`,
     `evidence/issues/M1-024/commands.json`,
     `MacKVM_Implementation_Package_v2/toolchain.lock.json`,
     `docs/adr/M1-SCOPE-001-linux-only-validation.md`,
     `MacKVM_Implementation_Package_v2/PROTOCOL_EVIDENCE_POLICY.md`,
     `MacKVM_Implementation_Package_v2/ARCHITECTURE_GUARDRAILS.md`,
     `MacKVM_Implementation_Package_v2/DEFINITION_OF_READY.md`,
     `MacKVM_Implementation_Package_v2/DEFINITION_OF_DONE.md` and the packaged
     M1-025 Issue are all present and readable. No required source is missing,
     inaccessible or in concrete conflict with this Issue.
4. Checked one source gap rather than inferring past it.
   - Expected: a recorded Linux peer OS build for `peer.os.build`.
   - Actual: none exists. `evidence/issues/M1-024/environment.json` records the
     peer OS name, version and architecture but no build;
     `toolchain.lock.json` pins the peer OS by name and version only; and
     `evidence/issues/M1-024/manual.md` records the peer as Ubuntu 22.04 with
     no build column. The private logs that might have carried it were deleted.
     The field is mandatory and non-empty in `entryContract.requiredFields`, so
     it is recorded as `not-reported`, following the M1-024 precedent of
     recording unproven values explicitly, and the gap is stated in the entry's
     `limitations` and raised as a follow-up. No build identifier is invented.

## Steps and results

1. Ran the full gate set at the pre-change head.
   - Expected: a clean baseline, so that any later failure is attributable.
   - Actual: register tests 11/11, `make docs-check`, `make architecture-check`,
     `python3 Tools/Backlog/validate_package.py` and `git diff --check` all
     exit 0.
2. Wrote `tests/test_registration.py` before changing the register, and
   re-established the red phase by observation rather than by recall.
   - Expected: a failing red phase that names the missing registration, and a
     demonstration that the two M1-023 state assertions had to change rather
     than were changed for convenience.
   - Actual: the pre-change `evidence/registers/M1-023.json` and
     `docs/evidence/M1-023-barrier-evidence-register.md` were restored from
     `HEAD` into the working tree, the three red commands were run, and the
     modified copies were restored and confirmed byte-identical by SHA-256.
     `test_registration.py` exits 1 with 14 tests, 10 failures and 0 errors;
     seven of them report `exactly one BARRIER-EVID-0001 entry must exist`,
     and the remaining three name the stale documentation sentence, a Windows
     sentence that the pre-change documentation did not negate, and the
     `initialized-no-approved-evidence` status. The updated
     `test_register.py` exits 1 against the pre-change register, and the
     pre-change `test_register.py` exits 1 against the registered register.
     All three runs are recorded in `tests/red-phase.json`.
3. Appended `BARRIER-EVID-0001` and moved `status` to `active`.
   - Expected: the M1-023 validator accepts the entry, recomputes the fixture
     digest and length from the file as it stands in the tree, and rejects a
     status that disagrees with entry presence.
   - Actual: accepted. `shasum -a 256` over the fixture returns
     `57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2` and
     `stat` returns 1079 bytes, both matching the registered values and both
     matching the digest and length already declared in the fixture
     `metadata.json`, in `evidence/issues/M1-024/commands.json` and in the
     M1-024 independent review.
4. Verified the fixture path is a regular file with no symlink component.
   - Expected: every path component resolves without a symlink and the leaf is
     a regular file.
   - Actual: confirmed by the M1-023 validator and independently by
     `test_registered_fixture_is_a_regular_file_with_matching_digest_and_length`.
5. Verified the unknown-field rule.
   - Expected: every ambiguous identifier stays `unknown` and none appears in
     an `establishedFieldIds` list.
   - Actual: seven ambiguous identifiers, all `unknown`, disjoint from the nine
     established identifiers across the three claims.
6. Verified the independent review that authorises the `approved` disposition.
   - Expected: a review by a party that is neither the capture producer nor the
     implementation author, recorded in the repository.
   - Actual: `evidence/issues/M1-024/independent-review.md` is present on
     `main`, states its own independence explicitly, records zero Critical,
     High and Medium findings, and records that the reviewer re-ran the
     producer's sanitizer over the raw capture and reproduced the committed
     fixture byte for byte. `provenance.reviewer.identity` names that file and
     differs from `provenance.producer`, which the validator requires.
     `reviewedAt` is `2026-10-01T02:36:57Z`, the UTC committer timestamp of
     `294700a0d3dd9b96d7c00e2681d4aad89f66afc5`, the commit that added the
     review.
7. Verified the raw-capture disposition is recorded without a retention claim.
   - Expected: the registration neither requires the deleted private material
     nor claims it is retained.
   - Actual: the entry's `limitations` record the deletion after the M1-024
     merge, record that re-derivation from raw bytes is no longer repeatable,
     and name the retained fixture plus the M1-024 independent review as the
     verification record. No file changed by this Issue asserts that the raw
     capture is still held.
8. Inspected the change for prohibited material.
   - Actual: no packet byte, no new fixture, no peer address, host name or
     port, no typed text, no clipboard payload, no credential, key or token, no
     Barrier or Deskflow source, header or constant table, and no decompiled
     material. Every hexadecimal run added to the register is a digest already
     declared and independently verified in the M1-024 package: the fixture
     digest, the sanitizer digest and the sanitizer self-test digest.
9. Confirmed the two untracked owner artifacts at the repository root are
   outside this Issue.
   - Actual: neither was opened, read, staged or modified.
10. Reread the live GitHub Issue #249 scope for the traceability obligation.
    - Expected: an explicit instruction about M1-024/M1-025 traceability.
    - Actual: `gh issue view 249` read-only returns the Scope bullet "Update
      M1-024/M1-025 traceability and evidence links", which the author phase did
      not satisfy.
      `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md` carried no chain
      from M1-024 through this Issue to M1-025. A traceability-index section was
      added that names each stage, its artifact and its verifying test. No
      M1-025 contract content was written, the packaged M1-025 Issue file was
      not opened for modification, and no wire contract was frozen.
11. Re-established the red phase for the three new checks by observation.
    - Expected: each new assertion fails against the wording it replaced.
    - Actual: the pre-fix `transport.networkScope`, the pre-fix
      `provenance.producer` and the absence of the traceability section were
      restored into the working tree from backups taken first. The suite exited
      1 with 18 tests and exactly 3 failures:
      `test_transport_scope_records_only_the_observed_peer_loopback_leg` on "no
      wider network path", `test_producer_identity_names_durable_repository_evidence`
      on "root session", and
      `test_traceability_index_records_the_m1_024_to_m1_025_chain` on the
      missing section. Both files were then restored and confirmed byte-identical
      by SHA-256: `evidence/registers/M1-023.json`
      `18a1f5de1bb44a7ae3c390146db5ede7491ad42f5490d8273466e50c65a78c5e` and
      `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md`
      `7fa562db6562477943e1ea727ab4641742afaacf27bf6d56d6a096e00118ff3c`. No git
      index operation was performed and nothing was staged or committed.
12. Verified the strengthened claim-to-fixture mapping rejects drift.
    - Expected: the mapping must fail on a drifted fixture or a widened claim,
      not merely on an aggregate that still happens to match.
    - Actual: `test_claim_mapping_rejects_a_fixture_or_claim_that_drifts` runs
      twelve mutations in memory — a dropped run, a resized run, two swapped
      payloads, a renumbered sequence, collapsed direction labels, an
      undecodable payload, a repointed payload pointer, a pointer outside the
      registered fixture, a widened `establishedFieldIds` list, a reordered
      `establishedFieldIds` list, a renamed claim id, and a restated aggregate —
      and every one is rejected. No fixture byte on disk is modified by the
      suite; every mutation is a deep copy.
13. Checked that the rewritten transport scope records no endpoint.
    - Expected: no address, no port and no host name anywhere in the field.
    - Actual: the field names the peer loopback interface, records the wider leg
      as encrypted and uncaptured rather than as absent, and matches no IPv4
      literal, IPv6-style token, `:port` suffix or host-name pattern. Verified by
      `test_transport_scope_records_only_the_observed_peer_loopback_leg`.

14. Reproduced and fixed the stale CI gate inventory that root's outside-sandbox
    `make verify` exposed.
    - Reported: root ran `make verify` in this repository outside the managed
      sandbox this session runs in. `code-quality` passed and
      `tool-test:cigates/tests/test_cigates.py` failed, because
      `test_cumulative_gate_inventory_is_the_expected_named_gates` still
      expected the pre-change evidence gate list and omitted
      `evidence-test:M1-EVIDENCE-001/tests/test_registration.py`.
    - Expected: the reported failure should reproduce here from the gate's own
      command, and the auto-discovered gate should appear exactly once.
    - Actual: `python3 -m unittest discover -s Tools/cigates/tests -p
      'test_cigates.py'` against the unmodified file exits 1 with 23 tests, 1
      failure and 0 errors, reporting `Lists differ` with
      `evidence-test:M1-EVIDENCE-001/tests/test_registration.py` present in the
      actual inventory and absent from the expected one. The suite's own
      per-gate run log shows that gate executing as the twenty-second named
      gate, and the evidence discovery gate reports 3 files. The expected list
      gained that one name at its discovered sort position between the M1-023
      and M1-SCOPE-001 evidence gates, and
      `EXPECTED_CUMULATIVE_GATE_COUNT` moved from 21 to 22. The suite's existing
      `assertEqual(len(names), len(set(names)))` already rejects a duplicate, so
      no assertion was added. Rerun green at 23 tests.
    - Not done: `make verify` was not rerun here. `code-quality` still fails in
      this session for the recorded environmental reason and cigates stops at
      the first failure, so the repaired gate would not be reached. No
      full-verify pass is claimed; root must rerun it outside the managed
      sandbox.

## Platform disposition

Windows was not executed by this Issue and was not executed in M1 at all, under
`docs/adr/M1-SCOPE-001-linux-only-validation.md`. No Windows result is claimed
or implied, no Windows compatibility is asserted, and no Windows capture is
required or added. The registered entry and the register documentation both say
so in their own wording.

## Cleanup and fail-safe

No connection, TLS session, input event, key or button state, process,
temporary fixture or mutable product resource is created by this change.
Cancellation, input cleanup and stuck-input verification are not applicable to
this registry-only change. The MacKVM production TLS default is untouched: this
change contains no Swift source, no package manifest and no build setting.

## Reviewer disposition

This package was produced by the implementation author. It is not an
independent review. An independent reviewer who is neither the M1-024 capture
producer nor this author must verify it against the implementation commit and
must rerun every gate at that head, including the Swift gates outside a
SwiftPM-blocking sandbox, before this Issue is closed.

## Remaining manual work

- Independent review of this registration change.
- A decision on `nextEvidenceIssue` and on whether the entry contract should
  carry an explicit registering-Issue field.
- A decision on whether a missing peer OS build is a recordable value or a hard
  rejection.
- M1-025 freezes the client wire contract only from `BARRIER-EVID-0001`.
