# M1-TOOLING-002 Evidence Summary

## Scope

Files: `Tools/Evidence/run_e2e.py`, `Tools/Evidence/validate_evidence.py`,
`MacKVM_Implementation_Package_v2/schemas/e2e-result.schema.json`,
`Tools/Evidence/tests/test_run_e2e.py`, `Tools/Evidence/tests/test_validate_evidence.py`,
`docs/tooling/M1-TOOLING-001-e2e-evidence-gate.md`, and this directory (GitHub Issue #350).

The E2E evidence tooling accepts the corrective id form `M[1-5]-[0-9]{3}(?:-FOLLOWUP-[0-9]{3})?`
(for example `M4-036-FOLLOWUP-001`) in the runner (`ISSUE_PATTERN`, `SCRIPT_NAME_PATTERN`), the
validator (`ISSUE_PATTERN`, `ARTIFACT_PATH_PATTERN`) and `e2e-result.schema.json` (`issueId` and
the artifact path). Nothing else is accepted: `-FOLLOWUP-` without three digits, two digits, four
digits, a second suffix, lower case and a trailing newline are rejected. A base id such as
`M4-036` never resolves the script of `M4-036-FOLLOWUP-001` (`resolve_script`). The consumer is
`make e2e-evidence` for the owner E2E of the FOLLOWUP issues (for example M4-036-FOLLOWUP-001).
Existing ids behave as before. `schemas/issue.schema.json` is unchanged by design.

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Which id form is added? | One optional `-FOLLOWUP-` suffix with exactly three digits after a base id. | Issue #350; component doc, FOLLOWUP ids. |
| Do the three definitions stay identical? | Yes: runner, validator and schema use the same pattern, all anchored, and a test compares the schema and validator patterns. | `test_schema_patterns_match_validator`; mutants 7, 12. |
| Does a base id claim a FOLLOWUP script? | No. `resolve_script` skips `<base>-FOLLOWUP-nnn-*` scripts for a base id, so the two ids stay independent. | Component doc; mutant 6. |
| Is `issue.schema.json` changed? | No, it is outside this scope. | Independent review, INFO. |

## RED

The new tests were run against the base-commit tools (`e4c8769`): `python3 -I -m unittest
discover -s Tools/Evidence/tests` ran 156 tests and exited 1 with `FAILED (failures=11,
errors=5)`. Failing tests include `test_followup_issue_id_accepted`,
`test_followup_artifact_path_for_wrong_issue_is_mismatch` and
`test_schema_accepts_and_rejects_followup_ids` (`commands.json`, first command).

## GREEN

With the change, the same command ran 211 tests and exited 0 (`OK`; the committed log is
`tests/unittest-evidence.txt`). The other gates in `commands.json`, all exit 0:

| Gate | Result |
| --- | --- |
| `python3 Tools/Backlog/validate_package.py` | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| `swift test` | 301 tests in 28 suites passed |
| `swift test -Xswiftc -warnings-as-errors` | 301 tests in 28 suites passed |
| `swift format lint --recursive --strict` | exit 0, no output |
| `make docs-check` | `docs check OK` |
| `make architecture-check` | `architecture check OK` |
| `git diff --cached --check` | exit 0 |
| `make verify` | 24 of 24 steps `[PASSED]` |

Toolchain: Apple Swift version 6.2.3, Python 3.9.6, macOS 26.6.2 arm64.

## Mutation checks

`mutations/mutations.json` records 12 mutants (ids 1 to 4 and 6 to 13; there is no id 5), each
applied, run with the unit command, and restored clean. All 12 were killed (`allKilled: true`);
the baseline exit code was 0.

| Mutant | Change | Killed by |
| --- | --- | --- |
| 1 | runner `ISSUE_PATTERN` loses the FOLLOWUP group | `test_followup_script_is_resolved_and_run`, `test_issue_pattern_accepts_and_rejects` |
| 2, 3 | runner pattern allows repeated suffixes; accepts zero digits | `test_issue_pattern_accepts_and_rejects` |
| 4 | runner pattern is case-insensitive | `test_invalid_issue_is_rejected_before_path_resolution`, `test_issue_pattern_accepts_and_rejects` |
| 6 | `resolve_script` no longer excludes FOLLOWUP scripts for a base id | `test_base_issue_does_not_resolve_followup_script`, `test_base_issue_resolves_only_its_own_script_beside_followup` |
| 7 | validator `ISSUE_PATTERN` loses the FOLLOWUP group | 5 tests, including `test_followup_issue_id_accepted` and `test_schema_patterns_match_validator` |
| 8, 9 | validator pattern allows repeated suffixes; accepts zero digits | `test_followup_issue_id_rejected_forms`, `test_schema_patterns_match_validator` |
| 10 | validator `ARTIFACT_PATH_PATTERN` loses the FOLLOWUP group | `test_followup_artifact_path_for_wrong_issue_is_mismatch`, `test_followup_issue_end_to_end_with_artifact` |
| 11 | artifact path pattern allows repeated suffixes | `test_artifact_path_rejects_malformed_followup_directory` |
| 12 | schema `issueId` loses the FOLLOWUP group | `test_schema_accepts_and_rejects_followup_ids`, `test_schema_patterns_match_validator` |
| 13 | schema artifact path loses the FOLLOWUP group | `test_schema_accepts_and_rejects_followup_ids` |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Runner, validator and schema accept `M[1-5]-[0-9]{3}-FOLLOWUP-[0-9]{3}` | The accept and end-to-end tests in `test_run_e2e.py` and `test_validate_evidence.py`; mutants 1, 7, 10, 12, 13 |
| Malformed forms are rejected | Reject tests: no digits, 2 and 4 digits, two suffixes, lower case, non-digit, trailing newline, extra suffix; mutants 2, 3, 4, 8, 9, 11 |
| A FOLLOWUP artifact path under another issue is a mismatch | `test_followup_artifact_path_for_wrong_issue_is_mismatch` |
| Base ids and FOLLOWUP ids do not claim each other's scripts | The two base-id tests; mutant 6 |
| Existing ids unchanged | The 211-test suite and `make verify` (24 of 24) pass |
| Lint, build, docs and architecture gates with no new warning | `commands.json`: `-warnings-as-errors` run, lint, `make docs-check`, architecture check all exit 0 |

## Independent review

- A fresh-context Opus reviewer (Tier B) approved the PR at `1e42eb2`: nothing blocking, 2 Nits
  and 1 Info (`independent-review.md`). It checked every pattern site and that all are
  anchored, and judged the `resolve_script` change correct and necessary.
- The reviewer ran 211 tests in a detached worktree on the PR head, all passing, and 4 mutants
  of its own, all detected.
- The lead accepted all notes as they are; there was no code change after the review.

## Merge

Pending owner approval.

## Known limitations

- `run_e2e.py:61`: the infix check only matches `FOLLOWUP-[0-9]{3}-`, so a badly named script
  such as `M4-036-FOLLOWUP-01-x.sh` still resolves for the base id `M4-036`. This needs a badly
  named repository script and is harmless (review Nit, accepted).
- Style only, accepted: extra blank lines in `test_run_e2e.py` and the import order in
  `test_validate_evidence.py`.
- `schemas/issue.schema.json` is unchanged (review Info).
- Not re-run after the review: there was no code change after it, so nothing needed re-running.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3 (swiftlang-<ip>.21
clang-1700.6.3.2)); mutants are in `mutations/mutations.json`; the unit-test log is in `tests/`.
