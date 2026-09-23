import AppKit
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

// MARK: - Deterministic seam recording

/// One observed call into a substituted pasteboard seam, in the order it
/// happened.
///
/// The ordered log is how a test asserts both *which* pasteboard work happened
/// and *that nothing happened after a failure*. Written text is kept apart from
/// the log so that ordering assertions never depend on content.
private enum PasteboardSeamCall: Equatable {
  case readAccess
  case changeCount
  case availableTypes
  case readString
  case clear
  case setString
}

/// A type identifier no plain-text reader accepts, standing in for image, file,
/// or private application data.
private let nonTextTypeIdentifier = "com.example.mackvm.m1-053.synthetic-non-text"

/// An in-memory pasteboard that every ordinary test uses instead of a real one.
///
/// Each test owns its own instance, so tests are deterministic and safe to run
/// in parallel, and no ordinary test reads or mutates any system pasteboard.
///
/// A successful clear advances the change count and removes every type; a
/// successful string write advertises the plain-text type and does not advance
/// the count again. The adapter does not rely on either rule: it reads the count
/// through the seam after writing, and the tests compare against whatever this
/// fake reports.
///
/// The seam closures are `@Sendable`, so the fake is lock-guarded and
/// `@unchecked Sendable`. macOS 14 is the platform floor, so `NSLock` is used
/// rather than `Synchronization.Mutex`.
private final class FakePasteboard: @unchecked Sendable {
  private let lock = NSLock()
  private var count: Int
  private var types: [String]
  private var string: String?
  private var hidesAdvertisedString: Bool
  private var readAccessState: MacPasteboardReadAccess
  private var pendingClearRefusals = 0
  private var pendingWriteRefusals = 0
  private var callLog: [PasteboardSeamCall] = []
  private var writtenTexts: [String] = []

  /// - Parameters:
  ///   - changeCount: the initial change count.
  ///   - types: the type identifiers the pasteboard advertises.
  ///   - string: what a plain-text read returns while plain text is advertised.
  ///   - hidesAdvertisedString: models a pasteboard that advertises plain text
  ///     but returns no string when asked for it.
  ///   - readAccess: what the access seam reports.
  init(
    changeCount: Int = 41,
    types: [String] = [],
    string: String? = nil,
    hidesAdvertisedString: Bool = false,
    readAccess: MacPasteboardReadAccess = .notExplicitlyDenied
  ) {
    self.count = changeCount
    self.types = types
    self.string = string
    self.hidesAdvertisedString = hidesAdvertisedString
    self.readAccessState = readAccess
  }

  /// A pasteboard currently holding `text` as plain text.
  convenience init(
    holding text: String,
    changeCount: Int = 41,
    readAccess: MacPasteboardReadAccess = .notExplicitlyDenied
  ) {
    self.init(
      changeCount: changeCount,
      types: [MacPasteboardAdapter.plainTextTypeIdentifier],
      string: text,
      readAccess: readAccess
    )
  }

  var calls: [PasteboardSeamCall] { lock.withLock { callLog } }
  var written: [String] { lock.withLock { writtenTexts } }
  var currentCount: Int { lock.withLock { count } }
  var currentTypes: [String] { lock.withLock { types } }
  var currentString: String? { lock.withLock { string } }

  /// Models the user changing the application's pasteboard access in System
  /// Settings. It is not a seam call, so it never appears in the call log.
  func setReadAccess(_ access: MacPasteboardReadAccess) {
    lock.withLock { readAccessState = access }
  }

  /// Makes the next `count` clear requests report failure and change nothing.
  func refuseNextClears(_ count: Int) {
    lock.withLock { pendingClearRefusals = count }
  }

  /// Makes the next `count` string writes report failure and write nothing.
  func refuseNextWrites(_ count: Int) {
    lock.withLock { pendingWriteRefusals = count }
  }

  /// Models another application replacing the contents. It is not a seam call,
  /// so it never appears in the call log.
  func simulateExternalChange(types: [String], string: String?) {
    lock.withLock {
      count += 1
      self.types = types
      self.string = string
      hidesAdvertisedString = false
    }
  }

  var environment: MacPasteboardEnvironment {
    MacPasteboardEnvironment(
      readAccess: { self.recordReadAccess() },
      changeCount: { self.recordChangeCount() },
      availableTypeIdentifiers: { self.recordAvailableTypes() },
      readPlainTextString: { self.recordReadString() },
      clearContents: { self.recordClear() },
      writePlainTextString: { self.recordSetString($0) }
    )
  }

  private func recordReadAccess() -> MacPasteboardReadAccess {
    lock.withLock {
      callLog.append(.readAccess)
      return readAccessState
    }
  }

  private func recordChangeCount() -> Int {
    lock.withLock {
      callLog.append(.changeCount)
      return count
    }
  }

  private func recordAvailableTypes() -> [String] {
    lock.withLock {
      callLog.append(.availableTypes)
      return types
    }
  }

  private func recordReadString() -> String? {
    lock.withLock {
      callLog.append(.readString)
      guard !hidesAdvertisedString, types.contains(MacPasteboardAdapter.plainTextTypeIdentifier)
      else { return nil }
      return string
    }
  }

  private func recordClear() -> Bool {
    lock.withLock {
      callLog.append(.clear)
      if pendingClearRefusals > 0 {
        pendingClearRefusals -= 1
        return false
      }
      count += 1
      types = []
      string = nil
      return true
    }
  }

  private func recordSetString(_ text: String) -> Bool {
    lock.withLock {
      callLog.append(.setString)
      if pendingWriteRefusals > 0 {
        pendingWriteRefusals -= 1
        return false
      }
      writtenTexts.append(text)
      types = [MacPasteboardAdapter.plainTextTypeIdentifier]
      string = text
      return true
    }
  }
}

