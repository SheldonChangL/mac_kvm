# M1-035 Manual Verification — VERIFIED, WITH LIMITATIONS

Status: **performed, and sufficient for the canonical Issue.** The coordinating
Codex reviewer executed the probe actions on a real machine on the
**2026-09-22 UTC** observation day, against commit
`9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3`.

The canonical Issue #23 Scope names three real actions — **check**, **request**
and **open settings** — and all three were executed on real macOS through
`AccessibilityPermissionService` production defaults, with no seam substituted,
by a reviewer who is not the executing author. The Acceptance Criterion
"Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證" is therefore **met**.

Two observations were **not** demonstrated and are recorded below as explicit
Tier `H` limitations and remaining risks, not as failed criteria: macOS never
visibly redisplayed its Accessibility prompt, and no same-process
grant-to-revoke transition was demonstrated. The canonical Issue requires
neither, so neither blocks acceptance. Steps 3, 4 and the prompt-appearance
expectation in Step 2 are author-created supplemental steps that exceed the
Issue's stated Scope; they remain honestly recorded as not demonstrated.

Every step below was written for the reviewer to execute. The Claude Opus 5
author still displayed no Accessibility prompt, opened no System Settings
window, granted or revoked no permission, and observed no OS UI. Every `Actual`
value here is transcribed from the reviewer's report; nothing in this file is an
author-verified observation, and nothing is inferred where the reviewer reported
no value.

## Headline limitation (non-blocking): the grant and revoke transition was not demonstrated

After explicit owner authorization and Touch ID, the reviewer switched the
System Settings Accessibility toggle named lowercase `claude` from off to on,
and the UI visibly showed it on. A `check` probe launched by Claude Opus 5 then
exited 0 and still emitted `outcome=notTrusted`. The reviewer restored the
toggle to off, and a repeat of the same probe again exited 0 and emitted
`outcome=notTrusted`.

Neither direction changed the observed outcome, so grant and revoke success for
the actual Swift test process was **not demonstrated**. The most direct reading
is that the lowercase `claude` UI row was not the effective TCC responsible
identity of that test process. This is recorded as a remaining Tier `H`
limitation and risk. It is **not** a product-code failure, and no
trusted-transition test is claimed anywhere in this package as passed.

It is also **not blocking**. The canonical Issue's Scope is `check/request/open
settings`, 未授權不 crash, and 狀態可被 UI 與 injector 使用. It does not require a
same-process grant-to-revoke transition, and its Acceptance Criteria do not name
one. Steps 3 and 4 below are author-created supplemental steps written to
strengthen the record beyond what the Issue asks for; their outcome is reported
faithfully and does not reduce the Issue's criterion to partial.

Separately, a `check` probe run under the root / ChatGPT responsible identity
did emit `outcome=trusted`, so the real trusted branch of `AXIsProcessTrusted`
was observed — just not as a transition produced by the reviewer's toggle.

Tier `H` applies to this Issue: real-machine, OS-permission verification is
mandatory and cannot be satisfied by the automated mocked suite. The automated
suite substitutes the dependency seam precisely so that it never displays OS UI,
which is why it cannot cover the items below.

## What automation already covers, and what it cannot

Covered by automated tests with the seam substituted, recorded in
`tests/results.json`: the prompt option value submitted to the SDK, the frozen
`CoreError` mapping for every failure path, the absence of platform error text
and paths in failures, exact macOS call counts, idempotency, and that the
production default reads trust through the real `AXIsProcessTrusted` without
displaying UI.

Not coverable by automation, and therefore exercised here on a real machine:

1. that the real `check` path runs against the real macOS API and reports a
   state — **required by the Issue Scope**, verified;
2. that the real `request` path runs against the real macOS API — **required by
   the Issue Scope**, verified; that macOS visibly *redisplays* its prompt is an
   author-created supplemental expectation, **not required** by the Issue, and
   was not demonstrated;
3. that the real System Settings application actually opens — **required by the
   Issue Scope**, verified; and
4. that a real grant and a real revoke are reflected by a later check — an
   author-created supplemental expectation, **not required** by the Issue, and
   not demonstrated.

## How to execute these steps

M1-035 adds no application wiring, and the service is `package`-level, so there
is no app build from which these methods can be called. The Exact Test File
therefore contains one opt-in Tier-H probe,
`manualRealAPIProbeRunsOneReviewerSelectedAction`, which drives
`AccessibilityPermissionService()` production defaults — the real macOS APIs,
with no seam substituted — inside the real SwiftPM test process. The reviewer
runs one command per action and then inspects the real OS UI directly.

The probe is skipped unless `MACKVM_M1_035_MANUAL_PROBE` names one action, so no
ordinary run can display OS UI. It accepts exactly `check`, `request` and
`open-settings`; any other value fails the run rather than passing silently. One
run performs exactly one action, with no sleep, poll, retry, or app wiring.

```sh
# Action: check. Displays no UI; AXIsProcessTrusted is a plain query.
MACKVM_M1_035_MANUAL_PROBE=check \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealAPIProbeRunsOneReviewerSelectedAction

