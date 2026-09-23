import CoreGraphics
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

// MARK: - Deterministic seam recording

/// One observed call into a substituted seam, in the order it happened.
///
/// The ordered log is how a test asserts both *which* platform work happened
/// and *that nothing happened after a failure*, without relying on counters
/// that cannot express ordering.
private enum InjectionSeamCall: Equatable {
  case trustCheck
  case resolvePosition(NormalizedPoint)
  case makeEvent(CGPoint)
  case post(CGEventTapLocation)

  /// Any M1-035 seam call the injector must never make. Injection checks trust;
  /// it never prompts and never opens System Settings.
  case unexpectedPermissionCall
}

/// Records every seam invocation, creates one fresh synthetic handle per
/// accepted creation request, and keeps every handle handed to `post`.
///
/// Every handle it creates comes from `MacMouseMoveEventHandle.synthetic()`,
/// which wraps no event, so no ordinary test asks CoreGraphics to create or
/// post anything. The root reviewer sampled two clean full-suite hangs in which
/// test-side event creation sat inside CoreGraphics' first window-server
/// initialization while M1-035's real trust reads waited in TCC; with no
/// event creation in any ordinary test, this file no longer enters that
/// initialization at all.
///
/// The seam closures are `@Sendable`, so the recorder is lock-guarded and
/// `@unchecked Sendable`. macOS 14 is the platform floor, so `NSLock` is used
/// rather than `Synchronization.Mutex`. A handle is not `Sendable`, which is
/// the second reason handles live here behind the lock rather than being
/// captured directly by a `@Sendable` closure.
private final class SeamRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let refusesCreation: @Sendable (CGPoint) -> Bool
  private var callLog: [InjectionSeamCall] = []
  private var createdHandles: [MacMouseMoveEventHandle] = []
  private var postedHandles: [MacMouseMoveEventHandle] = []

  /// - Parameter refusesCreation: returns `true` for each position at which
  ///   the substituted creation seam models a creation failure.
  init(refusingCreation refusesCreation: @escaping @Sendable (CGPoint) -> Bool = { _ in false }) {
    self.refusesCreation = refusesCreation
  }

  var calls: [InjectionSeamCall] { lock.withLock { callLog } }
  var created: [MacMouseMoveEventHandle] { lock.withLock { createdHandles } }
  var posted: [MacMouseMoveEventHandle] { lock.withLock { postedHandles } }

  func record(_ call: InjectionSeamCall) {
    lock.withLock { callLog.append(call) }
  }

  /// Records one creation request and returns a new synthetic handle, or `nil`
  /// where creation is refused.
  func create(at position: CGPoint) -> MacMouseMoveEventHandle? {
    lock.withLock {
      callLog.append(.makeEvent(position))
      guard !refusesCreation(position) else { return nil }
      let handle = MacMouseMoveEventHandle.synthetic()
      createdHandles.append(handle)
      return handle
    }
  }

  func recordPost(_ handle: MacMouseMoveEventHandle, tap: CGEventTapLocation) {
    lock.withLock {
      postedHandles.append(handle)
      callLog.append(.post(tap))
    }
  }
}

/// The substituted creation and post seams every ordinary test uses.
///
/// Creation returns synthetic handles only and posting is only recorded, so no
/// test using this seam can create an event or move the real cursor.
private func syntheticPlatform(recorder: SeamRecorder) -> MacMouseMoveInjectionEnvironment {
  MacMouseMoveInjectionEnvironment(
    makeMouseMoveEvent: { position in recorder.create(at: position) },
    postEvent: { handle, tap in recorder.recordPost(handle, tap: tap) }
  )
}

/// A platform position with digits that appear nowhere else, so a privacy test
/// can prove no resolved coordinate reaches an encoded failure.
private let resolvedPlatformPosition = CGPoint(x: 4321.5, y: 8765.25)

/// A domain point with digits that appear nowhere else, for the same reason.
private let domainPosition = NormalizedPoint(x: 0.312_5, y: 0.687_5)

/// A permission service whose trust seam records every read.
///
/// Trust holds for the first `trustedChecks` reads and is withdrawn after them,
/// which models a grant revoked between two injections. Every other M1-035 seam
/// records an unexpected call: injection checks trust, it never prompts and
/// never opens System Settings.
private func makePermissions(
  recorder: SeamRecorder,
  trustedChecks: Int
) -> AccessibilityPermissionService {
  AccessibilityPermissionService(
    environment: AccessibilityPermissionEnvironment(
      isProcessTrusted: {
        recorder.record(.trustCheck)
        return recorder.calls.filter { $0 == .trustCheck }.count <= trustedChecks
      },
      isProcessTrustedRequestingPrompt: { _ in
        recorder.record(.unexpectedPermissionCall)
        return false
      },
      settingsApplicationURL: {
        recorder.record(.unexpectedPermissionCall)
        return nil
      },
      openApplication: { _ in
        recorder.record(.unexpectedPermissionCall)
        return false
      }
    )
  )
}

private func makeInjector(
  recorder: SeamRecorder,
  trusted: Bool = true,
  resolvedPosition: CGPoint? = resolvedPlatformPosition
) -> MacMouseMoveInjector {
  MacMouseMoveInjector(
    permissions: makePermissions(recorder: recorder, trustedChecks: trusted ? .max : 0),
    positionResolver: MacPlatformPositionResolver { normalizedPoint in
      recorder.record(.resolvePosition(normalizedPoint))
      return resolvedPosition
    },
    environment: syntheticPlatform(recorder: recorder)
  )
}

