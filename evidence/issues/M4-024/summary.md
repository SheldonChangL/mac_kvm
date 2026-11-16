# M4-024 Evidence Summary

## Scope

Files: `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Injector.swift`,
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxX11InjectorTests.swift`,
`docs/platform/linux/M4-024-linux-x11-injector.md`, and this directory.

`LinuxX11Injector` is the Linux conformer of the C-015 `InputInjectionBackend` contract (M4-002).
It turns `KVMEvent` input (pointer motion, buttons, scroll, keys, modifiers) into XTest requests on
an X11 display connection it owns, records each held key and button with the key code or button it
was pressed with, and sweeps them on `releaseAllHeld()`, `releaseRemaining()` and `close()`.
`LinuxInjectionDrain` is the bounded FIFO and the dedicated `mackvm-inject` thread that feeds it,
with `clearTransientState()` for the terminal path. `LinuxKeySymMapper` and `LinuxX11PointerMath`
hold the pure conversions. X11 capability is detected at `init`: no display is
`lifecycle.subsystemUnavailable`, no XTest is `permission.capabilityUnavailable`. The consumer is
the first-party Linux client (M4-SCOPE-001). The policy is first-party, built from the X11 public
API and the repository's contracts.

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Which key layout is claimed? | US ANSI positional, as M1-043: letters, digits, F1 to F24, punctuation, editing and arrow keys, the five modifiers and three media keys map to fixed keysyms; the key code is `XKeysymToKeycode`, and 0 is `.unsupported(.noPlatformKeyCode)`. Other layouts are not claimed. | Component doc, Key table; plan risk f.5. |
| Is `.repeatKey` injected? | Never: `.unsupported(.repeatNotInjected)`. The X server autorepeats an XTest-held key. | Plan decision 6, risk f.4; mutant M06. |
| How is a release matched to its press? | The injector records the key code or button used at press time and releases with that, so a keymap change between press and release cannot strand a key. | Component doc, Held input and the sweep; mutant M07. |
| Wheel mapping | Per notch, a press and release of button 4 (up), 5 (down), 6 (left) or 7 (right); vertical first; at most 32 notches per axis. A button above `XGetPointerMapping`'s count is `.unsupported(.buttonUnavailable)`. | Component doc, Events; mutants M09 to M12, M25. |
| Pixel math | `origin + round(v * (extent - 1))`, clamped; the inverse of the decoder's `(pixel - origin) / (extent - 1)`. | Mutants M13, M27. |
| Sweep order | Keys other than modifiers, then buttons, then the modifier group, each in reverse press order, then `XFlush`; `releaseRemaining()` adds an `XSync`. A failed release stays recorded, the call fails with `inputSafety.cleanupPartial`, and a later call retries it. | Plan h.1 and h.6; mutants M14 to M16, M18, M29. |
| Which thread drains? | One dedicated `Thread` named `mackvm-inject` (within Linux's 15-byte thread-name limit), never the cooperative pool. `enqueue` never blocks and returns `false` when the queue is full or stopped; an injection failure is reported once and stops the worker; `clearTransientState()` waits for the in-flight event, then drops the queue. | M1-063; plan h.6; mutants M20 to M23, M28. |
| `ClientInputSafety` conformance | Not declared: `LinuxPlatform` does not import `KVMCore`. The composition root (M4-020-FOLLOWUP-001) adapts the drain and the injector. | Component doc, API. |
| `XInitThreads` and the Xlib I/O error handler | Neither is called nor installed in this source. Both belong to the composition root. | Component doc, Threads and Known limitations; review h.8 check. |
| Which tests does the issue's `make verify-linux ISSUE=M4-024` mean? | The Linux suite run in `swift:6.2.3-jammy`, plus the CI `verify-linux` job, which is the gate of record. | `commands.json` notes. |
| No `environment.json` and no `manual.md` | Accepted for this PR: the Tier H evidence is the Xvfb suite now, with the owner E2E (M4-036-FOLLOWUP-001) later. | Component doc, Known limitations. |

## RED

Against the tests with `LinuxX11Injector.swift` removed (`commands.json`, first command, exit 1,
recorded as an expected failure): the build failed with 239 compiler errors, for example `cannot
find 'LinuxKeySymMapper' in scope`, `cannot find 'LinuxX11Injector' in scope` and `cannot find
'LinuxInjectionDrain' in scope`. The log was transcribed from the session's tool output because the
raw log's scratch directory was cleared.

## GREEN

Linux, `swift:6.2.3-jammy`, linux/arm64, after the review notes (`5286139`):

- `swift test --filter LinuxPlatformTests`, plain: `✔ Test run with 52 tests in 7 suites passed
  after 0.206 seconds.`
- Three runs with `MACKVM_X11_TESTS=1` under `xvfb-run`: each `✔ Test run with 52 tests in 7
  suites passed`, after 6.345, 6.337 and 6.328 seconds.
- The earlier run before the review notes was 51 tests in 7 suites: one plain run and 8 Xvfb runs
  (the machine-readable report below is from it).

macOS at `5286139` (the rerun after the review notes):

- Full root package: `✔ Test run with 285 tests in 27 suites passed after 0.135 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 285 tests in 27 suites passed after 0.137
  seconds.`
- Both format lints (the two files, and the repository) exit 0; `docs check OK`; `architecture
  check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `git diff --cached --check` exit 0;
  `make verify`: 24 of 24 gates passed (`[PASSED]` lines in `commands.json`).
