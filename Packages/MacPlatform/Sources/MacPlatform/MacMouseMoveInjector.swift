import CoreGraphics
import KVMContracts

/// What one injection attempt did, as far as the installed SDK can truthfully
/// report it.
///
/// There is deliberately no "moved" or "delivered" case. `CGEventPost` returns
/// `void`: the SDK reports neither success nor failure of posting, and posting
/// is asynchronous. Claiming the cursor moved would therefore be an invention,
/// so the only success value states exactly what happened — the event was
/// created and handed to the event stream.
package enum MouseMoveInjectionOutcome: String, CaseIterable, Hashable, Sendable {
  case postRequested
}

/// Supplies the macOS platform position at which one domain point is injected.
///
/// This is the seam that keeps coordinate ownership where it belongs. M1-039
/// owns logical, backing and wire coordinate separation, normalization into
/// `0...1`, clamping, and multi-display and Retina behavior. M1-036 owns none
/// of it and must not guess any of it, so the injector never computes a
/// platform position: it asks for one.
///
/// The type is `internal`, so no `CGPoint` reaches the `MacPlatform` package
/// surface. M1-039's mapper lives inside this module and can supply a value
/// without widening any access level or adding a public contract.
struct MacPlatformPositionResolver: Sendable {
  /// Returns the platform position for `point`, or `nil` when none resolves.
  ///
  /// The injector does not interpret `nil`. Why a position fails to resolve is
  /// M1-039's concern; the injector only fails closed.
  var platformPosition: @Sendable (NormalizedPoint) -> CGPoint?
}

extension MacPlatformPositionResolver {
  /// The shipped production default: nothing resolves.
  ///
  /// M1-036 ships no display mapper, because inventing one would take over
  /// M1-039's ownership. Until M1-039 installs the real mapper, production
  /// injection therefore fails closed instead of moving the cursor to a guessed
  /// position.
  static let unresolved = MacPlatformPositionResolver { _ in nil }
}

/// An opaque handle for one created mouse-move event.
///
/// The injector never looks inside a handle: it posts exactly the handle its
/// creation seam returned, so identity is the only property it relies on, and
/// `==` compares identity, never event content.
///
/// A handle from `MacMouseMoveInjectionEnvironment.live` wraps the real
/// `CGEvent` CoreGraphics created, and only the live post seam unwraps it. A
/// substituted environment returns `synthetic()` handles instead. They wrap no
/// event at all, so a unit test can observe creation, identity and posting
/// without CoreGraphics creating or posting anything. The type is `internal`,
/// so no `CGEvent` reaches the package surface.
struct MacMouseMoveEventHandle: Equatable {
  /// The identity of a handle that wraps no event.
  private final class SyntheticIdentity: Sendable {}

  private enum Referent {
    case event(CGEvent)
    case synthetic(SyntheticIdentity)
  }

  private let referent: Referent

  private init(referent: Referent) {
    self.referent = referent
  }

  /// Wraps an event CoreGraphics created. Only the live environment, in this
  /// file, can call it.
  fileprivate init(wrapping event: CGEvent) {
    self.init(referent: .event(event))
  }

  /// Returns a new handle that wraps no event and is equal only to itself.
  static func synthetic() -> Self {
    Self(referent: .synthetic(SyntheticIdentity()))
  }

  /// Posts the wrapped event at `tap`.
  ///
  /// A synthetic handle wraps no event, so it posts nothing. Production never
  /// hands one to the live seam; if anything ever did, the failure would be the
  /// safe one, because no cursor could move.
  fileprivate func postWrappedEvent(at tap: CGEventTapLocation) {
    guard case .event(let event) = referent else { return }
    event.post(tap: tap)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs.referent, rhs.referent) {
    case (.event(let left), .event(let right)): left === right
    case (.synthetic(let left), .synthetic(let right)): left === right
    default: false
    }
  }
}

