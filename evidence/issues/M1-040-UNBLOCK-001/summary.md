# M1-040-UNBLOCK-001 Summary

## Status

Corrective governance decision for GitHub Issue #282, accepted by Product Owner
authorization on 2026-10-06 (Asia/Taipei). This work does not complete M1-040
and does not create a keyboard fixture.

## Change summary

- Updated `docs/adr/M1-040-UNBLOCK-001-keyboard-capture-scope.md` to
  `Status: Accepted by Product Owner authorization`.
- Declared the future M1-040 Linux keyboard fixture and evidence paths in the
  M1-040 package Issue and `issues_manifest.json`.
- Added M1-040 to `toolchain.lock.json` `scoped_issues` without changing any
  pinned OS, architecture, Swift, Python, Barrier or capture-tool versions.
- Added `Tests/Contracts/test_m1_040_keyboard_capture_scope.py` to prove:
  - the corrective ADR is accepted;
  - `toolchain.lock.json` scopes M1-040 and fails closed on drift;
  - no keyboard fixture/evidence files are claimed to exist yet;
  - M1-040 cannot be claimed complete before a real fixture exists.
- Updated `Tests/Contracts/test_m1_024_capture_readiness.py` so the shared
  capture lock remains closed and deterministic after the M1-040 scope addition.
- Added traceability in `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md`.

## Acceptance criteria mapping

- Corrected source/fixture/toolchain scope is explicit enough for future M1-040
  work: the future fixture path is
  `Tests/Fixtures/Barrier/m1-040-linux-keyboard/`, and evidence paths are listed
  identically in the Issue and manifest.
- No keyboard fixture is claimed before real capture: the ADR is accepted and
  the lock now scopes M1-040, but the contract test still requires the future
  files to remain absent before capture and reports M1-040 incomplete until
  those files exist from a real Linux Barrier Server capture.
- Linux-only M1 scope is preserved: Windows execution remains out of scope and
  no Windows result is recorded.
- Independent implementation and privacy-safe evidence are preserved: raw
  capture stays outside the repository, retained bytes are uninterpreted, and
  a non-implementing independent review remains required.
- M1-040 remains blocked: this change is not completion evidence for #25.

## Known limitations

- The Product Owner acceptance recorded in this PR authorizes only the M1-040
  source/manifest/lock scope correction, not the capture itself.
- The capture lock scope changed from `["M1-024"]` to `["M1-024", "M1-040"]`;
  all pinned tool versions remain unchanged.
- No real keyboard capture was performed and no M1-040 fixture exists.

## Rollback

Revert the ADR, the M1-CAPTURE-TOOLCHAIN-001 amendment, `toolchain.lock.json`,
the M1-040 Issue and manifest changes, the traceability update, this evidence
package, and the M1-040/M1-024 contract-test updates together.
