# M4-020-FOLLOWUP-001 Evidence Summary

## Scope

Files: `Package.swift`, `Makefile`, `Apps/Linux/MacKVMClient/{main,ClientConfiguration,ClientRuntime,ClientEffects,ClientReport}.swift`,
`Apps/Linux/systemd/mackvm-client.service`,
`Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxLifecycleMonitor.swift`,
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxLifecycleMonitorTests.swift`,
`Tests/Integration/LinuxClientRuntimeTests.swift`,
`docs/platform/linux/M4-020-FOLLOWUP-001-linux-client-app.md`, and this directory.

The `mackvm-client` executable for Linux (X11): `connect <host>[:port] --name <n> [--display <:n>]
[--non-interactive]` and `fingerprint show|trust|forget`, exit codes 0 / 1 / 64 / 69 / 78, root
refused. `ClientRuntime` is the composition root: the Linux backends behind `ClientEffects` (one
`LinuxInjectionDrain` per generation), `FailSafeCoordinator`, `CleanupHooks`, `ClientCoordinator`,
`ReconnectManager` (a fresh TLS transport and `BarrierClientProtocolSession` per attempt) and
`RecoveryCoordinator`, fed by the new `LinuxLifecycleMonitor`. SIGINT, SIGTERM and SIGHUP end through
one bounded shutdown. Packaging: a `systemd --user` unit and `make dist-linux`. Built from the
repository's contracts and plan (b.16, h.3, h.5, h.6, h.8, a.7); no Barrier source was consulted.
Tier C/S, risk critical (issue #349, PR #370).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Injection thread | `LinuxInjectionDrain` (M4-024) replaces the plan's `CaptureQueue`, because h.6 and M1-063 need a joinable dedicated `Thread`. | PR body; accepted by the Tier C reviewer. |
| X11 start-up order (h.8) | `XInitThreads()`, then root X error and I/O handlers (previous kept, restored on stop), then screen, injector and clipboard. Protocol errors are counted, not forwarded. | Component doc; mutants M06 to M09, M29. |
| Display loss | Marks the display gone, runs the cleanup without touching Xlib and without joining a parked drain, exits 69. | Review resolution; mutants M22 to M26, M35. |
| Trust (a.7) | The stored fingerprint is read before each connect; only an equal one is accepted. Unknown: prompt (interactive) or instructions with no host, exit 78, nothing written. Changed: both displays, never stored. An unusable store fails closed, 78. | Component doc; mutants M10 to M13, M27, M28. |
| Signals during the trust prompt | The prompt races signals and display loss: declines, stores nothing, exits 0 or 69; stdin EOF exits 78. | Review resolution; mutant M36. |
| Shutdown bound | Release sweep first (1 s bound), other joins and injector close 2 s each, whole shutdown cut at 5 s. | Review resolution; Known limitations. |
| Root | Refused with exit 1 before any state is read. | Component doc; mutant M04. |
| Security reviewer | The owner decided on 2026-11-17 that a fresh-context security review replaces the designated Codex Security Reviewer for Tier S PRs. | `security-review.md`. |
| Which run is `make verify-linux ISSUE=M4-020-FOLLOWUP-001`? | The Linux suites in a native arm64 `swift:6.2.3-jammy` container, plus the CI `verify-linux` job (amd64), which is the gate of record. A local amd64 run under emulation stalled in the compiler for over an hour. | `commands.json` note. |

## RED

The new tests built against the base without the implementation files (`commands.json`, first
command, exit 1, recorded as an expected failure) fail to compile with missing types, for example
`error: cannot find type 'ClientExitCode' in scope`, `ClientConnector`, `ClientRuntimeSettings`,
`ClientBackendFactory`. The same RED was repeated after the review fixes (exit 1).

## GREEN

Linux, native arm64 `swift:6.2.3-jammy`, built with `-warnings-as-errors`, at the review fixes
(`fffb60f`):

- Focused `LinuxClient|LinuxLifecycle`: `✔ Test run with 33 tests in 5 suites passed after 0.034
  seconds.`, and 20 repeats all passing.
- Full root package: `✔ Test run with 517 tests in 53 suites passed after 1.534 seconds.`; with Xvfb
  and `MACKVM_X11_TESTS=1`: `✔ Test run with 517 tests in 53 suites passed after 6.375 seconds.`
- Child packages as `verify-linux` runs them: 118 tests in 2 suites and 374 tests in 15 suites pass.
- Real-binary smoke (exit 0): usage 64, root refused, no display 69, `fingerprint show` against
  `openssl s_server` equals openssl's SHA-256, unknown identity non-interactive exits 78 with no host
  and no trust file, trust then connect over real TLS, SIGTERM exits 0, killing Xvfb exits 69.
- Before the review fixes: focused 30 tests in 5 suites (20 repeats), full 514 tests in 53 suites;
  one Xvfb full run failed once in an existing M4-024 test (see Known limitations) and three reruns
  passed.

macOS, at the review fixes:

- `swift test`: `✔ Test run with 332 tests in 29 suites passed after 0.177 seconds.`; with
  `-Xswiftc -warnings-as-errors`: 332 tests in 29 suites passed.
- Both format lints exit 0; `docs check OK`; `architecture check OK`; `PACKAGE OK: 217 issues, 5
  milestones, 17 epics`; `make verify` exit 0; `xcodebuild ... build`: `** BUILD SUCCEEDED **`.
- `make dist-linux` (pinned linux/amd64 image, static stdlib): `dist-linux OK`, `SHA256SUMS` written
  (`mackvm-client` `54d6c22d...`, `mackvm-client.service` `a10aea88...`).
- CI at `fffb60f`: `verify-linux` and `build-test-manifest` both SUCCESS.
- The machine-readable report is `tests/swift-testing-xunit-swift-testing.xml`, the full Linux run
  after the review fixes (its header reads `tests="476"`, `skipped="41"`, `failures="0"`).

## Mutation checks

36 mutants in `mutations/mutations.json`, run by `mutations/run_mutations.py` with filter
`LinuxClient|LinuxLifecycle`: 35 killed by a failing test, 1 survivor (M34) by design.

| Ids | Area | Killing tests |
| --- | --- | --- |
| M01 to M05 | parser (default port, name length, extra fingerprint arguments), root refused, no display 69 | `the parser accepts the documented forms`; `the parser rejects malformed command lines`; `exit codes: usage 64, root refused, no X11 display 69` |
| M06 to M09, M29 | h.8 order, failed `XInitThreads`, previous handler kept and restored, display loss reported once | the `h.8:` tests; `a lost display reported by Xlib's I/O error handler ends with exit 69`; `connect runs the runtime after the bootstrap and ends on a signal with 0` |
| M10 to M13, M27, M28 | trust: non-interactive never prompts, unknown and changed never accepted, interactive trust stores, unusable store fails closed, `fingerprint trust` never replaces | `an unknown fingerprint exits 78 with instructions that name no host; nothing written`; `a changed fingerprint is refused, both shown, nothing replaced, exit 78`; the `interactive:` tests; `the evaluator accepts only the stored value`; `an unusable trust store fails closed with exit 78`; `fingerprint trust, forget and show` |
| M14 to M17, M25 | cleanup reaches the injector, sweep runs, new drain and new session per generation, shutdown closes the injector | `killing the server stream releases every held key and starts the next generation`; `h.5: a wake while connected releases the old input before the new session injects`; `enter, move, key, button, leave and clipboard both ways through the composition root` |
| M18 to M21 | h.3: network state before each wake, cancelled attempt cleaned up, termination refuses connect and stops monitors | the `h.3:` tests |
| M22 to M24, M26 | display loss exits 69 from the I/O handler, the injector and a screen stream end; no Xlib after loss | `an injection failure that loses the display runs the cleanup and exits 69`; `a screen stream that ends without a stop is a display loss: exit 69` |
| M30 to M32 | lifecycle: resume threshold, network edges only on change, polled only while armed | `a boot-time jump over 5 s between ticks is one resume; smaller drift is not`; the two network edge tests |
| M33 | unit: exit codes 64 69 78 never restart | `the systemd user unit has the required keys and nothing unexpected` |
| M35, M36 | review fixes: no unbounded join of a parked drain; a signal interrupts the trust prompt | `review: a drain worker parked by a display loss does not hang the cleanup; exit 69`; `review: a signal or a display loss while the prompt waits declines and exits` |
| M34 (survived) | h.5: a wake ends the old generation first | Expected: h.5 also holds by `prepareGeneration` waiting for `beginSession()`, which needs the old cleanup to have returned. |

