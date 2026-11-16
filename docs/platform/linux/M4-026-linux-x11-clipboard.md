# M4-026 Linux X11 Clipboard

## Outcome

`LinuxX11Clipboard` is the Linux conformer of the C-015 `ClipboardBackend`
contract (M4-002) for the X11 `CLIPBOARD` selection. It carries UTF-8 plain text
only (C-007), owns the selection in-process with Xlib, serves and reads large
content with `INCR`, reports other applications' copies through XFixes, and
never reports its own writes. The policy below is first-party; no Barrier
behavior is involved (the wire side is the session's, M1-PROTOCOL-003).

Exact Files, with the M4-001 toolchain lock's placeholders resolved:

| Placeholder path | Resolved path |
| --- | --- |
| `${LINUX_SOURCE_ROOT}/linux-x11-clipboard.${LINUX_SOURCE_EXT}` | `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Clipboard.swift` |
| `${LINUX_TEST_ROOT}/linux-x11-clipboard-tests.${LINUX_TEST_EXT}` | `Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxX11ClipboardTests.swift` |

## Why Xlib and not `xclip` (first-party decision)

1. An `xclip -i` owner process must outlive each write and be killed on every
   terminal path, which multiplies cleanup paths.
2. `xclip` is a GPL tool: running it from the product needs an M1-003 intake
   and makes the client depend on it being installed.
3. The toolchain lock already provides libXfixes for selection notifications.
4. `INCR` and owner-change handling need our own window and event loop.

## API

```swift
package final class LinuxX11Clipboard: ClipboardBackend {
  package init(displayName: String?) throws(CoreError)
  package func readPlainText(limit: ClipboardByteLimit) async -> CoreResult<PlatformClipboardText?>
  package func writePlainText(_ text: String, limit: ClipboardByteLimit) async -> CoreResult<Void>
  package let ownerChanges: AsyncStream<Void>
  package func stop() async
  package var transferredByteCount: Int { get }  // content bytes fetched; a count, never content
}

package enum LinuxX11ClipboardRules   // pure rules, testable without a display
```

`init` fails with `lifecycle.subsystemUnavailable` when the display cannot be
opened and with `permission.capabilityUnavailable` when the server lacks XFixes.
The composition root calls `XInitThreads()` once before any backend opens a
display.

## Threading

- One private `Thread` (`mackvm.x11-clipboard`) owns the `Display*` and an
  unmapped 1×1 window. It is a dedicated thread, not a task on the cooperative
  pool, because it blocks in `poll`.
- API calls put a command in a lock-guarded mailbox and write one byte to a
  non-blocking wake pipe. The thread polls the X connection and the pipe, with a
  timeout set by the nearest deadline.
- Reads are served one at a time, in arrival order.

## Writing (owner side)

- The size is checked before the text is encoded; over the limit fails with
  `clipboard.oversized` and the selection is left as it was.
- `XSetSelectionOwner(CLIPBOARD)` on the private window; if the server does not
  report us as owner afterwards, the write fails with
  `lifecycle.subsystemUnavailable`.
- `SelectionRequest` answers:

| Target | Answer |
| --- | --- |
| `TARGETS` | `ATOM` list: `TARGETS`, `UTF8_STRING`, `text/plain;charset=utf-8`, and `STRING` only when the text is Latin-1 |
| `UTF8_STRING`, `text/plain;charset=utf-8` | the UTF-8 bytes, typed as the requested target |
| `STRING` | ISO 8859-1 bytes when every scalar is ≤ U+00FF, refused otherwise |
| anything else (including `MULTIPLE`) | refused (`property = None`) |

- A requestor that names no property gets the target atom as the property
  (ICCCM rule for obsolete clients).
- Content larger than a quarter of the server's maximum request (that quarter in
  bytes is the `XMaxRequestSize` unit count, never below 4096) is sent with
  `INCR`: the property first states the size, then each `PropertyDelete` from
  the requestor gets the next chunk, and a zero-length chunk ends it. A transfer
  whose requestor stops taking chunks for 5 s is dropped.
- `SelectionClear` drops the content we served; another application owns the
  clipboard now.

## Reading (requestor side)

- No owner → `nil`. We are the owner → our own content, checked against the
  limit, without a round trip.
- Otherwise `XConvertSelection(CLIPBOARD, UTF8_STRING)` into a private property.
  Reads rotate through four properties, so an abandoned `INCR` transfer that the
  owner keeps writing, or a late answer to a timed-out read, never lands in the
  next read's property.
