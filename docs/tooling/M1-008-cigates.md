# M1-008 Pull Request CI Gates

## Outcome

M1-008 adds one fail-fast build/test/manifest gate used locally by `make verify` and on every pull request or push to `main`. It writes an atomic, machine-readable JSON report whether a command passes, fails, times out, or the pipeline is cancelled.

## Gate order

1. Canonical backlog/package manifest validation.
2. CI gate unit tests.
3. Repository contract tests.
4. Swift Unit/Integration/System test-target verifier.
5. Native macOS 14 arm64 build verifier.

The first non-passing gate stops execution, marks later gates `not-run`, writes the report, and returns non-zero. A timeout terminates the spawned process group. Keyboard interruption and runner `SIGTERM` use the same cleanup path, return exit 130, and make a best-effort report write before the runner's forced-termination grace period ends.

## Report contract

Schema version 1 includes:

- overall status, start/end timestamps, commit, platform, machine architecture, Python version, and Swift version
- each gate name, argv array, status, exit code, timestamps, duration, output SHA-256 values, and output line counts

Raw stdout/stderr is intentionally excluded from the report so future fixture or failure content cannot become a durable artifact. The console prints only allowlisted context and gate status metadata.

Default report path: `artifacts/ci/m1-008-report.json`. The directory is ignored by Git. CI uploads the report for 14 days even when the gate fails.

## GitHub Actions and merge enforcement

`.github/workflows/m1-ci.yml` runs on pull requests and pushes to `main`, uses the GitHub-hosted `macos-15` arm64 image, and selects Xcode 26.2 for Swift tools 6.2 compatibility. Workflow permissions are read-only, checkout credentials are not persisted, and both official actions are pinned to immutable commit SHAs.

After the workflow establishes its real check-run context, branch protection must require that exact check with strict up-to-date branches, prohibit force pushes/deletion, and require resolved review conversations. A failed or missing required check then blocks merge.

## Commands

```bash
make verify
make ci-gate-tests
python3 Tools/Backlog/validate_package.py
```

## Scope and remaining bootstrap

M1-008 does not add format/lint policy or the architecture checker. M1-009 and M1-010 own those gates and must extend `make verify`/CI without weakening existing checks. Formal gate backfill for earlier bootstrap PRs remains mandatory before M1 completion.

## Rollback

Revert the M1-008 PR and remove its required status check from branch protection in the same rollback operation. Do not leave a required context that no workflow can produce. No production runtime or user data is affected.

## Verified upstream references

- GitHub runner images: `https://github.com/actions/runner-images`
- macOS 15 arm64 installed software: `https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md`
- Checkout v7.0.1 (`node24`) immutable ref: `3d3c42e5aac5ba805825da76410c181273ba90b1`
- Upload Artifact v7.0.1 (`node24`) immutable ref: `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`
