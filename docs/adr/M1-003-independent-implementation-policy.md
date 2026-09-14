# M1-003 Independent Implementation, Licensing and Evidence Policy

## Status

Accepted by Product Owner for M1 implementation on 2026-09-14. Temporary Product Owner review waiver applies until the formal M1 gates and independent Critical/High review are completed.

## Context

MacKVM is intended to support closed-source, company-internal and commercial use. It needs Barrier-compatible behavior during M1 and M2, but copying, modifying, incorporating or linking GPL implementation may create obligations that conflict with that intended distribution model.

This ADR defines a clean-room implementation and evidence workflow. It is an engineering control, not a legal opinion. Any contemplated use of GPL implementation must stop and receive a documented licensing assessment before work continues.

Authoritative inputs:

1. [`CANONICAL_SPEC_SECTION_55.md` §55](../spec/CANONICAL_SPEC_SECTION_55.md#55-license-strategy)
2. [`M1-001-product-contract.md`](M1-001-product-contract.md)
3. [`M1-002-architecture-boundary.md`](M1-002-architecture-boundary.md)
4. [`FROZEN_DECISIONS.md`](../../MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md), especially decision 9
5. [`PROTOCOL_EVIDENCE_POLICY.md`](../../MacKVM_Implementation_Package_v2/PROTOCOL_EVIDENCE_POLICY.md)
6. [`EVIDENCE_STANDARD.md`](../../MacKVM_Implementation_Package_v2/EVIDENCE_STANDARD.md)

## Decision

### Independent implementation baseline

- Do not directly fork Barrier or Deskflow for the first-party product.
- Do not copy Barrier or Deskflow source, headers, implementation structure, comments or source-derived tables into first-party implementation.
- Do not bundle, modify, link or invoke GPL implementation as a hidden first-party product component without first stopping for licensing reassessment and Product Owner approval.
- Implement protocol encoders and decoders independently from approved behavioral evidence and frozen contracts.
- Implement the macOS input engine independently using native Swift and documented macOS APIs.
- Keep Barrier compatibility inside `BarrierCompatibility`; KVM Core and platform engines remain independent as frozen by M1-002.

### Allowed evidence sources

Implementation may rely on evidence that has a recorded source and review disposition, including:

- publicly available protocol specifications and vendor documentation whose use permits implementation
- observable network behavior from lawfully operated software in a controlled black-box interoperability test
- independently captured and sanitized packet fixtures
- expected input/output behavior and conformance vectors derived from black-box tests
- public standards for byte encoding, TLS and platform behavior
- Apple platform documentation for native input, clipboard, networking, permissions and secure storage

The mere availability of material does not establish permission to copy it. Every evidence item must record provenance and its permitted use.

### Prohibited implementation inputs

First-party implementation contributors must not use the following as implementation material:

- copied Barrier or Deskflow source files or snippets
- copied GPL headers, constants tables, generated files, comments or tests
- a line-by-line or structure-preserving translation of GPL implementation into Swift or another language
- decompiled implementation, private data or material obtained by bypassing access controls
- fixtures containing typed text, real clipboard contents, credentials, private keys, tokens or identifying network data
- model-generated claims about protocol bytes that are not backed by an approved source or captured evidence

If prohibited material enters a working tree, patch, prompt, fixture or review, work stops. The affected artifact is quarantined, its consumers are identified, and the implementation is rebuilt from approved evidence rather than cosmetically rewritten.

### Clean-room roles and separation

For Barrier wire behavior:

1. An evidence producer operates a legally obtained executable and records only externally observable behavior.
2. The producer sanitizes the capture and documents the environment, steps, input category and expected observable output.
3. A provenance/licensing reviewer verifies that the fixture contains behavior, not copied implementation, source text or private data.
4. A contract owner freezes field layout, endianness, limits, version behavior and unknown-message policy from the approved evidence.
5. An implementation contributor writes the encoder/decoder only from that frozen contract and sanitized fixture.
6. A reviewer checks source provenance, implementation independence and conformance results before merge.

The same person may perform multiple roles during early development only when the PR explicitly records that reduced separation and receives the required Product Owner waiver. Security- or release-critical evidence still requires the designated independent review before M1 completion.

### Evidence register

M1-023 establishes the canonical Barrier evidence register. Every protocol evidence item must include:

- stable evidence identifier and related Issue
- source category and acquisition method
- capture date, tool versions and peer version
- lawful-use/provenance statement and reviewer disposition
- sanitization procedure and redaction result
- cryptographic hash of the retained fixture
- protocol direction and behavior covered
- limitations, ambiguous fields and prohibited inferences
- links to the frozen contract and tests consuming the evidence

Unknown or ambiguous bytes remain unknown. A successful handshake or HTTP/TCP status does not prove unobserved field semantics.

### Per-PR provenance declaration

Every Barrier compatibility PR must state:

- all specifications, evidence IDs and fixtures used
- that no Barrier/Deskflow GPL implementation was copied, translated, linked or embedded
- whether any contributor viewed disallowed implementation material
- how each asserted wire behavior is covered by a frozen contract and test
- license/security reviewer requirement and disposition

A missing or false declaration blocks merge.

### Dependency and tool intake

Before adding a dependency or executable:

1. Record its source, version, license and intended runtime/build/test use.
2. Determine whether it is distributed with the product, linked, invoked only in testing or used only as an external interoperability peer.
3. Confirm that the planned use does not silently turn the first-party Core or application into a GPL-derived or GPL-linked deliverable.
4. Record attribution, notice and source-offer obligations when applicable.
5. Obtain a licensing review before any ambiguous or copyleft-sensitive use.

Barrier or Deskflow may be used as an external black-box test peer during M1/M2. That does not authorize copying or bundling their implementation.

## Selected versus rejected alternatives

### Selected: clean-room adapter from specifications and black-box evidence

Selected because it enables compatibility while preserving independent Core, platform engines and distribution choices.

### Rejected: fork Barrier or Deskflow

Rejected by canonical §55 because the first-party product would inherit implementation and licensing constraints instead of owning an independent protocol adapter.

### Rejected: translate GPL codec source into Swift

Rejected because changing language or names does not make a source-derived implementation independent.

### Rejected: embed an unmodified Barrier executable

Rejected because the executable would remain a product runtime dependency and would contradict the M1-001 product/exit contract. Any future separately distributed compatibility tool requires a new licensing and product decision.

### Rejected: guess protocol bytes from model output or incomplete captures

Rejected because unverifiable bytes create compatibility, security and provenance risks. Missing evidence blocks the relevant codec Issue.

## Consequences

### Positive

- First-party Core and input engines remain independently authored and protocol-neutral.
- Every compatibility claim can be traced to approved behavior and reproducible evidence.
- Ambiguous bytes and licensing questions fail closed instead of becoming hidden product debt.
- A later Native Protocol can replace the compatibility adapter without inheriting Barrier implementation.

### Costs and constraints

- Evidence capture, sanitization, review and contract freezing add work before codec implementation.
- Some protocol behavior may remain unsupported until a lawful black-box fixture exists.
- Contributors must maintain provenance declarations and avoid implementation-derived shortcuts.
- Ambiguous licensing questions require qualified review and may delay a dependent Issue.

## Security and privacy impact

- Captures and fixtures are untrusted inputs and must be size-bounded before parsing.
- Fixture sanitization removes typed text, clipboard content, credentials, private keys, tokens, device names and identifying addresses unless an explicitly synthetic value is required.
- Raw captures remain outside the repository until sanitized and reviewed.
- Hashes prove retained-fixture integrity but do not prove provenance or legal permission; both must be reviewed separately.
- Logs and diagnostic evidence use allowlisted metadata only.
- Licensing uncertainty, changed identity, malformed evidence and missing provenance fail closed.

## Compatibility impact

- Compatibility behavior is supported only when backed by a frozen contract and approved fixtures.
- Unsupported or unknown messages produce explicit typed outcomes; they are not guessed or silently treated as success.
- External Barrier/Deskflow peers remain test fixtures or optional compatibility peers, not Application Core.
- Clean-room restrictions apply equally to client and server adapters.

## Review and incident workflow

If possible GPL-derived material or an unverifiable source is discovered:

1. Stop the affected implementation and do not merge, publish or distribute it.
2. Preserve audit metadata without copying the questionable content into a new location.
3. Identify every commit, generated artifact, fixture, test and downstream file that consumed it.
4. Notify the Product Owner and licensing reviewer with the provenance facts.
5. Decide whether to remove the affected history/artifacts, rebuild cleanly or comply with applicable obligations.
6. Resume only after the disposition and clean reimplementation evidence are recorded.

This ADR does not authorize rewriting canonical history or force-pushing shared branches. Any required history remediation is a separate Product Owner-controlled incident action.

## Deferred questions with owners and blockers

| Decision | Owner | Blocking Issue |
|---|---|---|
| Barrier evidence register schema and first approved items | Protocol evidence owner plus licensing reviewer | M1-023 |
| Barrier client wire contract | Protocol owner plus fixture reviewer | M1-025 |
| Whether a proposed third-party dependency is distributable | Dependency owner plus licensing reviewer | The Issue proposing that dependency |
| Treatment of any contemplated GPL modification/linking | Product Owner plus qualified licensing reviewer | Blocks the affected implementation immediately |

## Rollback

- Revert any policy change that weakens source provenance, clean-room separation, evidence sanitization or stop conditions.
- Quarantine and replace implementation or fixtures that cannot demonstrate approved provenance.
- Do not preserve questionable code through renaming, reformatting, mechanical translation or generated output.
- Restore the last independently evidenced implementation and rerun conformance, security and license review.
- Policy changes require a superseding ADR and explicit Product Owner approval.

## Acceptance record

- Product Owner supplied and authorized canonical §55 on 2026-09-14.
- M1-001 and M1-002 are merged and establish the product and architecture boundaries used here.
- Product Owner Standing Authorization permits temporary same-executor five-axis review for M1, but not a claim of permanent independent review.
- Formal gates and independent Critical/High review must be backfilled before M1 completion.
