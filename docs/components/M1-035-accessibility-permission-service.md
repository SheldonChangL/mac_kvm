# M1-035 macOS Accessibility Permission Service

## Outcome

`MacPlatform` provides one Swift-native Accessibility permission service that
checks trust, requests trust, and opens System Settings. Untrusted is a valid
reported state rather than a crash or an automatic failure, and every actionable
failure crosses the boundary as a frozen M1-015 `CoreError` from the permission
domain.

No public contract is added. Every declaration is `package` or narrower, so the
frozen `CONTRACT_CATALOG` public surface is unchanged. The service is available
to the application shell and to a future injector inside the package, and is not
exported as cross-module public API.

## Behavior

### Check

`currentTrustState()` calls `AXIsProcessTrusted()` and returns
`AccessibilityTrustState.trusted` or `.notTrusted`. The installed SDK documents
this function as a plain query, so no prompt and no window is displayed. The
call never throws and never produces a failure value: "not granted yet" is a
state, not an error of the read.

A caller that must refuse to inject input converts the state through
`AccessibilityTrustState.actionableFailure`, which is `nil` while trusted and
otherwise the frozen `permission.accessibilityDenied` `CoreError` with
`userActionRequired` retry and `notRequired` cleanup. Automatic retry is refused
because only explicit user action can change Accessibility trust.

### Request

`requestTrust()` calls `AXIsProcessTrustedWithOptions` and always submits
`kAXTrustedCheckOptionPrompt` as `true`. The installed macOS 26.2 SDK states
that "Prompting occurs asynchronously and does not affect the return value", so
the returned `AccessibilityTrustRequestResult` reports only
`trustStateAtReturn`, the state observed at the instant the SDK call returned.

`trustStateAtReturn == .notTrusted` therefore means "not trusted at return". It
is never evidence that a prompt appeared, that the user saw it, or that the user
refused it. The service does not sleep, poll, retry, or wait for an answer. A
caller that needs the post-grant state calls `currentTrustState()` again after
observing its own state change.

### Open settings

`openSystemSettings()` resolves the System Settings application with
`NSWorkspace.urlForApplication(withBundleIdentifier:)` and opens it with
`NSWorkspace.open(_:)`. Both are documented public AppKit API, and both report
absence or failure without producing a platform error object.

Success returns `AccessibilitySettingsDestination.systemSettingsApplication`.
The resolved application URL never crosses the boundary, so no filesystem path
reaches a caller.

Failure mapping, both in the frozen permission domain:

- the identifier resolves to no application → `permission.capabilityUnavailable`
  with `never` retry, because no user action completes the request here; and
- the system refuses the open request → `permission.capabilityUnavailable` with
  `userActionRequired` retry, because retry is possible but never automatic.

## Known limitation: no Accessibility pane deep link

The exact Accessibility pane is deliberately not targeted. No installed SDK
header and no other verified public source declares a URI that is guaranteed to
open that pane, so no pane-level URI contract is invented. `openSystemSettings`
opens the System Settings application and the `AccessibilitySettingsDestination`
value states exactly that, rather than implying pane-level navigation.

The System Settings bundle identifier `com.apple.systempreferences` is read from
the `CFBundleIdentifier` of the installed `/System/Applications/System
Settings.app` on macOS 26.2. It is not SDK-declared, so an identifier that does
not resolve fails closed as `permission.capabilityUnavailable` instead of being
assumed present. A future macOS release that renames the application therefore
produces a typed failure, not a crash and not a silent no-op.

## Dependency seam and determinism

`AccessibilityPermissionEnvironment` is an internal struct of four `@Sendable`
closures covering exactly the four macOS calls the service makes. Its `live`
value is the production default used by `AccessibilityPermissionService()` and
calls the real macOS APIs. Tests substitute closures, so an automated run never
displays an Accessibility prompt or a System Settings window.

No seam signature can carry a platform `Error`, localized message, or status
code: the closures return `Bool` and `URL?` only. Arbitrary platform error text
therefore cannot reach the typed boundary by construction, and the emitted
`CoreError` values carry no underlying diagnostic code.

## Resource ownership, cancellation, and cleanup

The service is an immutable `Sendable` struct. It owns no task, timer, queue,
observer, notification registration, file handle, or mutable state, and each
operation is one synchronous macOS call whose result is derived only from that
call.

Cancellation is therefore not applicable to this Issue: there is no asynchronous
operation, no in-flight work, and no cancellation or teardown entry point to
expose. Nothing is allocated that requires release, so there is no cleanup path
either. The equivalent obligation is met by idempotency: repeating any operation
delegates to the seam again and produces a result that depends only on that
call, with no state accumulated between calls.

## Privacy and logging

