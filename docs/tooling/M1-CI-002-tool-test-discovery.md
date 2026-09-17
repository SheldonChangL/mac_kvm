# M1-CI-002 Tool Test Auto-discovery

## Outcome

The cumulative `make verify` and GitHub M1 CI pipeline automatically execute
every repository tool test matching:

```text
Tools/*/tests/**/test_*.py
```

This closes the regression-coverage gap found during M1-012 review. In
particular, `Tools/diagnostic-bundle/tests/test_diagnostic_bundle.py` now
appears as its own blocking gate and its result is recorded in the uploaded
machine-readable report.

## Discovery and execution contract

- Tool roots, `tests` roots, nested entries, and test files are scanned in
  deterministic repository-relative order.
- A test is a regular non-symlink Python file whose name begins with `test_`.
- Tool roots, test roots, or nested symlink entries fail closed with a typed
  discovery error.
- An empty valid `Tools` tree is accepted; a missing/symlinked `Tools` root is
  rejected.
- The discovery gate checks the expected file count immediately before test
  execution to detect a changed test set.
- Every file runs once in a separate process using `unittest discover` scoped
  to its parent directory and exact filename. Nested tests therefore do not
  require Python package marker files and cannot be double-run by a parent
  discovery pass.
- A discovery error, import error, assertion failure, timeout, cancellation, or
  nonzero test process stops the pipeline and marks later gates `not-run`.

Gate names use:

```text
tool-test:<path relative to Tools/>
```

The command array, exit code, timing, output hashes, and line counts remain in
the existing report schema. Raw test output remains excluded from the durable
artifact.

## Validation coverage

CI-gate unit tests cover:

- current-repository discovery and single execution of M1-012 tests;
- deterministic root and nested ordering;
- empty versus missing tool roots;
- symlink rejection;
- passing and failing discovered test files;
- discovery-count mismatch;
- existing failure, timeout, process-group cleanup, and cancellation behavior.

The architecture/docs integration assertions were updated from old hard-coded
suite names to the dynamic discovery contract. No test behavior was removed.

## Scope and security

This change modifies repository CI orchestration and tests only. It does not
change diagnostic-bundle behavior, runtime application code, protocol/API
contracts, KVMEvent, input handling, networking, TLS, trust, or user data.
Commands are argv arrays with source-controlled paths; no shell interpolation
or raw test output is added to reports.

## Rollback

Revert the M1-CI-002 PR to restore fixed test-suite gates. If rolled back, keep
M1 completion blocked until M1-012 and all later tool tests have equivalent
automatic GitHub CI coverage.
