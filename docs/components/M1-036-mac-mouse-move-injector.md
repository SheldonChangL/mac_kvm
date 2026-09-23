# M1-036 macOS Mouse Move Injector

## Outcome

`MacPlatform` provides one Swift-native mouse-move injector. Its input boundary
is domain-only: it accepts `KVMEvent`, the single Core event language, refuses
every other case with a frozen M1-015 `CoreError`, checks Accessibility trust
before doing any event work, resolves a platform position through an injected
resolver, creates a mouse-move `CGEvent` with documented public CoreGraphics
API, and posts it at the HID event tap.

No public contract is added. Every declaration is `package` or narrower, so the
frozen `CONTRACT_CATALOG` public surface is unchanged. No `CGEvent`, `CGPoint`,
or `CGEventTapLocation` appears in any `package` or `public` declaration, so
C-015 holds: platform injection input and output use KVM contracts only, and
nothing platform-specific reaches `KVMEvent` or any wire schema.

## Coordinate ownership belongs to M1-039

This component computes no coordinate. M1-039 owns logical, backing and wire
coordinate separation, normalization into `0...1`, clamping, and multi-display
and Retina behavior. M1-036 must not implement or guess any of it.

The seam that enforces that split is `MacPlatformPositionResolver`, an
`internal` struct holding one `@Sendable (NormalizedPoint) -> CGPoint?`
closure. The injector asks it for a platform position and never derives one.
Because the type is `internal`, no `CGPoint` reaches the package surface, and
M1-039's mapper — which lives inside this same module — can supply a value
without widening any access level.

The shipped production default is `MacPlatformPositionResolver.unresolved`,
which resolves nothing. Until M1-039 installs the real mapper, production
injection therefore fails closed rather than moving the cursor to a guessed
position. That is deliberate: a plausible-looking built-in mapper would be this
Issue silently taking over M1-039's ownership.

## Behavior

`inject(_:)` is synchronous, `nonisolated`, and returns
`CoreResult<MouseMoveInjectionOutcome>`. Its order is fixed and asserted:

1. **Accept only `KVMEvent.mouseMove`.** Every other case is refused locally,
   before any macOS call, as `internal.preconditionFailed` with `never` retry.
   `enterScreen` carries a `NormalizedPoint` too and is refused all the same:
   this is a mouse-move injector, not a position-bearing-event injector.
2. **Read Accessibility trust** through the M1-035 `AccessibilityPermissionService`
   and stop on denial, returning exactly
   `AccessibilityTrustState.notTrusted.actionableFailure` — the existing frozen
   `permission.accessibilityDenied` value with `userActionRequired` retry. No
   second permission error shape is introduced. Injection never prompts and
   never opens System Settings: asking the user for permission is the
   application shell's decision, not a side effect of one move in a
   high-frequency stream.
3. **Resolve a platform position** through the injected resolver. `nil` fails
   closed as `lifecycle.subsystemUnavailable` with `immediateAfterStateChange`
   retry. The injector does not interpret *why* nothing resolved; that is
   M1-039's concern.
4. **Create the event.** Creation failure fails closed as
   `internal.unclassified` with `immediateAfterStateChange` retry, and nothing
   is posted.
5. **Post exactly the created event, once**, at `kCGHIDEventTap`.

Every failure carries `severity: .error`, `cleanupDisposition: .notRequired`,
and no `underlyingDiagnosticCode`. No path sleeps, polls, or retries.

## Known limitation: posting has no truthful success signal

`CGEventPost` is declared `void`. The installed SDK reports neither success nor
failure of posting, and posting is asynchronous with respect to the caller.

The success value is therefore `MouseMoveInjectionOutcome.postRequested` and
there is deliberately no `moved` or `delivered` case. "The event was created and
handed to the event stream" is the strongest true statement available; claiming
the cursor moved would be an invented confirmation. A caller that needs to know
where the cursor actually is must observe that itself.

## Why `internal.unclassified` for creation failure