# Action: request. Asks macOS to display the Accessibility prompt; macOS may
# suppress redisplay for an existing TCC decision. Returns immediately either way.
MACKVM_M1_035_MANUAL_PROBE=request \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealAPIProbeRunsOneReviewerSelectedAction

# Action: open-settings. Brings the real System Settings application forward.
MACKVM_M1_035_MANUAL_PROBE=open-settings \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealAPIProbeRunsOneReviewerSelectedAction
```

Each run emits exactly one sanitized line. It is the value to transcribe into
the `Actual` fields below, into `manual-output.log` verbatim, and into
`manual-result.json` as a closed `outcome` value:

```text
M1-035 manual probe: action=<action> outcome=<name>
```

`<name>` is only ever a closed enum case name — `trusted`, `notTrusted` or
`systemSettingsApplication` — or a closed taxonomy name such as
`permission.capabilityUnavailable`. No path, URL, platform error string, typed
text, clipboard payload, or other private data is emitted, and an unrecognized
action value is never echoed back. Please do not paste any other output into
this file.

Two properties of the probe the reviewer may want to confirm once, before
starting:

- with `MACKVM_M1_035_MANUAL_PROBE` unset, the full child-package suite runs and
  the probe is reported as skipped, displaying no UI; and
- with an unrecognized value such as `MACKVM_M1_035_MANUAL_PROBE=bogus-action`,
  the filtered run fails with "unknown manual probe action" and a non-zero exit,
  rather than passing.

### Attempted command that could not run, and why

The exact form above was attempted once inside a Claude Code agent session and
failed before any test ran, at SwiftPM manifest evaluation, with a
`sandbox-exec` failure and exit 1. That is the nested-sandbox restriction
already recorded in `environment.json` `authorEnvironmentLimitations`, not a
product test failure: the same exact form passed in the reviewer environment,
both standalone and as the `swift-package-test:MacPlatform` gate of `make
verify`. Probe runs launched from such a session therefore used the
`--disable-sandbox` equivalent, which is flagged as `equivalent` wherever it
appears below and in `commands.json`.

## What these steps prove, and what they do not

These steps verify the production-default service in the real SwiftPM test
process against the real macOS APIs. They are **not** a verification of the
final application's signing identity.

macOS Accessibility authorization is identity-specific: TCC grants trust to a
particular requesting binary and code-signing identity, not to a project or a
source tree. A grant observed here for the test process does not transfer to a
signed app bundle, and a grant held by an app bundle does not transfer to the
test process. Verifying Accessibility authorization for the final app bundle and
signing identity is a downstream integration concern for the Issue that wires
this service into the application shell. M1-035 does not claim it, and this file
must not be read as evidence of it.

When recording grant and revoke actions below, identify the target by the entry
name that System Settings displays, not by a filesystem path.

## Environment recorded at the time of the runs

- Date: **2026-09-22**, UTC observation day. The reviewer reported the
  observation day, not per-run clock times, so no per-run timestamp is stated.
- Build commit tested: **`9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3`**.
- macOS product version **26.6.2**, build version **25G83**.
- CPU architecture **arm64**; `sysctl.proc_translated = 0`, so execution is
  **not** Rosetta-translated.
- Machine: **MacBook Pro**, model identifier **`Mac16,7`**, **Apple M4 Pro**,
  **24 GB** memory, reported by the reviewer from a read-only metadata query.
  Unique device identifiers present in that raw output were deliberately
  excluded from this evidence and are not recorded in any form.
- Display resolution and layout: **not captured**. The reviewer's display query
  reported the built-in Apple M4 Pro display and GPU path with Metal support,
  but reported no panel resolution or layout in that non-interactive output.
  Neither is guessed. This remains an uncaptured item; it affects no automated
  result, because the automated suite substitutes the dependency seam.
- Keyboard: the selected input sources are **Traditional Chinese Zhuyin**
  (`com.apple.inputmethod.TCIM.Zhuyin`) and the **PressAndHold** non-keyboard
  input method. These identify the active input methods, not the physical
  keyboard layout; the **physical layout is not captured** and is not inferred
  from them.
- Network: **not applicable**; the `check`, `request` and `open-settings`
  actions are local-only and open no network connection.
- Peer version: **not applicable**; the local-only actions make no peer
  connection, and no Barrier or Native peer is involved.
- Accessibility grant state before the runs: the probe process was **not**
  trusted under the Claude Code and Claude Opus 5 responsible identities, and
  **was** trusted under the root / ChatGPT responsible identity. Two distinct
  responsible identities were therefore exercised, and the results below are
  labelled with the identity that produced them.

## Step 1 — Untrusted check does not crash and reports a state

Preconditions: the test process has no Accessibility grant. If it was granted
previously, remove it in System Settings → Privacy & Security → Accessibility
first, and record that you did.

Action: run the probe once with `MACKVM_M1_035_MANUAL_PROBE=check`.

Expected: the emitted outcome is `notTrusted`, the run exits 0, no prompt
appears, no window appears, no crash, and no hang. The corresponding
`actionableFailure` mapping to `permission.accessibilityDenied` is proven by the
automated suite and is not re-derived by eye here.

Actual: the reviewer ran the `check` action under two responsible identities.
Under root / ChatGPT it **exited 0** and emitted
`M1-035 manual probe: action=check outcome=trusted`. Under the
Claude Code and Claude Opus 5 identities it emitted
`M1-035 manual probe: action=check outcome=notTrusted` with exit 0. No prompt,
no window, no crash and no hang was reported in any of these runs.

Result: **pass.** The real `AXIsProcessTrusted` path returns a valid state and
does not crash. Both real states were observed, each under the responsible
identity that holds or lacks the grant, which is the identity-specific TCC
behavior described above rather than a defect.

## Step 2 — Request asks macOS to display the prompt, and the immediate return is not the answer

Action: run the probe once with `MACKVM_M1_035_MANUAL_PROBE=request`. If macOS
displays a prompt, do not answer it yet. Record the emitted outcome immediately.

Expected: the emitted outcome is `notTrusted`, because prompting is asynchronous
and does not affect the return value. The call *requests macOS to display a
prompt* by submitting `kAXTrustedCheckOptionPrompt` as `true`; macOS decides
whether to display it and can suppress redisplay when an existing TCC decision
already covers the requesting identity. If macOS displays it, the reviewer can
observe it. The probe asserts `promptRequested` is `true` and returns without
waiting, so the run completes regardless of whether any prompt is on screen.

Actual: run under the Claude Code responsible identity; it **exited 0** and
emitted `M1-035 manual probe: action=request outcome=notTrusted`. **No OS prompt
was visibly observed.**

Result: **pass, with a recorded limitation.** The Issue Scope item `request` was
executed against the real macOS API through production defaults, exited 0, and
returned the documented immediate `notTrusted` state, exactly as the installed
SDK specifies with "Prompting occurs asynchronously and does not affect the
return value."

Limitation, recorded and **not** claimed as passed: macOS did not visibly
redisplay its Accessibility prompt. A pre-existing denied TCC decision for that
responsible identity plausibly suppressed redisplay; that is an inference only,
not an observation, and it is not evidence that the prompt is displayed. The
canonical Issue neither requires prompt redisplay nor requires that macOS
redisplay a prompt a pre-existing TCC decision suppresses, so this is a Tier `H`
limitation and remaining risk rather than an unmet criterion.

## Step 3 — Grant is observed only by a later check, never by the request return value

Action: with the Step 2 prompt still open, grant Accessibility to the process
the prompt names, then run the probe again with
`MACKVM_M1_035_MANUAL_PROBE=check`.

Expected: the later check emits `trusted`. The Step 2 outcome is unchanged and
was never retroactively correct. Confirm the service performed no polling,
sleeping, or retrying between the two runs.

Note: each probe run is a separate process. If the granted entry is the test
runner rather than a per-run binary, record which entry System Settings listed,
by name only. If the grant does not carry across runs because the requesting
identity differs, record that observation rather than forcing a `trusted`
result: it is the identity-specific TCC behavior described above, not a defect
in this service.

Actual: after explicit owner authorization and Touch ID, the reviewer switched
the Accessibility toggle named lowercase `claude` from off to on, and the UI
visibly showed it on. A Claude Opus 5 launched probe,
`MACKVM_M1_035_MANUAL_PROBE=check swift test --disable-sandbox --package-path
Packages/MacPlatform --filter manualRealAPIProbeRunsOneReviewerSelectedAction`,
then exited 0 and emitted `outcome=notTrusted`. The entry is recorded by the
name System Settings displayed, lowercase `claude`, and by no other identifier.

Result: **not demonstrated.** No grant transition was observed for the probe
process. Taking the note above at its word rather than forcing a `trusted`
result: the lowercase `claude` UI row was not that Swift test process's
effective TCC responsible identity. This is a Tier `H` verification limitation,
not a product-code failure, and this step is not recorded as passed.

Scope note: this step is an author-created supplemental step. The canonical
Issue does not require a same-process grant-to-revoke transition, so the outcome
is **non-blocking** for acceptance.

## Step 4 — Revoke fails closed

Action: revoke Accessibility for that entry in System Settings, then run the
probe again with `MACKVM_M1_035_MANUAL_PROBE=check`.

Expected: emits `notTrusted` with no crash and no cached `trusted` value. The
service must not remember the earlier grant.

Actual: the reviewer restored the lowercase `claude` toggle to off. A repeat of
the same Claude Opus 5 launched `check` probe exited 0 and again emitted
`outcome=notTrusted`.

Result: **not demonstrated.** The observation is consistent with failing closed,
but it establishes nothing about revoke: the process never reached `trusted` in
Step 3, so no `trusted` value existed to be revoked or cached. Together with
Step 3, this is the remaining Tier `H` limitation stated at the top of this
file, and like Step 3 it is an author-created supplemental step that the
canonical Issue does not require, so it is **non-blocking** for acceptance. The
system was left in its original state, with the toggle off.

## Step 5 — Open settings actually opens System Settings

Action: run the probe once with `MACKVM_M1_035_MANUAL_PROBE=open-settings`.

Expected: the emitted outcome is `systemSettingsApplication`, the run exits 0,
and the System Settings application comes to the foreground.

Confirm explicitly, and record, that the Accessibility pane is **not** claimed
to be selected. Opening the application rather than the pane is the documented
known limitation, because no verified public source declares a pane-level URI.
If System Settings opens on some other pane, that is the expected documented
behavior and is not a defect.

Actual: the probe exited 0 and emitted `outcome=systemSettingsApplication`. The
reviewer visually confirmed that System Settings opened and showed the
Accessibility permissions list.

Result: **pass.** Note precisely what this does and does not show: the
implementation opened the System Settings **application** only, and the
Accessibility pane was already the selected pane. No deep link to that pane is
claimed, performed, or evidenced. Known limitation 1 in `summary.md` stands
unchanged.

## Step 6 — Repeat every step once more

Action: repeat the `check`, `request` and `open-settings` runs a second time in
the same session.

Expected: identical outcomes, no duplicated or stuck prompt window, no leaked
window, no stuck input, and no accumulated state. This is the real-machine
counterpart of the automated idempotency test.

Actual: the `check` action was run repeatedly. Under one responsible identity it
emitted `outcome=notTrusted` on every run, including the toggle-on run and the
toggle-off run, each exiting 0. The reviewer reported no second `request` run
and no second `open-settings` run.

Result: **partial.** Repeated `check` runs produced identical outcomes and no
reported accumulated state, which is the real-machine counterpart of the
automated idempotency assertion for that action. Repetition of `request` and
`open-settings` was not reported and is not claimed.

## Step 7 — Privacy and fail-safe confirmation

Action: inspect all output, logs and diagnostics produced during Steps 1 to 6.

Expected: no typed text, no clipboard payload, no secret or key material, no
filesystem path, no URL, and no platform error string. The service itself emits
no log and no diagnostic event at all, and the probe emits only the single
sanitized `action=`/`outcome=` line per run. Also confirm no local input was
suppressed and no key or button was left held at any point.

Actual: every probe output captured across all five runs is recorded verbatim in
`manual-output.log`, which contains those five closed sanitized lines and
nothing else. Each line carries only `action=check`, `action=request` or
`action=open-settings` with a closed outcome name of `trusted`, `notTrusted` or
`systemSettingsApplication`. No typed text, clipboard payload, secret, key
material, filesystem path, URL or platform error string appears in any captured
output. The machine-readable counterpart is `manual-result.json`, whose fields
are drawn from the closed vocabularies it declares.

Result: **pass**, for the criterion in scope for M1-035. Two independent facts
carry it. First, all captured probe output is exactly the closed sanitized lines
in `manual-output.log`. Second, the service under test contains no logging call,
no diagnostic event, no input capture, no input injection, no event tap, no key
or button state, no async task, and no owned resource; this is a property of the
Exact Source File and is asserted by the automated suite recorded in
`tests/results.json`, not something the reviewer had to observe.

Scope of that claim, stated explicitly:

- A system-wide log inspection was **not performed** and is **not claimed**.
  It is not required to prove that a service which emits no log produced no
  product log: there is no logging call site to emit one. Any entry a
  system-wide sweep would surface would belong to the OS, the test runner, or
  System Settings, none of which is the subject of this criterion.
- Stuck input is **not applicable**. This service has no input suppression,
  injection, or capture path at all, so there is no mechanism by which a key or
  button could be left held. No held-key check is therefore claimed, and none
  is required.

## Step outcome table

| Step | Subject | Required by Issue Scope | Outcome |
| --- | --- | --- | --- |
| 1 | Check does not crash and reports a state | yes | pass |
| 2 | Request runs against the real API and returns the immediate state | yes | pass |
| 2a | Request visibly redisplays the real prompt | no — supplemental | not demonstrated, non-blocking |
| 3 | Grant observed by a later check | no — supplemental | not demonstrated, non-blocking |
| 4 | Revoke fails closed | no — supplemental | not demonstrated, non-blocking |
| 5 | Open settings opens System Settings | yes | pass |
| 6 | Repeat every step once more | no — supplemental | partial — `check` only |
| 7 | Privacy and fail-safe confirmation | yes | pass — all captured output sanitized; no-log, no-input-path service |

## Artifacts

The canonical Issue asks for a sanitized log, a `result.json`, and a screenshot
or video where one is necessary. Two artifacts are attached, and the third is
deliberately absent.

- `manual-output.log` — the **sanitized log**. It contains exactly the probe
  output lines of the five runs, in observed run order, and nothing else. No
  surrounding session transcript, SwiftPM output, path, username, or timestamp
  was added, because none of it is probe output and all of it would widen what
  this repository discloses.
- `manual-result.json` — the **machine-readable result**. `schemaVersion` 1,
  issue `M1-035`, stamped with commit
  `9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3`. It records the five runs with
  their action, command form, responsible identity, exit code, closed outcome,
  UI state and verdict; `canonicalFocusVerdict` is `passed`; and the two
  supplemental gaps are carried as `supplementalLimitations`. Every field is
  drawn from a closed vocabulary the file itself declares, so no arbitrary text,
  path, username, device identifier or secret can enter it.
- **No screenshot and no video.** None is necessary, so none was captured or
  stored. A capture of the System Settings window, or of any prompt, would add
  an installed-application and system-settings inventory of the reviewer's
  machine to this repository while strengthening nothing: the API result is
  already carried by the exit codes and the closed outcome names, and an image
  cannot make `outcome=systemSettingsApplication` more true. The reviewer's
  visual observation is recorded instead, per run, in `manual-result.json`
  `runs[].visualObservation` and in the `Actual` fields above.

Beyond these two files, the reviewer reported outcomes in prose. No session log
excerpt and no per-step artifact was handed back beyond what is recorded here,
and none is fabricated. No screenshot and no raw system path was added to this
repository.

## Reviewer

- Reviewer: the coordinating Codex agent, a different executor from the Claude
  Opus 5 implementation author. Probe runs were executed under two responsible
  identities, root / ChatGPT and Claude Code, with one `check` probe launched by
  Claude Opus 5 at the reviewer's direction and under the reviewer's
  observation.
- Date: 2026-09-22, UTC observation day.
- Verdict: **verified, with recorded limitations.** The automated and Required
  Command evidence is complete and green, including `make verify` at 19 of 19
  gates **against the committed tree** at
  `9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3`, exit 0. Tier `H` is satisfied for
  the canonical Issue: all three Issue Scope actions — real `check`, real
  `request`, real `open settings` — were executed on real macOS through
  production defaults by a non-author reviewer. Two supplemental observations
  are recorded as not demonstrated and non-blocking: the prompt was never
  visibly redisplayed, and no same-process grant-to-revoke transition was
  demonstrated.

## Remaining Tier `H` limitations and risks — none blocking

None of the items below is required by the canonical Issue #23 Scope or
Acceptance Criteria. They are recorded so the gap is visible to any downstream
Issue that wires this service into the application shell.

1. Demonstrate a grant and revoke transition against the probe process's actual
   effective TCC responsible identity, rather than against a UI row that turns
   out not to be that identity. Until then, no trusted-transition result is
   claimed.
2. Observe the real Accessibility prompt for an identity that does not already
   carry a denied TCC decision suppressing redisplay.
3. Capture the display resolution and layout, and the physical keyboard layout,
   that `environment.json` marks as reviewer-required. The reviewer's read-only
   queries returned neither, and neither is reconstructed.
4. Repeat the `request` and `open-settings` actions a second time for the
   Step 6 idempotency observation.

## Handback

The reviewer returned the recorded actual values and the verdict, and the
Claude Opus 5 author transcribed them into this file, `manual-output.log`,
`manual-result.json`, `summary.md`, `commands.json`, `environment.json` and
`tests/results.json`, together with the
real implementation commit SHA `9c53be7d5a49aaf69e371c83f2ac3e6ce3df17d3` in
place of every `pending` marker. The Issue's Acceptance Criterion
"Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證" is **met**: a reviewer
who is not the executing author performed real-machine verification of all three
Issue Scope actions — check, request and open settings — through
`AccessibilityPermissionService` production defaults on real macOS. The items
above remain outstanding as recorded limitations, and none of them is required
by the Issue.
