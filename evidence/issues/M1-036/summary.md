# M1-036 Evidence Summary

GitHub Issue: #28 — `[M1-036] 實作 macOS Mouse Move Injector`, priority P1, risk
high, execution tier `B/H`, `low_model_autonomous_merge: false`.

Branch: `feat/m1-036-mac-mouse-move-injector`

Base commit: `ce06b3b0976366a47f4158d4fe2a28dc9bc72601`

Implementation commit: `dbc45d4e04942a03a6e73b86420801802369673f`, created by
the root reviewer at `2026-09-23T01:33:30Z`.

Status: **reviewer verified.** The root reviewer validated the implementation
commit and executed the Tier-H probe on real macOS; evidence time after the
probes is `2026-09-23T01:34:27Z`. Five-axis verdict: Critical 0, High 0,
Medium 0 unresolved, Low 1. No validation or manual verification is pending.

Authorship and review: **Claude Opus 5** wrote the implementation, the tests, the
component document and this evidence package, and is the sole author of
repository content. The **root reviewer** is the separate executor that reviews,
validates, runs the Tier-H probe, stages, commits and manages the pull request;
it is not an independent external model. Every result in "Final validation" is
the root reviewer's, transcribed by the author, who compiled, ran and probed
none of it. No review waiver is invoked.

## Deliverables

- `Packages/MacPlatform/Sources/MacPlatform/MacMouseMoveInjector.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/MacMouseMoveInjectorTests.swift`
- `docs/components/M1-036-mac-mouse-move-injector.md`
- `evidence/issues/M1-036/` — `summary.md`, `commands.json`, `environment.json`,
  `manual.md`, `manual-result.json`, `manual-output.log`,
  `tests/red-phase.json`, `tests/results.json`

No other repository path was created, modified, or deleted. The two untracked
owner artifacts at the repository root were not read, listed for content,
written, staged, or deleted.

## What was built

An immutable `Sendable` injector whose input boundary is domain-only. It accepts
`KVMEvent`, refuses every non-`mouseMove` case with a frozen M1-015 `CoreError`
before touching macOS, reads Accessibility trust through the M1-035 service and
fails closed on denial with that Issue's existing `permission.accessibilityDenied`
value, asks an **injected** resolver for the platform position, creates a
mouse-move `CGEvent` with documented public CoreGraphics API behind an opaque
internal `MacMouseMoveEventHandle`, and posts exactly that event once at
`kCGHIDEventTap`. The success value is `postRequested`, because `CGEventPost`
returns `void`. Design detail is in the component document.

Coordinate ownership was deliberately not taken: M1-039 owns logical, backing and
wire separation, normalization, clamping, and multi-display and Retina behavior.
The shipped default `MacPlatformPositionResolver.unresolved` resolves nothing, so
production injection fails closed until M1-039 installs the real mapper.

## Final validation (root reviewer, commit `dbc45d4`)