/// Every `KVMEvent` case this injector must refuse.
///
/// `enterScreen` is deliberately included: it carries a `NormalizedPoint` too,
/// so accepting it would prove the injector matched on "has a position" instead
/// of on the mouse-move case.
private let nonMouseMoveEvents: [KVMEvent] = [
  .mouseButton(button: .left, phase: .down),
  .scroll(deltaX: 3, deltaY: -3),
  .key(key: .space, phase: .down, modifiers: ModifierState()),
  .clipboard(
    ClipboardPayload(
      transactionID: ClipboardTransactionID(),
      origin: .local,
      utf8Text: "",
      contentHash: ""
    )
  ),
  .enterScreen(screen: ScreenID(), position: domainPosition),
  .leaveScreen(screen: ScreenID()),
]

// MARK: - Handle identity

/// Handle equality is identity, never content. This is what makes every
/// "posted exactly the created handle" assertion below non-vacuous: two
/// separately created synthetic handles are never equal.
@Test func syntheticHandlesAreEqualOnlyToThemselves() {
  let handle = MacMouseMoveEventHandle.synthetic()
  let sameHandle = handle

  #expect(handle == sameHandle)
  #expect(handle != MacMouseMoveEventHandle.synthetic())
  #expect(MacMouseMoveEventHandle.synthetic() != MacMouseMoveEventHandle.synthetic())
}

// MARK: - Happy path

@Test func mouseMoveChecksTrustResolvesCreatesAndPostsExactlyOnceInThatOrder() throws {
  let recorder = SeamRecorder()
  let injector = makeInjector(recorder: recorder)

  let outcome = try injector.inject(.mouseMove(position: domainPosition)).get()

  #expect(outcome == .postRequested)
  #expect(
    recorder.calls == [
      .trustCheck,
      .resolvePosition(domainPosition),
      .makeEvent(resolvedPlatformPosition),
      .post(.cghidEventTap),
    ]
  )

  // The handle posted is the handle created: the injector must not re-create,
  // copy, or substitute the event between creation and posting.
  let created = try #require(recorder.created.first)
  #expect(recorder.created.count == 1)
  #expect(recorder.posted == [created])

  // The tap is a documented constant of this component, not a caller input.
  #expect(MacMouseMoveInjector.eventTapLocation == .cghidEventTap)
}

// MARK: - Boundary

/// The injector must hand the resolver exactly the point the M1-013 contract
/// produced, including at both ends of the closed 0...1 range.
///
/// `NormalizedPoint` itself clamps out-of-range and NaN input, so the last two
/// arguments arrive already normalized. Asserting the resolver receives that
/// same value proves the injector performs no clamp, scale, flip, or mapping of
/// its own: coordinate policy belongs to M1-039, not to this Issue.
@Test(
  arguments: [
    NormalizedPoint(x: 0, y: 0),
    NormalizedPoint(x: 1, y: 1),
    NormalizedPoint(x: 0, y: 1),
    NormalizedPoint(x: 1, y: 0),
    NormalizedPoint(x: -1, y: 2),
    NormalizedPoint(x: .nan, y: .nan),
  ]
)
func normalizedBoundaryPositionsReachTheResolverUnchanged(position: NormalizedPoint) throws {
  let recorder = SeamRecorder()
  let injector = makeInjector(recorder: recorder)

  #expect(try injector.inject(.mouseMove(position: position)).get() == .postRequested)
  #expect(
    recorder.calls == [
      .trustCheck,
      .resolvePosition(position),
      .makeEvent(resolvedPlatformPosition),
      .post(.cghidEventTap),
    ]
  )
  #expect(recorder.posted == recorder.created)
}

// MARK: - Invalid input

@Test(arguments: nonMouseMoveEvents)
func nonMouseMoveDomainEventsFailClosedWithoutAnyPlatformWork(event: KVMEvent) {
  let recorder = SeamRecorder()
  let injector = makeInjector(recorder: recorder)

  guard case .failure(let error) = injector.inject(event) else {
    Issue.record("expected a typed failure for an event this injector does not accept")
    return
  }

  #expect(error.code == .internalFailure(.preconditionFailed))
  #expect(error.domain == .internalFailure)
  #expect(error.severity == .error)
  #expect(error.retryDisposition == .never)
  #expect(error.retryDisposition.allowsRetry == false)
  #expect(error.cleanupDisposition == .notRequired)
  #expect(error.underlyingDiagnosticCode == nil)

  // Rejection is purely local: no trust read, no resolve, no event, no post.
  #expect(recorder.calls.isEmpty)
  #expect(recorder.created.isEmpty)
  #expect(recorder.posted.isEmpty)
}

// MARK: - Permission denial