private func makeAdapter(_ pasteboard: FakePasteboard) -> MacPasteboardAdapter {
  MacPasteboardAdapter(environment: pasteboard.environment)
}

private func byteLimit(_ byteCount: Int) throws -> ClipboardByteLimit {
  try #require(ClipboardByteLimit(byteCount: byteCount))
}

/// Private-looking text with one-, two-, three-, and four-byte UTF-8 scalars
/// and words that appear nowhere else, so a privacy test can prove none of it
/// reaches an error, a description, or a log line.
private let privateText = "OPAL-WALRUS-7731 caf\u{00E9} \u{4E2D}\u{6587} \u{1F511}"

/// Texts whose UTF-8 byte count differs from their character count, plus the
/// empty string and pure ASCII.
private let boundaryTexts = [
  "",
  "a",
  "plain ascii",
  "\u{00E9}",
  "\u{4E2D}\u{4E2D}",
  "\u{1F511}",
  "e\u{0301}",
  privateText,
]

// MARK: - Plain-text type

@Test func pasteboardPlainTextTypeIsTheUTF8PlainTextIdentifier() {
  #expect(MacPasteboardAdapter.plainTextTypeIdentifier == "public.utf8-plain-text")
}

// MARK: - Happy path

@Test func pasteboardReadObservesTheChangeCountThenReadsPlainText() throws {
  let pasteboard = FakePasteboard(holding: privateText, changeCount: 58)
  let adapter = makeAdapter(pasteboard)

  let read = try adapter.readPlainText(limit: byteLimit(privateText.utf8.count)).get()

  #expect(read.text == privateText)
  #expect(read.changeCount == MacPasteboardChangeCount(value: 58))

  // The count is observed before the text, so a concurrent copy can only make
  // the caller read again later; it can never label newer text as older.
  #expect(pasteboard.calls == [.readAccess, .changeCount, .availableTypes, .readString])
}

@Test func pasteboardWriteClearsWritesAndReportsTheCountObservedAfterWriting() throws {
  let pasteboard = FakePasteboard(changeCount: 41)
  let adapter = makeAdapter(pasteboard)

  let limit = try byteLimit(privateText.utf8.count)
  let count = try adapter.writePlainText(privateText, limit: limit).get()

  #expect(pasteboard.calls == [.clear, .setString, .changeCount])
  #expect(pasteboard.written == [privateText])
  #expect(pasteboard.currentString == privateText)
  #expect(pasteboard.currentTypes == [MacPasteboardAdapter.plainTextTypeIdentifier])
  #expect(count == MacPasteboardChangeCount(value: pasteboard.currentCount))
  #expect(count != MacPasteboardChangeCount(value: 41))
}

@Test func pasteboardWriteThenReadRoundTripsTheSameTextAndGeneration() throws {
  let pasteboard = FakePasteboard()
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(privateText.utf8.count)

  let written = try adapter.writePlainText(privateText, limit: limit).get()
  let read = try adapter.readPlainText(limit: limit).get()

  #expect(read.text == privateText)
  #expect(read.changeCount == written)
  #expect(adapter.currentChangeCount() == written)
}

@Test func pasteboardEmptyTextIsValidPlainTextInBothDirections() throws {
  let pasteboard = FakePasteboard(holding: "non-empty")
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(1)

  _ = try adapter.writePlainText("", limit: limit).get()
  #expect(pasteboard.currentString == "")
  #expect(pasteboard.currentTypes == [MacPasteboardAdapter.plainTextTypeIdentifier])

  #expect(try adapter.readPlainText(limit: limit).get().text == "")
}

// MARK: - UTF-8 byte limit

@Test(arguments: boundaryTexts)
func pasteboardReadAcceptsTextAtExactlyTheByteLimitAndRejectsOneByteOver(text: String) throws {
  let exact = try makeAdapter(FakePasteboard(holding: text))
    .readPlainText(limit: byteLimit(max(text.utf8.count, 1)))
  #expect(try exact.get().text == text)

  guard text.utf8.count > 1 else { return }
  let pasteboard = FakePasteboard(holding: text)
  let over = makeAdapter(pasteboard).readPlainText(limit: try byteLimit(text.utf8.count - 1))

  guard case .failure(let error) = over else {
    Issue.record("expected an oversized failure one byte below the text's UTF-8 length")
    return
  }
  expectOversized(error)
  // The text was read, measured, and discarded; nothing was written back.
  #expect(pasteboard.calls == [.readAccess, .changeCount, .availableTypes, .readString])
  #expect(pasteboard.currentString == text)
}

@Test(arguments: boundaryTexts)
func pasteboardWriteAcceptsTextAtExactlyTheByteLimitAndRejectsOneByteOverBeforeTouchingIt(
  text: String
) throws {
  let accepting = FakePasteboard()
  _ = try makeAdapter(accepting)
    .writePlainText(text, limit: byteLimit(max(text.utf8.count, 1))).get()
  #expect(accepting.written == [text])

  guard text.utf8.count > 1 else { return }
  let pasteboard = FakePasteboard(holding: "prior", changeCount: 7)
  let over = makeAdapter(pasteboard).writePlainText(text, limit: try byteLimit(text.utf8.count - 1))

  guard case .failure(let error) = over else {
    Issue.record("expected an oversized failure one byte below the text's UTF-8 length")
    return
  }
  expectOversized(error)
  // Size is checked first: the existing contents are neither cleared nor
  // replaced, and the count is not even read.
  #expect(pasteboard.calls.isEmpty)
  #expect(pasteboard.currentString == "prior")
  #expect(pasteboard.currentCount == 7)
}

