# M2-032 Evidence Summary

## Scope

Exact Files: `Packages/KVMCore/Sources/KVMCore/ServerClipboardRouter.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ServerClipboardRouterTests.swift`,
`docs/components/M2-032-server-clipboard-router.md`.

Outside them, and needed to make the router reach a Barrier client:
`ServerSession.monitorPeer(inbound:)` (M2-029), the Barrier clipboard transfer
(M2-028, `BarrierClipboard.swift`, session send and receive), the app wiring
(`ServerClipboard.swift`, `ServerRuntime.swift`, `MacKVMApplication.swift`,
`SmokeDriver.swift`) and the M2-035 smoke script. The owner asked for clipboard
sharing on 2026-10-29 ("剪貼簿跟標點符號都做").

## RED

- Router tests before the router existed: `cannot find type 'ServerClipboardRouter' in scope`.
- Session test before `monitorPeer(inbound:)` existed: `extra trailing closure passed in call`.

## GREEN

- `swift test --filter "ServerClipboardRouter|ServerSession"`: 24 tests in 2
  suites passed (11 router, 13 session).
- Full gates at `cba4ca8` in `commands.json`: `make verify` 24/24, xcodebuild
  build succeeded, and the M2-035 smoke against a real Barrier 2.4 client
  passed every case, including `clipboard-to-client`, `clipboard-from-client`,
  `clipboard-not-echoed` and `clipboard-on-reconnect`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| local clipboard → active client | `localToClient`, `everyClientOnce`; smoke `clipboard-to-client` |
| remote → local origin tracking | `clientToLocal`, `inboundHashRecomputed`; smoke `clipboard-from-client` |
| several clients, no echo storm | `noEchoStorm`, `clientToLocal`; smoke `clipboard-not-echoed` |
| boundary / limit | `sizeLimit`, `sameContentNewGeneration`, `nothingToSend` |
| invalid input | `invalidInbound` |
| cleanup / idempotency | `forget`; smoke `clipboard-on-reconnect` |
| no payload in logs | `redacted`; reports carry no text, size or hash |

## Manual

Owner run on 2026-10-29 with the build of `cba4ca8`, the real Mac pasteboard and
the owner's Linux desktop: the owner reported "驗證功能ok" for punctuation keys
and clipboard both ways. The server log shows one send on an enter, one receive
on a return, and no re-send on the next two enters. Details:
`evidence/issues/M2-035/owner-run/README.md` (Punctuation keys and clipboard).
The smoke used the in-memory stand-in on the Mac side by design.

## Review

Pending independent review.
