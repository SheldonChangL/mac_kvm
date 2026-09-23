# M1-053 macOS Pasteboard Adapter

## Outcome

`MacPlatform` provides one Swift-native adapter over AppKit `NSPasteboard` that
reads and writes UTF-8 plain text and observes the pasteboard change count. It
is an independent macOS backend: no Barrier, native protocol, transport,
network, `KVMCore`, or UI code is added or changed, and `MacPlatform` imports no
protocol module.

No public contract is added. Every declaration is `package` or narrower, so the
frozen `CONTRACT_CATALOG` public surface is unchanged. No AppKit type appears in
any `package` or `public` declaration, so C-015 holds: the clipboard backend's
inputs and outputs are `String`, the M1-052 `ClipboardByteLimit`, an opaque
change count, and frozen M1-015 `CoreError` values.

## API and seam

Package surface, in `MacPasteboardAdapter.swift`:

| Declaration | Purpose |
| --- | --- |
| `package struct MacPasteboardAdapter: Sendable` | the adapter |
| `package init()` | production default: the general pasteboard |
| `package func currentChangeCount() -> MacPasteboardChangeCount` | observe the generation; never mutates |
| `package func readPlainText(limit: ClipboardByteLimit) -> CoreResult<MacPasteboardText>` | read UTF-8 plain text |
| `package func writePlainText(_: String, limit: ClipboardByteLimit) -> CoreResult<MacPasteboardChangeCount>` | replace contents with UTF-8 plain text |
| `package struct MacPasteboardChangeCount: Hashable, Sendable` | opaque generation; equality only |
| `package struct MacPasteboardText: Equatable, Sendable` | `text` plus the `changeCount` observed before it was read |

Internal only:

- `MacPasteboardAdapter.init(environment:)` and
  `MacPasteboardAdapter.plainTextTypeIdentifier` (`public.utf8-plain-text`,
  from `NSPasteboard.PasteboardType.string`).
- `MacPasteboardReadAccess`: `explicitlyDenied` or `notExplicitlyDenied`. It is
  AppKit-free and `Sendable`, and states nothing about how any prompt was
  answered.
- `MacPasteboardEnvironment`: six `@Sendable` closures, the minimum the adapter
  needs — `readAccess`, `changeCount`, `availableTypeIdentifiers`,
  `readPlainTextString`, `clearContents -> Bool`, and
  `writePlainTextString -> Bool`. Type identifiers cross as plain `String`. No
  signature can carry a platform `Error`, localized message, or status code.
- `MacPasteboardEnvironment.backed(by:)` builds the production seam over a
  pasteboard resolved on each call, so the seam holds no AppKit reference and
  stays `Sendable`. `MacPasteboardEnvironment.live` is
  `backed { NSPasteboard.general }`.

The adapter is an immutable `Sendable` struct. It owns no task, timer, observer,
queue, cache, or mutable state, and nothing is annotated `@MainActor`.

## Change count semantics

`MacPasteboardChangeCount` is an opaque observation. Callers compare two values
for equality to learn whether the contents changed between them; no ordering,
arithmetic, or platform meaning is exposed.

- **No polling.** Monitoring is observation on demand. The caller decides when
  to call `currentChangeCount()`; the adapter never polls, sleeps, or starts a
  timer.
- **Read observes before content.** `readPlainText` reads the count before the
  text. If another process writes concurrently, the returned text may be newer
  than its reported generation, never older: the caller later sees the count
  move and reads again, so no change is missed. At worst one change is read
  twice.
- **Write reports the count observed after success.** `writePlainText` reads the
  count after the string write succeeds. That is not proof that the contents at
  that count are this write's: another process may write between the write and
  the read, and no platform call makes the two atomic. It is not a transaction
  token.

## Content and failures