/// The limit is UTF-8 bytes, never characters: two CJK characters are six
/// bytes, so every budget from two to five bytes rejects them.
@Test(arguments: 2...5)
func pasteboardLimitCountsUTF8BytesNotCharacters(byteCount: Int) throws {
  let text = "\u{4E2D}\u{4E2D}"
  let limit = try byteLimit(byteCount)

  let read = makeAdapter(FakePasteboard(holding: text)).readPlainText(limit: limit)
  let write = makeAdapter(FakePasteboard()).writePlainText(text, limit: limit)

  #expect(read.failure == oversizedReference())
  #expect(write.failure == oversizedReference())
}

/// The adapter reports oversize with exactly the value the M1-052 codec throws,
/// so a caller sees one oversize shape whichever layer rejected the content.
@Test func pasteboardOversizedFailureMatchesTheM1052CodecFailure() throws {
  let limit = try byteLimit(1)
  var codecError: CoreError?
  do {
    _ = try ClipboardTextCodec.encode("ab", limit: limit)
  } catch let error as CoreError {
    codecError = error
  }

  let adapterError = makeAdapter(FakePasteboard()).writePlainText("ab", limit: limit).failure
  #expect(codecError != nil)
  #expect(adapterError == codecError)
}

// MARK: - Empty, unsupported, and unreadable content

@Test func pasteboardEmptyPasteboardReadIsATypedUnsupportedFailureWithoutReadingAString() {
  let pasteboard = FakePasteboard(types: [])
  let result = makeAdapter(pasteboard).readPlainText(limit: ClipboardByteLimit(byteCount: 64)!)

  guard case .failure(let error) = result else {
    Issue.record("expected a typed failure for an empty pasteboard")
    return
  }
  expectNoPlainText(error)
  #expect(pasteboard.calls == [.readAccess, .changeCount, .availableTypes])
}

@Test(
  arguments: [
    [nonTextTypeIdentifier],
    ["public.png"],
    ["public.file-url", "public.tiff"],
    ["public.utf16-plain-text"],
    ["public.rtf", "public.html"],
  ]
)
func pasteboardNonPlainTextContentIsATypedUnsupportedFailureWithoutReadingAString(
  types: [String]
) {
  let pasteboard = FakePasteboard(types: types, string: privateText)
  let result = makeAdapter(pasteboard).readPlainText(limit: ClipboardByteLimit(byteCount: 4096)!)

  guard case .failure(let error) = result else {
    Issue.record("expected a typed failure when no UTF-8 plain-text type is advertised")
    return
  }
  expectNoPlainText(error)
  #expect(pasteboard.calls == [.readAccess, .changeCount, .availableTypes])
}

/// Plain text advertised alongside other types is still read: the adapter
/// selects the UTF-8 plain-text representation and ignores the rest.
@Test func pasteboardPlainTextAlongsideOtherTypesIsRead() throws {
  let pasteboard = FakePasteboard(
    types: ["public.rtf", MacPasteboardAdapter.plainTextTypeIdentifier, "public.png"],
    string: privateText
  )

  let read = try makeAdapter(pasteboard).readPlainText(limit: byteLimit(privateText.utf8.count))
    .get()
  #expect(read.text == privateText)
}

@Test func pasteboardAdvertisedPlainTextThatCannotBeReadIsATypedUnclassifiedFailure() {
  let pasteboard = FakePasteboard(
    types: [MacPasteboardAdapter.plainTextTypeIdentifier],
    string: privateText,
    hidesAdvertisedString: true
  )
  let result = makeAdapter(pasteboard).readPlainText(limit: ClipboardByteLimit(byteCount: 4096)!)

  guard case .failure(let error) = result else {
    Issue.record("expected a typed failure when advertised plain text cannot be read")
    return
  }
  // The platform returns no string and no reason, so none is invented.
  expectUnclassifiedPlatformRefusal(error)
  #expect(pasteboard.calls == [.readAccess, .changeCount, .availableTypes, .readString])
}

// MARK: - Read access

@Test func pasteboardExplicitReadDenialFailsClosedBeforeAnyObservation() {
  let pasteboard = FakePasteboard(holding: privateText, readAccess: .explicitlyDenied)
  let result = makeAdapter(pasteboard).readPlainText(limit: ClipboardByteLimit(byteCount: 4096)!)

  guard case .failure(let error) = result else {
    Issue.record("expected the frozen permission failure while reading is explicitly denied")
    return
  }
  #expect(error == readAccessDeniedReference())
  #expect(error.code == .permission(.capabilityUnavailable))
  #expect(error.domain == .permission)
  #expect(error.severity == .error)
  #expect(error.retryDisposition == .userActionRequired)
  #expect(error.retryDisposition.allowsAutomaticRetry == false)
  #expect(error.cleanupDisposition == .notRequired)
  #expect(error.underlyingDiagnosticCode == nil)

  // Denial stops everything: no count, no types, no content, no mutation.
  #expect(pasteboard.calls == [.readAccess])
  #expect(pasteboard.currentString == privateText)
}

/// Every non-denied answer — including the legacy answer before macOS 15.4 —
/// proceeds to the read, and the read's own result stays authoritative.
@Test func pasteboardReadThatIsNotExplicitlyDeniedProceedsAndTheReadDecides() throws {
  let allowed = FakePasteboard(holding: privateText, readAccess: .notExplicitlyDenied)
  let read = try makeAdapter(allowed).readPlainText(limit: byteLimit(privateText.utf8.count))
    .get()
  #expect(read.text == privateText)
  #expect(allowed.calls == [.readAccess, .changeCount, .availableTypes, .readString])

  // A read the platform refuses without a standing denial is not reported as
  // a permission failure: no reason is invented.
  let refused = FakePasteboard(
    types: [MacPasteboardAdapter.plainTextTypeIdentifier],
    string: privateText,
    hidesAdvertisedString: true,
    readAccess: .notExplicitlyDenied
  )
  #expect(
    makeAdapter(refused).readPlainText(limit: try byteLimit(4096)).failure
      == unclassifiedReference()
  )
}

