# M1-008 Evidence Summary

Implementation commits: `f1e1ec6f4b1970ec18c870dbb2a1b80c4407b013`, `7226c7770c0482083c8a19f74b5a3cb0959aef30`

## Deliverables

- Fail-fast Python CI gate for manifest validation, CI/unit tests, repository contract tests, Swift test targets, and native arm64 build.
- Atomic privacy-safe machine report with toolchain, commit, timestamps, exit codes, output hashes, and line counts.
- Timeout, keyboard-interrupt, and runner-`SIGTERM` process-group cleanup, plus explicit not-run results after the first failure.
- Stable `make verify`, canonical `Tools/Backlog/validate_package.py`, and SHA-pinned read-only GitHub Actions workflow.

## Acceptance criteria

- Build, unit/contract test, and manifest gates are directly locatable and locally executable.
- Happy, gate failure, invalid root/timeout, timeout cleanup, cancellation cleanup, report, workflow, and command-path tests pass.
- A non-passing gate returns non-zero, stops later gates, and still writes machine-readable evidence.
- Workflow runs on every pull request/push to `main` on native arm64 with pinned Xcode 26.2 and no write permission or persisted credential.
- Raw command output is not stored in the artifact, preventing fixture/test content from becoming a durable CI payload.

## Scope and rollback

Workflow, Makefile, canonical wrapper, ignore rule, evidence, and handoff additions are necessary tooling-bootstrap expansions disclosed under Product Owner authorization. M1-009 lint and M1-010 architecture enforcement are not implemented early. Rollback requires both reverting the PR and removing its required status context so `main` is not left permanently blocked.

## Remaining risk

The exact required check context and strict branch protection can only be configured after GitHub creates the first PR check run. That configuration and a successful GitHub-hosted run are merge blockers for this Issue, not deferred waivers.

The restricted local tool sandbox prevents SwiftPM from starting its own macOS sandbox (`sandbox_apply: Operation not permitted`). That environment-only run failed at the repository-contract gate. Re-running the identical commit outside the nested sandbox passed all five gates; GitHub-hosted CI remains the independent environment check.
