# M1-040-UNBLOCK-001 Summary

## Status

Corrective governance draft for GitHub Issue #282. This work does not complete
M1-040 and does not create a keyboard fixture.

## Change summary

- Added `docs/adr/M1-040-UNBLOCK-001-keyboard-capture-scope.md` with
  `Status: Proposed, pending Product Owner approval`.
- Declared the future M1-040 Linux keyboard fixture and evidence paths in the
  M1-040 package Issue and `issues_manifest.json`.
- Added `Tests/Contracts/test_m1_040_keyboard_capture_scope.py` to prove:
  - the corrective ADR is still Proposed;
  - `toolchain.lock.json` has not been silently changed;
  - no keyboard fixture/evidence files are claimed to exist yet;
  - M1-040 cannot be claimed complete before a real fixture exists.
- Added traceability in `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md`.

## Acceptance criteria mapping

- Corrected source/fixture/toolchain scope is explicit enough for future M1-040
  work: the future fixture path is
  `Tests/Fixtures/Barrier/m1-040-linux-keyboard/`, and evidence paths are listed
  identically in the Issue and manifest.
- No keyboard fixture is claimed before real capture: the ADR is Proposed, the
  lock remains scoped only to M1-024, and the contract test requires the future
  files to remain absent before capture.
- Linux-only M1 scope is preserved: Windows execution remains out of scope and
  no Windows result is recorded.
- Independent implementation and privacy-safe evidence are preserved: raw
  capture stays outside the repository, retained bytes are uninterpreted, and
  a non-implementing independent review remains required.
- M1-040 remains blocked: this change is not completion evidence for #25.

## Known limitations

- Product Owner acceptance is still required before any capture lock change.
- `toolchain.lock.json` is intentionally unchanged in this PR.
- No real keyboard capture was performed and no M1-040 fixture exists.

## Rollback

Revert the ADR, the M1-040 Issue and manifest changes, the traceability update,
this evidence package, and `Tests/Contracts/test_m1_040_keyboard_capture_scope.py`
together.