@Test func pasteboardReadDenialLatchesNothingAndRecoversOnTheNextCall() throws {
  let pasteboard = FakePasteboard(holding: privateText, readAccess: .explicitlyDenied)
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(privateText.utf8.count)

  #expect(adapter.readPlainText(limit: limit).failure == readAccessDeniedReference())
  #expect(adapter.readPlainText(limit: limit).failure == readAccessDeniedReference())

  pasteboard.setReadAccess(.notExplicitlyDenied)
  #expect(try adapter.readPlainText(limit: limit).get().text == privateText)

  pasteboard.setReadAccess(.explicitlyDenied)
  #expect(adapter.readPlainText(limit: limit).failure == readAccessDeniedReference())

  // Each call asked exactly once; nothing was retried or cached.
  #expect(
    pasteboard.calls == [
      .readAccess,
      .readAccess,
      .readAccess, .changeCount, .availableTypes, .readString,
      .readAccess,
    ]
  )
}

/// Read access governs reads only. Writes and change-count observation never
/// consult it, so neither is blocked by it.
@Test func pasteboardReadDenialDoesNotBlockWritesOrChangeCountObservation() throws {
  let pasteboard = FakePasteboard(changeCount: 5, readAccess: .explicitlyDenied)
  let adapter = makeAdapter(pasteboard)

  #expect(adapter.currentChangeCount() == MacPasteboardChangeCount(value: 5))
  _ = try adapter.writePlainText("x", limit: byteLimit(1)).get()
  #expect(pasteboard.currentString == "x")
  #expect(pasteboard.calls == [.changeCount, .clear, .setString, .changeCount])
}

// MARK: - Write failures and ordering

@Test func pasteboardClearFailureStopsBeforeAnyStringIsWritten() {
  let pasteboard = FakePasteboard(holding: "prior", changeCount: 9)
  pasteboard.refuseNextClears(1)

  let result = makeAdapter(pasteboard).writePlainText(
    privateText,
    limit: ClipboardByteLimit(byteCount: 4096)!
  )

  guard case .failure(let error) = result else {
    Issue.record("expected a typed failure when clearing is refused")
    return
  }
  expectUnclassifiedPlatformRefusal(error)
  #expect(pasteboard.calls == [.clear])
  #expect(pasteboard.written.isEmpty)
  #expect(pasteboard.currentString == "prior")
  #expect(pasteboard.currentCount == 9)
}

@Test func pasteboardStringWriteFailureReportsNoGenerationAndLeavesThePasteboardCleared() {
  let pasteboard = FakePasteboard(holding: "prior")
  pasteboard.refuseNextWrites(1)

  let result = makeAdapter(pasteboard).writePlainText(
    privateText,
    limit: ClipboardByteLimit(byteCount: 4096)!
  )

  guard case .failure(let error) = result else {
    Issue.record("expected a typed failure when the string write is refused")
    return
  }
  expectUnclassifiedPlatformRefusal(error)
  // No count is read after a refused write, because no generation of this
  // adapter's own content exists to report.
  #expect(pasteboard.calls == [.clear, .setString])
  #expect(pasteboard.written.isEmpty)

  // Clearing already happened and is not undone. The adapter restores nothing
  // it did not write, so the pasteboard is left empty rather than partial.
  #expect(pasteboard.currentString == nil)
  #expect(pasteboard.currentTypes.isEmpty)
}

// MARK: - Change count observation

@Test func pasteboardChangeCountObservationReadsOnlyTheCountAndTracksEveryChange() throws {
  let pasteboard = FakePasteboard(changeCount: 100)
  let adapter = makeAdapter(pasteboard)

  let first = adapter.currentChangeCount()
  let second = adapter.currentChangeCount()
  #expect(first == MacPasteboardChangeCount(value: 100))
  #expect(second == first)
  #expect(pasteboard.calls == [.changeCount, .changeCount])

  pasteboard.simulateExternalChange(types: [nonTextTypeIdentifier], string: nil)
  let afterExternal = adapter.currentChangeCount()
  #expect(afterExternal != first)

  let written = try adapter.writePlainText("x", limit: byteLimit(1)).get()
  #expect(written != afterExternal)
  #expect(adapter.currentChangeCount() == written)

  // Observation never mutates: only the write cleared and set.
  #expect(pasteboard.calls.filter { $0 == .clear }.count == 1)
  #expect(pasteboard.calls.filter { $0 == .setString }.count == 1)
}

// MARK: - Repetition, idempotency, and recovery

@Test func pasteboardRepeatedReadsAreIdempotentAndNeverMutate() throws {
  let pasteboard = FakePasteboard(holding: privateText, changeCount: 12)
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(privateText.utf8.count)

  let reads = try (0..<3).map { _ in try adapter.readPlainText(limit: limit).get() }

  #expect(reads.allSatisfy { $0 == reads[0] })
  #expect(reads[0].changeCount == MacPasteboardChangeCount(value: 12))
  #expect(pasteboard.calls.contains(.clear) == false)
  #expect(pasteboard.calls.contains(.setString) == false)
  #expect(pasteboard.currentCount == 12)
}

@Test func pasteboardRepeatedWritesEachClearAndWriteExactlyOnceInOrder() throws {
  let pasteboard = FakePasteboard()
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(8)

  _ = try adapter.writePlainText("one", limit: limit).get()
  _ = try adapter.writePlainText("one", limit: limit).get()
  _ = try adapter.writePlainText("two", limit: limit).get()

  let oneWrite: [PasteboardSeamCall] = [.clear, .setString, .changeCount]
  #expect(pasteboard.calls == oneWrite + oneWrite + oneWrite)
  #expect(pasteboard.written == ["one", "one", "two"])
  #expect(pasteboard.currentString == "two")
}

