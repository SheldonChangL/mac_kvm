import BarrierCompatibility
import Foundation
import KVMContracts
import KVMCore
import MacPlatform

/// The server's local clipboard: the general pasteboard when serving, an
/// in-memory stand-in for the smoke driver.
protocol LocalClipboard: Sendable {
  associatedtype Generation: Hashable & Sendable
  /// The current generation; never reads the content.
  func generation() -> Generation
  /// The plain text within `limit`, or `nil` when there is none.
  func text(limit: ClipboardByteLimit) -> String?
  /// Replaces the content; the generation after the write, or `nil`.
  func write(_ text: String, limit: ClipboardByteLimit) -> Generation?
}

extension MacPasteboardAdapter: LocalClipboard {
  func generation() -> MacPasteboardChangeCount {
    currentChangeCount()
  }

  func text(limit: ClipboardByteLimit) -> String? {
    try? readPlainText(limit: limit).get().text
  }

  func write(_ text: String, limit: ClipboardByteLimit) -> MacPasteboardChangeCount? {
    try? writePlainText(text, limit: limit).get()
  }
}

/// What the runtime needs from clipboard sharing, whatever the store.
protocol ClipboardSync: Sendable {
  /// The clipboard to send to `screen` as it becomes active, if any.
  func outbound(to screen: ScreenID) -> ClipboardPayload?
  /// Applies a clipboard received from `screen`; whether it was written.
  func inbound(_ payload: ClipboardPayload, from screen: ScreenID) -> Bool
  /// Forgets a client that went away.
  func forget(_ screen: ScreenID)
}

/// Shares plain text between the local clipboard and the client through
/// `ServerClipboardRouter` (M2-032). Nothing here logs content.
final class ServerClipboard<Store: LocalClipboard>: ClipboardSync, @unchecked Sendable {
  private let store: Store
  private let limit = ClipboardByteLimit(
    byteCount: BarrierServerProtocolSession.clipboardByteLimit)!
  private let lock = NSLock()
  private var router: ServerClipboardRouter<Store.Generation>

  init(_ store: Store) {
    self.store = store
    router = ServerClipboardRouter(limit: limit)
  }

  func outbound(to screen: ScreenID) -> ClipboardPayload? {
    lock.withLock {
      router.outbound(to: screen, generation: store.generation()) { store.text(limit: limit) }
    }
  }

  func inbound(_ payload: ClipboardPayload, from screen: ScreenID) -> Bool {
    lock.withLock {
      guard let admitted = router.inbound(payload, from: screen, generation: store.generation())
      else { return false }
      guard let generation = store.write(admitted.utf8Text, limit: limit) else {
        router.applyFailed(from: screen)
        return false
      }
      router.applied(generation: generation, from: screen)
      return true
    }
  }

  func forget(_ screen: ScreenID) {
    lock.withLock { router.forget(screen) }
  }
}