| Command | Result |
| --- | --- |
| `swift build --disable-sandbox --package-path Packages/MacPlatform --build-tests` | exit 0; build complete in 3.56 s; no compile errors or warnings from repository code |
| `env -u MACKVM_M1_036_MANUAL_PROBE -u MACKVM_M1_035_MANUAL_PROBE swift test --disable-sandbox --package-path Packages/MacPlatform` | exit 0; 31 declared, 29 ran, 2 manual probes skipped, 0 failures; Swift Testing run 0.006 s; clean process, no hang |
| `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | exit 0; final line `** BUILD SUCCEEDED **`; target `arm64-apple-macos14.0` on the local Apple Silicon destination; non-fatal warnings noted below |
| `make verify` (post-commit, authoritative) | exit 0; 19/19 gates passed at HEAD `dbc45d4`, including `swift-package-test:MacPlatform` (exact `swift test --package-path Packages/MacPlatform`, 3290 ms), `manifest-validation` (53 ms), `architecture-check` (334 ms), `code-quality` (2577 ms), `docs-check` (126 ms), `native-arm64-build` (934 ms); all 19 durations in `commands.json` `reviewerFinalResults.makeVerify` |
| `git diff --cached --check` | exit 0, no output, before the implementation commit |
| `jq` on every M1-036 JSON file | exit 0 |
| `MACKVM_M1_036_MANUAL_PROBE=read-origin swift test --package-path Packages/MacPlatform --filter manualRealInjectionProbeRunsOneReviewerSelectedAction` | exit 0; probe passed in 0.025 s |
| `MACKVM_M1_036_MANUAL_PROBE=move-and-restore swift test --package-path Packages/MacPlatform --filter manualRealInjectionProbeRunsOneReviewerSelectedAction` | exit 0; probe passed in 0.057 s; cursor restored |

`xcodebuild` notes: run after the implementation commit and after the current
evidence edits. Xcode warned that supported platforms were empty in
IDERunDestination metadata and that the first of multiple matching macOS
destinations was selected; both warnings are non-fatal. The first approval
attempt timed out before any execution result, so it is not a build failure; a
single retry ran and passed. The author's own attempt was refused by the
permission policy before start and is history only.

`make verify` notes: the authoritative run was rerun after the current evidence
edits with HEAD still `dbc45d4`; its ignored report
`artifacts/ci/m1-008-report.json` records commit `dbc45d4…` and overall status
passed (`2026-09-23T01:50:05Z`–`01:50:38Z`). History: an earlier **pre-commit**
sweep also passed 19/19 against the working tree that became `dbc45d4` (report
commit `ce06b3b…`, ended `2026-09-23T01:32:13Z`), after a first attempt inside
the nested Codex sandbox failed only with
`sandbox-exec: sandbox_apply: Operation not permitted`. It is kept in
`commands.json` `reviewerFinalResults.makeVerifyPreCommitHistory`.

## Acceptance criteria mapping

| # | Issue criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met.** Domain-only input: `nonMouseMoveDomainEventsFailClosedWithoutAnyPlatformWork` and the boundary test. Diagnosable creation failure: `eventCreationFailureIsDiagnosableAndPostsNothing`. No MainActor for high-frequency events: `injectionRunsOnADetachedNonMainActorTask`. All passed in the reviewer's ordinary suite. | `tests/results.json` `reviewerFinal`, `m1036Tests` |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** 31 declared, 29 ran, 2 manual probes skipped, 0 failures. Cancellation is not applicable (no asynchronous operation or owned resource); cleanup coverage is statelessness/idempotency plus the probe's restore and cleanup-only sequencing tests. | `tests/results.json` `reviewerFinal.ordinarySuite` |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** Every declaration is `package` or narrower; no platform type or handle on the package surface; nothing added to `KVMEvent` or any wire schema. Reviewer product/architecture axis: pass, no public API added. | component document; `commands.json` `reviewerFinalResults.fiveAxisReview` |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met** by build exit 0 with no repository-code warnings, the exact `xcodebuild` workspace build `** BUILD SUCCEEDED **` (only non-fatal Xcode destination-selection warnings, none from repository code), and post-commit `make verify` 19/19 (architecture-check, code-quality lint and `-warnings-as-errors`, native-arm64-build, MacPlatform exact-form tests). | `commands.json` `reviewerFinalResults` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** The component emits no log. `everyFailureEncodesToTheClosedTaxonomyWithoutCoordinatesOrPlatformText` passed; the probe output in `manual-output.log` is closed vocabulary with no coordinate or identifier. Reviewer security axis: no sensitive logs. | `tests/results.json`; `manual-output.log` |
| 6 | Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證 | **Met.** The root reviewer, not the author, ran both probe actions at `dbc45d4`, exit 0 each, and saw the cursor restored. **Post-request truth:** both the target move and the origin restore were *post-requested* (`move=postRequested restore=postRequested`), and the immediate read-back matched the origin (`cursor=matchesOrigin`), with `cleanup=notRequired`. **Delivery:** not claimed — `CGEventPost` is `void` and asynchronous, so no field asserts delivery. | `manual.md`, `manual-result.json`, `manual-output.log` |

## Five-axis review (root reviewer, commit `dbc45d4`)

1. **Source validity and traceability — pass.** GitHub Issue 28 re-read;
   dependencies 10 and 23 previously closed; canonical/frozen architecture
   unchanged.
2. **Product contract and architecture — pass.** `KVMEvent`-only boundary,
   protocol/core separation, no Barrier or network, M1-039 retains coordinate
   mapping, no public API added, no MainActor.
3. **Security, fail-safe and compatibility — pass.** Accessibility denial and
   event-creation failure fail closed, no sensitive logs, restore safety
   verified, TLS untouched.
4. **Tests and acceptance — pass** with the results above.
5. **Scope, hygiene and rollback — pass.** Only the three Exact Files plus
   evidence; protected artifacts excluded; rollback is PR revert.

Findings: Critical 0, High 0, Medium 0 unresolved, **Low 1** (see Remaining
risks, item 1).

## History of review corrections (superseded)

Each correction below is retained as history. Every "pending" or "not run"
statement it originally carried is superseded by "Final validation".

1. **Tier-H move-and-restore safety.** The probe pre-creates both the target and
   the origin restore events before any post, posts the target through
   `MacMouseMoveInjector.inject`, requests the origin back through the injector
   whenever the target post was requested, and — cleanup only — requests the
   pre-created restore directly once if the injector's restore requested none,
   reporting `cleanup=fallbackPostRequested` and failing the run. Four
   always-running sequencing tests use a recording post seam. The reviewer then
   reported 29 tests passing with 2 probes skipped for that tree.
2. **Cursor observation.** The `case .some(origin)` read-back switch was replaced
   by the pure helper `manualProbeCursorObservation`, compared with explicit `==`,
   plus the test `cursorObservationComparesTheReadBackWithTheOrigin`.
3. **CoreGraphics first-initialization hang — failed.** The reviewer reproduced
   twice that a clean ordinary suite hung before any output, sampled in
   `SLEventCreate` → `CGSScoreboard` → `SLSServerPort` initialization. A
   test-only `SerializedTestEventCreation` lock was added; the reviewer's clean
   run of that tree **hung again**, with one M1-036 thread holding the lock in
   the same initialization and two M1-035 tests blocked in
   `TCCAccessRequest`. This correction was removed.
4. **Pure-unit event seam — resolved.** The internal environment now creates and
   posts an opaque `MacMouseMoveEventHandle` with identity equality; `live` wraps
   the real `CGEvent`, so CoreGraphics calls, arguments and order are unchanged,
   and nothing reaches the package surface. Ordinary tests use only
   `MacMouseMoveEventHandle.synthetic()`. The lock, its boundary test, the opaque
   stub and the always-running live-creation test were removed;
   `syntheticHandlesAreEqualOnlyToThemselves` and the static source audit
   `onlyTheTierHLiveRegionNamesLiveEventCreationPostingOrTheProductionSeam` were
   added. M1-036 declares 19 tests. **The reviewer's clean-process suite passed
   with no hang** (31/29/2/0).

In the sessions for corrections 1–4 the author's `swift`, `make` and `python3`
invocations were refused by the permission policy, so the author compiled and ran
none of them; the details are in `commands.json` under
`reviewCorrectionSession`, `cursorObservationCorrectionSession`,
`coreGraphicsInitializationCorrectionSession` and
`pureUnitSeamCorrectionSession`, each now marked with its `historyStatus`.

The first author session's pre-correction results (25 declared tests, exit 0 in
the `--disable-sandbox` form; `validate_package.py` and `make architecture-check`
exit 0; `swift format lint` clean; exact `swift test`, `xcodebuild` and
`make verify` blocked by that environment) remain in `commands.json`
`requiredCommands` and `supplementaryCommands` as history, each with its
`reviewerResolution`.

## TDD

The original red phase is in `tests/red-phase.json`: exit 1 at `emit-module`,
naming the three missing types, recorded before any production file existed. The
review corrections were **not** test-first and no red run exists for them; the
file records the actual edit order. Green for the committed tree is the
reviewer's run in `tests/results.json` `reviewerFinal`.

## Tier-H manual probe — reviewer verified

| Run | Action | Exit | Sanitized line |
| --- | --- | --- | --- |
| 1 | `read-origin` | 0 | `action=read-origin origin=readable preparation=notAttempted move=notAttempted restore=notAttempted cleanup=notRequired cursor=notObserved` |
| 2 | `move-and-restore` | 0 | `action=move-and-restore origin=readable preparation=eventsPrepared move=postRequested restore=postRequested cleanup=notRequired cursor=matchesOrigin` |

The reviewer observed the cursor restored, and the immediate closed read-back
matched the original position. No cleanup fallback was required. The optional
unknown-action run was not executed because fail-closed parsing is covered by
the ordinary test `manualProbeSelectionFailsClosedAndIsSkippedByDefault`, which
passed. Environment: macOS 26.6.2 (25G83), arm64, Apple M4 Pro; display/layout
**unavailable** (`system_profiler` returned no per-display entries); keyboard
layout, network and peer not applicable.

## Scope

In scope: the injector, its tests and the opt-in Tier-H probe, the component
document, and this evidence. Out of scope and not implemented: coordinate
mapping (M1-039), buttons, scroll, keyboard, UI, app wiring, diagnostics catalog
entries, input-state ledgers, and any protocol, network or TLS change.

## Remaining risks

No Critical, High or Medium finding is unresolved.

1. **Low (retained, non-blocking): live creation boundary.** Live CoreGraphics
   event creation and posting are exercised only by the opt-in Tier-H probe, not
   by ordinary unit tests. This is intentional, to avoid the proven
   clean-process CoreGraphics/TCC initialization deadlock; the successful real
   probe closes acceptance for this Issue. A regression in the `live` seam would
   surface only in a Tier-H run or by source review.
2. **No delivery signal.** `CGEventPost` returns `void`; evidence records post
   requests and an immediate observation only.
3. **The shipped default posts nothing** until M1-039 lands; real end-to-end
   movement in the app is unverifiable before then.
4. **Probe residual window.** If the test process is terminated between the
   target post request and the restore request, no probe code runs any more.
5. **Identity scope.** The probe ran in the SwiftPM test process; app-bundle
   Accessibility authorization is not claimed.
6. **Static source audit.** The ordinary-test audit inspects test-file text only
   and proves nothing about framework behavior at run time.

## Rollback

Revert the M1-036 pull request. That removes the injector, its tests, the probe,
the document and this evidence in one operation and leaves `MacPlatform` at its
M1-035 state. Nothing persists and nothing is allocated across calls, so no
runtime resource, permission grant or migration needs cleanup.

## Follow-up

- **M1-039** installs the real `MacPlatformPositionResolver`.
- The app-wiring Issue owns app-bundle Accessibility authorization and when to
  prompt.