The installed SDK declares `CGEventCreateMouseEvent` as returning a nullable
event and documents no failure reason for a `NULL` return. The failure is
therefore reported as unclassified rather than given a reason the platform never
supplied, and no platform text, status code, or invented underlying diagnostic
code is attached.

## Documented CoreGraphics facts this component relies on

Read from `MacOSX26.2.sdk` `CoreGraphics.framework/Headers`:

- `CGEventCreateMouseEvent` — the event source "may be taken from another event,
  or may be NULL"; `mouseCursorPosition` "should be the position of the mouse
  cursor in global coordinates"; and `mouseButton` "is ignored unless
  `mouseType` is one of `kCGEventOtherMouseDown`, `kCGEventOtherMouseDragged`,
  or `kCGEventOtherMouseUp`". A mouse-moved event is none of those three, so the
  button argument is documented-ignored here and no button state is introduced.
- `CGEventPost(CGEventTapLocation tap, CGEventRef event)` returns `void`, and
  "posts the specified event immediately before any event taps instantiated for
  that location".
- `kCGHIDEventTap` is the tap location used, because a synthetic move must enter
  where HID system events enter to behave like the hardware pointer for every
  observer downstream. It is a constant of this component, never a caller input.

No event source object is created, so the component owns no CoreGraphics
resource and has nothing to release.

## Dependency seam and determinism

`MacMouseMoveInjectionEnvironment` is an `internal` struct of two `@Sendable`
closures covering exactly the two macOS event calls this component makes:
create, and post. Creation returns an opaque `internal`
`MacMouseMoveEventHandle`, and posting takes exactly that handle. Its `live`
value is the production default: it wraps the real `CGEvent` from
`CGEventCreateMouseEvent` in the handle, and its post seam posts exactly that
event, so production behavior is unchanged. Handle equality is identity, never
content. Tests substitute both closures and create only
`MacMouseMoveEventHandle.synthetic()` handles, which wrap no event, so **no
ordinary automated test creates or posts a real event and no automated run can
move the real cursor**. No handle, `CGEvent` or `CGPoint` reaches the package
surface.

Trust is substituted through the existing M1-035
`AccessibilityPermissionEnvironment`, so the denial path is exercised without
depending on the machine's real trust state.

Neither seam signature can carry a platform `Error`, localized message, or
status code, so arbitrary platform error text cannot reach the typed boundary by
construction.

### Pure-unit event seam (review correction)

Swift Testing runs the suite in parallel. The root reviewer twice found the
clean full suite hanging before any output:

1. First sample: several M1-036 tests were blocked at once in the process's
   first CoreGraphics/SkyLight initialization (`SLEventCreate` /
   `SLEventCreateMouseEvent` → `CGSEventSourceForID` → `CGSScoreboard` →
   `SLSServerPort` → `_dispatch_once_wait`) while M1-035's real trust reads ran
   concurrently.
2. A test-only `NSLock` gate (`SerializedTestEventCreation`) then serialized
   every M1-036 test-side creation. The reviewer's build succeeded and the
   clean full suite hung again. The post-fix `/usr/bin/sample` showed one M1-036
   thread owning the gate while blocked in `SLEventCreate` → `CGSScoreboard` →
   `SLSServerPort` initialization, two ordinary M1-035 tests concurrently
   blocked in `hasAuthorizationForControlComputer` → `TCCAccessRequest`, and
   every other M1-036 event test waiting on the gate.

Serializing only M1-036's own creations therefore cannot break a
cross-framework initialization cycle with M1-035's trust reads, and M1-035 is
not modified by this Issue. The gate was removed. Instead, **ordinary automated
M1-036 tests create no real `CGEvent` and call no CoreGraphics event-creation
API**: they use the synthetic handles above, which cover creation, exact
identity, creation failure, ordering, repetition, and privacy. The former
always-running test of the live creation closure was removed with the gate.