/// Deterministic seam for the two macOS event calls this injector makes.
///
/// Tests substitute both closures and create only synthetic handles, so no
/// automated run creates or posts an event and no automated run can move the
/// real cursor. `live` is the production default and calls the real
/// CoreGraphics APIs.
///
/// Neither signature can carry a platform `Error`, localized message, or status
/// code, so arbitrary platform error text cannot reach the typed boundary.
struct MacMouseMoveInjectionEnvironment: Sendable {
  /// Creates one mouse-move event at `position` and returns its opaque handle,
  /// or `nil` on failure.
  var makeMouseMoveEvent: @Sendable (CGPoint) -> MacMouseMoveEventHandle?

  /// Posts the event behind an already-created handle at `tap`, reporting
  /// nothing.
  ///
  /// The absence of a return value mirrors the SDK exactly. See
  /// `MouseMoveInjectionOutcome`.
  var postEvent: @Sendable (MacMouseMoveEventHandle, CGEventTapLocation) -> Void
}

extension MacMouseMoveInjectionEnvironment {
  /// Production default. Calls the documented public CoreGraphics APIs.
  ///
  /// `CGEventCreateMouseEvent` is documented as taking an event source that
  /// "may be taken from another event, or may be NULL", a `mouseCursorPosition`
  /// that "should be the position of the mouse cursor in global coordinates",
  /// and a `mouseButton` that "is ignored unless `mouseType` is one of
  /// `kCGEventOtherMouseDown`, `kCGEventOtherMouseDragged`, or
  /// `kCGEventOtherMouseUp`". A mouse-moved event is none of those three, so
  /// the button argument is documented-ignored here rather than meaningful, and
  /// no button state is introduced by this Issue.
  ///
  /// No event source object is created, so this seam owns no resource and has
  /// nothing to release. The handle wraps the created event unchanged, and the
  /// post seam posts exactly that event.
  static let live = MacMouseMoveInjectionEnvironment(
    makeMouseMoveEvent: { position in
      guard
        let event = CGEvent(
          mouseEventSource: nil,
          mouseType: .mouseMoved,
          mouseCursorPosition: position,
          mouseButton: .left
        )
      else { return nil }
      return MacMouseMoveEventHandle(wrapping: event)
    },
    postEvent: { handle, tap in handle.postWrappedEvent(at: tap) }
  )
}