@Test func accessibilityDenialReturnsTheFrozenPermissionFailureAndDoesNoEventWork() {
  let recorder = SeamRecorder()
  let injector = makeInjector(recorder: recorder, trusted: false)

  guard case .failure(let error) = injector.inject(.mouseMove(position: domainPosition)) else {
    Issue.record("expected the frozen permission failure while Accessibility trust is denied")
    return
  }

  // Exactly the existing frozen M1-015 value M1-035 already emits. This Issue
  // introduces no second permission error shape.
  #expect(error == AccessibilityTrustState.notTrusted.actionableFailure)
  #expect(error.code == .permission(.accessibilityDenied))
  #expect(error.domain == .permission)
  #expect(error.severity == .error)
  #expect(error.retryDisposition == .userActionRequired)
  #expect(error.retryDisposition.allowsAutomaticRetry == false)
  #expect(error.cleanupDisposition == .notRequired)
  #expect(error.underlyingDiagnosticCode == nil)

  // Trust is read exactly once, and denial stops everything after it.
  #expect(recorder.calls == [.trustCheck])
  #expect(recorder.created.isEmpty)
  #expect(recorder.posted.isEmpty)
}

// MARK: - Position resolver failure

@Test func unresolvablePlatformPositionFailsClosedBeforeAnyEventIsCreated() {
  let recorder = SeamRecorder()
  let injector = makeInjector(recorder: recorder, resolvedPosition: nil)

  guard case .failure(let error) = injector.inject(.mouseMove(position: domainPosition)) else {
    Issue.record("expected a typed failure when no platform position resolves")
    return
  }

  #expect(error.code == .lifecycle(.subsystemUnavailable))
  #expect(error.domain == .lifecycle)
  #expect(error.severity == .error)
  #expect(error.retryDisposition == .immediateAfterStateChange)
  #expect(error.cleanupDisposition == .notRequired)
  #expect(error.underlyingDiagnosticCode == nil)

  #expect(recorder.calls == [.trustCheck, .resolvePosition(domainPosition)])
  #expect(recorder.created.isEmpty)
  #expect(recorder.posted.isEmpty)
}

// MARK: - Event creation failure

@Test func eventCreationFailureIsDiagnosableAndPostsNothing() {
  let recorder = SeamRecorder(refusingCreation: { _ in true })
  let injector = makeInjector(recorder: recorder)

  guard case .failure(let error) = injector.inject(.mouseMove(position: domainPosition)) else {
    Issue.record("expected a typed failure when the platform refuses to create the event")
    return
  }

  // The installed SDK documents no failure reason for a NULL return, so the
  // failure is reported as unclassified rather than given a reason the platform
  // never supplied.
  #expect(error.code == .internalFailure(.unclassified))
  #expect(error.domain == .internalFailure)
  #expect(error.severity == .error)
  #expect(error.retryDisposition == .immediateAfterStateChange)
  #expect(error.cleanupDisposition == .notRequired)
  #expect(error.underlyingDiagnosticCode == nil)

  #expect(
    recorder.calls == [
      .trustCheck,
      .resolvePosition(domainPosition),
      .makeEvent(resolvedPlatformPosition),
    ]
  )
  #expect(recorder.created.isEmpty)
  #expect(recorder.posted.isEmpty)
}

// MARK: - Non-MainActor invocation

/// Reads the executing thread synchronously.
///
/// `Thread.isMainThread` is annotated unavailable from an asynchronous context,
/// so it is read from this synchronous nonisolated function instead. Nothing
/// about the observation changes; only the call site does.
private func isExecutingOnTheMainThread() -> Bool {
  Thread.isMainThread
}

/// High-frequency injection must never require the main actor or hop through a
/// UI actor. Running the whole call inside `Task.detached` and observing that it
/// did not execute on the main thread is the executable form of that
/// requirement: the call would not compile here if the type or method were
/// `@MainActor`.
@Test func injectionRunsOnADetachedNonMainActorTask() async throws {
  let recorder = SeamRecorder()
  let injector = makeInjector(recorder: recorder)

  let observed = await Task.detached {
    (
      onMainThread: isExecutingOnTheMainThread(),
      result: injector.inject(.mouseMove(position: domainPosition))
    )
  }.value

  #expect(observed.onMainThread == false)
  #expect(try observed.result.get() == .postRequested)
  #expect(
    recorder.calls == [
      .trustCheck,
      .resolvePosition(domainPosition),
      .makeEvent(resolvedPlatformPosition),
      .post(.cghidEventTap),
    ]
  )
  #expect(recorder.posted == recorder.created)
}

// MARK: - Statelessness and idempotency

/// Move injection is stateless: there is no pressed state, no latch, and no
/// accumulated position. Repetition is therefore safe, and a failure in the
/// middle of a stream neither poisons nor short-circuits the next call.
@Test func repeatedInjectionsAreStatelessAndCarryNoLatchedFailure() throws {
  let recorder = SeamRecorder()
  let injector = makeInjector(recorder: recorder)
  let event = KVMEvent.mouseMove(position: domainPosition)

  let outcomes = try (0..<3).map { _ in try injector.inject(event).get() }

  #expect(outcomes == [.postRequested, .postRequested, .postRequested])
  #expect(recorder.calls.filter { $0 == .post(.cghidEventTap) }.count == 3)
  #expect(recorder.calls.contains(.unexpectedPermissionCall) == false)

  // Each call posts its own freshly created handle, once, in call order, and
  // never a handle from an earlier call.
  let created = recorder.created
  #expect(created.count == 3)
  #expect(recorder.posted == created)
  if created.count == 3 {
    #expect(created[0] != created[1])
    #expect(created[1] != created[2])
    #expect(created[0] != created[2])
  }

  // A refused event in between changes nothing for the calls around it.
  let failingRecorder = SeamRecorder(refusingCreation: { _ in true })
  let failingInjector = makeInjector(recorder: failingRecorder)
  #expect(failingInjector.inject(event).isSuccess == false)
  #expect(failingInjector.inject(event).isSuccess == false)
  #expect(failingRecorder.posted.isEmpty)

  // Nothing was allocated that requires release: the injector owns no task,
  // timer, observer, event tap, or handle, so there is no cleanup entry point
  // to exercise and idempotent repetition is the equivalent proof.
}