V1 is UTF-8 plain text only. Only `public.utf8-plain-text` is read or written;
no other representation is read, converted, or written. The byte budget is
always caller-supplied as `ClipboardByteLimit`; the adapter defines no default,
minimum, or maximum. Size is UTF-8 bytes, never characters. The empty `String`
is valid plain text in both directions.

| Condition | `CoreError` code | Severity | Retry | Cleanup |
| --- | --- | --- | --- | --- |
| Read explicitly denied (see below) | `permission.capabilityUnavailable` | `error` | `userActionRequired` | `notRequired` |
| Empty pasteboard, or no UTF-8 plain-text type | `clipboard.unsupportedType` | `warning` | `never` | `notRequired` |
| Plain text advertised but no string returned | `internal.unclassified` | `error` | `immediateAfterStateChange` | `notRequired` |
| Clear refused | `internal.unclassified` | `error` | `immediateAfterStateChange` | `notRequired` |
| String write refused | `internal.unclassified` | `error` | `immediateAfterStateChange` | `notRequired` |
| Text over the byte limit (read or write) | `clipboard.oversized` | `warning` | `never` | `notRequired` |

- The frozen `ClipboardErrorCode` allowlist has no separate code for an empty
  pasteboard, and this Issue must not extend it. Empty and non-text content both
  mean "no supported type" and share `unsupportedType`. Reading the same
  generation again can only fail the same way, so retry is `never`; a later
  generation is a new read, not a retry.
- The SDK documents no failure reason for a `nil` `string(forType:)`, for
  clearing, or for a `false` `setString(_:forType:)`. These are reported as
  `internal.unclassified` instead of being given a reason the platform never
  supplied. No `underlyingDiagnosticCode` is attached to any failure.
- `clearContents()` has no failure result in the SDK, so the live seam always
  reports success for it and discards the count it returns. The seam's `Bool`
  exists so that the adapter fails closed if a backend ever reports a refusal.
- The oversized failure is identical to the value the M1-052
  `ClipboardTextCodec` throws, and a test asserts that.

## Permission behavior

On macOS 15.4 and later the SDK reports a read-only per-application
`NSPasteboard.accessBehavior`: `.default` asks on programmatic access to the
general pasteboard and allows other pasteboards, `.ask` asks, `.alwaysAllow`
allows, and `.alwaysDeny` denies automatically, and the user may change it in
System Settings.

The live seam reads it behind `if #available(macOS 15.4, *)` (the package floor
is macOS 14) and maps **only `.alwaysDeny`** to `explicitlyDenied`. `.default`,
`.ask`, `.alwaysAllow`, `@unknown default`, and every macOS before 15.4 map to
`notExplicitlyDenied`, so the actual read stays authoritative.

`readPlainText` checks access **first**. On an explicit denial it returns
`permission.capabilityUnavailable` / `error` / `userActionRequired` /
`notRequired` before the count, the types, or any content is observed. The
adapter never prompts, never opens System Settings, and never assumes how a
prompt was answered.

Writes and `currentChangeCount()` do not consult access behavior. The SDK facts
verified for this Issue describe access behavior for programmatic access and do
not state that it denies writes, so blocking writes on it would invent platform
behavior.

There is no Accessibility dependency: the adapter does not use the M1-035
service, and no clipboard operation needs Accessibility trust.

## Privacy

- No production code path logs or emits a diagnostic event.
- No failure carries text, a byte count, a type identifier, an access behavior,
  or a change-count value. A test confirms every failure encodes to exactly
  `code`, `severity`, `retryDisposition`, `cleanupDisposition`, and that no
  content fragment or platform name appears in its JSON, `description`, or
  `debugDescription`.
- `MacPasteboardText` redacts `description`, `debugDescription`, string
  interpolation, `dump`, and reflection (`customMirror` has no children), so
  printing a read by accident cannot leak content. Only `text` itself carries
  it.
- No hash is computed.

## Fail-safe behavior

- **Oversize is rejected before mutation.** `writePlainText` measures size first;
  oversized text makes no pasteboard call at all, so existing contents and the
  count are untouched.