- CI at the reviewed head `402c795`: runs 43872500432 and 43869297081, `verify-linux` passed. CI at
  the final head `5286139`: run 43978839484, both jobs passed.
- The machine-readable report is `tests/swift-testing-xunit-swift-testing.xml`, from the earlier
  51-test Linux run (not regenerated after the review notes).

## Mutation checks

29 mutants in `mutations/mutations.json`, run by `mutations/run_mutations.py`: 28 killed by a
failing test and 1 killed by timeout (M20, a hang).

| Ids | Area | Killing tests |
| --- | --- | --- |
| M01 to M05 | key table: letters, function keys, quote, command, out-of-domain letters | `every catalog member maps to its X11 keysym`; `unknown and out-of-domain payloads have no keysym` |
| M06 to M08 | repeat injected; release uses the current keymap; key code 0 injected | `a repeat is never injected, even for a held key`; `a release after a keymap change frees the key code that was pressed`; `a key the keymap lacks is noPlatformKeyCode and is not recorded` |
| M09 to M12 | wheel signs, notch cap 33, auxiliary button | `wheel sign table: up 4, down 5, left 6, right 7, vertical first`; `a scroll is a press and release per notch`; `each wheel axis is capped at 32 notches, including Int32.min`; `button table: left 1, middle 2, right 3, auxiliary 8` |
| M13, M27 | pixel scale uses the extent; motion ignores the origin | `every pixel round-trips through the decoder's normalization`; `a move lands on the pixel the server meant, offset by the origin` |
| M14 to M16, M29 | sweep order, buttons skipped, failed release forgotten, modifiers before buttons | `releaseAllHeld: other keys, then buttons, then modifiers, each in reverse press order`; `the terminal path leaves no key or button down (h.1, h.6)`; `a failed sweep reports cleanupPartial, keeps what failed and retries it` |
| M17 | non-input injected as success | `events that are not input fail with preconditionFailed and change nothing` |
| M18, M19 | flush is `XFlush` not `XSync`; `release(_:)` does not sync | `release(_:) waits for the server, and an unsupported release counts as done`; `releaseRemaining sweeps, then syncs; flush is XSync` |
| M20 to M23, M28 | drain does not join the worker, keeps the queue, is unbounded, does not stop on failure, uses the global queue | `joinsInFlight` (timeout, M20); `a full queue refuses, and a stopped drain refuses`; `clearTransientState waits for the in-flight event, then drops the queue`; `an injection failure is reported once and stops the worker`; `events are injected in order on the drain's own thread` |
| M24, M25 | missing XTest accepted; pointer button count ignored | `an X server without XTest is permission.capabilityUnavailable`; `buttons beyond the pointer's button count are unavailable` |
| M26 | `close()` does not release | `close releases what is held, closes once, and later calls fail` |

