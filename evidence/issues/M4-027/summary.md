# M4-027 Evidence Summary

## Scope

Files: `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxScreenBackend.swift`,
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxScreenBackendTests.swift`,
`docs/platform/linux/M4-027-linux-screen-backend.md`, and this directory. No shared file
(`Package.swift`, `Makefile`, CI workflow, architecture checker) is touched and no public contract
is added.

`LinuxScreenBackend` is the Linux conformer of the C-015 `ScreenBackend` contract. It reports the
local X11 desktop's root-window geometry (origin (0, 0), size 1...0x7FFF, otherwise
`protocol.invariantViolation`) and the pointer position, and publishes a `changes` stream (newest
value only) when the origin or size changes, driven by RandR `RRScreenChangeNotify`. Pointer
movement alone is not a change.

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| How does the event thread wait? | It polls the event connection plus a wake pipe instead of blocking in `XNextEvent`. | Plan said blocking `XNextEvent`; this is a plan addition. `stop` writes the wake pipe, then joins the thread, then closes the connections. No busy loop. |
| Lost X server | EOF is peeked on both connections, and POLLHUP is honoured. | Xlib's default IO handler exits the process on a lost display; peeking first lets the backend finish `changes` and fail with `lifecycle.subsystemUnavailable`. |
| Connections | Two X connections: a locked query connection, and an event connection used only by the event thread. | No `XInitThreads` is needed because no connection is shared across threads. |
| Where does geometry come from? | `XGetGeometry` on the root window, clamped to 1...0x7FFF. | Live value, not Xlib's cached screen; `XRRUpdateConfiguration` is not needed. Consistent with DINF. |
| Server without RandR | Fails closed with `permission.capabilityUnavailable`. | Plan b.11. |
| Error handler and threads | No `XSetErrorHandler`, no `XInitThreads`. | Amendment h.8. |
| Xvfb flaky opens | Cause: Xvfb resets when its last client disconnects, and a connection made during the reset is dropped. Each test Xvfb keeps one sentinel connection and the retry loop is removed. | Reviewer's retry Low. A raw Xlib loop in the arm64 container: 556 of 600 opens failed without a kept client, 0 of 600 with one (from the lead's resolution notes, not from `commands.json`). |
| Test seam | A package-level `init(displayName:runsEventThread:)` lets a test query a dead server with no event thread. | Beyond the plan; kills mutants Q3 and L1. |
| Mutant L2 | Documented survivor. | `QueuedAfterReading` re-reads the socket; a test cannot schedule that deterministically. |
| Extra types | `LinuxScreenError` and `LinuxScreenGeometryRules`, package-level and small. | The reviewer accepted both. |

## RED

- Linux container, a compiling stub `LinuxScreenBackend.swift` with the real tests: 6 of the
  pure-rule tests failed (`commands.json`, `linux-container-red`, exit 1, expected failure). The
  raw log was lost when the session ended, so the entry records no output.

## GREEN

- Linux container (linux/arm64, image `swift:6.2.3-jammy`, same digest as `verify-linux`): 15 of
  15 runs of `MACKVM_X11_TESTS=1 swift test --filter LinuxScreen` passed, `Test run with 20 tests
  in 3 suites passed`, about 2.0 seconds each (`linux-container-green`). That entry is a summary
  of the loop runner's output, not a raw log.
- Mutation baseline in the container: `Test run with 20 tests in 3 suites passed after 2.036
  seconds.`
- macOS `swift test`: `Test run with 285 tests in 27 suites passed after 0.137 seconds.`
  (`swift-test-full`, exit 0); with `-warnings-as-errors` the same 285 tests pass
  (`swift-test-warnings-as-errors`, exit 0).
- Both format lints exit 0; `docs check OK`; `architecture check OK`; `PACKAGE OK: 217 issues,
  5 milestones, 17 epics`; `git diff --cached --check` exit 0.
- `make verify`: exit 0, the last five of its 24 gates shown in `commands.json` as PASSED
  (`make-verify`).
- Linux CI: both jobs, `verify-linux` and `build-test-manifest`, are SUCCESS at head `1b3b460`
  (run 43882089208, read from the PR checks). The first `verify-linux` attempt failed on an
  unrelated flaky M1-064 test (thread name), passed on rerun, and is fixed separately.

## Mutation checks

25 mutants against the container run (`mutations/mutations.json`, runner
`mutations/run_mutations.py`, `Dockerfile` beside it): 24 killed, restored byte for byte, with
`gitDiffClean` true for all 25. The file's `allKilled` flag reads true although L2 has `killed: false`;
the per-mutant entries are the truth, and L2 is the documented survivor.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| G1 | maximum dimension 0x8000 | 2 |
| G2 | accepted range starts at 0 | 1 |
| G3 | only the width is range-checked | 2 |
| G4 | `hasChanged` ignores the height | 1 |
| G5 | `hasChanged` also compares the pointer | 2 |
| G6 | geometry gets origin x 1 | 3 |
| E1 | `invariantViolation` allows a backoff retry | 3 |
| E2 | `subsystemUnavailable` carries `lifecycle.sleep` | 7 |
| E3 | `capabilityUnavailable` reports a failed cleanup | 2 |
| O1 | first open failure reports `invariantViolation` | 1 |
| R1 | missing RandR reports `subsystemUnavailable` | 1 |
| Q1 | cursor x and y swapped | 2 |
| Q2 | width and height swapped | 4 |
| C1 | event type compared with the wrong offset | 2 |
| C2 | `XRRSelectInput` never called | 2 |
| C3 | publish yields on every screen event | 1 |
| C4 | the stream keeps the oldest buffered value | 1 |
| S1 | `currentGeometry` reports `invariantViolation` once stopped | 5 |
| S2 | shutdown does not finish the stream | 3 |
| S3 | shutdown leaves the pipe descriptors open | 1 |
| S4 | shutdown leaves the displays open | 1 |
| Q3 | `currentGeometry` hands a closed connection to Xlib (crash kill) | process exit |
| L1 | neither POLLHUP nor the EOF peek checked (crash kill) | process exit |
| L2 | drain loop uses `QueuedAfterReading` | survived, documented |
| H1 | `markLost` does not finish the stream | 1 |

Q3 and L1 are killed by the Xlib fatal IO exit, not by a named failing test, which is why their
failing-test count is 0 in the JSON.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| Screen geometry and pointer on X11 | the Xvfb happy-path tests; mutants G1 to G6, Q1, Q2 |
| Change notification on resolution change | the screen-resize test with the CRTC resize helper; mutants C1 to C4 |
| Errors are terminal and typed | error-shape tests; mutants E1 to E3, O1, R1 |
| Clean stop, no leak, no crash on a lost server | stop, concurrent-stop, descriptor-leak (40 iterations) and server-loss tests; mutants S1 to S4, H1, Q3, L1 |
| Documentation | `docs/platform/linux/M4-027-linux-screen-backend.md`; `docs check OK` |
| Manual run on hardware | Not done. Hot-plug and resolution change on real hardware need the owner's E2E (issue tier H). |

## Independent review

- A fresh-context Opus reviewer (Tier C/H) approved with nits at `74ddbf2`
  (`independent-review.md`): 0 Critical, 0 High, 1 Medium, 4 Low. Nothing blocked the merge.
- The Medium (no EOF guard on the query connection) is fixed at `1b3b460`; the retry Low is fixed
  by the sentinel connection; the EOF-peek and `QueuedAfterReading` Low is covered by mutant L1,
  with L2 kept as a documented survivor; the other two Lows are documented. The review's own
  runs were Docker arm64 with Xvfb, three baseline runs of 18 tests, and four reviewer mutants.

## Merge

Pending owner approval.

## Known limitations

- No per-monitor identity or scale: only the root-window desktop size is reported.
- Wayland is out of scope; this backend serves X11 only.
- Hot-plug and resolution change on real hardware need the owner's E2E; Xvfb can only shrink, and
  the resize helper sets a CRTC mode, then the screen size.
- With several screens, a pointer on another screen makes `XQueryPointer` return False and the
  whole geometry fails closed.
- A server that dies in the middle of a query can still exit the process, because Xlib's IO
  handler cannot return; the guard covers a server already lost before the query.
- After a loss both Displays are deliberately left open, on the assumption that the composition
  root exits on display loss (plan b.16, amendment h.8).
- The Xvfb suite skips silently unless `MACKVM_X11_TESTS=1` is set.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2); Linux image `swift:6.2.3-jammy`); the machine-readable
test report is in `tests/`.