- **A failed clear prevents the write.** The string is never written after a
  refused clear.
- **A failed string write leaves the pasteboard cleared.** The clear already
  happened and is not undone; the fail-closed state is empty, not partial. No
  change count is read after a refused write.
- **No restoration.** The adapter never restores prior contents it did not
  write and does not know.
- **No retry, sleep, or latch.** Each call issues exactly one attempt of each
  step and derives its result only from that call. A failure latches nothing:
  the next call starts from scratch. There is nothing to cancel or clean up, so
  every `cleanupDisposition` is `notRequired`.

## Deterministic seam and Tier-H probe

Every ordinary test uses `FakePasteboard`, an in-memory, lock-guarded fake that
records each seam call in order. Each test owns its own instance, so tests are
deterministic and parallel-safe, and **no ordinary test reads, writes, or clears
the general pasteboard or any system pasteboard**.

`onlyTheTierHLiveRegionNamesARealPasteboard` is a static source audit of the
test file. Above the one `// MARK: - Tier-H live region` line, no platform
pasteboard type, general pasteboard, production seam (`live`, `backed`),
unique-name factory, or production initializer is named. Below it, the live
region creates a uniquely named pasteboard, releases it in `defer`, uses the
production `backed` factory, never names the general pasteboard or the
production initializer, and holds exactly one test. Every forbidden token is
assembled from split literals so the audit never matches its own source. It is
static evidence, not runtime proof.

The opt-in probe `manualUniquePasteboardProbeRunsTheRealAdapterPath` is skipped
unless `MACKVM_M1_053_MANUAL_PROBE=unique-pasteboard-round-trip`; any other
non-empty value fails the run without being echoed.

```sh
MACKVM_M1_053_MANUAL_PROBE=unique-pasteboard-round-trip \
  swift test --package-path Packages/MacPlatform \
  --filter manualUniquePasteboardProbeRunsTheRealAdapterPath
```

It creates a private pasteboard with `NSPasteboard.withUniqueName()`, calls
`releaseGlobally()` in `defer`, and drives the adapter through
`MacPasteboardEnvironment.backed`, the same factory the production default uses.
Only a fixed synthetic marker and one fixed synthetic non-text byte are written,
only to that private pasteboard, so the user's clipboard is never read,
overwritten, or cleared and no access prompt is expected. There is no sleep,
poll, retry, or timer. The probe prints one line of closed vocabulary only:
closed step names, closed `CoreError` taxonomy names, and `equal`/`different`
count relations. It never prints clipboard text, bytes, a hash, a count value,
or the pasteboard name. Its sequencing, `performManualPasteboardProbe`, is also
covered by an ordinary test on the fake.

## Validation coverage

Ordinary tests verify:

- the plain-text identifier is `public.utf8-plain-text`;
- a read calls `[readAccess, changeCount, availableTypes, readString]` in order
  and returns the text with the pre-read count;
- a write calls `[clear, setString, changeCount]` in order; write-then-read
  round-trips text and count; empty text is valid in both directions;
- exact-limit text is accepted and one byte over is rejected, for ASCII,
  two-, three-, and four-byte scalars, combining sequences, and the empty
  string; oversized writes make no seam call; the limit counts bytes, not
  characters; the oversized value matches M1-052;
- empty and five non-text type sets fail as `unsupportedType` without reading a
  string; plain text beside other types is still read; advertised-but-`nil`
  fails as `internal.unclassified`;
- a refused clear stops before `setString`; a refused `setString` reads no count
  and leaves the pasteboard cleared;
- explicit read denial returns exactly the frozen permission failure with only
  `[readAccess]` called; not-denied proceeds and the read decides; denial
  latches nothing and recovers on the next call; denial blocks neither writes
  nor count observation;
- count observation reads only the count, is stable without change, and tracks
  external and own changes; repeated reads never mutate; repeated writes each
  clear and write once; every failure recovers on the next call with no retry;