// MARK: - Privacy

@Test func everyFailureEncodesToTheClosedTaxonomyWithoutCoordinatesOrPlatformText() throws {
  let failures = [
    makeInjector(recorder: SeamRecorder())
      .inject(.enterScreen(screen: ScreenID(), position: domainPosition)),
    makeInjector(recorder: SeamRecorder(), trusted: false)
      .inject(.mouseMove(position: domainPosition)),
    makeInjector(recorder: SeamRecorder(), resolvedPosition: nil)
      .inject(.mouseMove(position: domainPosition)),
    makeInjector(recorder: SeamRecorder(refusingCreation: { _ in true }))
      .inject(.mouseMove(position: domainPosition)),
  ]

  #expect(failures.allSatisfy { $0.isSuccess == false })

  for failure in failures {
    guard case .failure(let error) = failure else {
      Issue.record("expected a typed failure")
      continue
    }

    let encoded = try JSONEncoder().encode(error)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == ["code", "severity", "retryDisposition", "cleanupDisposition"])

    let text = try #require(String(data: encoded, encoding: .utf8))
    for forbidden in [
      "4321", "8765",  // the resolved platform coordinate
      "0.3125", "0.6875",  // the domain coordinate
      "CGEvent", "CGPoint", "cghid", "mouseMoved", "Accessibility", "synthetic", "Handle",
    ] {
      #expect(!text.contains(forbidden), "encoded failure must not carry \(forbidden)")
    }
  }
}

// MARK: - Production defaults

/// The shipped production default resolves no platform position, because
/// M1-039 owns logical/backing/wire mapping, normalization, clamping, and
/// multi-display and Retina behavior, and this Issue must not implement or
/// guess any of it.
///
/// This is the one ordinary test that composes the production initializer, and
/// with it the production event seam. That seam is never invoked here: trust
/// denial stops before the resolver, and the unresolved resolver stops before
/// creation, which `unresolvablePlatformPositionFailsClosedBeforeAnyEventIsCreated`
/// proves for the injector's ordering. The trust read is M1-035's real,
/// non-prompting read; it is not a CoreGraphics event call.
@Test func productionDefaultResolvesNoPlatformPositionSoNothingIsEverPosted() {
  let result = MacMouseMoveInjector().inject(.mouseMove(position: domainPosition))

  guard case .failure(let error) = result else {
    Issue.record("the production default must not report a posted move without a mapper")
    return
  }

  // Untrusted stops at the permission check; trusted stops at the resolver.
  // Both are closed, and neither creates or posts an event.
  let closedCodes: [CoreErrorCode] = [
    .permission(.accessibilityDenied),
    .lifecycle(.subsystemUnavailable),
  ]
  #expect(closedCodes.contains(error.code))
  #expect(MacPlatformPositionResolver.unresolved.platformPosition(domainPosition) == nil)
}

// MARK: - Tier-H manual probe vocabulary and sequencing

/// The exact action names the manual probe accepts. Anything else is refused.
private enum ManualInjectionProbeAction: String, CaseIterable {
  /// Reads the current cursor position and injects nothing.
  case readOrigin = "read-origin"
  /// Injects one bounded real move and then injects the original position back.
  case moveAndRestore = "move-and-restore"
}

private enum ManualProbeSelection: Equatable {
  case notSelected
  case selected(ManualInjectionProbeAction)
  case unknown
}

/// Parses the reviewer's selection, failing closed on anything unrecognized.
///
/// Kept separate from the probe body so the fail-closed behavior is covered by
/// an ordinary always-running test instead of only by running the real probe.
private func manualProbeSelection(from rawValue: String?) -> ManualProbeSelection {
  guard let rawValue else { return .notSelected }
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return .notSelected }
  guard let action = ManualInjectionProbeAction(rawValue: trimmed) else { return .unknown }
  return .selected(action)
}

/// Renders the one sanitized line the reviewer transcribes into `manual.md`.
///
/// Every field is a closed enum case or a closed `CoreError` taxonomy name. No
/// coordinate, platform error string, typed text, clipboard payload, or other
/// private data can reach this output, because no such value is passed to it.
private func manualProbeLine(
  action: ManualInjectionProbeAction,
  origin: ManualProbeOrigin,
  result: ManualMoveAndRestoreResult = ManualMoveAndRestoreResult(preparation: .notAttempted),
  cursor: ManualProbeCursorObservation = .notObserved
) -> String {
  let fields = [
    "action=\(action.rawValue)",
    "origin=\(origin.rawValue)",
    "preparation=\(result.preparation.rawValue)",
    "move=\(result.move.closedName)",
    "restore=\(result.restore.closedName)",
    "cleanup=\(result.cleanup.rawValue)",
    "cursor=\(cursor.rawValue)",
  ]
  return "M1-036 manual probe: " + fields.joined(separator: " ")
}

