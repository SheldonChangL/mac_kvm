# M4-020 Evidence Summary

## Scope

Files: `Package.swift`, `Makefile`, `.github/workflows/m1-ci.yml`, `.gitignore`,
`Tools/architecture-check/architecture-check.py` and its tests, `Packages/LinuxPlatform/` (the
`LinuxPlatform` library, `LinuxPlatformTests`, and the system-library shims CX11, CXTest, CXRandR
and CXFixes), and this directory.

The change adds the Linux skeleton and its build infrastructure. `Package.swift` keeps the shared
targets in the `Package(...)` literal; `#if os(macOS)` adds the Mac targets and `#if os(Linux)`
adds LinuxPlatform, its tests, the four shims and every LOCK dependency pinned with `exact:`.
`LinuxDisplayEnvironment.detect(environment:)` returns x11, wayland or headless from the
environment alone. `make verify-linux ISSUE=<id>` runs the pinned image, checks the dependency
graph against LOCK (drift exits 65), builds, runs the root and child package tests, and runs the
`.x11` tests under `xvfb-run`; a new CI job `verify-linux` runs it on ubuntu-22.04. The
architecture checker treats LinuxPlatform as a platform root and keeps X11, NIO, Glibc, Musl and
crypto module families out of KVMCore and KVMContracts, and NIO out of the protocol roots.

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Extra dependencies | LinuxPlatform also depends on SwiftASN1, Atomics and SystemPackage. | Without them SwiftPM warns that these directly pinned LOCK packages are unused. The reviewer accepted it; the CI drift check reports "dependency graph matches the lock: 7 packages". |
| `xauth` | Added to the apt list of the pinned image. | `xvfb-run` needs it. |
| `Package.resolved` | Not committed; it stays in `.gitignore`. | Plan a.1. On macOS, `swift package resolve` deleted a test copy of it, which confirms the inference. |
| Where does Linux evidence come from? | The CI `verify-linux` job: runs 43752615456, 43790182654 and 43822204604. | Local `make verify-linux` hangs or fails with swift-build JSON parse errors under Docker linux/amd64 emulation (`commands.json`, note). |
| Swift RED and GREEN | Run on a macOS mirror package holding `LinuxSkeleton.swift` and its tests. | `LinuxPlatform` builds only on Linux; the mirror is built by `mutations/run_mutations.py`. The reviewer called this weak evidence and relies on CI. |
| Change to the checker's own test file | `Tools/architecture-check/tests/test_architecture_check.py` is changed although it is outside the Exact Files. | Plan b.10 [DECISION] reads TOOL:91 as covering the checker's tests. The PR asks the reviewer to confirm that reading. |
| Detection policy | Wayland wins over XWayland's `DISPLAY`; blank values count as unset. | First-party policy, pinned by the detection tests. |

## RED

- Swift, macOS mirror against a RED stub: `✘ Test run with 15 tests in 3 suites failed after
  0.001 seconds with 31 issues.` (`commands.json`, `red-mirror-swift-test`, exit 1, recorded as
  an expected failure; 12 of the 15 tests failed.)
- Architecture checker, before the checker change: 34 tests, 5 failed (`commands.json`, note).
- Review round: the checker as of `7b23d03` against the 39 tests of the fixed tree:
  `Ran 39 tests in 3.643s` / `FAILED (failures=25)` (`review-red-checker-tests-old-checker`,
  exit 1, expected failure).

## GREEN

- Swift mirror: `✔ Test run with 15 tests in 3 suites passed after 0.001 seconds.` with the one
  `.x11` test skipped (`green-mirror-swift-test`).
- Checker tests: 34 tests OK at first; after the review fix `Ran 39 tests in 2.160s` / `OK`
  (`review-checker-tests`).
- Local root package: `✔ Test run with 222 tests in 22 suites passed after 0.126 seconds.`
- Both format lints exit 0; `docs check OK`; `architecture check OK`; `PACKAGE OK: 217 issues,
  5 milestones, 17 epics`; `git diff --cached --check` exit 0.
- `make verify`: 24 of 24 gates passed at first (`make-verify`) and again after the review fix
  (`review-make-verify`, exit 0).