/// A failure latches nothing: the next call starts from scratch and succeeds
/// once the platform accepts it, without the adapter sleeping or retrying.
@Test func pasteboardFailuresLatchNothingAndTheNextCallRecovers() throws {
  let pasteboard = FakePasteboard()
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(64)

  pasteboard.refuseNextClears(1)
  #expect(adapter.writePlainText("after clear", limit: limit).failure != nil)
  #expect(pasteboard.calls == [.clear])
  _ = try adapter.writePlainText("after clear", limit: limit).get()
  #expect(pasteboard.currentString == "after clear")

  pasteboard.refuseNextWrites(1)
  #expect(adapter.writePlainText("after write", limit: limit).failure != nil)
  _ = try adapter.writePlainText("after write", limit: limit).get()
  #expect(pasteboard.currentString == "after write")
  #expect(pasteboard.written == ["after clear", "after write"])

  #expect(adapter.writePlainText(String(repeating: "x", count: 65), limit: limit).failure != nil)
  #expect(try adapter.readPlainText(limit: limit).get().text == "after write")

  // Each failed call issued exactly one attempt: nothing was retried.
  #expect(
    pasteboard.calls == [
      .clear,
      .clear, .setString, .changeCount,
      .clear, .setString,
      .clear, .setString, .changeCount,
      .readAccess, .changeCount, .availableTypes, .readString,
    ]
  )
}

@Test func pasteboardUnreadableOrUnsupportedContentRecoversAfterTheNextChange() throws {
  let pasteboard = FakePasteboard(
    types: [MacPasteboardAdapter.plainTextTypeIdentifier],
    string: "hidden",
    hidesAdvertisedString: true
  )
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(64)

  #expect(adapter.readPlainText(limit: limit).failure == unclassifiedReference())

  pasteboard.simulateExternalChange(types: [nonTextTypeIdentifier], string: nil)
  #expect(adapter.readPlainText(limit: limit).failure == noPlainTextReference())

  pasteboard.simulateExternalChange(
    types: [MacPasteboardAdapter.plainTextTypeIdentifier],
    string: "visible"
  )
  #expect(try adapter.readPlainText(limit: limit).get().text == "visible")
}

// MARK: - Non-MainActor invocation

/// Reads the executing thread synchronously, because `Thread.isMainThread` is
/// unavailable from an asynchronous context.
private func pasteboardTestIsOnMainThread() -> Bool {
  Thread.isMainThread
}

@Test func pasteboardAdapterRunsOnADetachedNonMainActorTask() async throws {
  let pasteboard = FakePasteboard()
  let adapter = makeAdapter(pasteboard)
  let limit = try byteLimit(64)

  let observed = await Task.detached {
    (
      onMainThread: pasteboardTestIsOnMainThread(),
      write: adapter.writePlainText("detached", limit: limit),
      read: adapter.readPlainText(limit: limit)
    )
  }.value

  #expect(observed.onMainThread == false)
  #expect(try observed.read.get().text == "detached")
  #expect(try observed.read.get().changeCount == observed.write.get())
}

// MARK: - Privacy

@Test func pasteboardEveryFailureEncodesToTheClosedTaxonomyWithoutContent() throws {
  let unreadable = FakePasteboard(
    types: [MacPasteboardAdapter.plainTextTypeIdentifier],
    string: privateText,
    hidesAdvertisedString: true
  )
  let clearRefusing = FakePasteboard(holding: privateText)
  clearRefusing.refuseNextClears(1)
  let writeRefusing = FakePasteboard(holding: privateText)
  writeRefusing.refuseNextWrites(1)
  let small = try byteLimit(4)
  let large = try byteLimit(4096)

  let failures: [CoreError?] = [
    makeAdapter(FakePasteboard(holding: privateText)).readPlainText(limit: small).failure,
    makeAdapter(FakePasteboard()).writePlainText(privateText, limit: small).failure,
    makeAdapter(FakePasteboard(types: [])).readPlainText(limit: large).failure,
    makeAdapter(FakePasteboard(types: [nonTextTypeIdentifier], string: privateText))
      .readPlainText(limit: large).failure,
    makeAdapter(unreadable).readPlainText(limit: large).failure,
    makeAdapter(clearRefusing).writePlainText(privateText, limit: large).failure,
    makeAdapter(writeRefusing).writePlainText(privateText, limit: large).failure,
    makeAdapter(FakePasteboard(holding: privateText, readAccess: .explicitlyDenied))
      .readPlainText(limit: large).failure,
  ]

  for failure in failures {
    let error = try #require(failure)
    #expect(error.underlyingDiagnosticCode == nil)

    let encoded = try JSONEncoder().encode(error)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == ["code", "severity", "retryDisposition", "cleanupDisposition"])

    let renderings = [
      try #require(String(data: encoded, encoding: .utf8)),
      String(describing: error),
      String(reflecting: error),
    ]
    for rendering in renderings {
      for forbidden in privateTextFragments + platformNames {
        #expect(!rendering.contains(forbidden), "a failure rendering carries \(forbidden)")
      }
    }
  }
}

@Test func pasteboardReadTextNeverRendersItsContent() throws {
  let result = makeAdapter(FakePasteboard(holding: privateText))
    .readPlainText(limit: try byteLimit(privateText.utf8.count))
  let read = try result.get()

  var dumped = ""
  dump(read, to: &dumped)
  var dumpedResult = ""
  dump(result, to: &dumpedResult)

  let renderings = [
    String(describing: read),
    String(reflecting: read),
    "\(read)",
    String(describing: result),
    String(reflecting: result),
    dumped,
    dumpedResult,
  ]
  for rendering in renderings {
    for forbidden in privateTextFragments {
      #expect(!rendering.contains(forbidden), "a read rendering carries \(forbidden)")
    }
  }
  #expect(Mirror(reflecting: read).children.isEmpty)

  // The value itself still carries the text for the caller that asked for it.
  #expect(read.text == privateText)
}

