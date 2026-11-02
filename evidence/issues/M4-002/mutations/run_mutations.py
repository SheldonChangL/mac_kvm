"""M4-002 mutation runner for the C-015 platform backend contracts.

Usage (from anywhere):
  python3 -I evidence/issues/M4-002/mutations/run_mutations.py <repository> [--out <json>]
      [--only <id> ...]

Each mutant edits the production source, the reference conformers in the test file, or both, by
exact text replacement; every searched text must occur exactly once. The runner then runs the
M4-002 suite, records which tests failed, and restores both files from backup copies. Before the
mutants it runs the suite once unmodified (the baseline, which must pass).

A mutant is killed when the suite exits non-zero, the build succeeded (the output has a test run
summary and no compiler diagnostic), and every test named in its `killers` list is among the
failing tests. A mutant marked with `compileErrorPattern` shows a compile-time guard instead: it
is caught only when the build fails with a compiler diagnostic (`<file>.swift:<line>:<col>:
error:`) that matches the pattern, so a crash or an unrelated failure never counts. After every
restore the runner checks that both files are byte-for-byte the originals and that
`git diff --exit-code` on each returns 0, so stage both files before running.

The JSON report holds repository-relative paths only. It defaults to
evidence/issues/M4-002/mutations/mutations.json inside the repository. The exit code is 0 only
when the baseline passes, every mutant is killed or caught as expected and every restore is
clean.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

SOURCE = "Packages/KVMContracts/Sources/KVMContracts/PlatformBackendContracts.swift"
TESTS = "Packages/KVMContracts/Tests/KVMContractsTests/PlatformBackendContractsTests.swift"
COMMAND = [
    "swift", "test", "--package-path", "Packages/KVMContracts",
    "--filter", "PlatformBackendContractsTests",
]
TIMEOUT_SECONDS = 900

STATED_AND_PART_CHECKS = (
    "    guard (statedByteCount ?? bytes.count) <= limit.byteCount else {\n"
    "      return .failure(referenceFailure(.clipboard(.oversized)))\n"
    "    }\n"
    "    var held: [UInt8] = []\n"
    "    for part in parts(of: bytes) {\n"
    "      guard held.count + part.count <= limit.byteCount else {\n"
    "        return .failure(referenceFailure(.clipboard(.oversized)))\n"
    "      }\n"
    "      held += part\n"
    "      transferredByteCount += part.count\n"
    "      largestHeldByteCount = max(largestHeldByteCount, held.count)\n"
    "    }\n"
)
CHECK_AFTER_TRANSFER = (
    "    var held: [UInt8] = []\n"
    "    for part in parts(of: bytes) {\n"
    "      held += part\n"
    "      transferredByteCount += part.count\n"
    "      largestHeldByteCount = max(largestHeldByteCount, held.count)\n"
    "    }\n"
    "    guard held.count <= limit.byteCount else {\n"
    "      return .failure(referenceFailure(.clipboard(.oversized)))\n"
    "    }\n"
)
WRITE_LIMIT_CHECK = (
    "    guard text.utf8.count <= limit.byteCount else {\n"
    "      return .failure(referenceFailure(.clipboard(.oversized)))\n"
    "    }\n"
    "    let bytes = Array(text.utf8)\n"
    "    encodedByteCount += bytes.count\n"
)
NEW_REASON = (
    "  case repeatNotInjected\n"
    "\n"
    "  /// Mutant: a fifth reason.\n"
    "  case unsupportedEvent\n"
    "}"
)
DECODE_VALIDATION = (
    "    guard let key = PeerKey(rawValue: stored) else {\n"
    "      throw DecodingError.dataCorruptedError(\n"
    "        forKey: .rawValue,\n"
    "        in: container,\n"
    "        debugDescription: \"not a host:port peer key\"\n"
    "      )\n"
    "    }\n"
    "    self = key\n"
)
HOST_CHECK = "    !host.isEmpty && host.utf8.allSatisfy { printableASCII.contains($0) }\n"
STRICT_PORT = (
    "    guard let first = text.utf8.first, first != UInt8(ascii: \"0\"),\n"
    "      text.utf8.allSatisfy({ decimalDigits.contains($0) })\n"
    "    else { return nil }\n"
    "    return UInt16(text)\n"
)
PROTECTED_LOAD = (
    "    guard protectedFromOthers else {\n"
    "      return .failure(referenceFailure(.security(.secureStorageUnavailable)))\n"
    "    }\n"
    "    storageOperationCount += 1\n"
    "    guard available else {\n"
    "      return .failure(referenceFailure(.security(.secureStorageUnavailable)))\n"
    "    }\n"
    "    return .success(records[peer])\n"
)
LENGTH_THEN_CANCELLATION = (
    "    guard fingerprint.count == sha256DigestLength else {\n"
    "      return .failure(referenceFailure(.security(.trustRejected)))\n"
    "    }\n"
    "    guard !Task.isCancelled else {\n"
    "      return .failure(referenceFailure(.cancellation(.requested)))\n"
    "    }\n"
)
CANCELLATION_THEN_LENGTH = (
    "    guard !Task.isCancelled else {\n"
    "      return .failure(referenceFailure(.cancellation(.requested)))\n"
    "    }\n"
    "    guard fingerprint.count == sha256DigestLength else {\n"
    "      return .failure(referenceFailure(.security(.trustRejected)))\n"
    "    }\n"
)
LIFECYCLE_OVERFLOW = (
    "      if case .enqueued = continuation.yield(signal) { return }\n"
    "      // The signal cannot be delivered: end the stream rather than drop it silently.\n"
    "      stopped = true\n"
    "      continuation.finish()\n"
)
MOVE_DROP = "      if case .dropped = result, case .mouseMove = event { return }\n"
SWEEP_BUTTONS = (
    "      releases += heldButtons.reversed().map { .button(code: $0.code, isDown: false) }\n"
)
SWEEP_GROUPS = (
    "      var releases: [PlatformInput] = ordinaryKeys.map { .key(code: $0.code, isDown: false) }\n"
    + SWEEP_BUTTONS
    + "      releases += modifierKeys.map { .key(code: $0.code, isDown: false) }\n"
)
SWEEP_GROUPS_MODIFIERS_FIRST = (
    "      var releases: [PlatformInput] = modifierKeys.map { .key(code: $0.code, isDown: false) }\n"
    "      releases += ordinaryKeys.map { .key(code: $0.code, isDown: false) }\n"
    + SWEEP_BUTTONS
)
FILE_END = "  var events: AsyncStream<KVMEvent> { get }\n}\n"

MUTANTS = [
    {
        "id": "1",
        "requirement": "required 1: the in-memory injection conformer records an unknown key",
        "description": "the reference injector sends something to the platform for an unknown "
                       "or out-of-domain key while still answering .unsupported(.unknownKey)",
        "replacements": [(
            TESTS,
            "        guard referenceKeyCode(key) != nil else {\n"
            "          return .success(.unsupported(.unknownKey))\n",
            "        guard referenceKeyCode(key) != nil else {\n"
            "          queued.append(.key(code: 0, isDown: phase == .down))\n"
            "          return .success(.unsupported(.unknownKey))\n",
        )],
        "killers": ["unknownAndOutOfDomainKeysAreUnsupportedInEveryPhaseAndNothingIsRecorded"],
    },
    {
        "id": "2a",
        "requirement": "required 2: the clipboard limit is checked after allocating or reading",
        "description": "a read takes all of the platform's content into the process first and "
                       "checks the limit afterwards",
        "replacements": [(TESTS, STATED_AND_PART_CHECKS, CHECK_AFTER_TRANSFER)],
        "killers": [
            "anOversizedReadIsRefusedBeforeAnyContentIsTransferred",
            "aReadInPartsWithAnUnderstatedSizeNeverHoldsMoreThanTheLimit",
        ],
    },
    {
        "id": "2b",
        "requirement": "required 2: the clipboard limit is checked after allocating or reading",
        "description": "a write encodes the text for the platform first and checks the limit "
                       "afterwards",
        "replacements": [(
            TESTS,
            WRITE_LIMIT_CHECK,
            "    let bytes = Array(text.utf8)\n"
            "    encodedByteCount += bytes.count\n"
            "    guard bytes.count <= limit.byteCount else {\n"
            "      return .failure(referenceFailure(.clipboard(.oversized)))\n"
            "    }\n",
        )],
        "killers": ["anOversizedWriteIsRefusedBeforeAnythingIsEncodedAndChangesNothing"],
    },
    {
        "id": "2c",
        "requirement": "required 2 and review M4: a transfer in parts is checked only at the end",
        "description": "the stated size is still checked, but parts are accumulated without a "
                       "check and the codec refuses the whole only afterwards",
        "replacements": [(
            TESTS,
            "      guard held.count + part.count <= limit.byteCount else {\n"
            "        return .failure(referenceFailure(.clipboard(.oversized)))\n"
            "      }\n"
            "      held += part\n",
            "      held += part\n",
        )],
        "killers": ["aReadInPartsWithAnUnderstatedSizeNeverHoldsMoreThanTheLimit"],
    },
    {
        "id": "3",
        "requirement": "required 3: PlatformClipboardText's description exposes the text",
        "description": "description renders the text: PlatformClipboardText(<text>)",
        "replacements": [(
            SOURCE,
            "public var description: String { \"PlatformClipboardText(redacted)\" }",
            "public var description: String { \"PlatformClipboardText(\\(text))\" }",
        )],
        "killers": ["platformClipboardTextNeverRendersItsTextOrHash"],
    },
    {
        "id": "4",
        "requirement": "required 4: PeerKey normalization keeps uppercase",
        "description": "init?(host:port:) stores the host as given, without lowercasing",
        "replacements": [(
            SOURCE,
            "    rawValue = \"\\(Self.lowercasingASCII(host)):\\(port)\"\n",
            "    rawValue = \"\\(host):\\(port)\"\n",
        )],
        "killers": ["peerKeyNormalizationLowercasesTheHost"],
    },
    {
        "id": "5",
        "requirement": "required 5: a new InjectionUnsupportedReason case is added without the "
                       "closed-set test noticing",
        "description": "a fifth case, unsupportedEvent, is added, and the test file's exhaustive "
                       "switch gets the branch a developer would add to make it compile again; "
                       "the closed-set test must still fail",
        "replacements": [
            (SOURCE, "  case repeatNotInjected\n}", NEW_REASON),
            (
                TESTS,
                "  case .repeatNotInjected: \"repeatNotInjected\"\n  }",
                "  case .repeatNotInjected: \"repeatNotInjected\"\n"
                "  case .unsupportedEvent: \"unsupportedEvent\"\n  }",
            ),
        ],
        "killers": ["injectionUnsupportedReasonIsAClosedSetWithAFrozenCoding"],
    },
    {
        "id": "5-compile",
        "requirement": "required 5, first guard: the exhaustive switch",
        "description": "the same fifth case without the test-file branch: the switch without "
                       "a default in the test file stops the build",
        "replacements": [(SOURCE, "  case repeatNotInjected\n}", NEW_REASON)],
        "killers": [],
        "compileErrorPattern": r"switch must be exhaustive",
    },
    {
        "id": "6",
        "requirement": "required 6: a Codable round trip drops a field",
        "description": "PlatformScreenGeometry's coding keys omit cursorY (the property gets a "
                       "default so the mutant compiles), so encoding drops it and decoding "
                       "yields 0",
        "replacements": [(
            SOURCE,
            "  public let cursorX: Int\n  public let cursorY: Int\n",
            "  public let cursorX: Int\n  public var cursorY: Int = 0\n\n"
            "  private enum CodingKeys: String, CodingKey {\n"
            "    case originX, originY, width, height, cursorX\n"
            "  }\n",
        )],
        "killers": ["platformScreenGeometryRoundTripsWithAFrozenCodingShape"],
    },
    {
        "id": "7",
        "requirement": "extra: PeerKey decoding skips validation",
        "description": "init(from:) stores the decoded rawValue as it is",
        "replacements": [(SOURCE, DECODE_VALIDATION, "    rawValue = stored\n")],
        "killers": ["peerKeyRoundTripsAndDecodingNormalizesOrRefuses"],
    },
    {
        "id": "8",
        "requirement": "review M7: PeerKey accepts hosts outside printable ASCII",
        "description": "a host may hold any byte from 0x80 up, so non-ASCII letters, composed "
                       "or not, and invisible characters pass",
        "replacements": [(
            SOURCE,
            HOST_CHECK,
            "    !host.isEmpty && !host.utf8.contains { $0 < 0x21 || $0 == 0x7F }\n",
        )],
        "killers": [
            "peerKeyRefusesHostsAndPortsThatCannotIdentifyAPeer",
            "peerKeyParsesARawValueWithTheRulesOfItsInitializer",
        ],
    },
    {
        "id": "8b",
        "requirement": "extra: PeerKey accepts any non-empty host",
        "description": "a host only has to be non-empty",
        "replacements": [(SOURCE, HOST_CHECK, "    !host.isEmpty\n")],
        "killers": ["peerKeyRefusesHostsAndPortsThatCannotIdentifyAPeer"],
    },
    {
        "id": "9",
        "requirement": "extra: PeerKey accepts port 0",
        "description": "init?(host:port:) no longer refuses port 0",
        "replacements": [(
            SOURCE,
            "    guard port != 0, Self.isUsableHost(host) else { return nil }\n",
            "    guard Self.isUsableHost(host) else { return nil }\n",
        )],
        "killers": ["peerKeyRefusesHostsAndPortsThatCannotIdentifyAPeer"],
    },
    {
        "id": "10",
        "requirement": "extra: PlatformClipboardText's reflection exposes its fields",
        "description": "customMirror lists text and contentHash as children",
        "replacements": [(
            SOURCE,
            "Mirror(self, children: [:], displayStyle: .struct)",
            "Mirror(self, children: [\"text\": text, \"contentHash\": contentHash], "
            "displayStyle: .struct)",
        )],
        "killers": ["platformClipboardTextNeverRendersItsTextOrHash"],
    },
    {
        "id": "11",
        "requirement": "extra: the reference clipboard reports its own writes",
        "description": "writePlainText yields an owner change after its own write",
        "replacements": [(
            TESTS,
            "    // This backend now owns the clipboard: its own write is not an owner change.\n"
            "    platformBytes = bytes\n",
            "    platformBytes = bytes\n    continuation.yield()\n",
        )],
        "killers": ["ownerChangesReportOtherApplicationsButNeverOwnWrites"],
    },
    {
        "id": "12",
        "requirement": "extra: the reference trust store replaces an existing record",
        "description": "insertTrustedFingerprintIfAbsent overwrites a stored fingerprint",
        "replacements": [(
            TESTS,
            "    if let stored = records[peer] {\n"
            "      return .success(.existing(storedFingerprint: stored))\n"
            "    }\n",
            "",
        )],
        "killers": [
            "insertNeverReplacesAnExistingRecord",
            "concurrentInsertsForOnePeerKeepExactlyOneRecord",
        ],
    },
    {
        "id": "13",
        "requirement": "extra: flush returns without the platform processing anything",
        "description": "the reference injector's flush succeeds and leaves its queue as it is",
        "replacements": [(
            TESTS,
            "      processedInputs += queued\n      queued.removeAll()\n",
            "",
        )],
        "killers": ["flushIsTheBarrierForEverythingInjectedBeforeItAndCanRepeat"],
    },
    {
        "id": "14",
        "requirement": "review H1: a held key is released with the current mapping",
        "description": "the reference injector releases a key with the keyboard mapping in "
                       "force at release instead of the code it pressed",
        "replacements": [(
            TESTS,
            "    heldKeys.first { $0.key == key }?.code ?? currentCode(for: key)\n",
            "    currentCode(for: key)\n",
        )],
        "killers": ["releasingHeldInputReleasesWhatWasPressedEvenAfterTheMappingChanged"],
    },
    {
        "id": "14b",
        "requirement": "review H1: a held button is released with the current pointer mapping",
        "description": "the reference injector releases a button with the pointer mapping in "
                       "force at release instead of the button it pressed",
        "replacements": [(
            TESTS,
            "    heldButtons.first { $0.button == button }?.code ?? currentCode(for: button)\n",
            "    currentCode(for: button)\n",
        )],
        "killers": ["releasingHeldInputReleasesWhatWasPressedEvenAfterTheMappingChanged"],
    },
    {
        "id": "15",
        "requirement": "review M1: a store others could change still reads its records",
        "description": "the reference trust store's load ignores that its records are exposed "
                       "to other users",
        "replacements": [(
            TESTS,
            PROTECTED_LOAD,
            "    storageOperationCount += 1\n"
            "    guard available else {\n"
            "      return .failure(referenceFailure(.security(.secureStorageUnavailable)))\n"
            "    }\n"
            "    return .success(records[peer])\n",
        )],
        "killers": ["aStoreOthersCouldChangeFailsClosedWithoutTouchingARecord"],
    },
    {
        "id": "16",
        "requirement": "review M2: capture drops a key or button that does not fit",
        "description": "the reference capture drops any event that does not fit and keeps "
                       "capturing",
        "replacements": [(TESTS, MOVE_DROP, "      if case .dropped = result { return }\n")],
        "killers": ["captureNeverDropsAKeyOrButtonAndEndsTheStreamWhenOneDoesNotFit"],
    },
    {
        "id": "16b",
        "requirement": "review M2: capture stops on a move that does not fit",
        "description": "the reference capture ends capture for a dropped pointer move too, the "
                       "behavior the M2-003 policy does not require",
        "replacements": [(TESTS, MOVE_DROP, "")],
        "killers": ["captureMayDropAPointerMoveThatDoesNotFitAndKeepsCapturing"],
    },
    {
        "id": "17",
        "requirement": "review M3: lifecycle signals that do not fit vanish",
        "description": "the reference lifecycle keeps the newest signals and drops the oldest "
                       "silently",
        "replacements": [
            (
                TESTS,
                "      bufferingPolicy: .bufferingOldest(capacity))\n",
                "      bufferingPolicy: .bufferingNewest(capacity))\n",
            ),
            (TESTS, LIFECYCLE_OVERFLOW, "      continuation.yield(signal)\n"),
        ],
        "killers": ["lifecycleSignalsThatDoNotFitEndTheStreamInsteadOfVanishing"],
    },
    {
        "id": "18",
        "requirement": "review M5: the content hash is not the frozen lowercase SHA-256 hex",
        "description": "the reference clipboard writes the digest in uppercase hex",
        "replacements": [(
            TESTS,
            "contentHash: sha256Hex(Array(text.utf8))))",
            "contentHash: sha256Hex(Array(text.utf8)).uppercased()))",
        )],
        "killers": ["contentHashIsTheLowercaseHexSHA256OfTheUTF8Bytes"],
    },
    {
        "id": "19",
        "requirement": "review M6: a conformance on a continuation line",
        "description": "PlatformClipboardText gains Codable on the second line of its header, "
                       "which would let an encoder emit the text and the hash",
        "replacements": [(
            SOURCE,
            "  CustomDebugStringConvertible, CustomReflectable\n",
            "  CustomDebugStringConvertible, CustomReflectable, Codable\n",
        )],
        "killers": [
            "publicSurfaceIsExactlyTheC015Inventory",
            "platformClipboardTextNeverRendersItsTextOrHash",
        ],
    },
    {
        "id": "20",
        "requirement": "review M6: a conformance in an extension",
        "description": "an extension makes PlatformClipboardText Encodable",
        "replacements": [(
            SOURCE,
            FILE_END,
            FILE_END + "\nextension PlatformClipboardText: Encodable {}\n",
        )],
        "killers": [
            "publicSurfaceIsExactlyTheC015Inventory",
            "platformClipboardTextNeverRendersItsTextOrHash",
        ],
    },
    {
        "id": "21",
        "requirement": "review M6: an attributed public member in an extension",
        "description": "an extension adds an @inlinable public property to PeerKey",
        "replacements": [(
            SOURCE,
            FILE_END,
            FILE_END + "\nextension PeerKey {\n"
            "  @inlinable public var debugHost: String { rawValue }\n}\n",
        )],
        "killers": ["publicSurfaceIsExactlyTheC015Inventory"],
    },
    {
        "id": "22",
        "requirement": "review L6: PeerKey splits at the first colon",
        "description": "the parser takes the port after the first colon, so a host with a colon "
                       "no longer parses",
        "replacements": [(
            SOURCE,
            "    guard let separator = rawValue.lastIndex(of: \":\"),\n",
            "    guard let separator = rawValue.firstIndex(of: \":\"),\n",
        )],
        "killers": [
            "peerKeyParsesARawValueWithTheRulesOfItsInitializer",
            "peerKeyRoundTripsAndDecodingNormalizesOrRefuses",
        ],
    },
    {
        "id": "23",
        "requirement": "review L6: a lenient port parse",
        "description": "the port is whatever UInt16(_:) accepts, so a sign or a leading zero "
                       "passes",
        "replacements": [(SOURCE, STRICT_PORT, "    UInt16(text)\n")],
        "killers": [
            "peerKeyParsesARawValueWithTheRulesOfItsInitializer",
            "peerKeyRoundTripsAndDecodingNormalizesOrRefuses",
        ],
    },
    {
        "id": "24",
        "requirement": "review L2: cancellation is checked before the length",
        "description": "the reference trust store answers a cancelled insert of a wrong-length "
                       "value with cancellation instead of trustRejected",
        "replacements": [(TESTS, LENGTH_THEN_CANCELLATION, CANCELLATION_THEN_LENGTH)],
        "killers": ["loadAndInsertFromACancelledTaskReadAndWriteNothing"],
    },
    {
        "id": "25",
        "requirement": "review L3: a read waits for an owner that never answers",
        "description": "the reference clipboard ignores that the owner stopped answering",
        "replacements": [(
            TESTS,
            "    guard ownerAnswers else {\n"
            "      return .failure(referenceFailure(.timeout(.read)))\n"
            "    }\n",
            "",
        )],
        "killers": ["aReadFromAnOwnerThatNeverAnswersTimesOutAndChangesNothing"],
    },
    {
        "id": "26",
        "requirement": "review L4: pointer movement alone is reported as a change",
        "description": "the reference screen yields its geometry when only the pointer moved",
        "replacements": [(
            TESTS,
            "      // Pointer movement alone is not a change: nothing is yielded.\n",
            "      continuation.yield(geometry)\n",
        )],
        "killers": ["pointerMovementAloneIsNotAScreenChange"],
    },
    {
        "id": "27",
        "requirement": "amendment h.1: releaseAllHeld releases in press order",
        "description": "the sweep releases each group in press order instead of reverse press "
                       "order",
        "replacements": [(
            TESTS,
            "      let keys = Array(heldKeys.reversed())\n",
            "      let keys = heldKeys\n",
        )],
        "killers": ["releaseAllHeldReleasesKeysThenButtonsThenModifiersInReversePressOrder"],
    },
    {
        "id": "27b",
        "requirement": "amendment h.1: releaseAllHeld releases modifiers first",
        "description": "the sweep releases modifier keys before the other keys and the buttons",
        "replacements": [(TESTS, SWEEP_GROUPS, SWEEP_GROUPS_MODIFIERS_FIRST)],
        "killers": ["releaseAllHeldReleasesKeysThenButtonsThenModifiersInReversePressOrder"],
    },
    {
        "id": "28",
        "requirement": "amendment h.1: releaseAllHeld is not idempotent",
        "description": "a successful sweep keeps its record, so the next sweep releases the "
                       "same input again",
        "replacements": [(
            TESTS,
            "      heldKeys.removeAll()\n      heldButtons.removeAll()\n      return .success(())\n",
            "      return .success(())\n",
        )],
        "killers": ["releaseAllHeldIsIdempotentAndHasNothingToReleaseOnceAllWasReleased"],
    },
    {
        "id": "29",
        "requirement": "amendment h.1: releaseAllHeld skips buttons",
        "description": "the sweep releases keys only, so a held button stays pressed",
        "replacements": [(TESTS, SWEEP_BUTTONS, "")],
        "killers": [
            "releaseAllHeldReleasesKeysThenButtonsThenModifiersInReversePressOrder",
            "releaseAllHeldReleasesInputWhoseReleaseNeverArrivedWithItsPressedCode",
        ],
    },
    {
        "id": "30",
        "requirement": "amendment h.1: a failed sweep forgets what is still pressed",
        "description": "the sweep clears its record before it knows the releases went out, so "
                       "a retry after a failure finds nothing to release",
        "replacements": [(
            TESTS,
            "      guard releases.isEmpty || !platformLost else {\n",
            "      heldKeys.removeAll()\n      heldButtons.removeAll()\n"
            "      guard releases.isEmpty || !platformLost else {\n",
        )],
        "killers": ["releaseAllHeldOnALostPlatformFailsAsPartialCleanupAndKeepsTheRecord"],
    },
]

FAILED_TEST = re.compile(r"Test (\w+)\(\) failed")
RUN_SUMMARY = re.compile(r"Test run with \d+ tests? in \d+ suites? (passed|failed)[^\n]*")
COMPILER_DIAGNOSTIC = re.compile(r"\.swift:\d+:\d+: error: ([^\n]*)")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_suite(repository: pathlib.Path) -> dict:
    started = time.monotonic()
    try:
        process = subprocess.run(COMMAND, cwd=repository, capture_output=True, text=True,
                                 timeout=TIMEOUT_SECONDS)
        exit_code, output = process.returncode, process.stdout + process.stderr
    except subprocess.TimeoutExpired as expired:
        exit_code = "timeout"
        partial = expired.stdout or ""
        output = partial.decode("utf-8", "replace") if isinstance(partial, bytes) else partial
    summary_line = RUN_SUMMARY.search(output)
    diagnostics = sorted(set(COMPILER_DIAGNOSTIC.findall(output)))
    return {
        "exitCode": exit_code,
        "durationSeconds": round(time.monotonic() - started, 1),
        "failingTests": sorted(set(FAILED_TEST.findall(output))),
        "compileError": bool(diagnostics) and summary_line is None,
        "compilerDiagnostics": diagnostics[:5],
        "summary": summary_line.group(0) if summary_line else None,
    }


def git_diff_exit_code(repository: pathlib.Path, path: str) -> int:
    return subprocess.run(["git", "diff", "--exit-code", "--quiet", "--", path],
                          cwd=repository).returncode


def is_tracked(repository: pathlib.Path, path: str) -> bool:
    return subprocess.run(["git", "ls-files", "--error-unmatch", "--", path], cwd=repository,
                          capture_output=True).returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    parser.add_argument("--out", default="evidence/issues/M4-002/mutations/mutations.json")
    parser.add_argument("--only", action="append", default=[],
                        help="run only the mutant with this id; repeat for more")
    arguments = parser.parse_args()
    repository = pathlib.Path(arguments.repository).resolve()
    selected = [mutant for mutant in MUTANTS
                if not arguments.only or mutant["id"] in arguments.only]
    if arguments.only and len(selected) != len(set(arguments.only)):
        raise SystemExit("--only names a mutant that does not exist")
    files = (SOURCE, TESTS)
    for path in files:
        if not is_tracked(repository, path):
            raise SystemExit("stage the source and the tests first: the git diff restore "
                             "check needs them tracked")
    originals = {path: (repository / path).read_bytes() for path in files}
    original_hashes = {path: sha256(data) for path, data in originals.items()}
    backup_directory = pathlib.Path(tempfile.mkdtemp(prefix="m4-002-mutations-"))
    backups = {path: backup_directory / pathlib.Path(path).name for path in files}
    for path in files:
        shutil.copyfile(repository / path, backups[path])

    def restore() -> None:
        for path in files:
            shutil.copyfile(backups[path], repository / path)

    results = []
    clean = True
    try:
        baseline = run_suite(repository)
        print(f"baseline: exit {baseline['exitCode']}, {baseline['summary']}", flush=True)
        for mutant in selected:
            for path in files:
                if sha256((repository / path).read_bytes()) != original_hashes[path]:
                    raise SystemExit("a file changed before a mutant was applied")
            texts = {path: originals[path].decode("utf-8") for path in files}
            for path, old, new in mutant["replacements"]:
                if texts[path].count(old) != 1:
                    raise SystemExit(f"mutant {mutant['id']}: the text to replace is not unique "
                                     f"in {path}")
                texts[path] = texts[path].replace(old, new)
            try:
                for path in {path for path, _, _ in mutant["replacements"]}:
                    (repository / path).write_text(texts[path], encoding="utf-8")
                outcome = run_suite(repository)
            finally:
                restore()
            restored = all(sha256((repository / path).read_bytes()) == original_hashes[path]
                           for path in files)
            diff_exits = {path: git_diff_exit_code(repository, path) for path in files}
            clean = clean and restored and all(code == 0 for code in diff_exits.values())
            pattern = mutant.get("compileErrorPattern")
            missing = sorted(set(mutant["killers"]) - set(outcome["failingTests"]))
            if pattern:
                caught = (outcome["exitCode"] not in (0, "timeout") and outcome["compileError"]
                          and any(re.search(pattern, line)
                                  for line in outcome["compilerDiagnostics"]))
            else:
                caught = (outcome["exitCode"] not in (0, "timeout")
                          and not outcome["compileError"] and outcome["summary"] is not None
                          and bool(outcome["failingTests"]) and not missing)
            result = {
                "id": mutant["id"],
                "requirement": mutant["requirement"],
                "description": mutant["description"],
                "files": sorted({path for path, _, _ in mutant["replacements"]}),
                "expectedOutcome": f"compile error matching '{pattern}'" if pattern
                else "named tests fail",
                "killers": mutant["killers"],
                "killersNotFailing": missing,
                "caught": caught,
                **outcome,
                "restoredByteForByte": restored,
                "gitDiffExitCodesAfterRestore": diff_exits,
            }
            results.append(result)
            print(f"mutant {mutant['id']}: caught={caught} exit={outcome['exitCode']} "
                  f"failing={len(outcome['failingTests'])} compileError="
                  f"{outcome['compileError']} restored={restored} "
                  f"diff={list(diff_exits.values())}", flush=True)
    finally:
        restore()
        shutil.rmtree(backup_directory, ignore_errors=True)
    final_clean = all(sha256((repository / path).read_bytes()) == original_hashes[path]
                      and git_diff_exit_code(repository, path) == 0 for path in files)
    clean = clean and final_clean

    baseline_ok = (baseline["exitCode"] == 0 and not baseline["failingTests"]
                   and baseline["summary"] is not None)
    all_caught = all(result["caught"] for result in results)
    report = {
        "schemaVersion": 1,
        "issue": "M4-002",
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE,
        "sourceSha256": original_hashes[SOURCE],
        "tests": TESTS,
        "testsSha256": original_hashes[TESTS],
        "command": " ".join(COMMAND),
        "timeoutSeconds": TIMEOUT_SECONDS,
        "baseline": baseline,
        "mutants": results,
        "baselinePassed": baseline_ok,
        "allCaught": all_caught,
        "allRestored": clean,
        "killedByNamedTestsCount": sum(result["caught"] and result["expectedOutcome"]
                                       == "named tests fail" for result in results),
        "caughtAtCompileTimeCount": sum(result["caught"] and result["expectedOutcome"]
                                        != "named tests fail" for result in results),
        "mutantCount": len(results),
    }
    out = pathlib.Path(arguments.out)
    out = out if out.is_absolute() else repository / out
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{report['killedByNamedTestsCount']} mutants killed by named tests and "
          f"{report['caughtAtCompileTimeCount']} caught at compile time, of "
          f"{report['mutantCount']}; baseline {'passed' if baseline_ok else 'FAILED'}; "
          f"restores {'clean' if clean else 'NOT clean'}")
    return 0 if baseline_ok and all_caught and clean else 1


if __name__ == "__main__":
    sys.exit(main())
