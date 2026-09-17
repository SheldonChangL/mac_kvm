# M1-CI-003 Evidence Summary

GitHub Issue: #251

Implementation commit: `78c0262419c934b12329c6e4af4276cac42e5d56`

## Trigger and outcome

M1-023 PR #250 committed a rerunnable evidence validator, but GitHub run
35190279915 proved the formal pipeline only discovered `Tools/*/tests` and did
not execute it. M1-CI-003 adds a separate, fail-closed discovery/count gate and
one isolated named gate for every committed
`evidence/issues/*/tests/**/test_*.py` file.

## Acceptance criteria mapping

- Closed roots: only direct issue directories below `evidence/issues`, their
  `tests` trees, and regular `test_*.py` files are eligible.
- Determinism: paths are repository-relative, sorted, de-duplicated, and each
  file receives one exact-filename `unittest discover` process.
- Fail closed: missing roots, parent/root/issue/tests/nested symlinks, I/O
  errors, count mismatch, import failure, assertion failure, timeout,
  cancellation, or nonzero exit cannot produce a passing pipeline.
- Machine report: the existing argv/status/exit/timing/output-hash/line-count
  schema is preserved; durable artifacts contain no raw test output.
- Compatibility: tool-test discovery and every existing package, repository,
  Swift, native arm64, docs, architecture, quality, and manifest gate remain.
- Formal validation: 21/21 CI-gate tests and all 15 repository gates pass at
  the implementation commit.
- Scope/privacy: no product runtime, protocol, KVMEvent, networking, TLS/trust,
  input, secret, credential, private data, or deployment behavior is changed.

## TDD and remediated findings

- Initial focused tests failed with four missing discovery API errors.
- Parent `evidence/` symlink coverage then failed, proving an escape around an
  `evidence/issues`-only check; the parent/root/issue/tests/file chain now fails
  closed.
- One existing missing-root assertion was updated to the more precise parent
  root error after the hardening change.

## Remaining risk and required proof

This corrective branch is based on main before M1-023, so its evidence discovery
gate correctly finds zero issue-evidence test files. After this PR merges, #250
must incorporate current main and obtain a GitHub report with the explicit
passing gate `evidence-test:M1-023/tests/test_register.py`. Until then, #250
remains blocked.

## Rollback

Revert the M1-CI-003 PR and keep every PR containing issue-evidence Python tests
blocked until equivalent automatic GitHub coverage is restored.