/// Injects one macOS mouse-move event for one domain `KVMEvent`.
///
/// The input boundary is domain-only: the injector accepts `KVMEvent`, the
/// single Core event language, and `NormalizedPoint`. No `CGEvent`, `CGPoint`,
/// `CGEventTapLocation`, or other platform type appears in any `package` or
/// `public` declaration, so nothing leaks out of this module and nothing is
/// added to `KVMEvent` or to any wire schema. No public contract is added:
/// every declaration here is `package` or narrower.
///
/// The injector is an immutable `Sendable` struct. It owns no task, timer,
/// queue, observer, event tap, hook, event source, file handle, pressed-button
/// ledger, or any other mutable state. Each call derives its result only from
/// that call, so there is no cancellation or teardown entry point to expose and
/// nothing to clean up; repeating a call is safe. Nothing is annotated
/// `@MainActor`, so a high-frequency caller can inject from a detached task
/// without hopping through a UI actor.
///
/// Every failure path fails closed: the event is not created, or is created and
/// not posted, and the failure crosses the boundary as a frozen M1-015
/// `CoreError`. No path sleeps, polls, or retries.
package struct MacMouseMoveInjector: Sendable {
  /// Where a created event enters the event stream.
  ///
  /// `kCGHIDEventTap` is the point at which HID system events enter the window
  /// server, which is what a synthetic move must imitate to behave like the
  /// hardware pointer for every observer downstream. It is a constant of this
  /// component, never a caller input.
  static let eventTapLocation: CGEventTapLocation = .cghidEventTap

  /// A caller handed an event this injector does not accept. Nothing was
  /// created and nothing was posted, so no cleanup is owed, and re-sending the
  /// same event can never succeed.
  private static let unacceptedEventFailure = CoreError(
    code: .internalFailure(.preconditionFailed),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  /// No platform position resolved, so injection cannot proceed. Retry is
  /// meaningful only after a state change — a mapper being installed, or a
  /// display configuration changing — never on a timer, and this injector never
  /// retries on its own.
  private static let unresolvedPositionFailure = CoreError(
    code: .lifecycle(.subsystemUnavailable),
    severity: .error,
    retryDisposition: .immediateAfterStateChange,
    cleanupDisposition: .notRequired
  )

  /// The platform refused to create the event.
  ///
  /// The installed SDK declares `CGEventCreateMouseEvent` as returning a
  /// nullable event and documents no failure reason for a `NULL` return, so the
  /// failure is reported as unclassified rather than given a reason the
  /// platform never supplied. No platform text is attached and no underlying
  /// diagnostic code is invented.
  private static let eventCreationFailure = CoreError(
    code: .internalFailure(.unclassified),
    severity: .error,
    retryDisposition: .immediateAfterStateChange,
    cleanupDisposition: .notRequired
  )

  private let permissions: AccessibilityPermissionService
  private let positionResolver: MacPlatformPositionResolver
  private let environment: MacMouseMoveInjectionEnvironment

  /// Production initializer.
  ///
  /// Trust is read through the real M1-035 service and events are created and
  /// posted through the real CoreGraphics APIs. The position resolver is
  /// `MacPlatformPositionResolver.unresolved` until M1-039 installs the real
  /// mapper, so production injection currently fails closed rather than moving
  /// the cursor to a guessed position.
  package init() {
    self.init(
      permissions: AccessibilityPermissionService(),
      positionResolver: .unresolved,
      environment: .live
    )
  }

  init(
    permissions: AccessibilityPermissionService,
    positionResolver: MacPlatformPositionResolver,
    environment: MacMouseMoveInjectionEnvironment
  ) {
    self.permissions = permissions
    self.positionResolver = positionResolver
    self.environment = environment
  }

  /// Injects one mouse move, or fails closed.
  ///
  /// The order is fixed and is part of the contract this Issue tests:
  ///
  /// 1. accept only `KVMEvent.mouseMove`. Every other case is refused locally,
  ///    before any macOS call, because no OS work should be spent on an event
  ///    this injector never injects. `enterScreen` carries a position too and
  ///    is refused all the same: this is a mouse-move injector, not a
  ///    position-bearing-event injector;
  /// 2. read Accessibility trust, and stop on denial before any event work;
  /// 3. ask the injected resolver for a platform position;
  /// 4. create the event, and stop without posting if creation fails; and
  /// 5. post exactly the created handle, exactly once, at `eventTapLocation`.
  ///
  /// The method is synchronous and nonisolated. It allocates no resource that
  /// outlives the call, so no failure path owes cleanup.
  package func inject(_ event: KVMEvent) -> CoreResult<MouseMoveInjectionOutcome> {
    guard case .mouseMove(let position) = event else {
      return .failure(Self.unacceptedEventFailure)
    }

    // Fail closed on denial, with the value M1-035 already emits. Injection
    // never prompts and never opens System Settings: asking the user for
    // permission is the application shell's decision, not a side effect of one
    // move in a high-frequency stream.
    if let denial = permissions.currentTrustState().actionableFailure {
      return .failure(denial)
    }

    guard let platformPosition = positionResolver.platformPosition(position) else {
      return .failure(Self.unresolvedPositionFailure)
    }

    guard let mouseMoveEvent = environment.makeMouseMoveEvent(platformPosition) else {
      return .failure(Self.eventCreationFailure)
    }

    environment.postEvent(mouseMoveEvent, Self.eventTapLocation)
    return .success(.postRequested)
  }
}
