# M1-CAPTURE-TOOLCHAIN-001 M1-024 Capture Readiness Toolchain Lock

## Status

Accepted by Product Owner authorization on 2026-09-29, tracked in GitHub Issue #274. Amended by accepted ADR M1-040-UNBLOCK-001 on 2026-10-06 to also scope M1-040 keyboard capture without changing pinned tool versions.

## Decision owners

- Toolchain lock and M1-024 scope: Product Owner
- Security and privacy interpretation: designated Security Reviewer
- Capture evidence and independent review: designated QA/Human Reviewer who is not the implementing agent

## Context

M1-024 requires at least one real Linux Barrier Server handshake capture ([`M1-SCOPE-001`](M1-SCOPE-001-linux-only-validation.md)). Its provenance is a controlled black-box capture: a lawfully installed external Barrier macOS client (`barrierc`) connects to an external Linux Barrier server (`barriers`), and the observed bytes are used only as evidence for a later independent first-party implementation. No first-party macOS Client participates in this capture, because the first-party Mac client contract is not frozen until M1-025. Its Implementation Procedure requires the needed toolchain lock to exist before capture, and its Stop Conditions forbid guessing protocol bytes. The package only ships [`toolchain.lock.example.json`](../../MacKVM_Implementation_Package_v2/toolchain.lock.example.json), whose status is `UNRESOLVED_UNTIL_M4-001` and which describes the M4 first-party Windows/Linux production toolchain, not an M1 capture environment.

The following capture environment was verified before this decision:

- macOS capture host: macOS 26.6.2 build 25G83, arm64; Apple Swift 6.2.3 with the swift-driver version pinned in the lock, target `arm64-apple-macosx26.0`; Python 3.9.6 (system) and 3.14.7 (CI Homebrew); Barrier client `barrierc` 2.4.0-release, protocol 1.6.
- Linux external test peer: Ubuntu 22.04, x86_64; Barrier server `barriers` 2.4.0-release, protocol 1.6; Dumpcap/Wireshark 3.6.2 (package 3.6.2-2); tcpdump 4.99.1.

M1-024 as originally written also listed only four Exact Files, while its Expected Evidence and Deliverables require a fixture set and a full evidence package. That mismatch would force either an undeclared PR expansion or an incomplete evidence record.

## Decision

- Add [`MacKVM_Implementation_Package_v2/toolchain.lock.json`](../../MacKVM_Implementation_Package_v2/toolchain.lock.json) as a closed, deterministic lock with `lock_id` `M1-CAPTURE-TOOLCHAIN-001`, status `LOCKED` and scope `M1_CONTROLLED_BARRIER_BLACK_BOX_CAPTURE_ONLY`. Its scoped Issues are M1-024 and M1-040.
- The lock pins exactly the verified OS, architecture, Swift, Python, Barrier and capture tool versions listed in Context. Unknown or missing keys are invalid.
- Barrier has the role `EXTERNAL_TEST_PEER_ONLY`. No Barrier implementation is copied, linked or bundled into the repository.
- Raw packet capture stays outside the repository and is never committed. The retained fixture contains only ordered direction plus uninterpreted application payload bytes. No field meaning, message code, endianness or compatibility is asserted by the lock or the fixture.
- Windows is not executed in M1; the lock records `windows_executed` as false.
- Drift fails closed: any OS, architecture, tool, Barrier or protocol version that differs from the lock stops every capture scoped by this lock. Only a new Product Owner approved ADR may change the lock.
- M1-024 keeps its original four Exact Files first and adds exactly the two fixture files and the six evidence files (`summary.md`, `commands.json`, `tests/e2e-validation.json`, `environment.json`, `manual.md`, `independent-review.md`). The package Issue and `issues_manifest.json` are updated identically, including the clarifications above. The mandatory evidence package and the non-implementing independent review are in M1-024 scope.
- [`Tests/Contracts/test_m1_024_capture_readiness.py`](../../Tests/Contracts/test_m1_024_capture_readiness.py) enforces the lock contract, the Issue/manifest agreement and the claim prohibitions with the Python standard library only.

