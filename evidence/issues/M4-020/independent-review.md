# M4-020 Independent Review

- Reviewer: a fresh-context review agent (Opus, Tier C), started by the lead, not the
  implementer, 2026-11-16.
- Target: PR #359 at `7b23d03` (the first head), read-only.
- The client master plan, including plan a.1 and b.10, is the lead's planning document and is not
  in the repository. The decisions it settled for this issue are restated in `summary.md`.

## Report

The report is verbatim, in English, as the reviewer wrote it.

> Reviewer: fresh-context Opus agent, Tier C (STRONG_REVIEW_PROMPT), 2026-11-16, target head 7b23d03 (PR #359).
> Verdict: APPROVE WITH FOLLOW-UPS. Nothing blocks merge. macOS gates intact; Linux job not vacuous.
> MEDIUM Tools/architecture-check/architecture-check.py:24-33, 47-56, 85-88: forbidden imports matched by exact name; passed with rc=0: `import NIOFoundationCompat`, `import NIOConcurrencyHelpers` (KVMCore); `import _CryptoExtras`, `import SystemPackage`, `import X509` (KVMContracts); `import Musl` (KVMCore); `import NIOEmbedded` (BarrierCompatibility). Fix: prefix rule (NIO*, _Crypto*, Crypto*) plus SwiftASN1, Atomics, SystemPackage, Musl.
> LOW LinuxSkeletonTests.swift:96-106: the X11-gate test checks only DISPLAY; no XOpenDisplay, LinuxPlatform imports no CX* module; not X11 evidence.
> LOW Makefile:75: `--filter LinuxPlatformTests` passes with 0 matches if suites are renamed; add a minimum count.
> LOW m1-ci.yml cache step: `.build-linux` key uses only hashFiles('Package.swift'); acceptable with exact pins.
> Declared deviations judged OK: SwiftASN1/Atomics/SystemPackage (exact pins in #if os(Linux), CI drift check "dependency graph matches the lock: 7 packages"); xauth; Package.resolved not committed; Linux evidence from CI only. Swift RED/GREEN on a macOS mirror is weak evidence; rely on CI.
> Ran: gh run view 43752615456 --log: root 236 tests in 25 suites passed (1 intended skip), KVMContracts 118, BarrierCompatibility 374, Xvfb 15 tests in 3 suites passed with the gated test run, "verify-linux OK". Checker pytest 34 passed, 97 subtests; checker on head OK. Mutations caught: `@preconcurrency import NIOCore`, `import struct NIOCore.ByteBuffer` in KVMCore; missed: the seven above and `import Glibc` in BarrierCompatibility (consistent with Darwin allowed). dump-package on macOS: no Linux deps leak.
> Not run: local make verify-linux, full macOS make verify.

## Resolution (`40265e0`, and `8c388bc`)

| Finding | Resolution |
| --- | --- |
| Medium: forbidden imports matched by exact name | Fixed in `40265e0`: KVMCore and KVMContracts reject NIO*, Crypto*, _Crypto* plus SwiftASN1, Atomics, SystemPackage, X509 and Musl; protocol roots reject NIO*; Glibc, Musl and Darwin stay allowed there. Five new checker tests; the old checker fails with `Ran 39 tests ... FAILED (failures=25)`, the new one passes with `Ran 39 tests ... OK`. The reviewer's mutants are recorded as R1 to R3 and killed (`mutations-checker.json`); M5 was redefined because the prefix rule now catches NIOCore. |
| Low: the X11-gate test checks only `DISPLAY` | Documented: the component doc states that the Xvfb test proves only `DISPLAY` presence; X11 evidence comes with M4-024, M4-026 and M4-027. |
| Low: `--filter LinuxPlatformTests` passes with 0 matches | Fixed: `verify-linux` fails if the Xvfb xunit has fewer than `LINUX_MIN_TESTS` (15) tests. CI run 43822204604: "LinuxPlatformTests cases under Xvfb: 15 (minimum 15)". |
| Low: cache key uses only `hashFiles('Package.swift')` | Accepted as is: every dependency is pinned with `exact:`. |
| Not run: local `make verify-linux` and full macOS `make verify` | `make verify` was run after the fix: 24 of 24 passed (`commands.json`, `review-make-verify`). Local `verify-linux` does not complete under emulation; CI run 43822204604 passes both jobs. The review-round runs are recorded in `8c388bc`. |
