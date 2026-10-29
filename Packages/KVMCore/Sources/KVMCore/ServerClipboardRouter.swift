import KVMContracts

/// Decides which clipboard contents cross between the server's local
/// clipboard and its client screens (M2-032).
///
/// Local to client: when a client screen becomes active, the local clipboard
/// goes to it only if that client does not hold the current local generation
/// yet, so an unchanged clipboard is neither read nor sent again. Client to
/// local: a client's clipboard is admitted and handed back for the caller to
/// apply; the local generation that applying it produced is then recorded for
/// that client, so the content never travels back to it.
///
/// Every client has its own `ClipboardLoopGuard` (M1-054). Content one client
/// sent still reaches the others, while content a client already holds is
/// refused from it and not sent to it again, so several clients cannot start
/// an echo storm.
///
/// `Generation` is the caller's opaque local clipboard generation, such as a
/// pasteboard change count; only equality is used. Content hashes are
/// computed here for both directions, whatever a peer supplied: 64-bit FNV-1a
/// over the UTF-8 bytes, with the byte count. They only identify content for
/// loop suppression, are not cryptographic and never leave the router's
/// guards. The router stores no text and never logs.
package struct ServerClipboardRouter<Generation: Hashable & Sendable>: Sendable {
  private struct Client: Sendable {
    var loopGuard = ClipboardLoopGuard()
    /// The local generation this client is known to hold.
    var generation: Generation?
  }

  private let limit: ClipboardByteLimit
  private var clients: [ScreenID: Client] = [:]

  package init(limit: ClipboardByteLimit) {
    self.limit = limit
  }

  /// The payload to send to `screen` as it becomes active, or `nil` when it
  /// already holds `generation` or nothing can be sent.
  ///
  /// `read` returns the local text, or `nil` when there is none, and is
  /// called only for a generation new to this client. That generation is then
  /// recorded whatever the outcome, so a clipboard without text, an oversized
  /// one, or content the client already holds is not read again until the
  /// local clipboard changes.
  package mutating func outbound(
    to screen: ScreenID, generation: Generation, read: () -> String?
  ) -> ClipboardPayload? {
    var client = clients[screen] ?? Client()
    guard client.generation != generation else { return nil }
    client.generation = generation
    defer { clients[screen] = client }
    guard let text = read() else { return nil }
    let payload = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: text,
      contentHash: Self.contentHash(text))
    do throws(CoreError) {
      try client.loopGuard.admitOutbound(payload, limit: limit)
    } catch {
      return nil
    }
    return payload
  }

  /// Admits a clipboard received from `screen` and returns it with the
  /// router's content hash, for the caller to apply locally; `nil` when it is
  /// oversized, not of remote origin, a replayed transaction, or content this
  /// client already holds. After applying it, the caller reports the
  /// resulting local generation with `applied(generation:from:)`.
  package mutating func inbound(_ payload: ClipboardPayload, from screen: ScreenID)
    -> ClipboardPayload?
  {
    guard payload.utf8ByteCount <= limit.byteCount else { return nil }
    let hashed = ClipboardPayload(
      transactionID: payload.transactionID, origin: payload.origin, utf8Text: payload.utf8Text,
      contentHash: Self.contentHash(payload.utf8Text))
    var client = clients[screen] ?? Client()
    do throws(CoreError) {
      try client.loopGuard.admitInbound(hashed, limit: limit)
    } catch {
      return nil
    }
    clients[screen] = client
    return hashed
  }

  /// Records that applying `screen`'s clipboard produced local `generation`.
  package mutating func applied(generation: Generation, from screen: ScreenID) {
    clients[screen, default: Client()].generation = generation
  }

  /// Forgets `screen`, as when its client disconnects. Repeated calls are
  /// no-ops.
  package mutating func forget(_ screen: ScreenID) {
    clients[screen] = nil
  }

  /// 64-bit FNV-1a over the UTF-8 bytes, with the byte count.
  private static func contentHash(_ text: String) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01B3
    }
    return String(hash, radix: 16) + ":" + String(text.utf8.count)
  }
}