The service emits no log and no diagnostic event. No typed text, clipboard
payload, secret, key material, filesystem path, URL, or platform error string is
recorded, returned, or retained. The only values that cross the boundary are
closed enum cases and frozen `CoreError` taxonomy fields.

## Validation coverage

Automated tests with the seam substituted verify:

- a trusted process reports `trusted` with no prompt submitted and no
  actionable failure;
- an untrusted process reports `notTrusted` as a state, with no prompt
  submitted, and maps to exactly the frozen `permission.accessibilityDenied`
  code, severity, retry, and cleanup values with no underlying code;
- a request submits `prompt` as `true` and reports only the immediate state,
  performing no additional trust read, poll, sleep, or retry;
- a request submits `prompt` as `true` for both immediate trust outcomes;
- a successful open reports the application destination and performs exactly one
  resolve and one open;
- an unresolvable application fails closed with `never` retry and opens nothing;
- a refused open request fails with `userActionRequired` retry;
- both settings failures encode to exactly the four closed `CoreError` keys and
  contain no application name, filesystem path, or URL scheme;
- repeating check, request, and open is idempotent, delegates once per call, and
  leaves nothing to clean up; and
- the production default reads trust through the real SDK without displaying UI.

One further test is declared but **skipped by default**: the Tier-H manual
probe described in the next section. Skipping it is not an acceptance bypass.
Every behavior test listed above runs and passes in an ordinary run, and the
probe asserts no behavior that those tests leave uncovered; it exists only so a
reviewer can trigger real OS UI on purpose.

The prompt window, the user grant and refusal paths, and the actual System
Settings window are OS UI and cannot be asserted by an automated run. They are
recorded as reviewer-performed real-machine verification in
`evidence/issues/M1-035/manual.md`, and the probe below is the executable entry
point the reviewer uses to trigger them.

## Tier-H manual probe

M1-035 deliberately adds no application wiring, so there is no app build from
which a reviewer could call these `package`-level methods. The test
`manualRealAPIProbeRunsOneReviewerSelectedAction`, in the Exact Test File,
closes that gap: it drives `AccessibilityPermissionService()` production
defaults — the real macOS APIs, with no seam substituted — inside the real
SwiftPM test process, so the reviewer can observe the actual prompt and the
actual System Settings window.

The probe is skipped unless the environment variable
`MACKVM_M1_035_MANUAL_PROBE` names one action, so an ordinary CI run or local
run can never display OS UI. It accepts exactly `check`, `request` and
`open-settings`; any other value fails the run instead of passing silently. One
run performs exactly one action, and there is no sleep, poll, retry, or app
wiring anywhere in it.

```sh
# Check trust. Displays no UI: AXIsProcessTrusted is a plain query.
MACKVM_M1_035_MANUAL_PROBE=check \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealAPIProbeRunsOneReviewerSelectedAction

# Request trust. Displays the real Accessibility prompt.
MACKVM_M1_035_MANUAL_PROBE=request \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealAPIProbeRunsOneReviewerSelectedAction

# Open settings. Brings the real System Settings application forward.
MACKVM_M1_035_MANUAL_PROBE=open-settings \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealAPIProbeRunsOneReviewerSelectedAction
```

Each run emits exactly one sanitized line:

```text
M1-035 manual probe: action=<action> outcome=<name>
```

`<name>` is only ever a closed enum case name — `trusted`, `notTrusted` or
`systemSettingsApplication` — or, for a typed failure, a closed taxonomy name
such as `permission.capabilityUnavailable`. No filesystem path, URL, platform
error string, typed text, clipboard payload, or other private data is emitted,
and an unrecognized action value is never echoed back.

### What the probe proves, and what it does not

The probe validates the production-default service running in the real SwiftPM
test process against the real macOS APIs. It says nothing about the final
application's signing identity.

macOS Accessibility authorization is identity-specific: TCC grants trust to a
particular requesting binary and code-signing identity, not to a project. A
grant observed for the test process therefore does not transfer to a signed app
bundle, and a grant held by an app bundle does not transfer to the test process.
Verifying Accessibility authorization for the final app bundle and signing
identity is a downstream integration concern for the Issue that wires this
service into the application shell. M1-035 must not, and does not, claim it.

## Architecture and scope boundaries

No Barrier, native protocol, transport, socket, network, TLS, clipboard, input
capture, or input injection behavior is introduced. No OS key code or event type
is added to `KVMEvent` or to any wire schema. `MacPlatform` imports no protocol
module. Security defaults are unchanged, and no permission decision is cached,
weakened, or bypassed.

## Rollback

Revert the M1-035 pull request. That removes the service, its tests, and this
document in one operation, and leaves the `MacPlatform` module at its previous
boundary-only state. No runtime resource, persisted data, permission grant, or
migration requires cleanup, because the service stores nothing and changes no
system state except asking macOS to prompt or to open System Settings.
