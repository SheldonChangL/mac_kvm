# M1-040-UNBLOCK-001 M1-040 Keyboard Capture Scope

## Status

Proposed, pending Product Owner approval. Tracked in GitHub Issue #282.

This ADR is a corrective governance draft. Until the Product Owner records acceptance in this section, it authorizes no capture, no fixture and no change to `toolchain.lock.json`.

## Decision owners

- M1-040 scope and toolchain lock scope: Product Owner
- Security and privacy interpretation: designated Security Reviewer
- Capture evidence and independent review: designated QA/Human Reviewer who is not the implementing agent

## Context

[`M1-SCOPE-001`](M1-SCOPE-001-linux-only-validation.md) requires M1-040 to produce at least one real Linux Barrier Server keyboard fixture set with sanitisation, provenance and non-implementing reviewer verification. M1-040 is not source-valid as written:

- Its Implementation Procedure requires the needed toolchain lock to exist before capture, but [`toolchain.lock.json`](../../MacKVM_Implementation_Package_v2/toolchain.lock.json) (`M1-CAPTURE-TOOLCHAIN-001`) lists only M1-024 in `scoped_issues`, and its drift policy names M1-024 capture only. No lock covers M1-040 capture.
- Its four Exact Files contain no fixture path and no evidence path, while Expected Evidence and Deliverables require a fixture set and a full `evidence/issues/M1-040/` package. This is the same mismatch [`M1-CAPTURE-TOOLCHAIN-001`](M1-CAPTURE-TOOLCHAIN-001-capture-readiness.md) corrected for M1-024.
- A keyboard capture records input by construction, so the existing "no identifiable text" rule needs an explicit capture-time definition.

## Decision (proposed)

- M1-040 keeps its original four Exact Files first and declares exactly these eight future files, identically in the package Issue and `issues_manifest.json`:
  - `Tests/Fixtures/Barrier/m1-040-linux-keyboard/metadata.json`
  - `Tests/Fixtures/Barrier/m1-040-linux-keyboard/keyboard-capture.json`
  - `evidence/issues/M1-040/summary.md`
  - `evidence/issues/M1-040/commands.json`
  - `evidence/issues/M1-040/tests/e2e-validation.json`
  - `evidence/issues/M1-040/environment.json`
  - `evidence/issues/M1-040/manual.md`
  - `evidence/issues/M1-040/independent-review.md`
- None of these files is created by this ADR. They are declared so that a later capture PR is fully scoped.
- Provenance is the same controlled black-box capture as M1-024: an external Barrier macOS client (`barrierc`) connected to an external Linux Barrier server (`barriers`), with no first-party macOS Client participating.
- The keyboard input is a pre-declared scripted key sequence covering ordinary keys, modifiers, repeat and caps lock. It must not form words, names, credentials or any other identifiable text.
- The retained fixture holds only ordered direction plus uninterpreted application payload bytes. No key code meaning, message code, endianness or compatibility is asserted.
- On acceptance only, a follow-up change adds M1-040 to `scoped_issues` in `toolchain.lock.json` and widens its drift statement to M1-040 capture, updating `Tests/Contracts/test_m1_024_capture_readiness.py` in the same change. All pinned versions stay unchanged; any version difference still stops capture.

## Stop conditions added to M1-040

- This ADR is not Accepted by the Product Owner.
- `toolchain.lock.json` `scoped_issues` does not include M1-040.
- The actual capture environment differs from the lock.
- The scripted key sequence is not declared before capture, or it forms identifiable text.

M1-040 must not be reported complete until the declared fixture and evidence files exist from a real Linux Barrier Server capture and the non-implementing independent review is recorded.

## Rejected alternatives

### Capture under the current lock without amending it

Rejected because the lock scopes M1-024 only; reusing it silently would bypass the fail-closed drift policy.

### Edit `toolchain.lock.json` now

Rejected because only a Product Owner approved ADR may change the lock, and this ADR is still Proposed.

### Synthesize keyboard fixtures from M1-024 bytes or a mock

Rejected by M1-SCOPE-001: a mock, simulator or synthesized capture is not a substitute.

## Security and privacy

The M1-CAPTURE-TOOLCHAIN-001 prohibited-content list applies unchanged, including typed text and clipboard content. Raw packet capture stays outside the repository. TLS default ON, fail-closed identity handling, fail-safe cleanup and privacy-safe logging are unchanged.

## Compatibility

No compatibility claim is made. Windows is not executed in M1 (M1-SCOPE-001).

## Consequences

- M1-040 becomes source-valid as a scoped draft but stays blocked until Product Owner acceptance and the lock follow-up.
- M1-041 and M1-042, which depend on M1-040, stay blocked.

## Rollback

Revert this ADR, the M1-040 Issue and manifest changes, and `Tests/Contracts/test_m1_040_keyboard_capture_scope.py` together in one change.

## Traceability

- GitHub Issue #282
- [`MacKVM_Implementation_Package_v2/issues/M1/M1-040-barrier-keyboard-fixtures.md`](../../MacKVM_Implementation_Package_v2/issues/M1/M1-040-barrier-keyboard-fixtures.md)
- [`MacKVM_Implementation_Package_v2/issues_manifest.json`](../../MacKVM_Implementation_Package_v2/issues_manifest.json)
- [`Tests/Contracts/test_m1_040_keyboard_capture_scope.py`](../../Tests/Contracts/test_m1_040_keyboard_capture_scope.py)
- [`M1-CAPTURE-TOOLCHAIN-001`](M1-CAPTURE-TOOLCHAIN-001-capture-readiness.md)
- [`M1-SCOPE-001`](M1-SCOPE-001-linux-only-validation.md)