/// Whether the probe could read the cursor position it would have to restore.
private enum ManualProbeOrigin: String {
  case readable
  case unreadable
}

/// Whether both probe events were created before anything was posted.
private enum ManualProbePreparation: String {
  case notAttempted
  case eventsPrepared
  case eventCreationFailed
}

/// What one probe injection reported, named only in closed vocabulary.
///
/// `postRequested` is the strongest true statement: the platform post call
/// reports nothing, so no step ever claims the event was delivered or the
/// cursor moved.
private enum ManualProbeStep: Equatable {
  case notAttempted
  case postRequested
  case failed(CoreError)

  init(_ result: CoreResult<MouseMoveInjectionOutcome>) {
    switch result {
    case .success(.postRequested):
      self = .postRequested
    case .failure(let error):
      self = .failed(error)
    }
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .postRequested: "postRequested"
    case .failed(let error): sanitizedInjectionFailureName(error)
    }
  }
}

/// Whether cleanup had to request the restore post itself.
private enum ManualProbeCleanup: String {
  /// Nothing was displaced, or the injector's own restore requested the post.
  case notRequired
  /// The target post was requested but the injector's restore requested none,
  /// so cleanup requested the pre-created restore event directly.
  case fallbackPostRequested
}

/// What one `move-and-restore` run did, in closed vocabulary only.
private struct ManualMoveAndRestoreResult: Equatable {
  var preparation: ManualProbePreparation
  var move: ManualProbeStep = .notAttempted
  var restore: ManualProbeStep = .notAttempted
  var cleanup: ManualProbeCleanup = .notRequired
}

/// The two events a `move-and-restore` run can post.
private enum ManualProbeEventSlot {
  case target
  case restore
}

/// Holds both pre-created probe handles and records which of them a post was
/// requested for.
///
/// A handle is not `Sendable`, so, as in `SeamRecorder`, the handles live
/// behind this lock-guarded class rather than being captured directly by a
/// `@Sendable` seam closure. Requests are recorded by the identity of the
/// handle given to the post seam, independently of what `inject` reports, so
/// the cleanup decision rests only on observed post requests.
private final class ManualProbePostLedger: @unchecked Sendable {
  private let lock = NSLock()
  private let targetHandle: MacMouseMoveEventHandle
  private let restoreHandle: MacMouseMoveEventHandle
  private var requestedSlots: Set<ManualProbeEventSlot> = []

  init(targetHandle: MacMouseMoveEventHandle, restoreHandle: MacMouseMoveEventHandle) {
    self.targetHandle = targetHandle
    self.restoreHandle = restoreHandle
  }

  func handle(for slot: ManualProbeEventSlot) -> MacMouseMoveEventHandle {
    switch slot {
    case .target: targetHandle
    case .restore: restoreHandle
    }
  }

  func recordPostRequest(of handle: MacMouseMoveEventHandle) {
    lock.withLock {
      if handle == targetHandle { requestedSlots.insert(.target) }
      if handle == restoreHandle { requestedSlots.insert(.restore) }
    }
  }

  func postWasRequested(for slot: ManualProbeEventSlot) -> Bool {
    lock.withLock { requestedSlots.contains(slot) }
  }
}

/// A closed observation of where the cursor was when the probe last looked.
private enum ManualProbeCursorObservation: String {
  case matchesOrigin
  case differsFromOrigin
  case unreadable
  case notObserved
}

/// Maps a cursor read-back to its closed observation by explicit equality with
/// the origin captured before the move.
///
/// Kept separate from the probe body so the mapping is covered by an ordinary
/// always-running test instead of only by running the real probe. It takes
/// plain positions, so that test needs no event at all.
private func manualProbeCursorObservation(
  readBack: CGPoint?,
  origin: CGPoint
) -> ManualProbeCursorObservation {
  guard let readBack else { return .unreadable }
  return readBack == origin ? .matchesOrigin : .differsFromOrigin
}

@Test func cursorObservationComparesTheReadBackWithTheOrigin() {
  #expect(
    manualProbeCursorObservation(readBack: probeOrigin, origin: probeOrigin) == .matchesOrigin
  )
  #expect(
    manualProbeCursorObservation(readBack: probeTarget, origin: probeOrigin) == .differsFromOrigin
  )
  #expect(manualProbeCursorObservation(readBack: nil, origin: probeOrigin) == .unreadable)
}

@Test func manualProbeSelectionFailsClosedAndIsSkippedByDefault() {
  // Default state: nothing selected, so the probe never runs by accident.
  #expect(manualProbeSelection(from: nil) == .notSelected)
  #expect(manualProbeSelection(from: "") == .notSelected)
  #expect(manualProbeSelection(from: "   \n") == .notSelected)

  #expect(manualProbeSelection(from: "read-origin") == .selected(.readOrigin))
  #expect(manualProbeSelection(from: " move-and-restore ") == .selected(.moveAndRestore))

  // Unknown, partial, and differently-cased values are refused, never guessed.
  for rejected in ["bogus", "move", "Move-And-Restore", "read_origin", "inject", "0"] {
    #expect(manualProbeSelection(from: rejected) == .unknown)
  }

  #expect(
    ManualInjectionProbeAction.allCases.map(\.rawValue) == ["read-origin", "move-and-restore"]
  )
}