This decision does not change canonical or frozen product architecture: the canonical spec, `FROZEN_DECISIONS.md`, `ARCHITECTURE_GUARDRAILS.md`, `CONTRACT_CATALOG.md` and every public contract remain unchanged.

## Selected alternative

A separate M1-only capture lock plus an Exact Files amendment for M1-024. It gives capture a reviewable, machine-checked environment without resolving any M4 production toolchain decision.

## Rejected alternatives

### Fill in `toolchain.lock.example.json`

Rejected because that file represents the M4 first-party production toolchain, which stays `UNRESOLVED_UNTIL_M4-001`. Using it for a capture environment would silently pre-decide M4.

### Capture without a lock and record versions only in evidence

Rejected because version drift would then be detected only after capture, contradicting the M1-024 precondition and the fail-closed rule.

### Commit raw packet captures

Rejected because raw captures can contain hostnames, addresses, certificate material and input or clipboard content, and would exceed the minimal retained fixture.

### Decode payload semantics in the fixture

Rejected because M1-024 must not guess wire meanings; interpretation belongs to later codec Issues backed by their own evidence.

### Keep the original four Exact Files and add evidence in follow-ups

Rejected because it would leave the required fixture and evidence package undeclared, forcing a hidden PR expansion.

## Security and privacy

- The lock, fixture metadata and evidence must not contain a hostname, IP address, username, path containing a username, credential, key, token, certificate identity, certificate fingerprint, typed text or clipboard content. The lock enumerates these prohibitions and the contract test rejects identifying content.
- Raw packet capture remains outside the repository.
- Barrier is an external test peer only; no Barrier code enters the product.
- TLS default ON, fail-closed identity handling, fail-safe cleanup and privacy-safe logging requirements are unchanged.

## Compatibility

No compatibility claim is made. The retained fixture is uninterpreted bytes, and Windows Barrier Server interoperability remains unvalidated per M1-SCOPE-001.

## M4 preservation

- `toolchain.lock.example.json` is preserved byte-for-byte unchanged and keeps status `UNRESOLVED_UNTIL_M4-001`; the contract test pins its hash.
- The M1 lock records the M4 first-party production toolchain for Windows and Linux as `UNRESOLVED_UNTIL_M4-001` and states it is not selected by this lock.
- M4-001 remains the only decision point for the first-party Windows and Linux production toolchain.

## Consequences

- M1-024 and M1-040 captures can start once their Issue dependencies are satisfied and the actual environment matches the lock exactly.
- Any tool upgrade on either machine blocks capture until a new ADR updates the lock.
- M1-024 PRs are larger but fully declared: two fixture files and six evidence files.

## Rollback

Revert this ADR, `toolchain.lock.json`, the M1-024 Issue and manifest changes, and the contract test together in one change. Any fixture or evidence produced under this lock must then be treated as unapproved and must not be used as M1-024 completion evidence.

## Traceability

- GitHub Issue #274 (M1-CAPTURE-TOOLCHAIN-001)
- [`MacKVM_Implementation_Package_v2/toolchain.lock.json`](../../MacKVM_Implementation_Package_v2/toolchain.lock.json)
- [`MacKVM_Implementation_Package_v2/issues/M1/M1-024-barrier-client-handshake-fixtures.md`](../../MacKVM_Implementation_Package_v2/issues/M1/M1-024-barrier-client-handshake-fixtures.md)
- [`MacKVM_Implementation_Package_v2/issues_manifest.json`](../../MacKVM_Implementation_Package_v2/issues_manifest.json)
- [`Tests/Contracts/test_m1_024_capture_readiness.py`](../../Tests/Contracts/test_m1_024_capture_readiness.py)
- [`M1-SCOPE-001`](M1-SCOPE-001-linux-only-validation.md)