- `property = None` in the answer → `nil` (the owner has no UTF-8 text).
- A plain answer: its size is read first with a zero-length
  `XGetWindowProperty`; over the limit → `clipboard.oversized` before the
  content is fetched. A format other than 8 → `clipboard.unsupportedType`.
- An `INCR` answer: the stated size over the limit → `clipboard.oversized`, and
  no chunk is requested (the property is not deleted). Otherwise every chunk's
  size is checked before it is fetched, so the bytes held never pass the limit,
  even when the stated size was too small.
- Bytes are decoded with `ClipboardTextCodec.decode` (M1-052): malformed UTF-8
  fails with `clipboard.invalidUTF8` and is never repaired.
- Deadline: 2 s for the owner to answer, renewed by each `INCR` chunk, measured
  with the monotonic clock on the private thread (no `KVMClock`). Expiry →
  `timeout.read`.
- `contentHash` is the lowercase SHA-256 hex of the UTF-8 bytes (swift-crypto).

## Owner changes and loop prevention

`XFixesSelectSelectionInput(CLIPBOARD, SetSelectionOwnerNotifyMask)` on the
private window. A notification yields on `ownerChanges` only when the new owner
is neither `None` nor our window, so applying an inbound clipboard never looks
like a local copy. The stream buffers the newest element only (changes
coalesce) and carries no content. Content-level loop prevention (transaction id
and hash) stays with `ClipboardLoopGuard` (M1-054) in the coordinator.

## Errors

| Situation | `CoreError` code | retry |
| --- | --- | --- |
| content over the limit (either direction) | `clipboard.oversized` | `never` |
| malformed UTF-8 | `clipboard.invalidUTF8` | `never` |
| answer in a non-8-bit format | `clipboard.unsupportedType` | `never` |
| owner did not answer in time | `timeout.read` | `backoff` |
| called from a cancelled task | `cancellation.requested` | `never` |
| after `stop()`, display gone, ownership not taken | `lifecycle.subsystemUnavailable` | `never` |

## Cleanup

`stop()` is idempotent and bounded, also from a cancelled task. It answers a read
in progress and every queued command with `lifecycle.subsystemUnavailable`,
gives up the selection if we own it, destroys the window, closes the display,
finishes `ownerChanges` and closes the wake pipe. Dropping the last reference
requests the same stop without waiting. A hang-up on the X connection ends the
thread the same way, skipping the ownership and window calls and only closing
the display.

## Privacy

Nothing logs clipboard text, byte content or hashes (Frozen Decision 8).
`PlatformClipboardText` renders redacted (M4-002).

## Tests

`LinuxX11ClipboardTests.swift`. The pure suite runs on every Linux test run. The
X11 suite is tagged `.x11`, serialized (all tests share one `CLIPBOARD`), and
runs under Xvfb in `make verify-linux`. Its peer is a second Xlib connection
written in the test from the ICCCM rules, so the backend is checked against an
independent owner and requestor:

- write, then the peer reads `UTF8_STRING` and `text/plain;charset=utf-8`;
- `TARGETS` with and without `STRING`, `STRING` bytes, refused targets;
- the peer copies, then we read text and hash;
- 1 MiB out and in through `INCR`;
- over-limit reads: stated `INCR` size (no byte transferred), whole property,
  understated `INCR` size, each with no content byte fetched
  (`transferredByteCount`); exactly-at-limit accepted;
- an abandoned `INCR` transfer does not leak into the next read;
- over-limit write leaves the clipboard as it was; malformed UTF-8;
- no owner → `nil`; owner that exits → `nil`; ownership lost to the peer;
- silent owner → `timeout.read` between 2 s and 4 s;
- `ownerChanges` fires for the peer and stays quiet for our own writes;
- cancelled task; `stop()` idempotent and refusing later calls; `stop()` ending
  a read in progress.

## Known limitations

- `PRIMARY` is not synchronized; only `CLIPBOARD`, only UTF-8 text.
- `MULTIPLE` requests are refused.
- `CurrentTime` is used for ownership and conversion requests.
- Xlib's error handler is process-wide; this backend installs one that ignores
  protocol errors (Xlib's default exits the process), so a requestor window that
  disappears mid-transfer cannot kill the client.
- A lost X connection is detected by a hang-up on the socket; Xlib's own
  I/O-error handler still exits the process if an Xlib call hits the dead
  connection first. The composition root owns display-loss policy.
- Real-desktop interoperability (GTK, Qt, Electron applications) is owner E2E
  evidence (M4-036-FOLLOWUP-001), not covered by Xvfb.
