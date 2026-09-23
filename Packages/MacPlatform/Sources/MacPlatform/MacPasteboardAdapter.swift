import AppKit
import KVMContracts

/// One observed generation of the pasteboard's contents.
///
/// The value is opaque: callers compare two observations for equality to learn
/// whether the contents changed between them, and nothing else. No ordering,
/// arithmetic, or platform meaning is exposed, and no `NSPasteboard` type
/// reaches the package surface.
package struct MacPasteboardChangeCount: Hashable, Sendable {
  let value: Int
}

/// Plain text read from the pasteboard, with the generation observed before it
/// was read.
///
/// Every rendering of this value — `description`, `debugDescription`,
/// interpolation, `dump`, and reflection — is redacted, so logging or printing
/// it by accident cannot leak clipboard content. Only `text` itself carries it.
package struct MacPasteboardText: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  package let text: String
  package let changeCount: MacPasteboardChangeCount

  package var description: String { "MacPasteboardText(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

/// The one pasteboard access distinction the adapter acts on.
///
/// macOS 15.4 and later report a per-application pasteboard access behavior.
/// Only an explicit, standing denial is known before reading; every other
/// behavior — default, ask, always allow, a behavior this SDK does not know,
/// or an earlier macOS that reports none — leaves the actual read
/// authoritative. The value carries no AppKit type and states nothing about
/// whether the user answered a prompt.
enum MacPasteboardReadAccess: Hashable, Sendable {
  case explicitlyDenied
  case notExplicitlyDenied
}

/// Deterministic seam for the pasteboard operations this adapter makes.
///
/// Tests substitute every closure with an in-memory pasteboard, so no automated
/// run reads or mutates a system pasteboard. `live` is the production default.
///
/// No signature can carry a platform `Error`, localized message, or status
/// code, so arbitrary platform text cannot reach the typed boundary. Type
/// identifiers cross the seam as plain strings, so no AppKit type does either.
struct MacPasteboardEnvironment: Sendable {
  /// Reports whether reading is explicitly denied. Never prompts or mutates.
  var readAccess: @Sendable () -> MacPasteboardReadAccess

  /// Returns the pasteboard's current change count. Never mutates.
  var changeCount: @Sendable () -> Int

  /// Returns the type identifiers currently advertised; empty when none are.
  var availableTypeIdentifiers: @Sendable () -> [String]

  /// Returns the UTF-8 plain-text representation, or `nil` when none is read.
  var readPlainTextString: @Sendable () -> String?

  /// Clears the pasteboard, returning `false` when clearing was refused.
  var clearContents: @Sendable () -> Bool

  /// Writes `text` as the UTF-8 plain-text representation, returning `false`
  /// when the write was refused.
  var writePlainTextString: @Sendable (String) -> Bool
}

extension MacPasteboardEnvironment {
  /// Production default: the general pasteboard.
  static let live = backed { NSPasteboard.general }

  /// Builds the production seam over the pasteboard `pasteboard` resolves.
  ///
  /// The pasteboard is resolved on every call rather than captured, so the
  /// seam holds no AppKit reference and stays `Sendable`. `live` resolves the
  /// general pasteboard; the Tier-H probe resolves a uniquely named private
  /// pasteboard through this same factory, so it exercises exactly the code
  /// the shipped default runs.
  ///
  /// The installed SDK reports the following, and nothing more:
  ///
  /// - `accessBehavior` is a read-only property available from macOS 15.4.
  ///   Only `.alwaysDeny` is an automatic denial; `.default` asks on
  ///   programmatic access to the general pasteboard and allows others, `.ask`
  ///   asks, and `.alwaysAllow` allows. Only `.alwaysDeny` maps to
  ///   `explicitlyDenied`. Everything else, including an unknown future
  ///   behavior and every macOS before 15.4, maps to `notExplicitlyDenied`, so
  ///   the read itself stays authoritative;
  /// - `changeCount` is a read-only property;
  /// - `types` is optional, and `nil` is treated as no types;
  /// - `string(forType:)` is optional and documents no failure reason;
  /// - `clearContents()` returns the new change count and has no failure
  ///   result, so this seam always reports success for it. The count it
  ///   returns is discarded because the adapter reads the authoritative count
  ///   after the write completes. The seam's `Bool` exists so that the adapter
  ///   fails closed if a backend ever does report a refusal; and
  /// - `setString(_:forType:)` returns `Bool` and documents no failure reason.
  static func backed(by pasteboard: @escaping @Sendable () -> NSPasteboard) -> Self {
    Self(
      readAccess: {
        guard #available(macOS 15.4, *) else { return .notExplicitlyDenied }
        switch pasteboard().accessBehavior {
        case .alwaysDeny: return .explicitlyDenied
        case .default, .ask, .alwaysAllow: return .notExplicitlyDenied
        @unknown default: return .notExplicitlyDenied
        }
      },
      changeCount: { pasteboard().changeCount },
      availableTypeIdentifiers: { pasteboard().types?.map(\.rawValue) ?? [] },
      readPlainTextString: { pasteboard().string(forType: .string) },
      clearContents: {
        _ = pasteboard().clearContents()
        return true
      },
      writePlainTextString: { pasteboard().setString($0, forType: .string) }
    )
  }
}

/// Reads and writes UTF-8 plain text on the macOS pasteboard and observes its
/// change count.
///
/// The boundary is domain-only: text is `String`, limits are the M1-052
/// `ClipboardByteLimit`, generations are `MacPasteboardChangeCount`, and every
/// failure is a frozen M1-015 `CoreError`. No AppKit type appears in any
/// `package` or `public` declaration, and no public contract is added.
///
/// V1 is plain text only. Only the UTF-8 plain-text type is read or written;
/// every other representation is unsupported, and none is converted.
///
/// The adapter is an immutable `Sendable` struct. It owns no task, timer,
/// observer, queue, or cache, so there is nothing to cancel or clean up and
/// repeating a call is safe. Change-count *monitoring* is observation on
/// demand: the caller decides when to look, and the adapter never polls,
/// sleeps, or retries. Content hashing and loop suppression belong to M1-054
/// and are deliberately absent. Nothing here needs Accessibility trust, and
/// nothing is annotated `@MainActor`.
///
/// No path logs, and no failure carries text, a byte count, a type identifier,
/// or a change-count value.
package struct MacPasteboardAdapter: Sendable {
  /// The one pasteboard type this adapter reads and writes:
  /// `public.utf8-plain-text`.
  static let plainTextTypeIdentifier = NSPasteboard.PasteboardType.string.rawValue

  /// The pasteboard holds no UTF-8 plain text: it is empty, or it holds only
  /// other representations.
  ///
  /// The frozen `ClipboardErrorCode` allowlist has no separate code for an
  /// empty pasteboard, and this Issue must not extend it. Both cases mean no
  /// supported type is present, so both report `unsupportedType`. Reading the
  /// same generation again can only fail the same way, so retry is `never`; a
  /// later generation is a new read, not a retry.
  private static let noPlainTextFailure = CoreError(
    code: .clipboard(.unsupportedType),
    severity: .warning,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  /// Content exceeds the caller's UTF-8 byte budget. Identical to the value the
  /// M1-052 codec throws for oversized content.
  private static let oversizedFailure = CoreError(
    code: .clipboard(.oversized),
    severity: .warning,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  /// Reading is explicitly and automatically denied for this application.
  ///
  /// The user can change this in System Settings, so it is user-actionable and
  /// never retried automatically. Nothing was observed or read, so no cleanup
  /// is owed. No platform behavior name or value is attached.
  private static let readAccessDeniedFailure = CoreError(
    code: .permission(.capabilityUnavailable),
    severity: .error,
    retryDisposition: .userActionRequired,
    cleanupDisposition: .notRequired
  )

  /// The platform refused a pasteboard operation without a reason.
  ///
  /// Used when plain text is advertised but no string is returned, when
  /// clearing is refused, and when the string write returns `false`. The SDK
  /// documents no failure reason for any of these, so the failure is reported
  /// as unclassified rather than given a reason the platform never supplied,
  /// and no underlying diagnostic code is invented. Retry is meaningful only
  /// after a state change, and this adapter never retries on its own.
  private static let platformRefusalFailure = CoreError(
    code: .internalFailure(.unclassified),
    severity: .error,
    retryDisposition: .immediateAfterStateChange,
    cleanupDisposition: .notRequired
  )

  private let environment: MacPasteboardEnvironment

  /// Production initializer: the general pasteboard.
  package init() {
    self.init(environment: .live)
  }

  init(environment: MacPasteboardEnvironment) {
    self.environment = environment
  }

  /// Returns the pasteboard's current generation. Never mutates.
  package func currentChangeCount() -> MacPasteboardChangeCount {
    MacPasteboardChangeCount(value: environment.changeCount())
  }

  /// Reads the UTF-8 plain-text representation, or fails closed.
  ///
  /// The order is fixed:
  ///
  /// 1. fail with `permission.capabilityUnavailable` when reading is explicitly
  ///    denied, before the count, the types, or any content is observed;
  /// 2. observe the change count. It is read *before* the text, so if another
  ///    application writes concurrently the text may be newer than the
  ///    reported generation, never older: the caller sees the count move and
  ///    reads again, and no change is ever missed;
  /// 3. fail with `unsupportedType`, without reading, when no UTF-8 plain-text
  ///    type is advertised;
  /// 4. read the string, failing unclassified when none is returned; and
  /// 5. measure its UTF-8 length against `limit` and discard it if oversized.
  ///
  /// Any access behavior other than an explicit denial proceeds to the read,
  /// whose own result is authoritative. The adapter never prompts and never
  /// assumes how a prompt was answered.
  ///
  /// The platform materializes the string before it can be measured, so the
  /// limit bounds what crosses this boundary, not what AppKit allocates.
  package func readPlainText(limit: ClipboardByteLimit) -> CoreResult<MacPasteboardText> {
    guard environment.readAccess() == .notExplicitlyDenied else {
      return .failure(Self.readAccessDeniedFailure)
    }

    let changeCount = currentChangeCount()

    guard environment.availableTypeIdentifiers().contains(Self.plainTextTypeIdentifier) else {
      return .failure(Self.noPlainTextFailure)
    }

    guard let text = environment.readPlainTextString() else {
      return .failure(Self.platformRefusalFailure)
    }

    guard text.utf8.count <= limit.byteCount else {
      return .failure(Self.oversizedFailure)
    }

    return .success(MacPasteboardText(text: text, changeCount: changeCount))
  }

  /// Replaces the pasteboard's contents with `text` as UTF-8 plain text and
  /// returns the change count observed after the successful write, or fails
  /// closed.
  ///
  /// Access behavior is not consulted here. The SDK facts this Issue verified
  /// do not state that an access behavior denies writes, so blocking a write
  /// on it would invent platform behavior.
  ///
  /// The order is fixed:
  ///
  /// 1. measure the UTF-8 length against `limit`. Oversized text fails before
  ///    any pasteboard call, so the existing contents are untouched;
  /// 2. clear, and stop without writing if clearing is refused;
  /// 3. write the string, and stop without reading the count if it is
  ///    refused; and
  /// 4. read the change count. It is the count observed after the write
  ///    succeeded, not proof that the contents at that count are this write's:
  ///    another process may change the pasteboard between the write and the
  ///    read, and no platform call makes the two atomic.
  ///
  /// If the write is refused after clearing succeeded, the pasteboard is left
  /// cleared. The adapter never restores content it did not write, so the
  /// fail-closed state is empty, not partial.
  package func writePlainText(
    _ text: String,
    limit: ClipboardByteLimit
  ) -> CoreResult<MacPasteboardChangeCount> {
    guard text.utf8.count <= limit.byteCount else {
      return .failure(Self.oversizedFailure)
    }

    guard environment.clearContents() else {
      return .failure(Self.platformRefusalFailure)
    }

    guard environment.writePlainTextString(text) else {
      return .failure(Self.platformRefusalFailure)
    }

    return .success(currentChangeCount())
  }
}