M03, M11, M12, M18, M23 and M24 were rerun with the final tests (first runs exit 1 or 124 timeout);
the recorded results are the reruns.

## Acceptance mapping

| Criterion (issue #349) | Tests and evidence |
| --- | --- |
| Parser matrix and exit codes (0, 64, 69, 78, 1; port 24800; name 1 to 64 of `[A-Za-z0-9_-]`; `trust` takes `AA:BB:...` or bare hex) | The parser tests and `exit codes: usage 64, root refused, no X11 display 69`; mutants M01 to M05; smoke |
| Runtime with an in-process `BarrierServerProtocolSession` over an in-memory pair: enter, move, key, leave, clipboard | `enter, move, key, button, leave and clipboard both ways through the composition root`; mutants M21, M25 |
| Killing the server stream releases every held key and starts the next generation | `killing the server stream releases every held key and starts the next generation`; mutants M14, M15, M35 |
| Unknown fingerprint exits 78 with instructions that contain no host; non-interactive never writes the trust file | `an unknown fingerprint exits 78 with instructions that name no host; nothing written`; mutants M10, M11; smoke |
| SIGINT/SIGTERM/SIGHUP through the one cleanup | `connect runs the runtime after the bootstrap and ends on a signal with 0`; the prompt signal test; smoke SIGTERM 0 |
| Network state before each wake, cancelled attempt into the cleanup, termination stops monitors and refuses connects | The `h.3:` tests; mutants M18 to M21 |
| Lifecycle edges with injected clocks | `LinuxLifecycleMonitorTests`; mutants M30 to M32 |
| Structural test of the unit file; `make dist-linux` with static stdlib and `SHA256SUMS` | `the systemd user unit has the required keys and nothing unexpected`; mutant M33; `make dist-linux` in `commands.json` |
| Required commands | `commands.json`: Linux suites (CI `verify-linux` as amd64 record), `make dist-linux`, `make verify`, `xcodebuild`, `validate_package.py`, `make architecture-check` |
| Tier C/S reviews | `independent-review.md` and `security-review.md` |

## Independent review

- A fresh-context Opus reviewer (Tier C) asked for changes at `a020ac2`: 1 High, 1 Medium, 3 Low
  (`independent-review.md`). It ran the focused suites (30 tests in 5 suites) in arm64
  `swift:6.2.3-jammy` with Xvfb.
- A fresh-context Opus security review (the owner's 2026-11-17 decision, see `security-review.md`)
  approved with minor fixes: 4 Low, static only.
- All findings were addressed at `fffb60f` (bounded cleanup, prompt racing signals, release sweep
  first, dead code removed, bounded poll, systemd hardening); new mutants M35 and M36 are killed.

## Merge

Pending; the lead merges after green CI under the Product Owner's authorization of 2026-11-02.

## Discrepancies recorded

- The PR body predates the review fixes: it reports 30 focused tests, 514 full Linux tests and 34
  mutants (33 killed). The files at `fffb60f` record 33, 517 and 36 (35 killed). This summary uses
  the files.
- The PR body's RED quotes `cannot find type 'ClientRuntime'`; the recorded RED output lists other
  missing types (`ClientExitCode`, `ClientConnector`, ...). Both are the same failure mode.
- The xUnit report header reads `tests="476"` against the console's 517 tests in 53 suites; the
  report's count method differs from the console's (it was not reconciled here).
- The review record states `make verify` 24/24; `commands.json` records exit 0 and the last
  `[PASSED]` lines only, not a count.

## Known limitations

- Local `make verify-linux` (amd64 under emulation) stalled in the compiler and was not completed;
  the CI `verify-linux` job is the amd64 record.
- The existing M4-024 test "events are injected in order on the drain's own thread" can fail under
  load: `LinuxInjectionDrain` names its thread from inside the thread, which races on Linux. Outside
  this issue's files.
- Root is unsupported; a missing parent of the configuration directory fails closed (78); suspend is
  not seen in advance; a crash leaves XTest input held; the shutdown is cut at 5 s if a step hangs
  in Xlib, possibly with keys held.
- The `prepareGeneration` bound (10 s) has no test (timing).
- Signal handlers are installed after start-up begins (security review Low 4, harmless).
- Owner hardware E2E is issue #351.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21
clang-1700.6.3.2); Linux `swift:6.2.3-jammy`); the machine-readable test report is in `tests/`.
