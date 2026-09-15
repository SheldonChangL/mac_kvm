# M1-009 Code Quality Gate

## Outcome

M1-009 establishes one local/CI entrypoint for deterministic Swift formatting, lint, and compiler-warning enforcement:

```bash
make code-quality-check
```

The M1 CI pipeline invokes the identical Python entrypoint before its test and native-build gates. Any version mismatch, lint finding, compiler warning, timeout, invalid input, or command failure returns non-zero.

## Pinned toolchain

- Xcode: 26.2, selected by the M1 GitHub Actions workflow
- Swift: 6.2.3
- bundled `swift format`: 6.2.3

The gate requires the formatter version to equal `6.2.3`; it does not accept a compatible range or install an unreviewed external formatter/linter. Changing this pin requires an explicit tooling update with a clean format diff and successful full CI run.

## Checks

1. `swift format --version` must exactly match the pin.
2. `swift format lint --recursive --strict --no-color-diagnostics` checks `Package.swift`, `Apps`, `Packages`, `Tests`, and `reference`.
3. `swift test -Xswiftc -warnings-as-errors` builds all Swift targets and tests with compiler warnings promoted to errors, then runs the Swift test suite.

Raw child-process output is captured but not replayed by the wrapper. It reports only command status plus SHA-256 and line-count metadata, preserving the repository's privacy-safe diagnostic policy. Developers can run the documented underlying command directly when they need line-level local diagnostics.

## Failure and cancellation behavior

Checks fail fast: a failed version check prevents lint/build, and a lint failure prevents the warnings-as-errors build. Each process runs in its own process group. Timeout, keyboard interruption, and runner `SIGTERM` terminate that group; runner cancellation returns 130 on the best-effort graceful path.

## Scope

This Issue adds no Swift API, product behavior, protocol behavior, networking, platform input, or security policy. The mechanical formatting changes only bring existing scaffold files into the pinned formatter's canonical layout. M1-010 owns `make architecture-check`.

## Rollback

Revert the M1-009 PR. That removes the code-quality step from `make verify`/GitHub CI and restores the previous scaffold formatting. No runtime state or user data migration is involved.
