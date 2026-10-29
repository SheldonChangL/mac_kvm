# M2-032 Server Clipboard Router

## Outcome

`KVMCore` now has `ServerClipboardRouter<Generation>`, a value that decides
which clipboard contents cross between the server's local clipboard and its
client screens. Declarations are `package`. It consumes the frozen
`ClipboardPayload` (M1-013), `ClipboardByteLimit` (M1-052) and
`ClipboardLoopGuard` (M1-054); no public contract is added.

The owner asked for clipboard sharing on 2026-10-29 ("剪貼簿跟標點符號都做").

## API

| Declaration | Purpose |
| --- | --- |
| `init(limit:)` | caller-supplied UTF-8 byte limit for both directions |
| `outbound(to:generation:read:)` | the payload to send to a client as it becomes active, or `nil` |
| `inbound(_:from:generation:)` | admits a client's payload, given the current local generation, and returns it with the router's hash for the caller to apply; or `nil` |
| `applied(generation:from:)` | records the local generation that applying a client's payload produced |
| `applyFailed(from:)` | forgets what was just admitted from a client whose payload could not be applied |
| `forget(_:)` | forgets a client that went away; idempotent |

`Generation` is the caller's opaque local clipboard generation, such as the
pasteboard change count; only equality is used.

## Rules

- **Local to the active client.** A client is sent the local clipboard only
  when it does not hold the current generation yet. `read` is called only then,
  and the generation is recorded whatever the outcome, so a clipboard without
  text, an oversized one, or content the client already holds is not read
  again until the local clipboard changes. This matches Barrier, whose server
  sends a clipboard on enter only when it is dirty for that client.
- **Remote to local origin tracking.** A client's payload must have remote
  origin and pass that client's guard. After the caller applies it, the
  resulting local generation is recorded for that client, so the content never
  goes back to it. The guard's memory only counts while the local clipboard is
  still at the generation recorded for that client: once it moved on, the
  same content from the client is a new copy and is applied. A payload the
  caller failed to write is forgotten (`applyFailed`), so it can be admitted
  again.
- **Several clients, no echo storm.** Each client has its own
  `ClipboardLoopGuard`. Content from one client still reaches the others once
  each, while the same content coming back from any client, under any
  transaction, is refused.
- **Content hash.** Computed here for both directions, whatever a peer
  supplied: 64-bit FNV-1a over the UTF-8 bytes, with the byte count. It only
  identifies content for loop suppression, never leaves the guards and is not
  cryptographic; a crafted collision can only suppress a transfer.
- **Size.** Text over the limit is refused both ways before hashing.

## Wiring (macOS app)

`Apps/macOS/MacKVM/ServerClipboard.swift` puts the router behind a lock over a
`LocalClipboard`: the M1-053 `MacPasteboardAdapter` when serving, an in-memory
stand-in for the DEBUG smoke driver, so a smoke run never touches the owner's
pasteboard. `ServerRuntime` sends the outbound payload right after a
successful enter, as Barrier does, and applies `.clipboard` events from
`ServerSession.monitorPeer(inbound:)`. The limit is the Barrier session's
1 MiB. Reports say only `clipboard sent to the client` or
`clipboard received from the client`: no text, size or hash (M1-011).

## Tests

`ServerClipboardRouterTests` (13): local change sent once, each client once,
client copy applied and not sent back but reaching the other client, no echo
storm with two clients, a client copy equal to the last sync applied once the
local clipboard moved on, a copy whose write failed admitted again, inbound
hash recomputed, same content not re-sent, size boundary both ways, empty
local clipboard not re-read, local-origin and replayed inbound refused, forget
and idempotent forget, no rendering contains text.

The M2-035 smoke script checks the whole path against a real Barrier 2.4
client: the local clipboard reaches the client on enter, the client's copy
comes back on leave, it is not echoed on the next enter, large clipboards go
both ways (600 KB out, 100 KB back in 32 KiB chunks), and a reconnected client
gets the clipboard again.

## Known limitations

- Plain text only. The primary selection, HTML and bitmap formats are not
  shared.
- A clipboard moves only with a screen change: the local one on enter, the
  client's on leave.
- The app has one client; several clients are covered by the router tests
  only.
- The local generation is read after the write. If another app changes the
  pasteboard in between, that change is not sent to that client (M1-053
  documents the same window).
- Pasteboard privacy prompts: on macOS 26.6.2 the owner run read the
  pasteboard without a blocking prompt. Other macOS versions are not
  verified.

## Rollback

Revert this file, the router, its tests, `ServerClipboard.swift`, and the
clipboard lines in `ServerRuntime.swift`, `MacKVMApplication.swift` and
`SmokeDriver.swift`.
