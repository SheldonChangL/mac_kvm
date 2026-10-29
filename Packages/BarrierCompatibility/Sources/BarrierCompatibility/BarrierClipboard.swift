// Barrier clipboard transfer (M2-028). The layout comes from the independently reviewed
// M2-022 evidence (BARRIER-EVID-0006 to 0008, evidence/e2e/M2-022/punctuation-clipboard.md).
//
// A transfer is three or more `DCLP` frames for one clipboard id:
//
//   DCLP id:u8 sequence:u32 mark:u8 data:string(u32 length + bytes)
//
// mark 1 (start) carries the total size as a decimal ASCII string, mark 2 (chunk)
// carries the next bytes, mark 3 (end) is empty. The transferred bytes are a
// marshalled clipboard: a u32 format count, then per format a u32 format id, a u32
// size and the content. Only format 0 is read or written, as UTF-8 text; any other
// format is ignored. All integers are big-endian. A server sends sequence 0; a client
// sends the sequence of the enter during which it copied.

/// Why a clipboard transfer was refused. Carries no clipboard bytes.
enum BarrierClipboardError: Error, Equatable, Sendable {
  /// The declared or delivered size exceeds the limit.
  case oversized
  /// The frames or the marshalled data do not follow the frozen layout.
  case malformed
}

/// One complete transfer from a peer.
struct BarrierClipboardTransfer: Equatable, Sendable {
  let id: UInt8
  let sequence: UInt32
  let data: [UInt8]
}

/// Encodes and decodes the marshalled clipboard and its `DCLP` framing.
enum BarrierClipboard {
  static let textFormat: UInt32 = 0
  /// Formats a marshalled clipboard may list; Barrier defines three.
  static let maximumFormatCount: UInt32 = 16
  static let defaultChunkSize = 32 * 1024

  private enum Mark: UInt8 {
    case start = 1
    case chunk = 2
    case end = 3
  }

  /// A marshalled clipboard holding only `text`.
  static func marshal(text: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    return bigEndian(UInt32(1)) + bigEndian(textFormat) + bigEndian(UInt32(bytes.count)) + bytes
  }

  /// The UTF-8 text format of a marshalled clipboard, or `nil` when it has
  /// none. Throws `.malformed` for a truncated layout, trailing bytes or text
  /// that is not UTF-8. The text is byte-faithful: nothing is repaired and a
  /// leading byte order mark is kept.
  static func text(fromMarshalled data: [UInt8]) throws(BarrierClipboardError) -> String? {
    var offset = 0
    let count = try readUInt32(data, &offset)
    guard count <= maximumFormatCount else { throw .malformed }
    var text: String?
    for _ in 0..<count {
      let format = try readUInt32(data, &offset)
      let size = Int(try readUInt32(data, &offset))
      guard size <= data.count - offset else { throw .malformed }
      let content = data[offset..<offset + size]
      offset += size
      if format == textFormat {
        let decoded = String(decoding: content, as: UTF8.self)
        guard decoded.utf8.elementsEqual(content) else { throw .malformed }
        text = decoded
      }
    }
    guard offset == data.count else { throw .malformed }
    return text
  }

  /// The `DCLP` frames that transfer `data` as clipboard `id`.
  static func frames(
    id: UInt8, sequence: UInt32, data: [UInt8], chunkSize: Int = defaultChunkSize
  ) -> [[UInt8]] {
    var frames = [frame(id, sequence, .start, Array(String(data.count).utf8))]
    var offset = 0
    let step = max(chunkSize, 1)
    while offset < data.count {
      let end = min(offset + step, data.count)
      frames.append(frame(id, sequence, .chunk, Array(data[offset..<end])))
      offset = end
    }
    frames.append(frame(id, sequence, .end, []))
    return frames
  }

  fileprivate static func parse(_ payload: [UInt8]) throws(BarrierClipboardError) -> (
    id: UInt8, sequence: UInt32, mark: UInt8, data: ArraySlice<UInt8>
  ) {
    guard payload.count >= 14, payload.prefix(4).elementsEqual("DCLP".utf8) else {
      throw .malformed
    }
    var offset = 5
    let sequence = try readUInt32(payload, &offset)
    let mark = payload[9]
    offset = 10
    let length = Int(try readUInt32(payload, &offset))
    guard length == payload.count - offset else { throw .malformed }
    return (payload[4], sequence, mark, payload[offset...])
  }

  private static func frame(_ id: UInt8, _ sequence: UInt32, _ mark: Mark, _ data: [UInt8])
    -> [UInt8]
  {
    let payload =
      Array("DCLP".utf8) + [id] + bigEndian(sequence) + [mark.rawValue]
      + bigEndian(UInt32(data.count)) + data
    return bigEndian(UInt32(payload.count)) + payload
  }

  private static func readUInt32(_ bytes: [UInt8], _ offset: inout Int)
    throws(BarrierClipboardError) -> UInt32
  {
    guard offset + 4 <= bytes.count else { throw .malformed }
    let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    offset += 4
    return value
  }

  private static func bigEndian(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
  }
}

/// Reassembles `DCLP` transfers, one in flight per clipboard id.
///
/// A start announces the size, chunks may not exceed it, and the end must
/// complete it exactly. A transfer that breaks any rule or the byte limit is
/// discarded and throws; the next start begins afresh.
struct BarrierClipboardAssembler: Sendable {
  private struct Pending: Sendable {
    let sequence: UInt32
    let size: Int
    var data: [UInt8]
  }

  private let limit: Int
  private var pending: [UInt8: Pending] = [:]

  init(limit: Int) {
    self.limit = max(limit, 0)
  }

  /// Feeds one `DCLP` payload (code included, length prefix excluded) and
  /// returns the transfer it completes, if any.
  mutating func receive(payload: [UInt8]) throws(BarrierClipboardError)
    -> BarrierClipboardTransfer?
  {
    let parsed = try BarrierClipboard.parse(payload)
    let id = parsed.id
    switch parsed.mark {
    case 1:
      pending[id] = nil
      guard let size = Self.decimal(parsed.data) else { throw .malformed }
      guard size <= limit else { throw .oversized }
      pending[id] = Pending(sequence: parsed.sequence, size: size, data: [])
      return nil
    case 2:
      guard var transfer = pending.removeValue(forKey: id),
        transfer.sequence == parsed.sequence,
        parsed.data.count <= transfer.size - transfer.data.count
      else { throw .malformed }
      transfer.data += parsed.data
      pending[id] = transfer
      return nil
    case 3:
      guard let transfer = pending.removeValue(forKey: id), parsed.data.isEmpty,
        transfer.sequence == parsed.sequence, transfer.data.count == transfer.size
      else { throw .malformed }
      return BarrierClipboardTransfer(id: id, sequence: transfer.sequence, data: transfer.data)
    default:
      pending[id] = nil
      throw .malformed
    }
  }

  /// A non-negative decimal ASCII number of at most ten digits.
  private static func decimal(_ digits: ArraySlice<UInt8>) -> Int? {
    guard (1...10).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
  }
}
