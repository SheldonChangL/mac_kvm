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
| `clipboard(_:limit:)` | none | size checked first (`clipboardOversized`), then always `clipboardWireContractNotFrozen` |

A failed `enter` does not consume the single supported enter. A second enter
fails closed with `repeatedEnterUnsupported`; the session owner must end and
re-establish the session instead of guessing sequence semantics.

Normalized positions map to `origin + round(n × (size − 1))`. For clients
whose `DINF` origin is negative, positions that map below zero fail closed
with `coordinateOutOfRange` (frozen signedness rule).

## Privacy

No payload text, coordinates or bytes are carried in errors; clipboard text is
read only for its byte count.

## Tests

`BarrierClipboardControlEncoderTests` (6): golden `CINN`, normalized mapping,
golden `COUT`/`CALV`, single-enter rule, coordinate bounds, clipboard
fail-closed.

## Rollback

Revert the three M2-028 files.