/// Fixed offset the `move-and-restore` action adds to both components of the
/// original cursor position.
///
/// It is a constant, not a reviewer input, so no arbitrary value can be
/// injected. It is small enough to stay a bounded nudge. If the cursor starts
/// within the offset of a display edge the window server clamps the cursor to
/// the display area; that costs nothing, because the restore requests the
/// exact original position afterwards.
private let manualProbeOffset: CGFloat = 24

/// The domain event every probe injection carries. The probe supplies its own
/// position resolver, so this point is a placeholder that no resolver reads.
private let manualProbeEvent = KVMEvent.mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5))

/// Builds the real M1-036 injector for one probe step.
///
/// Trust is read through `permissions` and the created handle is posted through
/// `platform.postEvent` at the injector's own tap, so the whole
/// `MacMouseMoveInjector.inject` path stays under test. Only creation happens
/// earlier: the creation seam hands back the handle `platform` already created
/// for exactly this position, and nothing for any other position.
private func manualProbeInjector(
  for slot: ManualProbeEventSlot,
  at position: CGPoint,
  ledger: ManualProbePostLedger,
  permissions: AccessibilityPermissionService,
  platform: MacMouseMoveInjectionEnvironment
) -> MacMouseMoveInjector {
  MacMouseMoveInjector(
    permissions: permissions,
    positionResolver: MacPlatformPositionResolver { _ in position },
    environment: MacMouseMoveInjectionEnvironment(
      makeMouseMoveEvent: { requested in
        requested == position ? ledger.handle(for: slot) : nil
      },
      postEvent: { handle, tap in
        ledger.recordPostRequest(of: handle)
        platform.postEvent(handle, tap)
      }
    )
  )
}

/// Runs one bounded move and its restore through the real injector path.
///
/// 1. Both the target and the restore handle are created before anything is
///    posted, so a creation failure can only stop the run before the cursor
///    moves.
/// 2. The target is posted through the injector.
/// 3. Only if the target post was requested — otherwise nothing was displaced —
///    the restore is attempted through the injector.
/// 4. Cleanup only: if the target post was requested and the injector's restore
///    requested none, the pre-created restore handle is posted directly, once,
///    at the injector's tap. This is the only direct post in this file, and it
///    is reported as `cleanup=fallbackPostRequested`.
///
/// Nothing between the target post and cleanup can throw or return early. No
/// step sleeps, polls, or retries, and none claims delivery: the platform post
/// call reports nothing, so every record is of a post request. Ordinary tests
/// pass the synthetic platform; only the opt-in probe passes the production one.
private func performManualMoveAndRestore(
  from origin: CGPoint,
  permissions: AccessibilityPermissionService,
  platform: MacMouseMoveInjectionEnvironment
) -> ManualMoveAndRestoreResult {
  let target = CGPoint(x: origin.x + manualProbeOffset, y: origin.y + manualProbeOffset)

  guard let targetHandle = platform.makeMouseMoveEvent(target) else {
    return ManualMoveAndRestoreResult(preparation: .eventCreationFailed)
  }
  guard let restoreHandle = platform.makeMouseMoveEvent(origin) else {
    return ManualMoveAndRestoreResult(preparation: .eventCreationFailed)
  }

  let ledger = ManualProbePostLedger(targetHandle: targetHandle, restoreHandle: restoreHandle)
  var result = ManualMoveAndRestoreResult(preparation: .eventsPrepared)

  let moveInjector = manualProbeInjector(
    for: .target,
    at: target,
    ledger: ledger,
    permissions: permissions,
    platform: platform
  )
  result.move = ManualProbeStep(moveInjector.inject(manualProbeEvent))

  guard ledger.postWasRequested(for: .target) else { return result }

  let restoreInjector = manualProbeInjector(
    for: .restore,
    at: origin,
    ledger: ledger,
    permissions: permissions,
    platform: platform
  )
  result.restore = ManualProbeStep(restoreInjector.inject(manualProbeEvent))

  if !ledger.postWasRequested(for: .restore) {
    ledger.recordPostRequest(of: restoreHandle)
    platform.postEvent(restoreHandle, MacMouseMoveInjector.eventTapLocation)
    result.cleanup = .fallbackPostRequested
  }

  return result
}

/// The sequencing tests' origin, reusing digits that appear nowhere else.
private let probeOrigin = resolvedPlatformPosition

private let probeTarget = CGPoint(
  x: resolvedPlatformPosition.x + manualProbeOffset,
  y: resolvedPlatformPosition.y + manualProbeOffset
)

