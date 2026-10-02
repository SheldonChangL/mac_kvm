# M1-023 Barrier Compatibility Evidence Register

## Outcome

`evidence/registers/M1-023.json` is the canonical, fail-closed index for
Barrier wire evidence. It establishes the evidence contract before any wire
codec is written. The register holds no byte layout, field meaning, message
code, or compatibility assertion: a registered entry records only what was
observed and what remains unknown, and anything it does not record stays
unsupported until new approved evidence supersedes that uncertainty.

M1-024 owns the first controlled Linux server capture and sanitized handshake
fixture. M1-EVIDENCE-001 appended that fixture as `BARRIER-EVID-0001` after
provenance and independent review. M1-WIRE-001 (GitHub Issue #278) then
appended `BARRIER-EVID-0002`, a conformance vector derived from the same
fixture. It remained `pending-review` until its independent five-axis review
was recorded in `evidence/issues/M1-WIRE-001/independent-review.md`; both
entries are now `approved`, each only for its distinct recorded claims. A capture or
passing interaction that is absent from this register with disposition
`approved` is not implementation input, and M1-025 may freeze a client wire
contract only from registered `approved` evidence.

## Authority and source boundary

The register implements the evidence workflow established by:

- canonical specification §55;
- the accepted M1-003 independent-implementation ADR;
- the Protocol Evidence Policy; and
- the M1-007 fixture metadata schema.

Allowed evidence is limited to lawful public specifications, controlled
black-box observation, and sanitized conformance vectors derived from an
approved source. Availability alone does not authorize copying. Barrier or
Deskflow source, headers, implementation structure, comments, constant tables,
generated implementation artifacts, or decompiled material are prohibited.

## Register state and consumption rule

The initial `status` was `initialized-no-approved-evidence` with `entries`
empty by design. That was a safety state, not an assertion that the protocol
has no fields: it meant every Barrier wire behavior remained unsupported and
blocked codec work until evidence was captured and approved. The register is
now `active` and holds the two entries described below. Every Barrier wire
behavior that an `approved` entry does not record remains unsupported.

Only an entry whose `provenance.disposition` is exactly `approved` may support
a wire contract or implementation. `pending-review`, `rejected`, `quarantined`,
and `superseded` entries are non-consumable. Approval requires a reviewer who
is independent of the evidence producer; a Product Owner merge-review waiver
does not convert unreviewed protocol evidence into approved evidence. An
approved entry must establish at least one individually identified wire claim;
an empty approval cannot be used as a compatibility gate.

The register status must match its contents: an empty register remains
`initialized-no-approved-evidence`, while any non-empty register is `active`.
Retained fixtures must be regular files whose path contains no symlink; length
and SHA-256 are verified with bounded streaming reads before an entry passes.

Updates are append-only. Corrections add a replacement entry and mark the old
entry `superseded`; they never rewrite the provenance, fixture digest, or review
history of an accepted observation.

## Registered evidence

`BARRIER-EVID-0001` is the first entry and the only `approved` one.
M1-EVIDENCE-001 appended it; M1-024 produced it. `BARRIER-EVID-0002`, described
in the next section, follows it and does not change it.

- Producing Issue: `M1-024`; registering Issue: M1-EVIDENCE-001.
- Fixture: `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json`
- Source: one controlled black-box observation of two lawfully installed
  external Barrier programs, an external Barrier client against an external
  Ubuntu 22.04 Barrier server, with TLS disabled for that observation only.
- Transport scope: the recorder ran on the peer loopback interface and observed
  the Barrier leg there only, so every retained byte comes from that
  peer-loopback observation. The wider transport leg that reached the peer host
  was an encrypted local forward whose contents the recorder did not capture;
  no cleartext Barrier payload was observed or retained outside the
  peer-loopback leg, and the register makes no claim about that encrypted leg.
  No address, port or host name is recorded.
- Coverage: seven contiguous uninterpreted application-payload runs in both
  directions, 133 decoded bytes in total, inside one bounded connection window.
- Review: `evidence/issues/M1-024/independent-review.md` records the
  independent provenance, licensing, privacy and content review, and records
  the pre-deletion re-derivation of the fixture from the raw capture by a party
  that did not produce it.

Three boundaries govern every consumer of that entry.

1. Its `ambiguousFields` keep message code, field layout and widths, byte
   order, framing and message boundaries, version negotiation, optional and
   variant fields, and payload limits at `status: unknown`. None of those
   identifiers may appear in an `establishedFieldIds` list.
2. Its direction labels are capture provenance, not analysis. The capture
   producer supplied the server test port of the endpoint role it operated, and
   the sanitizer applied that producer-selected role; no direction label is
   derived from payload content, and the opposite port selection yields a
   structurally valid document with every label inverted.
3. Windows was not executed in M1 under
   `docs/adr/M1-SCOPE-001-linux-only-validation.md`, so this register records
   no Windows result and asserts no Windows Barrier Server compatibility. That
   ADR supersedes the Windows capture prerequisite this document previously
   carried, so no Windows capture is required in M1.

The private raw capture, the peer configuration and the private capture logs
were deleted by the capture producer after M1-024 merged. They are not retained
for this registration and must not be required or recreated. The sanitized
fixture on `main` and the M1-024 independent review are the verification
record; re-deriving the fixture from raw bytes is no longer repeatable.

`nextEvidenceIssue` still names `M1-024`. That field records which Issue owns
the next capture, no accepted source names a successor to M1-024, and
M1-EVIDENCE-001 has no authority to invent one, so it is left untouched and
raised as a follow-up rather than guessed.

`frozenContractRefs` and `consumingTests` are both empty, which is the correct
bounded state before M1-025 exists. Workflow step 7 is the only way they become
non-empty: M1-025 freezes a separate wire contract and links its tests, and
that link must leave the provenance, the fixture digest and the review history
of this entry untouched.

### Derived conformance vector

`BARRIER-EVID-0002` is a `sanitized-conformance-vector` entry appended by
M1-WIRE-001 (GitHub Issue #278) under
`docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`.

- It pins the same fixture path, SHA-256 and byte length as
  `BARRIER-EVID-0001` and introduces no new byte. Its `relatedIssue` is
  `M1-024`, the producer of the bytes, because the entry contract admits
  canonical manifest ids only.
- Its claims cite the fixture and the deterministic artifact
  `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`: a candidate
  4-byte unsigned big-endian length-prefix interpretation partitions every
  retained run with no remaining bytes, the first candidate frame in each
  direction starts with the 7 marker bytes of the ASCII word Barrier, and the
  4 bytes after the marker are `00 01 00 06`. The candidate interpretation is
  not proof of the prefix width, because a narrower 2-byte big-endian reading
  also partitions every run; the exact width stays unknown and blocked pending
  separately approved discriminating evidence.
- Its own `ambiguousFields` keep message codes, other field layout, the
  uniqueness of the prefix width, maximum frame length, fragmentation, the
  width and meaning of the version bytes, version negotiation and variant
  fields at `status: unknown`.
- It proposes, and does not decide, an exact-supported-version fail-closed
  policy for M1-025.
- It is not a correction of `BARRIER-EVID-0001`, so that entry is not marked
  `superseded`, not rewritten and not upgraded, and its unknown fields stay
  unknown in that entry.
- It remained `pending-review`, and therefore non-consumable, until a reviewer
  who was not the M1-WIRE-001 author recorded the review in
  `evidence/issues/M1-WIRE-001/independent-review.md`. It is now `approved`
  for its candidate-only claims; exact prefix width remains unknown and blocked
  on GitHub Issue #279 (M1-WIRE-002).

## Traceability index

The M1-024 → M1-EVIDENCE-001 → M1-025 chain, its artifacts and the test that
verifies each stage are indexed in
`MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md`, under the
`M1-024 → M1-EVIDENCE-001 → M1-025 Barrier Evidence Chain` section. That index
is traceability only; it freezes no wire contract and carries no M1-025
contract content. The corrected M1-WIRE-001 → M1-025 → M1-021 → M1-022 order is
indexed in the section that follows it.

## Required entry metadata

Every entry carries the following categories. The machine-readable
`entryContract.requiredFields` list is authoritative for path spelling.

| Category | Required evidence |
|---|---|
| Identity | Stable `BARRIER-EVID-NNNN` id and producing Issue |
| Source | Category and acquisition method |
| Capture | UTC date and exact capture tool names/versions |
| Peer | Product, version, server/client role, OS name/version/build |
| Transport | Sanitized network scope and explicit TLS enabled/version state |
| Provenance | Lawful-use statement, permitted use, producer, reviewer, disposition |
| Sanitization | Procedure, `sanitized` status, sensitive-data false, removed categories |
| Fixture | Repository-relative Barrier fixture path, SHA-256, byte length |
| Coverage | Direction, observed behaviors, individually identified wire claims |
| Uncertainty | Limitations, ambiguous fields, and prohibited inferences |
| Consumers | Frozen contract and test references, including empty lists before they exist |

TLS must be recorded as a boolean observation. When TLS is enabled, the
observed protocol version is mandatory. Certificate identity must be sanitized;
no certificate, private key, credential, token, hostname, address, or fingerprint
is stored in the register.

## Wire claims and unknown fields

Each wire claim belongs to one evidence entry and includes a stable claim id,
the narrowly observed assertion, the field identifiers established by that
assertion, and fixture locations supporting it. A whole handshake or connection
success never proves an unobserved field meaning.

Every ambiguous field remains recorded with `status: unknown`. An unknown field
identifier may not appear in a claim's `establishedFieldIds`. Its value,
endianness, semantic meaning, version behavior, optionality, and limits remain
unsupported until new approved evidence supersedes that uncertainty. Unknown
bytes must not be filled from model output, implementation source, analogy, or
memory.

## Privacy and licensing review

Raw captures remain outside the repository until allowlist sanitization and
review complete. Retained fixtures must exclude typed text, clipboard payload,
credentials, keys, tokens, hostnames, IP addresses, and other private data.
The fixture hash establishes integrity only; it does not prove lawful origin or
permission. Provenance and licensing disposition remain separate mandatory
review decisions.

If questionable implementation-derived material, incomplete provenance, a hash
mismatch, sensitive content, or a producer self-approval is discovered, the
entry is rejected or quarantined and every consumer remains blocked.

## Validation coverage

`evidence/issues/M1-023/tests/test_register.py` validates:

- the fail-closed contract and the status/entry-presence consistency rule in
  both directions;
- every persisted entry, including streamed fixture digest and length checks
  and the regular-file, no-symlink path rule;
- a complete in-memory approved-entry happy path (never persisted as evidence);
- missing peer/server version rejection;
- enabled TLS without an observed version rejection;
- sensitive or non-independently reviewed evidence rejection; and
- rejection when an unknown field is promoted to an established claim.

`evidence/issues/M1-EVIDENCE-001/tests/test_registration.py` validates the
registration itself against the same validator: the registered entry, the
fixture integrity, the recorded independent review, the unknown-field
disjointness, the explicit prohibited inferences, the bounded consumer lists,
the direction-convention provenance, the deleted-raw-capture statement, and the
rule that no Windows result is claimed anywhere in the registration. It also
maps each of the three stable claim ids to exactly the field identifiers and
the exact fixture JSON pointers it is allowed to establish, resolves every
pointer against the retained document, checks the decoded run lengths and their
aggregate in observed order, checks that the recorded transport scope stays
within what the recorder observed and names no endpoint, checks that the
producer identity resolves to repository evidence, and checks the traceability
index. A mutation suite confirms every one of those checks rejects a drifted
fixture or a widened claim.

`Tests/Contracts/test_m1_wire_001_contract_sequence.py` validates the
M1-WIRE-001 append: it pins `BARRIER-EVID-0001` byte for byte, re-derives the
conformance artifact from the fixture, maps each `BARRIER-EVID-0002` claim to
the exact fixture and artifact locations it cites, keeps that entry
non-consumable until its independent review exists, and rejects drifted
fixtures, artifacts and entries with in-memory mutations.

Neither Issue captures network traffic, operates a Barrier peer, or claims
protocol compatibility. Therefore peer execution, input cleanup, cancellation,
and stuck-input checks are not applicable to these registry-only changes; no
mock is substituted for the real Linux capture required by M1-024, which
`docs/adr/M1-SCOPE-001-linux-only-validation.md` scopes to Linux only.

## Registration workflow

1. Capture externally observable behavior in the owning H Issue.
2. Keep raw capture outside the repository.
3. Sanitize a bounded retained fixture and compute its SHA-256/byte length.
4. Record peer, OS, TLS, tools, acquisition, limitations, and unknown fields.
5. Obtain independent provenance/licensing and content review.
6. Append the entry; only `approved` evidence becomes consumable.
7. Freeze a separate wire contract and link its tests without rewriting evidence.

## Scope and rollback

This register adds no product runtime behavior, protocol parser, encoder,
message code, dependency, networking implementation, TLS policy, logging, UI,
or public Swift API. Barrier remains confined to the future compatibility
adapter, and KVM Core continues to receive only `KVMEvent`.

Rollback by reverting the M1-023 PR and blocking M1-024/M1-025 and all Barrier
codec work until an equivalent fail-closed register is restored. No runtime,
persisted user data, trust state, or input state requires cleanup.

Rolling back the M1-EVIDENCE-001 registration instead is narrower: revert that
append-only PR, which returns the register to `entries: []` and status
`initialized-no-approved-evidence`, and keep M1-025 blocked. An accepted entry
is never rewritten in place; a correction is a reviewed replacement entry that
marks the earlier one `superseded`.

Rolling back the M1-WIRE-001 append before it merges removes
`BARRIER-EVID-0002` and leaves `BARRIER-EVID-0001` exactly as registered. After
merge the register stays append-only, so the derived entry is marked `rejected`
or `superseded` by a reviewed follow-up rather than deleted, and M1-025 stays
blocked until approved evidence exists.
