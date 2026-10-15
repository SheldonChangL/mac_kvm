# M1-030-SCOPE-001 Evidence Summary

GitHub Issue: #317, `[M1-030-SCOPE-001] Correct Barrier handshake test exact
files out of KVMCore`. It blocks canonical M1-030 (GitHub Issue #53).

Base commit: `1964732e18ceebafb1fca67f953cb94adbb18bd5`

Implementation commit: the single atomic commit that adds this package. A
commit cannot contain its own hash; read it with
`git log --oneline -- evidence/issues/M1-030-SCOPE-001/`.

Authorship: implementation author Claude Code (--model opus); independent review is
assigned to a separate Codex executor and is not recorded here.

## Trigger and correction

M1-030 declared `Packages/KVMCore/Sources/KVMCore/BarrierHandshakeTests.swift`
and `Packages/KVMCore/Tests/KVMCoreTests/BarrierHandshakeTestsTests.swift` and
required `swift test --package-path Packages/KVMCore`. Testing the M1-029
`BarrierClientHandshake` from KVMCore requires Barrier-specific types in
KVMCore and a KVMCore import of `BarrierCompatibility`, which Frozen Decision 4
and the Architecture Guardrails prohibit. M1-030 therefore could not satisfy
its own Exact Files without violating a frozen decision.

The M1-030 Issue and `issues_manifest.json` now declare exactly:

- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierHandshakeTestsTests.swift`
- `docs/components/M1-030-barrier-handshake-tests.md`

The Swift Required Command is now
`swift test --package-path Packages/BarrierCompatibility`, matching M1-029.
The KVMCore helper source is removed rather than relocated: M1-029's existing
`BarrierClientHandshake` is the system under test, so no production helper is
authorized. The other three Required Commands, `depends_on` (M1-020, M1-029),
`topological_order` (53), Scope, Acceptance Criteria, Expected Evidence, and
Stop Conditions are unchanged.

## Changed files

- `MacKVM_Implementation_Package_v2/issues/M1/M1-030-barrier-handshake-tests.md`
- `MacKVM_Implementation_Package_v2/issues_manifest.json` (M1-030 entry only)
- `MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md` (new
  `M1-030-SCOPE-001 Barrier Handshake Test Scope Correction` section)
- `Tests/Contracts/test_m1_030_barrier_handshake_test_scope.py` (new)
- `evidence/issues/M1-030-SCOPE-001/` (this package)

`issues_index.csv` and `EXECUTION_ORDER.md` carry no exact files or commands
and need no change. `MacKVM_Implementation_Package_v2_Combined.md` and
`MacKVM_Implementation_Package_v2.zip` are bootstrap snapshots that earlier
corrections (M1-SCOPE-001, M1-WIRE-001, M1-040-UNBLOCK-001) also left
untouched.

## Acceptance criteria mapping

| Criterion | Result |
| --- | --- |
| M1-030 Exact Files contain no KVMCore path | Passed: Issue and manifest list the same two paths; `scope_violations` is empty. |
| Swift Required Command targets BarrierCompatibility | Passed: Issue and manifest list the identical four commands, the first being `swift test --package-path Packages/BarrierCompatibility`. |
| Old KVMCore scope is machine-rejected | Passed: `test_scope_check_rejects_old_kvmcore_scope` reinstates the old paths and command and asserts each is reported. |
| No production helper or behavior | Passed: no exact file is under `Sources/`; no Swift file changed; M1-029 source exists. |
| Dependency order M1-020, M1-029 preserved | Passed: manifest, Issue front matter, and index agree; both dependencies precede M1-030. |
| Traceability links #317 to #53 and Frozen Decision 4 | Passed: `test_traceability_links_correction_to_m1_030`. |
| M1-030 not claimed complete | Passed: no checked box in the Issue and no completion key in the manifest. |

## TDD

The new contract test was written first. Against the base tree it ran 8 tests
with 3 failing methods (8 subTest failures), reporting both KVMCore exact
files and the KVMCore command in both canonical sources plus the missing
traceability section (`tests/red-phase.json`). After the metadata and
traceability edits all 8 tests pass (`tests/results.json`).

## Validation

Detailed commands, timestamps, and exit codes are in `commands.json`.

- New regression test: 8 tests, OK.
- `python3 Tools/Backlog/validate_package.py`: `PACKAGE OK: 217 issues, 5 milestones, 17 epics`.
- `make architecture-check`: `architecture check OK`.
- `make docs-check`: `docs check OK` over tracked files. The author
  environment denies writes to `.git`, so the new files could not be staged;
  the docs-check Markdown and JSON rules were applied to them directly and
  reported no violations.
- `git diff --check`: no output; new files have no trailing whitespace.
- `python3 -m unittest discover -s Tests/Contracts -p 'test_*.py' -v`: 155
  tests, 146 passed, 9 failed. All 9 failures are M1-004 to M1-007 tests that
  invoke SwiftPM, which fails in the author environment with
  `sandbox-exec: sandbox_apply: Operation not permitted`. The same failure
  reproduces with `swift package describe` on the unmodified
  `Packages/BarrierCompatibility`. None of those tests read a file changed
  here. This is the same environment limitation recorded in M1-PKG-002 and
  M1-040-UNBLOCK-001; the reviewer must rerun the suite outside the sandbox.

## Scope and hygiene

- No Swift source, test target, package manifest, wire byte, fixture, product
  scope, or architecture rule changed.
- `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were not read, modified,
  or staged.
- No secret, credential, token, private key, network endpoint, or personal data
  is added.

## Remaining risks

- The full contract suite and any SwiftPM or Xcode command were not run
  successfully in the author environment; reviewer rerun outside the sandbox is
  required.
- The executor that stages and commits must rerun `make docs-check` and
  `git diff --cached --check` after staging.
- The future file name `BarrierHandshakeTestsTests.swift` keeps the original
  package naming pattern; it is a valid Swift test file name but unusual.

## Rollback

Revert the commit. That restores the original KVMCore scope, which keeps
M1-030 blocked because it conflicts with Frozen Decision 4.