private let privateTextFragments = ["OPAL", "WALRUS", "7731", "caf", "\u{4E2D}", "\u{1F511}"]

private let platformNames = [
  "NSPaste" + "board", "public.", "utf8-plain", "changeCount", "clearContents", "setString",
  "accessBehavior", "alwaysDeny", "explicitlyDenied",
]

// MARK: - Expected failure shapes

private func oversizedReference() -> CoreError {
  CoreError(
    code: .clipboard(.oversized),
    severity: .warning,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )
}

private func noPlainTextReference() -> CoreError {
  CoreError(
    code: .clipboard(.unsupportedType),
    severity: .warning,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )
}

private func readAccessDeniedReference() -> CoreError {
  CoreError(
    code: .permission(.capabilityUnavailable),
    severity: .error,
    retryDisposition: .userActionRequired,
    cleanupDisposition: .notRequired
  )
}

private func unclassifiedReference() -> CoreError {
  CoreError(
    code: .internalFailure(.unclassified),
    severity: .error,
    retryDisposition: .immediateAfterStateChange,
    cleanupDisposition: .notRequired
  )
}

private func expectOversized(_ error: CoreError) {
  #expect(error == oversizedReference())
  #expect(error.domain == .clipboard)
  #expect(error.retryDisposition.allowsRetry == false)
  #expect(error.underlyingDiagnosticCode == nil)
}

private func expectNoPlainText(_ error: CoreError) {
  #expect(error == noPlainTextReference())
  #expect(error.domain == .clipboard)
  #expect(error.retryDisposition.allowsRetry == false)
  #expect(error.underlyingDiagnosticCode == nil)
}

private func expectUnclassifiedPlatformRefusal(_ error: CoreError) {
  #expect(error == unclassifiedReference())
  #expect(error.domain == .internalFailure)
  #expect(error.retryDisposition.allowsAutomaticRetry == true)
  #expect(error.underlyingDiagnosticCode == nil)
}

extension Result {
  fileprivate var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}

// MARK: - Tier-H manual probe vocabulary and sequencing

/// The exact action names the manual probe accepts. Anything else is refused.
private enum ManualPasteboardProbeAction: String, CaseIterable {
  /// Writes, reads, and clears one synthetic marker on a private, uniquely
  /// named pasteboard that no other application uses.
  case uniquePasteboardRoundTrip = "unique-pasteboard-round-trip"
}

private enum ManualPasteboardProbeSelection: Equatable {
  case notSelected
  case selected(ManualPasteboardProbeAction)
  case unknown
}

/// Parses the reviewer's selection, failing closed on anything unrecognized.
private func manualPasteboardProbeSelection(
  from rawValue: String?
) -> ManualPasteboardProbeSelection {
  guard let rawValue else { return .notSelected }
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return .notSelected }
  guard let action = ManualPasteboardProbeAction(rawValue: trimmed) else { return .unknown }
  return .selected(action)
}

/// The fixed synthetic text the probe writes. It is never printed; the probe
/// only reports whether the read-back matched it.
private let manualProbeMarker = "MacKVM M1-053 synthetic marker caf\u{00E9} \u{4E2D} \u{1F511}"

/// A private type identifier the probe uses to seed non-text content.
private let manualProbeNonTextType = "com.jet-opto.mackvm.m1-053.probe-non-text"

/// What one probe read reported, in closed vocabulary only.
private enum ManualPasteboardReadState: Equatable {
  case notAttempted
  case markerMatched
  case markerMismatched
  case failed(CoreError)

  init(_ result: CoreResult<MacPasteboardText>) {
    switch result {
    case .success(let read):
      self = read.text == manualProbeMarker ? .markerMatched : .markerMismatched
    case .failure(let error): self = .failed(error)
    }
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .markerMatched: "markerMatched"
    case .markerMismatched: "markerMismatched"
    case .failed(let error): sanitizedPasteboardFailureName(error)
    }
  }
}

/// What one probe write reported, in closed vocabulary only.
private enum ManualPasteboardWriteState: Equatable {
  case notAttempted
  case written
  case failed(CoreError)

  init(_ result: CoreResult<MacPasteboardChangeCount>) {
    switch result {
    case .success: self = .written
    case .failure(let error): self = .failed(error)
    }
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .written: "written"
    case .failed(let error): sanitizedPasteboardFailureName(error)
    }
  }
}

/// How two observed change counts relate. The value itself is never reported.
private enum ManualChangeCountRelation: String {
  case notObserved
  case equal
  case different

  init(_ lhs: MacPasteboardChangeCount?, _ rhs: MacPasteboardChangeCount?) {
    guard let lhs, let rhs else {
      self = .notObserved
      return
    }
    self = lhs == rhs ? .equal : .different
  }
}

private struct ManualPasteboardProbeResult: Equatable {
  var initialRead: ManualPasteboardReadState = .notAttempted
  var markerWrite: ManualPasteboardWriteState = .notAttempted
  var writeCountVersusInitial: ManualChangeCountRelation = .notObserved
  var readBack: ManualPasteboardReadState = .notAttempted
  var readCountVersusWrite: ManualChangeCountRelation = .notObserved
  var oversizedWrite: ManualPasteboardWriteState = .notAttempted
  var countAfterOversizedVersusWrite: ManualChangeCountRelation = .notObserved
  var readAfterOversized: ManualPasteboardReadState = .notAttempted
  var nonTextRead: ManualPasteboardReadState = .notAttempted
  var clearedRead: ManualPasteboardReadState = .notAttempted
}

