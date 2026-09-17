# M1-023 Barrier Compatibility Evidence Register

## Outcome

`evidence/registers/M1-023.json` is the canonical, fail-closed index for
Barrier wire evidence. It establishes the evidence contract before any wire
codec is written. No approved wire evidence exists yet; the register therefore
contains no wire claim, fixture, byte layout, field meaning, message code, or
compatibility assertion.

M1-024 owns the first controlled Windows/Linux server captures and sanitized
handshake fixtures. Those artifacts must receive provenance and independent
review, then an append-only register update, before M1-025 may use them to
freeze a client wire contract. A capture or passing interaction that is absent
from this register with disposition `approved` is not implementation input.

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

The initial `status` is `initialized-no-approved-evidence` and `entries` is
empty by design. This is a safety state, not an assertion that the protocol has
no fields. It means every Barrier wire behavior remains unsupported and blocks
codec work until evidence is captured and approved.

Only an entry whose `provenance.disposition` is exactly `approved` may support
a wire contract or implementation. `pending-review`, `rejected`, `quarantined`,
and `superseded` entries are non-consumable. Approval requires a reviewer who
is independent of the evidence producer; a Product Owner merge-review waiver
does not convert unreviewed protocol evidence into approved evidence.

Updates are append-only. Corrections add a replacement entry and mark the old
entry `superseded`; they never rewrite the provenance, fixture digest, or review
history of an accepted observation.

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

The issue evidence test validates:

- the canonical empty fail-closed state;
- a complete in-memory approved-entry happy path (never persisted as evidence);
- missing peer/server version rejection;
- enabled TLS without an observed version rejection;
- sensitive or non-independently reviewed evidence rejection; and
- rejection when an unknown field is promoted to an established claim.

This Issue does not capture network traffic, operate a Barrier peer, or claim
protocol compatibility. Therefore peer execution, input cleanup, cancellation,
and stuck-input checks are not applicable to this registry-only change; no mock
is substituted for the real Windows/Linux captures required by M1-024.

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
