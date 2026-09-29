# M1-SCOPE-001 Linux-only M1 Barrier Server Validation

## Status

Accepted on 2026-09-29 by Product Owner decision recorded in GitHub Issue #270.

Product Owner decision (verbatim, 2026-09-29): 「確定，決定Windows不執行」.

## Decision owners

- Milestone scope: Product Owner
- Security interpretation: designated Security Reviewer
- Manual evidence and milestone exit: designated QA/Human Reviewer who is not the implementing agent

## Context

[`M1-001-product-contract.md`](M1-001-product-contract.md) and [`PRODUCT_ROADMAP.md`](../../MacKVM_Implementation_Package_v2/PRODUCT_ROADMAP.md) originally required M1 to validate the first-party Mac Client against both Windows and Linux Barrier Servers. The Product Owner has decided that Windows is not executed in M1.

This decision is interpreted narrowly: Windows execution and validation are excluded from M1 only. Linux is the only real-platform Barrier Server capture and E2E target in M1.

## Preserved sources

- [`docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md`](../spec/CANONICAL_SPEC_SECTIONS_60_64.md) remains the canonical source and is preserved byte-for-byte unchanged.
- [`docs/adr/M1-001-product-contract.md`](M1-001-product-contract.md) remains Accepted historical context and is preserved byte-for-byte unchanged. This ADR supersedes only the M1 validation clauses listed below; every other statement of M1-001 remains binding.
- Explicitly frozen decisions in [`FROZEN_DECISIONS.md`](../../MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md) remain unchanged and binding.
- [`SOURCE_TRACEABILITY.md`](../../MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md) remains an index only and does not become a product contract.

## Superseded clauses

This ADR supersedes exactly these M1 validation clauses and nothing else:

1. M1 goal/exit wording that requires both Windows and Linux Barrier Servers, including M1-001 “Connects to existing Windows and Linux Barrier servers through the Barrier Protocol Adapter.” and the `PRODUCT_ROADMAP.md` M1 goal and exit criterion “Windows 與 Linux Barrier Server 均可控制 Mac”.
2. M1-024 requirement for Windows and Linux Server fixtures (“Windows 與 Linux Server 各至少一組”).
3. M1-040 requirement for a Windows Server keyboard fixture set (“至少 Windows Server 一組”).
4. M1-068 requirement to execute Windows Barrier Server → Mac Client E2E.
5. M1-069 requirement to list differences against Windows (“列出與 Windows 差異”).
6. M1-070 use of the old Windows and Linux exit criteria.

## Decision

### Replacement M1 validation clauses

- M1 goal and exit require real Linux Barrier Server → first-party Mac Client validation only.
- M1-024 requires at least one real Linux Barrier Server handshake capture. A mock, simulator or synthesized capture is not a substitute. Sanitisation, provenance metadata, capture reproduction steps and non-implementing reviewer verification remain required.
- M1-040 requires at least one real Linux Barrier Server keyboard fixture set with the same sanitisation, provenance and reviewer requirements.
- M1-068 remains in the 70-issue plan as a Product Owner-approved Windows non-execution disposition gate. It must not execute Windows, must not report pass or compatibility, and records a machine-readable disposition plus reviewable documentation in its existing Exact Files.
- M1-069 remains a Tier H real Linux Barrier Server → Mac Client E2E gate. Windows results are unavailable and out of M1 scope; M1-069 performs no Windows comparison.
- M1-070 evaluates these Linux-only exit criteria.

### Windows claim boundary

- Windows was not executed or tested in M1.
- Windows Barrier Server compatibility must not be claimed from M1 evidence, M1 fixtures, M1-068 disposition records or the M1-070 exit review.
- Existing documents that list a Windows capture prerequisite for M1, including the M1-023 evidence register, are superseded for M1 by this ADR; their correction is tracked separately.

### Unchanged product scope

- M2, M4 and M5 Windows product scope remains unchanged. In particular, M4 first-party Windows support remains unchanged.
- The following architecture and security contracts remain unchanged: Swift native macOS implementation; Barrier exists only inside the Protocol Adapter; `KVMEvent` is the unified Core/Protocol boundary; Protocol and KVM Core remain separated; Input Engine remains independent of Barrier codes and networking; client before server; production TLS default ON and fail closed; fail-safe cleanup on every terminal path; privacy-safe evidence and logging; independent implementation.

## Rejected alternatives

### Remove M1-068 from the plan

Rejected because the 70-issue plan and dependency graph remain stable, and an explicit disposition gate makes the exclusion auditable before Linux E2E.

### Replace Windows evidence with mocks or Linux results

Rejected because it would present unexecuted platform behavior as validated.

### Remove Windows from M2, M4 or M5

Rejected because the Product Owner decision is limited to M1 execution.

## Consequences

- M1 exit can be reached with real Linux Barrier Server evidence only.
- M1 release wording must state that Windows Barrier Server interoperability was not validated.
- Windows Barrier interoperability risk remains open and must be addressed by later milestone evidence rather than inferred from M1.

## Security impact

None to the security contract. TLS default ON, fail-closed identity handling, fail-safe cleanup and privacy-safe evidence requirements are unchanged and apply fully to Linux validation.

## Compatibility impact

M1 makes no Windows Barrier Server compatibility claim. Linux Barrier Server compatibility evidence requirements are unchanged in rigor.

## Rollback

If the Product Owner reinstates Windows validation for M1, a new superseding ADR must restore the Windows clauses. M1-068 disposition records must not be reinterpreted as Windows execution evidence.

## Acceptance record

- Product Owner decision: 「確定，決定Windows不執行」, 2026-09-29, GitHub Issue #270.
- Implementing agent is not authorized to provide independent review or merge approval.