Real creation and real posting remain only in the opt-in Tier-H probe, which is
skipped unless `MACKVM_M1_036_MANUAL_PROBE` selects an action. It pre-creates
the target and restore handles through `MacMouseMoveInjectionEnvironment.live`
before the target post, restores through the injector, keeps the cleanup-only
fallback, never sleeps, and prints closed vocabulary only.

`onlyTheTierHLiveRegionNamesLiveEventCreationPostingOrTheProductionSeam` is a
static source audit of the test file. It proves that the text above the one
`// MARK: - Tier-H live region` line names no event creation, event post, event
source, production factory seam, or the removed gate, that the production
initializer is composed exactly once there (by the production-default test,
whose unresolved resolver stops before creation), and that the live region names
the production seam and the cursor read and holds exactly one test, the gated
probe. It is static evidence only. It does not prove at run time that no
framework call happens: the production-default test still makes M1-035's real,
non-prompting trust read. The root reviewer's clean-process ordinary suite at
commit `dbc45d4e04942a03a6e73b86420801802369673f` passed with no hang: 31
declared, 29 ran, 2 manual probes skipped, 0 failures. Live creation and posting
were then exercised by the reviewer's Tier-H probe; see
`evidence/issues/M1-036/manual-result.json`.

## Resource ownership, cancellation, and cleanup

The injector is an immutable `Sendable` struct. It owns no task, timer, queue,
observer, event tap, hook, event source, file handle, or pressed-button ledger,
and holds no mutable state. Each call derives its result only from that call.

Cancellation is therefore not applicable: there is no asynchronous operation, no
in-flight work, and no cancellation or teardown entry point to expose. Nothing
is allocated that outlives a call, so no failure path owes cleanup and
`cleanupDisposition` is `notRequired` everywhere. The equivalent obligation is
met by idempotency: move injection is stateless, so repetition is safe and a
failure in the middle of a stream neither latches nor poisons the next call.

Nothing is annotated `@MainActor`, so a high-frequency caller can inject from a
detached task without hopping through a UI actor.

## Privacy and logging

The component emits no log and no diagnostic event. No coordinate, timestamp,
typed text, clipboard payload, secret, key material, or platform error string is
recorded, returned, or retained. The only values that cross the boundary are a
closed enum case and frozen `CoreError` taxonomy fields, which an automated test
confirms encode to exactly four closed keys with no coordinate digits and no
platform type name present.

## Validation coverage

Automated tests with the seams substituted verify:

- the happy path performs exactly `[trustCheck, resolvePosition, makeEvent,
  post]` in that order, posts at `kCGHIDEventTap`, posts the very object the
  creation seam returned, and reports `postRequested`;
- boundary normalized points — both ends of `0...1`, both mixed corners, an
  out-of-range input, and a NaN input — reach the resolver **unchanged**, which
  is what proves the injector applies no clamp, scale, flip, or mapping of its
  own;
- all six non-`mouseMove` `KVMEvent` cases, including position-bearing
  `enterScreen`, fail closed as `internal.preconditionFailed` with an empty seam
  call log: no trust read, no resolve, no event, no post;
- Accessibility denial returns exactly the frozen M1-035 value, reads trust
  exactly once, and stops there;
- an unresolvable platform position stops after the resolver, before any event
  exists;
- creation failure stops after creation and posts nothing;
- the whole call runs inside `Task.detached` and did not execute on the main
  thread, which would not compile if the type or method were `@MainActor`;
- repeated injection is stateless and carries no latched failure, and a failing
  injector posts nothing on either of two consecutive calls;
- all four failures encode to exactly `code`, `severity`, `retryDisposition`,
  `cleanupDisposition`, with neither the injected platform coordinate digits nor
  the domain coordinate digits nor any platform type name present;
- every created handle is synthetic and handle equality is identity: two
  separately created handles are never equal, and each posted handle is exactly
  the handle created for that call; and
- the production default resolves no platform position, so it can never reach
  event creation whatever the machine's trust state is.