M20 was re-run after the review fix: with the 5 s limit on the join wait it now fails in 5.004 s
(review resolution).

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Every Focus item has an implementation, test or sign-off: mouse, button, scroll, keyboard, modifier | The pure table and pointer arithmetic tests, the in-memory port tests, and under Xvfb: key codes (`a` 38, Shift 50, `b` 56, Return 36, `1` 10, F5 71, minus 20), buttons, wheel and motion delivered to a test window on a second connection; mutants M01 to M13, M25, M27 |
| `releaseAll` keys and buttons | The sweep-order, partial-sweep and `releaseAllLeavesNothingDown` tests, the latter also under Xvfb (an empty `XQueryKeymap` and button mask after the terminal path); mutants M14 to M16, M26, M29 |
| X11 capability detection | The no-display test, and `permission.capabilityUnavailable` from an Xvfb started with `-extension XTEST`; mutant M24 |
| Happy path, boundary, invalid input, error, cancel and cleanup tests | Happy path `keyHappyPath` and the Xvfb pointer test; boundary: the 32-notch cap and the pixel clamp; invalid: unknown keys, non-input events; cleanup: `close`, the drain join and `clearTransientState`; failure: a failed XTest request, partial sweep, display loss |
| Public behavior matches the contract; no implicit API | C-015 conformer with `package` access; no `KVMEvent` or wire change. Not conforming to `ClientInputSafety` is recorded under Decisions |
| Architecture checker, lint, build and unit tests with no new warning | `commands.json`: architecture check OK, both lints exit 0, 285 root tests with warnings as errors, `make verify` 24 of 24, Linux 52 tests in 7 suites. The SwiftPM "unhandled files" warning predates this change (`Tests/SystemTests`) |
| Production logs carry no typed text, clipboard payload or secret | The source has no logging (independent review, `independent-review.md`); held input is kept in memory only |
| Manual evidence verified by a non-executing reviewer | Not available: no `manual.md` and no `environment.json`. The Xvfb suite stands in until the owner E2E (M4-036-FOLLOWUP-001). See Known limitations |

## Independent review

- A fresh-context Opus reviewer (Tier H) approved the PR at `402c795`: nothing blocking, 2 Low
  findings and 2 Nits (`independent-review.md`). The reviewer verified the keysym table against
  `keysymdef.h` and `XF86keysym.h`, the press-time release, the wheel and pixel math, the sweep
  order, the absence of `XInitThreads`, an error handler and logging, and the drain's threading.
- The reviewer ran 36 tests in 4 suites with the `LinuxX11Injector` filter on arm64 `swift:6.2.3-jammy`
  with Xvfb, all passing, and 6 mutants of its own, all detected.
- All four notes were addressed in `5286139`: one new test (`clearFromWorker`), two documentation
  changes, and a 5 s limit on the `joinsInFlight` wait.

## Merge

Pending owner approval.

## Known limitations

- Xlib's default I/O error handler exits the process when the display connection breaks. Turning
  that into `lifecycle.subsystemUnavailable` is the composition root's job
  (M4-020-FOLLOWUP-001); until then display loss ends the process.
- Only US-layout positions are claimed (risk f.5); `XKeysymToKeycode` picks the first key code for
  a keysym.
- Lock and modifier state at enter are not synthesized (owner decision 3, risk f.6).
- A crash of the client leaves XTest-held input pressed (risk f.9).
- The `screen` callback runs under the injector's lock on every move; it must return promptly and
  never call back into the injector (documented in both inits).
- `deinit` closes the connection without releasing held input; callers sweep with
  `releaseRemaining()` or `close()` first.
- Not re-run after the review notes: the full 29-mutant batch (only M20 was), and there is no
  mutant for the `clearFromWorker` test. The committed xunit report is the earlier 51-test run.
- Tier H manual evidence is the Xvfb suite now and the owner E2E (M4-036-FOLLOWUP-001) later;
  there is no `environment.json` or `manual.md`.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3 (swiftlang-<ip>.21
clang-1700.6.3.2); Linux `swift:6.2.3-jammy`); the machine-readable test report is in `tests/`.