/// The result a correct adapter produces on a fresh, empty pasteboard.
private let expectedManualPasteboardProbeResult = ManualPasteboardProbeResult(
  initialRead: .failed(noPlainTextReference()),
  markerWrite: .written,
  writeCountVersusInitial: .different,
  readBack: .markerMatched,
  readCountVersusWrite: .equal,
  oversizedWrite: .failed(oversizedReference()),
  countAfterOversizedVersusWrite: .equal,
  readAfterOversized: .markerMatched,
  nonTextRead: .failed(noPlainTextReference()),
  clearedRead: .failed(noPlainTextReference())
)

/// Runs every probe step once, in a fixed order, against `adapter`.
///
/// `seedNonText` and `clearDirectly` change the backing pasteboard outside the
/// adapter, the way another application would. No step sleeps, polls, or
/// retries, and every step runs even if an earlier one failed, so the output
/// names each step's own outcome. Ordinary tests pass the in-memory fake; only
/// the opt-in probe passes a real private pasteboard.
private func performManualPasteboardProbe(
  adapter: MacPasteboardAdapter,
  seedNonText: () -> Void,
  clearDirectly: () -> Void
) throws -> ManualPasteboardProbeResult {
  let exact = try byteLimit(manualProbeMarker.utf8.count)
  let oneByteShort = try byteLimit(manualProbeMarker.utf8.count - 1)
  var result = ManualPasteboardProbeResult()

  let initialCount = adapter.currentChangeCount()
  result.initialRead = ManualPasteboardReadState(adapter.readPlainText(limit: exact))

  let write = adapter.writePlainText(manualProbeMarker, limit: exact)
  result.markerWrite = ManualPasteboardWriteState(write)
  let writeCount = try? write.get()
  result.writeCountVersusInitial = ManualChangeCountRelation(writeCount, initialCount)

  let readBack = adapter.readPlainText(limit: exact)
  result.readBack = ManualPasteboardReadState(readBack)
  result.readCountVersusWrite = ManualChangeCountRelation(
    try? readBack.get().changeCount,
    writeCount
  )

  result.oversizedWrite = ManualPasteboardWriteState(
    adapter.writePlainText(manualProbeMarker, limit: oneByteShort)
  )
  result.countAfterOversizedVersusWrite = ManualChangeCountRelation(
    adapter.currentChangeCount(),
    writeCount
  )
  result.readAfterOversized = ManualPasteboardReadState(adapter.readPlainText(limit: exact))

  seedNonText()
  result.nonTextRead = ManualPasteboardReadState(adapter.readPlainText(limit: exact))

  clearDirectly()
  result.clearedRead = ManualPasteboardReadState(adapter.readPlainText(limit: exact))

  return result
}

/// Renders the one sanitized line the reviewer transcribes into `manual.md`.
///
/// Every field is a closed enum case or a closed `CoreError` taxonomy name. No
/// clipboard text, byte, hash, count value, or platform string can reach this
/// output, because no such value is passed to it.
private func manualPasteboardProbeLine(
  action: ManualPasteboardProbeAction,
  result: ManualPasteboardProbeResult
) -> String {
  let fields = [
    "action=\(action.rawValue)",
    "initialRead=\(result.initialRead.closedName)",
    "markerWrite=\(result.markerWrite.closedName)",
    "writeCountVsInitial=\(result.writeCountVersusInitial.rawValue)",
    "readBack=\(result.readBack.closedName)",
    "readCountVsWrite=\(result.readCountVersusWrite.rawValue)",
    "oversizedWrite=\(result.oversizedWrite.closedName)",
    "countAfterOversizedVsWrite=\(result.countAfterOversizedVersusWrite.rawValue)",
    "readAfterOversized=\(result.readAfterOversized.closedName)",
    "nonTextRead=\(result.nonTextRead.closedName)",
    "clearedRead=\(result.clearedRead.closedName)",
  ]
  return "M1-053 manual probe: " + fields.joined(separator: " ")
}

/// Maps a failure to a closed taxonomy name, never to platform text.
private func sanitizedPasteboardFailureName(_ error: CoreError) -> String {
  switch error.code {
  case .clipboard(let code): "clipboard.\(code.rawValue)"
  case .permission(let code): "permission.\(code.rawValue)"
  case .internalFailure(let code): "internal.\(code.rawValue)"
  default: "unexpectedDomain.\(error.domain.rawValue)"
  }
}

@Test func manualPasteboardProbeSelectionFailsClosedAndIsSkippedByDefault() {
  #expect(manualPasteboardProbeSelection(from: nil) == .notSelected)
  #expect(manualPasteboardProbeSelection(from: "") == .notSelected)
  #expect(manualPasteboardProbeSelection(from: " \n") == .notSelected)

  #expect(
    manualPasteboardProbeSelection(from: " unique-pasteboard-round-trip ")
      == .selected(.uniquePasteboardRoundTrip)
  )

  for rejected in ["general", "round-trip", "Unique-Pasteboard-Round-Trip", "1", "write"] {
    #expect(manualPasteboardProbeSelection(from: rejected) == .unknown)
  }

  #expect(ManualPasteboardProbeAction.allCases.map(\.rawValue) == ["unique-pasteboard-round-trip"])
}

@Test func manualPasteboardProbeSequenceProducesTheExpectedClosedResultOnAFake() throws {
  let pasteboard = FakePasteboard(types: [])
  let result = try performManualPasteboardProbe(
    adapter: makeAdapter(pasteboard),
    seedNonText: {
      pasteboard.simulateExternalChange(types: [manualProbeNonTextType], string: nil)
    },
    clearDirectly: { pasteboard.simulateExternalChange(types: [], string: nil) }
  )

  #expect(result == expectedManualPasteboardProbeResult)

  // Only the one exact-limit marker write reached the pasteboard.
  #expect(pasteboard.written == [manualProbeMarker])
  #expect(pasteboard.calls.filter { $0 == .clear }.count == 1)

  let expectedLine = """
    M1-053 manual probe: action=unique-pasteboard-round-trip \
    initialRead=clipboard.unsupportedType markerWrite=written writeCountVsInitial=different \
    readBack=markerMatched readCountVsWrite=equal oversizedWrite=clipboard.oversized \
    countAfterOversizedVsWrite=equal readAfterOversized=markerMatched \
    nonTextRead=clipboard.unsupportedType clearedRead=clipboard.unsupportedType
    """
  let line = manualPasteboardProbeLine(action: .uniquePasteboardRoundTrip, result: result)
  #expect(line == expectedLine)
  for forbidden in ["MacKVM M1-053 synthetic", "marker caf", "\u{4E2D}", "\u{1F511}"] {
    #expect(!line.contains(forbidden))
  }
}