@Test func moveAndRestorePreparesBothEventsFirstAndRestoresThroughTheInjector() {
  let recorder = SeamRecorder()
  let result = performManualMoveAndRestore(
    from: probeOrigin,
    permissions: makePermissions(recorder: recorder, trustedChecks: .max),
    platform: syntheticPlatform(recorder: recorder)
  )

  let expected = ManualMoveAndRestoreResult(
    preparation: .eventsPrepared,
    move: .postRequested,
    restore: .postRequested,
    cleanup: .notRequired
  )
  #expect(result == expected)

  // Both handles exist before the first post, and each post follows its own
  // trust read inside the injector.
  #expect(
    recorder.calls == [
      .makeEvent(probeTarget),
      .makeEvent(probeOrigin),
      .trustCheck,
      .post(.cghidEventTap),
      .trustCheck,
      .post(.cghidEventTap),
    ]
  )

  // The target handle is posted first and the restore handle second, each
  // exactly the handle created for its position.
  #expect(recorder.created.count == 2)
  #expect(recorder.posted == recorder.created)
}

@Test func cleanupRequestsTheRestorePostWhenTheInjectorRestoreFails() throws {
  let denial = try #require(AccessibilityTrustState.notTrusted.actionableFailure)
  let recorder = SeamRecorder()

  // Trust holds for the move and is withdrawn before the restore.
  let result = performManualMoveAndRestore(
    from: probeOrigin,
    permissions: makePermissions(recorder: recorder, trustedChecks: 1),
    platform: syntheticPlatform(recorder: recorder)
  )

  let expected = ManualMoveAndRestoreResult(
    preparation: .eventsPrepared,
    move: .postRequested,
    restore: .failed(denial),
    cleanup: .fallbackPostRequested
  )
  #expect(result == expected)

  // The injector's restore stopped at its trust read, and cleanup alone
  // requested the pre-created restore handle, exactly once, at the same tap.
  #expect(
    recorder.calls == [
      .makeEvent(probeTarget),
      .makeEvent(probeOrigin),
      .trustCheck,
      .post(.cghidEventTap),
      .trustCheck,
      .post(.cghidEventTap),
    ]
  )
  #expect(recorder.created.count == 2)
  #expect(recorder.posted == recorder.created)

  // The fallback is visible in the reviewer-facing line, in closed vocabulary
  // and with no coordinate.
  let expectedLine = """
    M1-036 manual probe: action=move-and-restore origin=readable \
    preparation=eventsPrepared move=postRequested \
    restore=permission.accessibilityDenied cleanup=fallbackPostRequested cursor=notObserved
    """
  let line = manualProbeLine(action: .moveAndRestore, origin: .readable, result: result)
  #expect(line == expectedLine)
}

@Test func moveThatFailsClosedPostsNothingAndOwesNoRestore() throws {
  let denial = try #require(AccessibilityTrustState.notTrusted.actionableFailure)
  let recorder = SeamRecorder()
  let result = performManualMoveAndRestore(
    from: probeOrigin,
    permissions: makePermissions(recorder: recorder, trustedChecks: 0),
    platform: syntheticPlatform(recorder: recorder)
  )

  // Nothing was posted, so nothing was displaced, and neither the injector's
  // restore nor cleanup has anything to request.
  let expected = ManualMoveAndRestoreResult(preparation: .eventsPrepared, move: .failed(denial))
  #expect(result == expected)
  #expect(recorder.calls == [.makeEvent(probeTarget), .makeEvent(probeOrigin), .trustCheck])
  #expect(recorder.posted.isEmpty)
}

/// If either handle cannot be created, the run stops before any trust read and
/// before any post, so a creation failure can never strand a displaced cursor.
@Test(arguments: [probeTarget, probeOrigin])
func eventThatCannotBePreparedStopsTheRunBeforeAnyPost(failingPosition: CGPoint) {
  let recorder = SeamRecorder(refusingCreation: { $0 == failingPosition })
  let result = performManualMoveAndRestore(
    from: probeOrigin,
    permissions: makePermissions(recorder: recorder, trustedChecks: .max),
    platform: syntheticPlatform(recorder: recorder)
  )

  #expect(result == ManualMoveAndRestoreResult(preparation: .eventCreationFailed))
  #expect(recorder.calls.contains(.trustCheck) == false)
  #expect(recorder.posted.isEmpty)
}

/// Maps a failure to a closed taxonomy name, never to platform text.
private func sanitizedInjectionFailureName(_ error: CoreError) -> String {
  switch error.code {
  case .permission(let code): "permission.\(code.rawValue)"
  case .lifecycle(let code): "lifecycle.\(code.rawValue)"
  case .internalFailure(let code): "internal.\(code.rawValue)"
  default: "unexpectedDomain.\(error.domain.rawValue)"
  }
}

extension Result {
  fileprivate var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}

// MARK: - Source ownership audit

