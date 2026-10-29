# M2-028 Barrier Clipboard and Control Encoder

## Outcome

`BarrierCompatibility` now has `BarrierClipboardControlEncoder`, the
server-to-client control encoder for one client session under the proposed
M2-023 subset. Declarations are module-internal.

| Call | Frame | Rule |
| --- | --- | --- |
| `enter(position:)` / `enter(x:y:)` | `CINN` | raw x/y in `0...0x7fff` and inside the client `DINF` rectangle; observed sequence `1` and opaque mask `0x2000`; once per session |
| `leave()` | `COUT` | token-only |
| `keepalive()` | `CALV` | token-only |
| `clipboard(_:limit:)` | `DCLP` start, chunk, end | size checked first (`clipboardOversized`, no bytes); then the transfer of clipboard 0 with sequence 0 (see Clipboard transfer) |

A failed `enter` does not consume the single supported enter. A second enter
fails closed with `repeatedEnterUnsupported`; the session owner must end and
re-establish the session instead of guessing sequence semantics.

Normalized positions map to `origin + round(n × (size − 1))`. For clients
whose `DINF` origin is negative, positions that map below zero fail closed
with `coordinateOutOfRange` (frozen signedness rule).

## Privacy

No payload text, coordinates or bytes are carried in errors. Clipboard text is
read only to measure and frame it, and nothing in this module logs.

## Tests

`BarrierClipboardControlEncoderTests` (6): golden `CINN`, normalized mapping,
golden `COUT`/`CALV`, single-enter rule, coordinate bounds, clipboard
fail-closed.

## Clipboard transfer (2026-10-29)

The `DCLP` layout is now frozen from the M2-022 punctuation and clipboard
addendum (`evidence/e2e/M2-022/punctuation-clipboard.md`, fixture
`Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/`), so the
fail-closed clipboard path and `clipboardWireContractNotFrozen` are gone.
The owner asked for clipboard sharing on 2026-10-29 ("剪貼簿跟標點符號都做").

`BarrierClipboard.swift` (module-internal, outside the M2-028 Exact Files)
holds the codec both directions use:

| Declaration | Rule |
| --- | --- |
| `BarrierClipboard.marshal(text:)` | one format, 0 (UTF-8 text) |
| `BarrierClipboard.text(fromMarshalled:)` | text format or `nil`; truncation, trailing bytes, more than 16 formats or invalid UTF-8 throw `malformed`; byte-faithful (a leading U+FEFF is kept) |
| `BarrierClipboard.frames(id:sequence:data:chunkSize:)` | start (decimal size), chunks of at most 32 KiB, empty end |
| `BarrierClipboardAssembler(limit:)` | one transfer in flight per id; a start over the limit throws `oversized`; a chunk without a start, a different sequence, too many bytes, or an end that is not empty or not exact throws `malformed` and drops the transfer |

The server sends clipboard 0 only, always with sequence 0, as the capture
shows. The primary selection (id 1) is neither sent nor applied, and HTML and
bitmap formats are ignored.

Barrier 2.4 sends clipboards in 32 KiB chunks, and a client's transfer carries
other formats besides the text (measured in the addendum's chunk table). So the
session accepts inbound frames of up to 64 KiB (control frames other than
`DCLP` still go through the 4 KiB decoder limit) and transfers of up to 4 MiB,
of which the text may use 1 MiB. Before 2026-10-29 the frame limit was 4 KiB,
which ended the session on any client copy over about 1.6 KB.

Tests: `BarrierClipboardTests` (7) compare the framing with both captured
server transfers, rebuild the captured client transfer, round-trip chunked
text, keep a byte order mark, and reject malformed data and transfers.
`clipboardTransfer` in `BarrierClipboardControlEncoderTests` checks hand-built
golden bytes and the oversize path. The session tests are listed in
M2-029-FOLLOWUP-001.

## Rollback

Revert the three M2-028 files. For the clipboard transfer only, also revert
`BarrierClipboard.swift` and `BarrierClipboardTests.swift`; the session then
has nothing to send clipboard text with.
