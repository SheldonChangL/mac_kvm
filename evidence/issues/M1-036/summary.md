# M1-036 Evidence Summary

GitHub Issue: #28 — `[M1-036] 實作 macOS Mouse Move Injector`, priority P1, risk
high, execution tier `B/H`, `low_model_autonomous_merge: false`.

Branch: `feat/m1-036-mac-mouse-move-injector`

Base commit: `ce06b3b0976366a47f4158d4fe2a28dc9bc72601`

Implementation commit: `pending`. The author never writes to `.git`; the root
reviewer creates the commit and the SHA is transcribed afterwards.

Status: **author complete, reviewer pending. Acceptance is not claimed.** The
Tier-H manual probe has **not been executed** by anyone. The corrected test file
has **not been compiled or run by the author**: in the correction session every
`swift`, `make` and `python3` invocation was refused by the session's permission
policy. See `commands.json` `reviewCorrectionSession`. The reviewer then found the
clean full suite hanging, twice: the test-only creation gate did not fix it, and
it is replaced by a pure-unit synthetic event-handle seam. **The clean full suite
is pending post-fix validation by the reviewer** (see "Review correction:
CoreGraphics first-initialization hang" and "Review correction: pure-unit event
seam").

Authorship and review: **Claude Opus 5** wrote the implementation, the tests, the
component document and this evidence package, and is the sole author of
repository content. The root reviewer is a separate executor that reviews,
validates, stages, commits and manages the pull request. No review waiver is
invoked.

## Deliverables

- `Packages/MacPlatform/Sources/MacPlatform/MacMouseMoveInjector.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/MacMouseMoveInjectorTests.swift`
- `docs/components/M1-036-mac-mouse-move-injector.md`
- `evidence/issues/M1-036/` — `summary.md`, `commands.json`, `environment.json`,
  `manual.md`, `manual-result.json`, `tests/red-phase.json`,
  `tests/results.json`

No other repository path was created, modified, or deleted. The two untracked
owner artifacts at the repository root were not read, listed for content,
written, staged, or deleted.

## What was built

An immutable `Sendable` injector whose input boundary is domain-only. It accepts
`KVMEvent`, refuses every non-`mouseMove` case with a frozen M1-015 `CoreError`
before touching macOS, reads Accessibility trust through the M1-035 service and
fails closed on denial with that Issue's existing `permission.accessibilityDenied`
value, asks an **injected** resolver for the platform position, creates a
mouse-move `CGEvent` with documented public CoreGraphics API, and posts exactly
that event once at `kCGHIDEventTap`. The success value is `postRequested`,
because `CGEventPost` returns `void`. Design detail is in the component document.

Coordinate ownership was deliberately not taken: M1-039 owns logical, backing and
wire separation, normalization, clamping, and multi-display and Retina behavior.
The shipped default `MacPlatformPositionResolver.unresolved` resolves nothing, so
production injection fails closed until M1-039 installs the real mapper.

## Review correction: Tier-H move-and-restore safety

The root reviewer required the opt-in probe to minimize any risk of leaving the
cursor displaced. The probe now:

1. creates both the target event and the origin restore event through the live
   creation seam **before anything is posted**, and stops before any trust read
   or post if either cannot be created;
2. posts the target through the real `MacMouseMoveInjector.inject` path;
3. requests the origin back through the same injector path whenever the target
   post was requested; and
4. **cleanup only**: if the target post was requested and the injector's restore
   requested none, requests the pre-created origin restore directly, once, at
   the injector's tap, reports `cleanup=fallbackPostRequested`, and fails the
   run.

Post requests are recorded by event identity at the post seam, independently of
what `inject` reports. No sleep was added and no field claims delivery. The
output line is closed vocabulary with no coordinate. The sequencing is covered by
four new always-running tests that use a recording post seam and cannot move the
real cursor. Production source is unchanged by the correction.

## Review correction: CoreGraphics first-initialization hang

The root reviewer reproduced twice, each from a clean test process, that
`env -u MACKVM_M1_036_MANUAL_PROBE swift test --disable-sandbox --package-path Packages/MacPlatform`
builds and then hangs indefinitely before any Swift Testing output. The
reviewer's one-second `/usr/bin/sample` of the live helper showed several
concurrent M1-036 tests blocked in the first CoreGraphics/SkyLight
initialization (`makeOpaqueStubEvent` or
`MacMouseMoveInjectionEnvironment.live.makeMouseMoveEvent` → `SLEventCreate` /
`SLEventCreateMouseEvent` → `CGSEventSourceForID` → `CGSScoreboard` →
`SLSServerPort` → `_dispatch_once_wait` / `__ulock_wait`), with other tests,
including M1-035's real trust read, running concurrently. Warming the runtime by
running one M1-036 event test first let the suite pass, which the reviewer
rejected as a gate. The reviewer terminated only the hung test process IDs.

Fix, test file only: every automated M1-036 test-side `CGEvent` creation (the
opaque stub, the recording platform's live creation, and the explicit
live-environment test) now goes through `SerializedTestEventCreation`, one
test-only `NSLock`. Production source is unchanged and the live seam stays
lock-free. No sleep, retry, timeout, production lock or test-order dependence was
added. The opt-in manual probe stays outside the gate. The new always-running
test `everyAutomatedEventCreationRouteCreatesInsideTheOneTestOnlyGate` pins the
boundary through a task-local observer that sees only its own test's creations;
it asserts which routes create inside the gate, not that the hang is gone,
because a race's absence cannot be asserted deterministically.

The author could not compile or run anything after that fix: `swift build` was
refused by the session's permission policy. See `commands.json`
`coreGraphicsInitializationCorrectionSession`. **The gate failed review; see the
next section.**

## Review correction: pure-unit event seam

The reviewer's build of the gated tree succeeded, and a clean full suite hung
again. The post-fix `/usr/bin/sample` showed one M1-036 thread owning
`SerializedTestEventCreation` while blocked in `SLEventCreate` →
`CGSScoreboard` → `SLSServerPort` initialization, two ordinary M1-035 tests
concurrently blocked in `hasAuthorizationForControlComputer` →
`TCCAccessRequest`, and every other M1-036 event test waiting on the gate.
Serializing only M1-036's own creation cannot break that cross-framework
initialization cycle, and M1-035 is not modified by this Issue.

Fix, production seam and test file:

- `MacMouseMoveInjectionEnvironment` now creates and posts an opaque `internal`
  `MacMouseMoveEventHandle` whose `==` is identity. `live` wraps the real
  `CGEvent` from `CGEventCreateMouseEvent` and its post seam posts exactly that
  event, so the CoreGraphics calls, arguments and order are unchanged. Only the
  live seam in `MacMouseMoveInjector.swift` can wrap or unwrap an event. No
  handle, `CGEvent` or `CGPoint` reaches the package surface; nothing is public.
- `SerializedTestEventCreation`, its boundary test, the opaque-stub helper and
  the always-running live-creation test were removed. Ordinary tests create only
  `MacMouseMoveEventHandle.synthetic()` handles, which wrap no event, and cover
  creation, exact identity, creation failure, ordering, repetition and privacy.
- Real creation and posting remain only in the opt-in Tier-H probe, skipped
  unless `MACKVM_M1_036_MANUAL_PROBE` is set, with its safety unchanged:
  pre-created target and restore before the target post, restore through the
  injector, cleanup-only fallback, no sleep, closed vocabulary.
- The explicit cursor read-back helper and its equal/different/nil test are
  kept; they use `CGPoint` values only.
- `onlyTheTierHLiveRegionNamesLiveEventCreationPostingOrTheProductionSeam` is a
  static source audit of the test file: ordinary text names no event creation,
  post, event source, production seam or the removed gate; the production
  initializer is composed exactly once, by the production-default test; the
  live region names the production seam and the cursor read and holds exactly
  the one gated probe. It is static evidence only, not dynamic proof. The
  production-default test still makes M1-035's real, non-prompting trust read.

No sleep, retry, timeout, production lock, global lock, `unsafeBitCast`, fake
CF object or test-order dependence was added. The M1-036 test file still
declares 19 tests.

**The clean full suite is pending post-fix validation by the reviewer.** The
author could not compile or run anything after this fix either: `swift build`,
and even a read-only `grep`, were refused by the session's permission policy
with "This command requires approval". See `commands.json`
`pureUnitSeamCorrectionSession`.

## Acceptance criteria mapping

| Issue criterion | Author verdict | Evidence |
| --- | --- | --- |
| Every Focus item has locatable implementation, test, or sign-off | Met by the author for the three Focus items: domain-only input (`nonMouseMoveDomainEventsFailClosedWithoutAnyPlatformWork`, boundary test), diagnosable creation failure (`eventCreationFailureIsDiagnosableAndPostsNothing`), no MainActor for high-frequency events (`injectionRunsOnADetachedNonMainActorTask`). | `tests/results.json` |
| Happy path, boundary, invalid input, error/cancel/cleanup tests pass | **Reviewer pending for the corrected file.** Passed in the first author session: 25 declared, 23 executed, 0 failures. The root reviewer reported the corrected file passing with 29 tests, 2 manual probes skipped. The cursor-observation and creation-gate corrections each added one test; the package now declares 31 tests by construction, neither correction has been run by the author, and the reviewer's post-fix clean full suite is pending. Cancellation is not applicable; idempotency and the probe's cleanup sequencing are the cleanup coverage. | `tests/results.json` `reviewCorrection` |
| Public behavior matches CONTRACT_CATALOG, no implicit new API | Met by construction: every declaration is `package` or narrower, no platform type on the package surface, nothing added to `KVMEvent` or any wire schema. | component document |
| Architecture checker, lint, build, unit tests pass with no new warning | **Reviewer pending.** Not run for the corrected tree. | `commands.json` |
| Production logs contain no typed text, clipboard payload, secret, or recoverable content | Met by construction: the component emits no log. A test asserts each failure encodes to four closed keys with no coordinate and no platform type name; a new test pins the probe's line to closed vocabulary. | `everyFailureEncodesToTheClosedTaxonomyWithoutCoordinatesOrPlatformText`, `cleanupRequestsTheRestorePostWhenTheInjectorRestoreFails` |
| Manual/real-machine evidence verified by a non-executing reviewer | **OPEN. Not yet executed.** The author ran neither probe action and moved no cursor. | `manual.md`, `manual-result.json` |

## Five-axis author evidence

This is the author's own account for the reviewer to check, not an independent
review.

1. **Source validity and traceability.** The Issue file
   `issues/M1/M1-036-mac-mouse-move-injector.md` and the M1-039 Issue's Exact
   Files, which place `ClientCoordinateMapper.swift` in this same module, were
   read before the correction. SDK facts are quoted from the installed
   `MacOSX26.2.sdk` headers in `environment.json`. Every `CoreError` value used
   already exists in `CoreErrors.swift`.
2. **Product contract and architecture.** `KVMEvent` is the only Core-to-platform
   input. No public declaration, protocol, transport, Barrier, networking or
   TLS dependency is added, and no coordinate mapping is implemented.
3. **Security, fail-safe and compatibility.** Every failure fails closed before
   posting. Injection never prompts and never opens System Settings. No
   permission decision is cached or bypassed, and TLS defaults are untouched.
   The probe is skipped unless named, prepares both events before posting, and
   always requests an origin restore once the move is requested.
4. **Tests and validation.** The ordered seam log proves call order and that
   nothing runs after a failure. The corrected file is **not validated by the
   author**: compilation, tests, lint and gates are reviewer pending.
5. **Scope, hygiene and rollback.** Only the three Exact Files and this evidence
   directory are touched. The correction changes the test file, the component
   document and this package, not production source.

## Commands and results

First author session, pre-correction, retained as history in `commands.json`:
`python3 Tools/Backlog/validate_package.py` exit 0 (PACKAGE OK: 217 issues);
`make architecture-check` exit 0; `swift format lint --recursive --strict` clean;
`swift test --disable-sandbox --package-path Packages/MacPlatform` exit 0 with
25 declared tests; the exact `swift test` and `xcodebuild` forms and
`make verify` were blocked by that environment.

Correction session, 2026-09-23:

| Command | Result |
| --- | --- |
| `swift test --package-path Packages/MacPlatform` | not run: refused by permission policy before start |
| `swift test --disable-sandbox --package-path Packages/MacPlatform` | not run: refused before start |
| `make architecture-check` | not run: refused before start |
| `python3 Tools/Backlog/validate_package.py` | not run: refused before start |
| `grep -c -E ".{101}"` on the test file | `0`; a line-length precheck only, not the lint gate |
| `git diff --check` | exit 0, no output; weak, because every M1-036 path is untracked |
| `git diff --no-index --check /dev/null <path>` for each M1-036 file except the unchanged source | no output for any path |

The root reviewer said the MacPlatform suite passed 25 tests before the
correction; that is the reviewer's observation, not an author run.

The root reviewer then reported that
`env -u MACKVM_M1_036_MANUAL_PROBE swift test --disable-sandbox --package-path Packages/MacPlatform`
passed against the corrected file with 29 tests, 2 manual probes skipped.

Cursor-observation correction, 2026-09-23: the probe's `case .some(origin)`
read-back switch was replaced by the pure helper `manualProbeCursorObservation`,
which compares with explicit `==`, and the always-running test
`cursorObservationComparesTheReadBackWithTheOrigin` covers equal, different and
nil read-backs. The probe was not run. The same `env -u ... swift test
--disable-sandbox` command and `swift format lint` on the test file were both
refused by the permission policy before start, so nothing after this
correction was compiled, linted or run by the author. See `commands.json`
`cursorObservationCorrectionSession`.

## TDD

The original red phase is in `tests/red-phase.json`: exit 1 at `emit-module`,
naming the three missing types, recorded before any production file existed. The
original green is in `tests/results.json`. The review correction was **not**
test-first, and no red or green run exists for it; `tests/red-phase.json`
`reviewCorrectionRedPhase` records the actual edit order.

## Tier-H manual probe — not yet executed

Steps, expected lines and the closed vocabulary are in `manual.md` and
`manual-result.json`, which has `status: pending_reviewer` and an empty `runs`
array. `manual-output.log` does not exist, because no run has produced output.

## Scope

In scope: the injector, its tests and the opt-in Tier-H probe, the component
document, and this evidence. Out of scope and not implemented: coordinate
mapping (M1-039), buttons, scroll, keyboard, UI, app wiring, diagnostics catalog
entries, input-state ledgers, and any protocol, network or TLS change.

## Remaining risks

1. **The corrected test file is uncompiled and unrun by the author.** Compile
   errors or swift-format findings are possible and would surface in the
   reviewer's run.
2. **Posting has no truthful success signal.** `CGEventPost` returns `void`, so
   only requests are recorded.
3. **The shipped default posts nothing** until M1-039 lands; real end-to-end
   movement in the app is unverifiable before then.
4. **The probe's `cursor=` read-back is racy by design** and is not asserted.
5. **Residual window:** if the test process is terminated between the target
   post request and the restore request, no probe code runs any more.
6. **`internal.unclassified` for creation failure** is a judgment call, because
   the SDK documents no reason for a `NULL` return.
7. **The creation gate failed and was removed; its replacement is
   unvalidated.** The pure-unit handle seam was neither compiled nor run by the
   author, so a compile error, a lint finding or a residual hang is possible. It
   removes every M1-036 ordinary event creation, but not M1-035's real trust
   reads or the production-default test's real trust read. If the hang can occur
   without any event creation in the process, this fix will not remove it; only
   the reviewer's clean-process full-suite run can show that. The file declares
   19 M1-036 tests and 31 package tests by construction, not by an observed run.
8. **Live creation is no longer asserted by an ordinary test.** That the live
   seam creates a `.mouseMoved` event at the requested position, and posts the
   wrapped event, is now exercised only by the opt-in Tier-H probe and by source
   review.
9. **The source audit is static.** It inspects names in the test file text, can
   be defeated by indirection it does not name, and proves nothing about what a
   framework does at run time.

## Rollback

Revert the M1-036 pull request. That removes the injector, its tests, the probe
and the document in one operation and leaves `MacPlatform` at its M1-035 state.
Nothing persists and nothing is allocated across calls, so no runtime resource,
permission grant or migration needs cleanup.

## Follow-up

- **M1-039** installs the real `MacPlatformPositionResolver`.
- The app-wiring Issue owns app-bundle Accessibility authorization and when to
  prompt.