/// Static source audit of this file. **It proves what the source names, not
/// what runs.**
///
/// The file is split at the one line that opens the Tier-H live region. Every
/// ordinary test lives above that line, and the audit asserts that the text
/// above it, comments included, names no CoreGraphics event creation, no event
/// post, no event source, no production factory seam, and not the removed
/// creation gate. It also pins the one ordinary composition of the production
/// initializer, whose event seam is never invoked for the reason stated on
/// `productionDefaultResolvesNoPlatformPositionSoNothingIsEverPosted`. Below the
/// line, it asserts the live region does name the production seam and the
/// cursor read, and holds exactly one test, the opt-in probe.
///
/// Each token is assembled from two literals, so the audit's own source never
/// contains a token it forbids. Absence of a name is a static fact; it is not
/// dynamic proof that no framework call happens, and the clean full-suite run
/// remains the reviewer's validation.
@Test func onlyTheTierHLiveRegionNamesLiveEventCreationPostingOrTheProductionSeam() throws {
  let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
  let regions = source.components(separatedBy: "// MARK: - Tier-H " + "live region")
  try #require(regions.count == 2, "the live region must open exactly once")
  let ordinary = regions[0]
  let live = regions[1]

  let liveOnlyTokens = [
    "CGEvent" + "(",
    "CGEvent" + "Create",
    "CGEvent" + "Post",
    "CGEvent" + "Source",
    "post" + "(tap:",
    "." + "live",
    "SerializedTest" + "EventCreation",
  ]
  for token in liveOnlyTokens {
    #expect(!ordinary.contains(token), "an ordinary route names \(token)")
  }

  let productionInitializer = "MacMouseMoveInjector" + "()"
  #expect(ordinary.components(separatedBy: productionInitializer).count == 2)
  #expect(!live.contains(productionInitializer))

  #expect(live.contains("MacMouseMoveInjectionEnvironment." + "live"))
  #expect(live.contains("CGEvent" + "(source: nil)"))
  #expect(live.components(separatedBy: "@" + "Test").count == 2)
  #expect(live.contains("if: selectedManualProbe() != " + ".notSelected"))
}

// MARK: - Tier-H live region

/// Environment variable that selects exactly one real-injection action.
///
/// Unset — the case for every ordinary CI run and every ordinary local run —
/// leaves the probe skipped, so no automated run can move the real cursor.
private let manualProbeActionKey = "MACKVM_M1_036_MANUAL_PROBE"

private func selectedManualProbe() -> ManualProbeSelection {
  manualProbeSelection(from: ProcessInfo.processInfo.environment[manualProbeActionKey])
}

/// Reads the current cursor position by creating, and never posting, an empty
/// event. Only the opt-in probe calls it.
private func readLiveCursorPosition() -> CGPoint? {
  CGEvent(source: nil)?.location
}

/// Reviewer-driven Tier-H manual harness. **Not an automated acceptance test.**
///
/// M1-036 adds no application wiring, so the Tier-H manual step would otherwise
/// have no executable entry point. This test is that entry point, and the only
/// place in the suite that creates or posts a real event: it drives the real
/// `MacMouseMoveInjectionEnvironment.live` seam and the real
/// `AccessibilityPermissionService()` inside the SwiftPM test process, so a
/// reviewer can watch the real cursor with their own eyes.
///
/// It supplies its own position resolver, because M1-039 owns the real mapping
/// and this Issue must not implement it. The domain point handed to `inject` is
/// therefore a placeholder, and the probe asserts nothing whatsoever about
/// coordinate mapping.
///
/// Safety properties:
///
/// - skipped unless the reviewer names one action, so no ordinary run moves the
///   cursor or creates a real event;
/// - one run performs at most one bounded move, and both its events are created
///   before anything is posted;
/// - the restore is requested through the injector and, if that request is not
///   made, by an explicit cleanup-only fallback that is reported in the output,
///   so once the move is requested an origin restore is always requested too;
/// - no sleep, poll, retry, or timer anywhere; and
/// - output is closed vocabulary only, never a coordinate.
///
/// The sequencing in `performManualMoveAndRestore` is covered by ordinary
/// always-running tests with synthetic handles that never post; this probe adds
/// only the real seams. It is one opt-in action run alone under `--filter`.
///
/// Its limitation is stated rather than hidden: `CGEventPost` returns no status
/// and posting is asynchronous, so the probe cannot confirm cursor placement
/// without sleeping. The read-back below is reported as an observation and is
/// deliberately not asserted.
@Test(
  .enabled(
    if: selectedManualProbe() != .notSelected,
    "manual Tier-H probe: set MACKVM_M1_036_MANUAL_PROBE to read-origin or move-and-restore"
  )
)
func manualRealInjectionProbeRunsOneReviewerSelectedAction() {
  guard case .selected(let action) = selectedManualProbe() else {
    // The unrecognized value is deliberately not echoed: this output is
    // reviewer-facing evidence and must stay free of arbitrary input.
    Issue.record("unknown manual probe action; expected read-origin or move-and-restore")
    return
  }

  guard let origin = readLiveCursorPosition() else {
    print(manualProbeLine(action: action, origin: .unreadable))
    Issue.record("the current cursor position could not be read, so no injection was attempted")
    return
  }

  guard action == .moveAndRestore else {
    print(manualProbeLine(action: action, origin: .readable))
    return
  }

  let result = performManualMoveAndRestore(
    from: origin,
    permissions: AccessibilityPermissionService(),
    platform: MacMouseMoveInjectionEnvironment.live
  )

  let cursor = manualProbeCursorObservation(readBack: readLiveCursorPosition(), origin: origin)

  print(manualProbeLine(action: action, origin: .readable, result: result, cursor: cursor))

  // Anything but two injector post requests and no cleanup is a failure of the
  // real path on this machine; the line above names the step.
  let expected = ManualMoveAndRestoreResult(
    preparation: .eventsPrepared,
    move: .postRequested,
    restore: .postRequested,
    cleanup: .notRequired
  )
  if result != expected {
    Issue.record("the real injection path did not request both posts through the injector")
  }
}
