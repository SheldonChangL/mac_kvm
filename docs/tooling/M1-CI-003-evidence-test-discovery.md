# M1-CI-003 Issue Evidence Test Discovery

## Outcome

The cumulative `make verify` and GitHub M1 CI pipeline now discover and run
every committed Python test matching both closed roots:

```text
Tools/*/tests/**/test_*.py
evidence/issues/*/tests/**/test_*.py
```

This closes the gap found on M1-023 PR #250: its register contract test was
committed and passed locally, but the formal GitHub report did not execute it.
Locally-only evidence tests are not a merge gate, so PR #250 remains blocked
until this corrective change merges and a new report contains its named gate.

## Discovery contract

Evidence discovery is independent from tool discovery and has its own blocking
`evidence-test-discovery` count-consistency gate. A valid evidence test is a
regular non-symlink Python file under one direct issue directory and a `tests`
directory, with a filename beginning `test_`.

Discovery is deterministic and de-duplicated. Every file executes exactly once
in a separate process with `unittest discover` scoped to its parent directory
and exact filename. Nested test directories need no package marker.

Gate names use:

```text
evidence-test:<path relative to evidence/issues/>
```

The existing machine-readable result contract remains unchanged: argv, status,
exit code, timestamps, duration, output hashes, and line counts are retained;
raw test output is not stored in the durable report.

## Fail-closed behavior

The pipeline fails before executing evidence tests when:

- `evidence` or `evidence/issues` is missing or is a symlink;
- a direct issue directory is a symlink;
- an issue `tests` directory or nested entry is a symlink;
- discovery encounters an I/O error;
- the immediately rechecked count differs from the planned gate list; or
- a discovered file has an import error, assertion failure, timeout,
  cancellation, or nonzero exit.

An existing empty `evidence/issues` tree is valid. This lets repository
bootstrap succeed without weakening later automatic coverage.

## Validation coverage

CI-gate tests cover deterministic root/nested ordering, stable gate names and
commands, empty versus missing roots, every symlink layer, count mismatch,
passing and failing test processes, and all pre-existing fail-fast,
timeout/cancellation, cleanup, report, tool-test, Swift, and native build gates.

The corrective PR itself has no committed issue-evidence Python test on main,
so its report contains the evidence discovery gate with count zero. After it
merges, PR #250 must merge current main and prove the M1-023 validator appears
as `evidence-test:M1-023/tests/test_register.py` and passes.

## Scope, security, and rollback

This changes repository CI orchestration, tests, documentation, and evidence
only. It adds no product runtime behavior, protocol contract, Barrier wire
claim, network access, input behavior, TLS/trust change, secret, or private
data. Commands remain fixed argv arrays without shell interpolation.

Rollback by reverting the M1-CI-003 PR and keeping every PR with committed
issue-evidence tests blocked until equivalent GitHub CI coverage is restored.