/// A mismatched read-back is reported by name only, never by content.
@Test func manualPasteboardProbeReportsAMismatchWithoutTheText() throws {
  let state = ManualPasteboardReadState(
    makeAdapter(FakePasteboard(holding: privateText)).readPlainText(limit: try byteLimit(4096))
  )
  #expect(state == .markerMismatched)
  #expect(state.closedName == "markerMismatched")
}

// MARK: - Source ownership audit

/// Static source audit of this file. **It proves what the source names, not
/// what runs.**
///
/// The file is split at the one line that opens the Tier-H live region. Every
/// ordinary test lives above it, and the text above it, comments included,
/// names no platform pasteboard type, no general pasteboard, no production
/// seam, and no production initializer. Below it, the live region names only a
/// uniquely named pasteboard, releases it, holds exactly one test, and never
/// names the general pasteboard or the production initializer either.
///
/// Each token is assembled from two literals, so the audit's own source never
/// contains a token it forbids.
@Test func onlyTheTierHLiveRegionNamesARealPasteboard() throws {
  let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
  let regions = source.components(separatedBy: "// MARK: - Tier-H " + "live region")
  try #require(regions.count == 2, "the live region must open exactly once")
  let ordinary = regions[0]
  let live = regions[1]

  let ordinaryForbidden = [
    "NSPaste" + "board",
    "." + "general",
    "." + "live",
    "." + "backed",
    "withUnique" + "Name",
    "MacPasteboardAdapter" + "()",
  ]
  for token in ordinaryForbidden {
    #expect(!ordinary.contains(token), "an ordinary route names \(token)")
  }

  let liveForbidden = [
    "." + "general",
    "MacPasteboardAdapter" + "()",
    "MacPasteboardEnvironment." + "live",
  ]
  for token in liveForbidden {
    #expect(!live.contains(token), "the live region names \(token)")
  }
  #expect(live.contains("NSPaste" + "board." + "withUnique" + "Name()"))
  #expect(live.contains("defer { pasteboard." + "releaseGlobally() }"))
  #expect(live.contains("MacPasteboardEnvironment." + "backed"))
  #expect(live.components(separatedBy: "@" + "Test").count == 2)
  #expect(live.contains("if: selectedManualPasteboardProbe() != " + ".notSelected"))
}

// MARK: - Tier-H live region

/// Environment variable that selects the one real-pasteboard action.
///
/// Unset — the case for every ordinary CI and local run — leaves the probe
/// skipped.
private let manualPasteboardProbeActionKey = "MACKVM_M1_053_MANUAL_PROBE"

private func selectedManualPasteboardProbe() -> ManualPasteboardProbeSelection {
  manualPasteboardProbeSelection(
    from: ProcessInfo.processInfo.environment[manualPasteboardProbeActionKey]
  )
}

/// Reviewer-driven Tier-H probe. **Not an automated acceptance test.**
///
/// It drives the production pasteboard seam, `MacPasteboardEnvironment.backed`,
/// which is the same factory the shipped default uses, against a real AppKit
/// pasteboard created with `NSPasteboard.withUniqueName()`. That pasteboard is
/// private to this run: the user's clipboard is never read, written, or
/// cleared, and the pasteboard is released globally when the probe returns.
///
/// Safety properties:
///
/// - skipped unless the reviewer names the action;
/// - only a fixed synthetic marker and a fixed synthetic non-text byte are
///   written, and only to the private pasteboard;
/// - no sleep, poll, retry, or timer; and
/// - output is closed vocabulary only: never clipboard text, bytes, a hash, a
///   change-count value, or the pasteboard's name.
///
/// The sequencing in `performManualPasteboardProbe` is covered by an ordinary
/// always-running test on the in-memory fake; this probe adds only the real
/// platform.
@Test(
  .enabled(
    if: selectedManualPasteboardProbe() != .notSelected,
    "manual Tier-H probe: set MACKVM_M1_053_MANUAL_PROBE to unique-pasteboard-round-trip"
  )
)
func manualUniquePasteboardProbeRunsTheRealAdapterPath() throws {
  guard case .selected(let action) = selectedManualPasteboardProbe() else {
    // The unrecognized value is deliberately not echoed.
    Issue.record("unknown manual probe action; expected unique-pasteboard-round-trip")
    return
  }

  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }

  // Only the name crosses into the `@Sendable` seam; each call resolves the
  // same private pasteboard by that name.
  let nameRawValue = pasteboard.name.rawValue
  let adapter = MacPasteboardAdapter(
    environment: MacPasteboardEnvironment.backed {
      NSPasteboard(name: NSPasteboard.Name(nameRawValue))
    }
  )

  let result = try performManualPasteboardProbe(
    adapter: adapter,
    seedNonText: {
      _ = pasteboard.clearContents()
      _ = pasteboard.setData(
        Data([0x4D]),
        forType: NSPasteboard.PasteboardType(manualProbeNonTextType)
      )
    },
    clearDirectly: { _ = pasteboard.clearContents() }
  )

  print(manualPasteboardProbeLine(action: action, result: result))

  if result != expectedManualPasteboardProbeResult {
    Issue.record("the real pasteboard path did not produce the expected closed result")
  }
}