No ordinary test asserts that the live seam creates a `mouseMoved` event at the
requested position; that always-running test was removed with the creation
gate, and the live seam is now exercised only by the opt-in Tier-H probe.

The manual probe's action parsing is covered by an ordinary always-running test:
unset, empty and whitespace select nothing; the two exact action names are
accepted; and unknown, partial and differently-cased values are refused rather
than guessed.

The probe's `move-and-restore` sequencing, `performManualMoveAndRestore`, is
also covered by ordinary always-running tests, through a recording seam whose
creation returns synthetic handles and whose post is only recorded, so none of
them creates a real event or can move the real cursor:

- with trust held, both events are created before the first post, and the
  target and then the origin are post-requested through the injector, each
  after its own trust read;
- with trust withdrawn between move and restore, the injector's restore fails
  closed and cleanup requests the pre-created origin restore exactly once at
  the same tap, and the rendered line reports
  `restore=permission.accessibilityDenied cleanup=fallbackPostRequested`;
- with trust denied, the move fails closed and nothing is posted, so no
  restore is owed; and
- if either event cannot be created, the run stops before any trust read and
  before any post.

The probe's `cursor=` read-back mapping, `manualProbeCursorObservation`, is a
pure function covered by an ordinary always-running test: a read-back equal to
the origin is `matchesOrigin`, a different one is `differsFromOrigin`, and no
read-back is `unreadable`. It compares with explicit `==`.

One further test is declared but **skipped by default**: the Tier-H manual probe
below. Skipping it is not an acceptance bypass. Every behavior test above runs
and passes in an ordinary run, and the probe asserts no behavior they leave
uncovered; it exists only so a reviewer can drive real injection on purpose.

## Tier-H manual probe

M1-036 deliberately adds no application wiring, so there is no app build from
which a reviewer could call these `package`-level methods. The test
`manualRealInjectionProbeRunsOneReviewerSelectedAction`, in the Exact Test File,
closes that gap: it drives the real `MacMouseMoveInjectionEnvironment.live` seam
and the real `AccessibilityPermissionService()` inside the SwiftPM test process,
so the reviewer can watch the real cursor with their own eyes.

The probe supplies **its own** position resolver, because M1-039 owns the real
mapping. The domain point handed to `inject` is therefore a placeholder and the
probe asserts nothing whatsoever about coordinate mapping.

It is skipped unless `MACKVM_M1_036_MANUAL_PROBE` names one action, so no
ordinary CI or local run can move the cursor. It accepts exactly `read-origin`
and `move-and-restore`; anything else fails the run instead of passing silently,
and the unrecognized value is never echoed back.

```sh
# Reads the current cursor position and injects nothing. Moves no cursor.
MACKVM_M1_036_MANUAL_PROBE=read-origin \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction

# Requests one bounded real move, then requests the original position back.
MACKVM_M1_036_MANUAL_PROBE=move-and-restore \
  swift test --package-path Packages/MacPlatform \
  --filter manualRealInjectionProbeRunsOneReviewerSelectedAction
```

Each run emits exactly one sanitized line:

```text
M1-036 manual probe: action=<action> origin=<origin> preparation=<preparation> move=<step> restore=<step> cleanup=<cleanup> cursor=<observation>
```

Every field is closed vocabulary:

| Field | Values |
| --- | --- |
| `origin` | `readable`, `unreadable` |
| `preparation` | `notAttempted`, `eventsPrepared`, `eventCreationFailed` |
| `move`, `restore` | `notAttempted`, `postRequested`, or a closed taxonomy name such as `permission.accessibilityDenied` |
| `cleanup` | `notRequired`, `fallbackPostRequested` |
| `cursor` | `matchesOrigin`, `differsFromOrigin`, `unreadable`, `notObserved` |

**No coordinate is ever emitted**, and no platform error string, typed text, or
clipboard payload can reach the output because no such value is passed to it.
`postRequested` and `fallbackPostRequested` record a post *request*; neither
claims delivery.