- Linux, CI `verify-linux` (the only Linux evidence):
  - run 43752615456 (first head): root 236 tests in 25 suites, KVMContracts 118,
    BarrierCompatibility 374, `.x11` tests under Xvfb 15 tests in 3 suites, `verify-linux OK`.
  - run 43790182654: `verify-linux` and `build-test-manifest` both success
    (`review-ci-run-43790182654`).
  - run 43822204604 (review-fix head): `dependency graph matches the lock: 7 packages`; root 282
    tests in 28 suites, KVMContracts 118, BarrierCompatibility 374, Xvfb 15 tests in 3 suites,
    `LinuxPlatformTests cases under Xvfb: 15 (minimum 15)`, `verify-linux OK`. The root count
    differs from the first run because main moved between the two.

## Mutation checks

9 mutants, each killed and restored byte for byte: `allKilled` true and `baseline` passing in
both `mutations/mutations-swift.json` (3 mutants) and `mutations/mutations-checker.json`
(6 mutants). The runner is `mutations/run_mutations.py`.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| M1 | detection ignores `WAYLAND_DISPLAY` and `XDG_SESSION_TYPE=wayland` | 2: `WAYLAND_DISPLAY makes the session wayland, even with an XWayland DISPLAY` and the `XDG_SESSION_TYPE=wayland` test |
| M2 | detection returns x11 when nothing is set | 5, among them `nothing set is headless` and `empty and blank values count as unset` |
| M3 | a toolchain lock constant drifts from LOCK (swift-nio 2.104.0 to 2.105.0) | 2: `the constants mirror the LOCK file exactly`, `the root manifest pins every LOCK dependency with exact:` |
| M4 | the checker no longer forbids CX11 in KVMCore | 1: `test_kvmcore_rejects_linux_platform_imports` |
| M5 | the checker no longer forbids NIOCore in contracts (name and prefix rule dropped) | 2, among them `test_contracts_reject_linux_platform_imports` |
| M6 | XEvent is not flagged as a contract platform type | 1: `test_contracts_reject_x11_event_types` |
| R1 | review: NIO*, Crypto* and _Crypto* no longer forbidden by prefix in Core | 2 |
| R2 | review: NIO* no longer concrete networking in protocol roots | 1 |
| R3 | review: Musl no longer forbidden in KVMCore | 1 |

M5 was redefined in the review round because the new prefix rule would otherwise still catch
NIOCore.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| Linux skeleton package and targets exist, shared targets unchanged on macOS | `Package.swift` with `#if os(Linux)`; `make verify` 24 of 24 on macOS; `swift package dump-package` on macOS shows no Linux dependency (reviewer) |
| Toolchain lock enforced | the `toolchainLock` tests and mutant M3; CI "dependency graph matches the lock: 7 packages" |
| Display-server detection and headless test mode | the 15 LinuxPlatformTests (mirror GREEN, Xvfb run in CI); mutants M1 and M2 |
| `make verify-linux` and the CI job | runs 43752615456, 43790182654 and 43822204604 |
| Architecture rules for the new platform | checker tests (39) and mutants M4 to M6, R1 to R3 |
| No new warning, lint clean | both lints exit 0; `make verify` 24 of 24 |
| Manual run on hardware | Not applicable to the skeleton; X11 evidence comes with M4-024, M4-026 and M4-027. |

## Independent review

- A fresh-context Opus reviewer (Tier C) approved with follow-ups at `7b23d03`
  (`independent-review.md`): 0 Critical, 0 High, 1 Medium, 3 Low. Nothing blocked the merge.
- The Medium (the checker matched forbidden imports by exact name, so `NIOFoundationCompat`,
  `SystemPackage`, `Musl` and others passed) is fixed at `40265e0` with prefix rules and five new
  tests; the Low on the missing test count is fixed in the Makefile; the X11 Low is recorded
  below; the cache-key Low is accepted. The review-round runs are recorded at `8c388bc`.
- The reviewer did not run local `make verify-linux` or the full macOS `make verify`;
  `commands.json` records `make verify`, and CI records Linux.

## Merge

Pending owner approval.

## Known limitations

- Detection reads the environment only. No X11 call exists yet: `LinuxPlatform` imports no CX*
  module, and the Xvfb test proves only that `DISPLAY` is present. X11 evidence comes with
  M4-024, M4-026 and M4-027.
- Local `make verify-linux` does not complete under Docker linux/amd64 emulation; Linux evidence
  is CI only, and the Swift RED and GREEN ran on a macOS mirror.
- The owner must mark `verify-linux` a required check after the merge.
- The Makefile floor on the Xvfb test count is 15 (`LINUX_MIN_TESTS`); renaming suites needs the
  floor updated.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2); Linux image `swift:6.2.3-jammy`); the machine-readable
test report is in `tests/`.
