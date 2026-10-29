# M4-001 Evidence Summary

## Scope

Exact File: `docs/adr/M4-001-cross-platform-toolchain.md`. The issue scope also requires
a toolchain lock; it is `MacKVM_Implementation_Package_v2/toolchain.m4.lock.json`.
`toolchain.lock.json` already holds the M1 capture lock, and its M4 placeholders are
pinned by `Tests/Contracts/test_m1_024_capture_readiness.py`. `toolchain.lock.example.json`
is pinned byte for byte. Both stay unchanged.

Starting M4-001 now relies on M4-SCOPE-001 (PR #331), which removes the dependency on
M3-039.

## Decision

The Linux language is Swift, a Product Owner decision of 2026-10-29 (「Swift」,
Issue #330). The ADR selects the rest of the Linux toolchain. Windows stays an open
question owned by the Product Owner.

## Evidence

- `spikes/linux-shared-packages.sh` builds and tests `KVMContracts`, `BarrierCompatibility`
  and `KVMCore` in the pinned image. Output: `tests/linux-shared-packages.txt`.
- `spikes/tls-pinning/` builds the TLS pinning spike as a static-stdlib release binary,
  runs it and lists its dynamic libraries. Output: `tests/tls-pinning.txt`.
- Commands, exit codes and time windows: `commands.json`. Environment: `environment.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| Selected, Rejected, Consequences, Security/Compatibility impact, Rollback | ADR sections of the same names |
| Every open question has an owner and a blocking condition | ADR "Open questions" |
| Owner, Security and Human sign-off recorded | ADR "Acceptance record": Product Owner recorded; Security Reviewer and evidence reviewer pending |
| Security reviewer checks fail-closed, key handling, identity change, abuse paths | `security-review.md`, pending reviewer |
| Manual evidence verified by a non-implementing reviewer | `manual.md`, pending reviewer |

## Review

Pending: Security Reviewer and a reviewer who is not the implementing agent.
