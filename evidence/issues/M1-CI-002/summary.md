# M1-CI-002 Evidence Summary

GitHub Issue: #244

Implementation commit: `51a1ca5337b5ef9653969af9054b2d6abfd4b90f`

## Deliverables

- Deterministic discovery of `Tools/*/tests/**/test_*.py`.
- One isolated, named blocking gate for every discovered test file.
- A fail-closed discovery/count-consistency gate.
- Unit coverage for empty, valid, nested, symlink, import-failure,
  assertion-failure, timeout, cancellation, and cleanup paths.
- Updated architecture/docs integration assertions and CI documentation.
- This evidence package.

## Acceptance criteria mapping

- M1-012 backfill: `make verify` discovers and passes
  `tool-test:diagnostic-bundle/tests/test_diagnostic_bundle.py`; that suite
  contains 18 tests.
- No skip/duplication: paths are sorted and de-duplicated, previous fixed tool
  suites were removed, and the current-repository test asserts the diagnostic
  suite command appears exactly once.
- Machine report: every discovered file receives a stable
  `tool-test:<path-relative-to-Tools>` name, argv array, status, exit code,
  timestamps, duration, output hashes, and line counts.
- Fail closed: missing/symlinked roots, nested symlinks, discovery I/O errors,
  count changes, import failures, assertion failures, timeouts, and
  cancellation cannot report a passing pipeline.
- Formal gates: all 13 cumulative gates pass at the implementation commit;
  docs, architecture, package validation, and `git diff --check` also pass.
- Hygiene: owner artifacts remain untracked; no secret, credential, private
  data, generated report, or build product is committed.

## Five-axis review

1. Source validity / traceability: live Issue #244 was re-read; the corrective
   relation to M1-012 PR #243 remains explicit, and the implementation/docs are
   limited to that Issue.
2. Product contract / architecture: this changes repository CI orchestration
   only. Swift-native product behavior, KVMEvent, the Core/Protocol boundary,
   Barrier isolation, client-first order, and TLS defaults are unchanged.
3. Security / fail-safe / compatibility: discovery accepts regular files,
   rejects symlinked roots or entries, uses argv arrays without a shell, emits
   closed error labels, and preserves the existing report schema.
4. Tests / validation / acceptance: 15 CI-gate tests and all 13 repository gates
   pass; both import and test failures are exercised as blocking outcomes.
5. Scope / hygiene / rollback: no runtime or product change is present. Revert
   the PR to restore fixed gates and keep M1 completion blocked until equivalent
   automatic coverage is restored.

## Findings

- Critical: 0.
- High: 0.
- Medium: 0 open.
- Low: 0 open.

## Remediated validation attempts

- The initial TDD run failed with five missing discovery API errors, then
  passed after the scoped implementation.
- Two intermediate full-gate runs exposed stale hard-coded architecture/docs
  assertions; both were updated to assert the dynamic discovery contract.
- One full-gate run inside the restricted outer execution sandbox failed when
  SwiftPM could not create its nested sandbox. The same command in the normal
  macOS toolchain environment passed 13/13; this was an environment restriction,
  not a product or test failure.

## Remaining risks

- GitHub Actions must independently pass on the PR head and its uploaded report
  must include the M1-012 diagnostic-bundle gate before merge.
- A maliciously named repository path could make console output awkward, but
  commands remain non-shell argv arrays and merging such a path still requires
  repository review. No untrusted runtime path reaches this tooling.

## Rollback

Revert the M1-CI-002 PR. Do not declare M1 complete until a replacement again
executes every repository tool test, including M1-012, in GitHub CI.