### Bounded movement and restore

`move-and-restore` reads the current cursor position with `CGEvent(source:)`,
which the SDK documents as using the default source when passed `NULL`, and
whose `location` is "the location of an event in global display coordinates".
The target is that position plus a fixed 24-point offset on both components. The
offset is a compiled-in constant, not a reviewer input, so no arbitrary value
can be injected.

The order minimizes the chance of leaving the cursor displaced:

1. **Prepare.** Both the target event and the origin restore event are created
   through the live creation seam before anything is posted. If either cannot
   be created the run stops with `preparation=eventCreationFailed`, before any
   trust read and before any post, so the cursor never moves.
2. **Move.** The target is posted through the real `MacMouseMoveInjector`
   `inject` path: real Accessibility trust read, probe-supplied resolver, the
   pre-created event handed back by the creation seam for exactly that
   position, and the live post at the injector's own tap.
3. **Restore.** Only if the target post was requested — otherwise nothing was
   displaced — the origin is requested back through the same injector path.
4. **Cleanup only.** If the target post was requested and the injector's
   restore requested none, the pre-created origin restore event is posted
   directly, once, at the injector's tap, and the line reports
   `cleanup=fallbackPostRequested`. The run then fails, because the injector
   did not restore on its own. This is the only direct post in the probe.

Post requests are recorded by the identity of the event object handed to the
post seam, independently of what `inject` reports, so the cleanup decision rests
only on observed requests. Nothing between the target post and cleanup can throw
or return early.

If the cursor starts within the offset of a display edge the window server
clamps it to the display area; that costs nothing, because the restore requests
the exact original position afterwards — a position that was, by construction, a
real cursor location a moment earlier. No display topology knowledge is needed
for the restore to be correct, which is precisely why the probe can be safe
without taking over M1-039's ownership.

What in-process cleanup cannot cover is stated, not hidden: if the test process
is terminated between the target post request and the restore request, no code
of the probe runs any more. That window is two consecutive synchronous calls
with no wait between them.

### What the probe proves, and what it does not

**Stated limitation, not hidden:** `CGEventPost` returns no status and posting is
asynchronous, so the probe cannot confirm cursor placement without sleeping, and
sleeping to mask that race is prohibited. The `cursor=` field is therefore an
**unasserted observation** of an immediate read-back. `differsFromOrigin` is an
expected outcome of reading too early and is not treated as a failure. What the
probe does guarantee is ordering: once the target post is requested, the last
post it requests is the origin restore — through the injector, or else through
the recorded cleanup-only fallback.

The probe also says nothing about the final application's signing identity.
macOS Accessibility authorization is identity-specific, so a grant held by the
test process does not transfer to a signed app bundle or vice versa. Verifying
authorization for the app bundle is a downstream integration concern for the
Issue that wires this injector into the application shell. M1-036 must not, and
does not, claim it.

## Architecture and scope boundaries

No Barrier, native protocol, transport, socket, network, TLS, or clipboard
behavior is introduced; `MacPlatform` imports no protocol module and no Barrier
token, type, or import appears anywhere. No display or Retina mapping, button,
scroll, keyboard, UI, app wiring, diagnostics catalog entry, or input state
ledger is added. No OS key code or event type is added to `KVMEvent` or to any
wire schema. Security and TLS defaults are unchanged, and no permission decision
is cached, weakened, or bypassed.

## Rollback

Revert the M1-036 pull request. That removes the injector, its tests, and this
document in one operation, and leaves `MacPlatform` at its previous M1-035
state. No runtime resource, persisted data, permission grant, or migration
requires cleanup, because the component stores nothing, owns nothing, and — in
its shipped production default — posts nothing.

## Follow-up

- **M1-039** installs the real `MacPlatformPositionResolver`, replacing
  `unresolved`, and owns every coordinate policy this Issue deliberately left
  out.
- The Issue that wires the injector into the application shell owns app-bundle
  Accessibility authorization and the caller-side decision about when to prompt.
