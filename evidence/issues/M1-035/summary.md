# M1-035 Evidence Summary

GitHub Issue: [#23](https://github.com/SheldonChangL/mac_kvm/issues/23) —
`[M1-035] 實作 macOS Accessibility Permission Service`, state OPEN, priority P1,
risk high, execution tier `B/H`, `low_model_autonomous_merge: false`.

Branch: `feat/m1-035-accessibility-permission-service`

Base commit: `c26240787447a911209867611c0210ec0fa7f428`

Implementation commit: **`9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3`**. Created
by the coordinating Codex reviewer; the author never wrote to `.git`, and the
SHA is transcribed from the reviewer's committed HEAD in place of every earlier
`pending` marker.

Status: **all canonical Acceptance Criteria met.** The reviewer's Required
Command sweep passed in the exact frozen forms, including `make verify` with all
19 named gates against the committed tree at `9c53be7d`, exit 0. The tier `H`
criterion is met: a reviewer who is not the executing author executed the real
`check`, the real `request` and the real open-settings action through
`AccessibilityPermissionService` production defaults on real macOS. Two
supplemental observations were not demonstrated and are recorded as explicit
non-blocking limitations — the real prompt was never visibly seen, and no
same-process grant-to-revoke transition was demonstrated. The Issue requires
neither. See `manual.md`.

Authorship and review: the implementation author is **Claude Opus 5**, which
wrote the implementation, the tests, the component document, and this evidence
package, and is the sole author of repository content for this Issue. The
**coordinating Codex agent** is a separate executor: it reviews, runs the
authoritative Required Command sweep in the exact frozen forms, performs the
manual verification, creates the commit, and opens and merges the pull request.
Author and reviewer are therefore not the same executor. No review waiver is
invoked, relied on, or extended.

## Deliverables

Exactly the Issue's three Exact Files plus the explicitly required evidence
directory:

- `Packages/MacPlatform/Sources/MacPlatform/AccessibilityPermissionService.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/AccessibilityPermissionServiceTests.swift`
- `docs/components/M1-035-accessibility-permission-service.md`
- `evidence/issues/M1-035/` — `summary.md`, `commands.json`, `environment.json`,
  `manual.md`, `manual-output.log`, `manual-result.json`,
  `tests/red-phase.json`, `tests/results.json`

No other repository path was created, modified, or deleted.

## API surface

No public contract is added. Every declaration is `package` or narrower, so the
frozen `CONTRACT_CATALOG` public surface is unchanged and no cross-module public
API was required. `package` rather than `internal` is used for the service and
its value types because the Issue's Scope requires the state to be usable by the
UI and a future injector, both of which live in the same root package; the
dependency seam itself stays `internal`.

- `AccessibilityTrustState` — `trusted` / `notTrusted`, plus
  `actionableFailure: CoreError?`.
- `AccessibilityTrustRequestResult` — `promptRequested`, `trustStateAtReturn`.
- `AccessibilitySettingsDestination` — `systemSettingsApplication`.
- `AccessibilityPermissionService` — `init()`, `currentTrustState()`,
  `requestTrust()`, `openSystemSettings()`.
- `AccessibilityPermissionEnvironment` — internal seam of four `@Sendable`
  closures, with a `live` production default.

## Source traceability

Read in full before editing: live Issue #23 via `gh issue view 23`; `README.md`;
`FROZEN_DECISIONS.md`; `ARCHITECTURE_GUARDRAILS.md`; `CONTRACT_CATALOG.md`;
`DEFINITION_OF_READY.md`; `DEFINITION_OF_DONE.md`; `AGENT_HANDOFF_TEMPLATE.md`;
`issues/M1/M1-035-accessibility-permission-service.md`;
`docs/components/M1-015-core-errors.md`;
`Packages/KVMContracts/Sources/KVMContracts/CoreErrors.swift`;
`Packages/MacPlatform/Package.swift`; the evidence packages for M1-015 and
M1-PKG-002; and the gate tools `cigates.py`, `architecture-check.py`,
`code-quality.py` and `docs-check.py` that define the acceptance gates.

Preconditions confirmed: M1-006 and M1-015 are merged into `main` and their
outputs are readable; M1-PKG-002 is merged, so
`swift test --package-path Packages/MacPlatform` resolves a real child package
and `swift-package-test:MacPlatform` is a blocking named gate. No `AGENTS.md`
exists anywhere in the repository; nothing was inferred in its place.

SDK facts were read from the installed `MacOSX26.2.sdk` headers on this host and
are quoted in `environment.json`, including the decisive sentence "Prompting
occurs asynchronously and does not affect the return value." A recursive search
of the installed AppKit and Foundation headers found **no** declared API or URI
for opening System Settings or the Accessibility pane. No undocumented platform
behavior was inferred.

## TDD

Red is recorded in `tests/red-phase.json` and was produced before any
implementation existed on disk: the test file was written first and the child
package failed to compile with 34 compiler errors, the distinct causes being
`cannot find type 'AccessibilityPermissionService' in scope`,
`cannot find 'AccessibilityPermissionService' in scope`, and
`cannot find 'AccessibilityTrustState' in scope`. Green is recorded in
`tests/results.json`: 11 tests in 12 executed cases, exit 0, zero failures, zero
compiler warnings.

One further test, `manualRealAPIProbeRunsOneReviewerSelectedAction`, was added
**after** green in response to a review finding, and is recorded as such in
`tests/red-phase.json`. It is a reviewer-driven Tier-H manual harness, not an
automated acceptance test. It asserts no new production behavior and changed no
production code, so no new red phase was manufactured; its fail-closed path was
instead demonstrated by execution, with an unknown action exiting 1. The child
package therefore now declares 12 tests: 11 run and pass by default, and the
probe is skipped unless `MACKVM_M1_035_MANUAL_PROBE` selects an action.

## Acceptance criteria mapping

| Issue criterion | Result |
| --- | --- |
| Every Focus item has locatable implementation, test, or sign-off evidence | Passed for check, request, open settings, no-crash-when-unauthorized, and state consumable by UI and injector. Check, request and open settings are `currentTrustState()`, `requestTrust()` and `openSystemSettings()`. Not-authorized is a returned state, covered by `untrustedProcessIsAValidStateMappedToTheFrozenPermissionFailure` and by the production-default smoke test. Consumability is the `package` access level plus the `Sendable` value types. |
| Happy path, boundary, invalid input, and error/cancel/cleanup tests all pass | Passed. Happy path: three tests. Boundary: the parameterized prompt test. Injected failure: three tests, including the privacy assertion. Idempotency and no-owned-resource: one test. Cancellation is explicitly not applicable and the reason is recorded in `tests/results.json` `cancellationCoverage` and in the component document. |
| Public behavior matches CONTRACT_CATALOG and frozen ADRs, with no new implicit API | Passed. No declaration is `public`. No contract in C-001 to C-015 is altered, and no new contract is introduced. |
| Architecture checker, lint, build, and unit tests pass with no new warning | Passed. The authoritative run is the reviewer's `make verify` against the committed tree at `9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3`: all 19 named gates passed, exit 0, started 2026-09-22T05:55:28.060+00:00 and ended 2026-09-22T05:56:03.868+00:00. The earlier pre-commit sweep, `make verify REPORT=artifacts/ci/m1-035-review-precommit.json`, also passed all 19 gates and is retained only as history. The exact child-package `swift test` passed with 12 total tests and the probe skipped by default, the exact `xcodebuild` workspace macOS build succeeded, and Repository Contracts passed 54 of 54. The author's own runs, which used `--disable-sandbox` equivalents because of a pre-existing environment restriction, are retained in `commands.json` as author observations only. |
| Production logs contain no typed text, clipboard payload, secret, private key, or recoverable content | Passed by construction, and confirmed against the captured real-machine output in `manual-output.log`. The service emits no log and no diagnostic event, and contains no input capture, injection, or event-tap path. No seam signature can carry a platform `Error`, message, or status code, so no platform error text can reach the boundary; `settingsFailuresRetainNoPlatformErrorContentOrPath` additionally proves an injected path-shaped URL never appears in an encoded failure. |
| Manual and real-machine evidence verified by a reviewer who is not the executing Agent | **Passed.** A reviewer who is not the executing author performed real-machine verification on 2026-09-22 UTC against this commit, executing all three Issue Scope actions — real `check`, real `request`, real open settings — through `AccessibilityPermissionService` production defaults on real macOS, with no seam substituted. The Issue requires neither visible prompt redisplay nor a same-process grant and revoke transition; both remain undemonstrated and are recorded as supplemental, non-blocking limitations rather than as failed criteria. The author performed no manual verification and claims none. See `manual.md`. |

## Tier-H manual probe

M1-035 intentionally adds no application wiring, and the service is
`package`-level, so the Tier-H manual steps previously named no executable entry
point that exists within Issue scope. The Exact Test File now contains one
opt-in probe, `manualRealAPIProbeRunsOneReviewerSelectedAction`, which drives
`AccessibilityPermissionService()` production defaults — the real macOS APIs,
with no mocked seam — inside the real SwiftPM test process.

- It is skipped unless `MACKVM_M1_035_MANUAL_PROBE` names one action, so no
  ordinary CI or local run can display OS UI.
- It accepts exactly `check`, `request` and `open-settings`, and fails on any
  other value rather than passing silently.
- It emits exactly one sanitized line per run, carrying only a closed enum case
  name or a closed `CoreError` taxonomy name. No path, URL, platform error
  string, typed text, clipboard payload, or private data can be emitted.
- One run performs exactly one action. No sleep, poll, retry, or app wiring.

The default skip is **not** an acceptance bypass. All 11 automated behavior
tests still run and still pass in the default run, the probe asserts nothing
those tests leave uncovered, and it carries no acceptance credit of its own. It
exists solely so the reviewer can drive the real macOS APIs on purpose and
observe whatever OS UI macOS displays. The `request` action asks macOS to
display the Accessibility prompt; macOS may suppress redisplay for an existing
TCC decision, and no prompt was observed for M1-035.

Exact commands are in `manual.md` and in `commands.json` `manualProbeCommands`.
The author ran the default suite (probe skipped, no UI), the `check` action
(prompt-free per the installed SDK), and one unknown-action case (exit 1). The
author did **not** run `request` or `open-settings` and observed no OS UI. The
reviewer executed all three actions on the real machine; the results, including
what they do not establish, are in `manual.md` and in `commands.json`
`manualProbeCommands.reviewerRuns`.

### Identity scope

The probe validates the production-default service in the real SwiftPM test
process. It does **not** validate the final application's signing identity.
macOS Accessibility authorization is identity-specific: TCC grants trust to a
particular requesting binary and code-signing identity, so a grant observed for
the test process does not transfer to a signed app bundle and vice versa.
Verifying Accessibility authorization for the final app bundle and signing
identity is a downstream integration concern for the Issue that wires this
service into the application shell, and this Issue does not claim it.

## Reviewer results

The coordinating Codex reviewer, a different executor from the Claude Opus 5
author, reported the following. The author ran none of them and transcribed the
values; where the reviewer reported no value, this package says so rather than
supplying one. Full detail is in `commands.json` `reviewerFinalResults`.

- `make verify` against the committed tree at
  `9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3` — **authoritative**. 19 of 19 named
  gates passed, each exiting 0, overall exit 0, started
  2026-09-22T05:55:28.060+00:00 and ended 2026-09-22T05:56:03.868+00:00, with
  `swift-package-test:MacPlatform` present exactly once. The two `Tools/verify`
  scripts are covered inside it, as the `swift-test-targets` and
  `native-arm64-build` gates. The `REPORT` argument named an ephemeral reviewer
  report outside the repository, basename
  `m1-035-review-head-unsandboxed.json`, which is not committed and is not part
  of this package.
- `make verify REPORT=artifacts/ci/m1-035-review-precommit.json` — **history
  only**. The same 19 named gates passed, but this sweep ran **before** the
  implementation commit existed, so it covered the staged change rather than the
  committed tree. It is superseded for authoritative committed-tree coverage by
  the run above, and is retained solely because it is a genuine reviewer
  observation of the staged change. `artifacts/` is Git-ignored, so the report
  itself is not committed.
- `swift test --package-path Packages/MacPlatform` — passed with **12 total
  tests**, the opt-in manual probe skipped by default.
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination
  'platform=macOS' build` — the workspace macOS build **succeeded**.
- `python3 -m unittest discover -s Tests/Contracts -p 'test_*.py'` — Repository
  Contracts passed **54 of 54**.
- `git diff --cached --check` and the relevant staged doc and verifier checks —
  passed. The reviewer did not enumerate the individual staged-check command
  forms, so none is reconstructed.

Every exact frozen form that the author environment had to record as blocked has
therefore since been reported as passing, including `make verify` against the
committed tree. No command coverage is outstanding. What remains is two
supplemental tier `H` observations that the Issue does not require.

### Real-machine probe results

- `check` under the root / ChatGPT responsible identity emitted
  `M1-035 manual probe: action=check outcome=trusted`. The real trusted branch of
  `AXIsProcessTrusted` was therefore observed through production defaults.
- `open-settings` exited 0 and emitted `systemSettingsApplication`, and the
  reviewer visually confirmed System Settings opened showing the Accessibility
  permissions list. This is **not** a deep link: the implementation opens the
  application only, and that pane was already selected.
- `request` under the Claude Code responsible identity emitted
  `M1-035 manual probe: action=request outcome=notTrusted`. The call asks macOS
  to display a prompt by submitting `kAXTrustedCheckOptionPrompt` as `true` and
  returns immediately either way; **no OS prompt was visibly observed**, and
  none is claimed. A pre-existing denied TCC entry plausibly suppressed
  redisplay; that is an inference, not an observation.
- With the System Settings Accessibility toggle named lowercase `claude`
  switched from off to on, after explicit owner authorization and Touch ID and
  with the UI visibly showing it on, a Claude Opus 5 launched `check` probe
  exited 0 and still emitted `outcome=notTrusted`. After the reviewer restored
  the toggle to off, a repeat exited 0 and again emitted `outcome=notTrusted`.
  **Grant and revoke success for the actual Swift test process was therefore not
  demonstrated**, because that UI row was not the probe process's effective TCC
  responsible identity. This is a tier `H` limitation and risk, not a
  product-code failure, and no trusted-transition test is claimed as passed.
- The same probe command **without** SwiftPM `--disable-sandbox` was attempted
  inside a Claude Code session and failed before any test ran, at manifest
  evaluation, with a `sandbox-exec` failure and exit 1. That is a nested sandbox
  environment limitation, not a product test failure; the exact form passed in
  the reviewer environment.

### Real-machine artifacts

Two artifacts carry the reviewer's runs, and both are sanitized by construction:

- `manual-output.log` — the five probe output lines in observed run order, and
  nothing else.
- `manual-result.json` — `schemaVersion` 1, issue `M1-035`, commit-stamped, with
  every field drawn from a closed vocabulary the file declares.
  `canonicalFocusVerdict` is `passed`; the prompt-not-observed and
  same-process-transition gaps are carried as `supplementalLimitations`.

No screenshot or video is stored, because none is necessary: it would add an
installed-application and system-settings inventory of the reviewer's machine
without strengthening the API result. The reviewer's visual observations are
recorded per run in `manual-result.json` instead. See `manual.md` "Artifacts".

## Contract and constraint compliance

- Swift native, public macOS SDK APIs only: `AXIsProcessTrusted`,
  `AXIsProcessTrustedWithOptions`, `kAXTrustedCheckOptionPrompt`,
  `NSWorkspace.urlForApplication(withBundleIdentifier:)` and
  `NSWorkspace.open(_:)`. No private API and no undocumented deep link.
- Untrusted is a state, not a crash and not automatically an error. Only
  `actionableFailure` converts it, and only for a caller that cannot proceed.
- The asynchronous prompt is honored: `requestTrust()` reports only the state at
  return, names the field `trustStateAtReturn`, and documents that the value is
  never evidence of a user answer. No sleep, poll, retry, or wait exists.
- Frozen M1-015 taxonomy only: `permission.accessibilityDenied` and
  `permission.capabilityUnavailable`. No string, no platform `Error` object, and
  no underlying diagnostic code crosses the boundary.
- No catch-all, no `do`/`catch` at all, no hard-coded success, no sleep, no
  retry loop, and no change to any security default.
- No Barrier, native protocol, transport, network, TLS, clipboard, capture, or
  injection behavior. `MacPlatform` imports no protocol module, and no OS key
  code or event type enters `KVMEvent` or any wire schema.
- No async, task, or owned resource was introduced, so none needed cancellation
  or cleanup machinery; idempotency is asserted instead.
- The seam lives inside the Exact File, so no automated run displays OS UI,
  while `AccessibilityPermissionService()` still calls the real macOS APIs.

## Known limitations

1. **No Accessibility pane deep link.** Only the System Settings application is
   opened. No installed SDK header or other verified public source declares a
   guaranteed pane-level URI, so none was invented. The returned destination
   value states exactly what was opened.
2. **The System Settings bundle identifier is not SDK-declared.**
   `com.apple.systempreferences` was read from the `CFBundleIdentifier` of the
   installed `/System/Applications/System Settings.app` on macOS 26.2. A future
   rename produces a typed `permission.capabilityUnavailable` failure, not a
   crash and not a silent no-op.
3. **`@preconcurrency import ApplicationServices` is required.** The SDK imports
   `kAXTrustedCheckOptionPrompt` as a mutable C global, which Swift 6 refuses to
   read from a nonisolated context. This was the narrowest mechanism that reads
   the SDK-declared constant instead of hard-coding its string value; three
   alternatives, including a `nonisolated(unsafe)` wrapper, were tested and
   rejected because they do not compile.
4. **Real-machine verification is complete for the Issue, with two supplemental
   gaps.** All three Issue Scope actions were executed on real macOS through
   production defaults: the actual System Settings window was observed opening,
   the real `request` path returned the documented immediate state, and the real
   `check` path was observed returning both `trusted` and `notTrusted` under
   different responsible identities. The prompt window was **not** visibly
   observed, and the grant and revoke transition was **not demonstrated**;
   neither is required by the Issue. See limitations 7 and 8 and `manual.md`.
5. **The `swift-package-test:MacPlatform` gate omits
   `-Xswiftc -warnings-as-errors`**, inherited from M1-PKG-002 so the gate stays
   byte-identical to the frozen Required Command. The new source is still
   compiled warnings-as-errors by the root `code-quality` gate; the new *test*
   file is not. Changing that is a follow-up decision, not a silent change here.
6. **Accessibility authorization is identity-specific.** TCC grants trust to a
   particular requesting binary and code-signing identity. The probe therefore
   proves the production-default service works in the real SwiftPM test process,
   not that the final signed app bundle is authorized. App-bundle and signing
   integration is a downstream integration concern, and this Issue must not be
   read as covering it.
7. **No grant or revoke transition was demonstrated for the probe process.**
   Switching the System Settings Accessibility toggle named lowercase `claude`
   on and then off left the probe's outcome at `notTrusted` in both states, so
   that UI row was not the probe process's effective TCC responsible identity.
   The consequence is evidential, not behavioral: the service's response to a
   real grant and a real revoke is still unverified on a real machine. Nothing
   observed indicates a defect in the product code, and nothing observed
   verifies the transition either. The canonical Issue does not require this
   transition, so it is **non-blocking** for M1-035, but it must be carried to
   the downstream app-shell and signing integration Issue.
8. **The real Accessibility prompt was never seen.** The `request` action
   returned the documented immediate state, but no prompt was visibly observed,
   most plausibly because of a pre-existing denied TCC entry for that
   responsible identity. That explanation is an inference and is recorded as
   one. The canonical Issue does not require prompt redisplay, so this is
   **non-blocking** for M1-035 and is likewise carried to the downstream
   app-shell and signing integration Issue.

## Remaining risks

- **Two supplemental tier `H` observations — non-blocking.** Grant and revoke
  against the probe process's effective TCC responsible identity, and the
  appearance of the real prompt, are unverified. The Issue's real-machine
  acceptance criterion is met without them, so they do not block M1-035. They
  must, however, be carried to the downstream Issue that wires this service into
  the application shell, which should not treat the transition behavior or the
  prompt display as evidenced here. The outstanding items are enumerated at the
  end of `manual.md`.
- **Author-environment gate coverage — resolved.** Six exact command forms could
  not run in the author environment, and each was proven to fail identically on
  a pristine export of the unmodified base commit. The reviewer has since
  reported every one of them as passing, including `make verify` at 19 of 19
  gates against the committed tree at `9c53be7d`, so `commands.json`
  `reviewerPendingSummary.exactCommandsToRerun` is now empty and no residual
  gate-coverage gap remains.
- **Uncaptured real-machine metadata.** Display resolution and layout, and the
  physical keyboard layout, remain uncaptured. The reviewer's read-only queries
  reported the built-in Apple M4 Pro display and GPU path with Metal support but
  no resolution or layout, and reported selected input sources (Traditional
  Chinese Zhuyin and PressAndHold) rather than a physical layout; neither value
  is reconstructed or inferred. They affect no automated result, because the
  automated suite substitutes the dependency seam, but they remain a gap in the
  tier `H` record. The machine itself is recorded in `environment.json` as a
  MacBook Pro, `Mac16,7`, Apple M4 Pro, 24 GB; unique device identifiers from
  that raw output were deliberately excluded from evidence.
- **Bundle-identifier durability.** Limitation 2 above is a genuine forward
  compatibility risk, mitigated to a typed failure rather than eliminated.
- **`@preconcurrency` breadth.** The attribute suppresses strict-concurrency
  diagnostics for the whole `ApplicationServices` import, not only for the one
  constant. The module is used for exactly two functions and one constant in
  this file, which bounds the exposure, but it is wider than ideal.

## Follow-up candidates

None is required for this Issue to be complete. Two are offered for the Product
Owner, neither to be actioned here: a decision on whether child-package test
sources should also compile warnings-as-errors (limitation 5), and a documented
policy for verifying Apple bundle identifiers across macOS releases
(limitation 2).

## Rollback

Revert the M1-035 pull request. That removes the service, its tests, and the
component document in one operation and restores `MacPlatform` to its previous
boundary-only state. No runtime resource, persisted state, permission grant, or
migration requires cleanup, because the service stores nothing and changes no
system state beyond asking macOS to prompt or to open System Settings. Rollback
is mandatory if any of the Issue's rollback conditions appears: a new crash,
stuck input, local input suppression, silent trust bypass, data leak, or
compatibility regression; tests passing only after relaxed assertions, skipped
cases, or sleeps; or divergence from a frozen contract.