- the adapter runs in `Task.detached` off the main thread;
- privacy of every failure and of `MacPasteboardText` renderings; and
- probe selection parsing, probe sequencing on the fake, mismatch reporting
  without text, and the source audit.

## Verification results so far

Reported by the reviewer for the current working tree:

- `swift test --package-path Packages/MacPlatform`: exit 0; 63 tests passed,
  0 failures; the M1-053 Tier-H probe and the other Tier-H probes were skipped
  by default (3 skipped).
- Opt-in M1-053 probe: exit 0, 1 test passed, sanitized output:

  ```text
  M1-053 manual probe: action=unique-pasteboard-round-trip initialRead=clipboard.unsupportedType markerWrite=written writeCountVsInitial=different readBack=markerMatched readCountVsWrite=equal oversizedWrite=clipboard.oversized countAfterOversizedVsWrite=equal readAfterOversized=markerMatched nonTextRead=clipboard.unsupportedType clearedRead=clipboard.unsupportedType
  ```

- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination
  'platform=macOS' build`: exit 0, `** BUILD SUCCEEDED **`, target
  `arm64-apple-macos14.0`, with a nonfatal multiple-destination warning.
- `python3 Tools/Backlog/validate_package.py`: exit 0,
  `PACKAGE OK: 217 issues, 5 milestones, 17 epics`.
- `make architecture-check`: exit 0.
- Code-quality check: exit 0; swift-format 6.2.3 strict lint 0 findings;
  warnings-as-errors 0.

Evidence files under `evidence/issues/M1-053/` have not been created yet.
Independent review is not yet complete.

## Review findings repaired

1. The source audit initially matched its own expectation line above the
   Tier-H marker, so 1 test failed with 2 issues. Fixed by splitting every
   forbidden token into separate literals; the assertion was not weakened.
2. **High:** explicit pasteboard permission handling was missing, so an
   `.alwaysDeny` read degraded to `internal.unclassified`. Fixed with the
   availability-guarded access seam and the pre-observation permission failure
   described above, plus tests.
3. Three swift-format findings (two line-length, one trailing comma) in the test
   file. Fixed with formatting-only edits.

## Scope exclusions

- No loop suppression, content hashing, or hash verification (M1-054).
- No protocol message, wire format, network, session, or UI.
- No default, minimum, or maximum byte limit.
- No polling observer, timer, or notification.
- No automated test of the general pasteboard.
- No representation other than UTF-8 plain text, and no conversion.

## Known limitations and risks

- **No real `.alwaysDeny` test.** No manual run has set pasteboard access to
  "deny" in System Settings and observed the failure. The denial path is
  verified only through the seam, and the live mapping only by compilation.
- **The unique pasteboard does not exercise access prompts.** It validates the
  real AppKit read, write, clear, type, and count path without prompting or
  touching the user's clipboard. Behavior of `.default`/`.ask` on the general
  pasteboard, including any user prompt, is not verified here.
- **String is materialized before it is measured.** `NSPasteboard` returns a
  `String`, so AppKit allocates the full text before the byte size can be
  checked. The limit bounds what crosses this boundary, not what AppKit
  allocates.
- **The change count is not an atomic transaction token.** Concurrent writers
  can make a read's text newer than its count, or change the pasteboard between
  a write and its reported count.
- **A refused string write leaves the pasteboard cleared.** The user's previous
  clipboard content is lost in that case; this is the fail-closed choice.
- Empty and non-text pasteboards share `unsupportedType` and cannot be told
  apart from the error alone.

## Rollback

Remove or revert the three M1-053 Exact Files:
`Packages/MacPlatform/Sources/MacPlatform/MacPasteboardAdapter.swift`,
`Packages/MacPlatform/Tests/MacPlatformTests/MacPasteboardAdapterTests.swift`,
and this document. No other file depends on them, and there is no migration,
persisted state, or runtime resource to clean up.
