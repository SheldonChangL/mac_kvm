# M2-032 Independent Review Disposition

## Review

A fresh-context agent that did not take part in the implementation reviewed the
clipboard and punctuation branch (PR #328) at `482472c`, read-only, on
2026-10-29. It found no High finding: no crash, unbounded memory or
session-ending path for malformed client clipboard input, no privacy leak, and
the punctuation codes and Barrier table match the SDK and the capture. PR #328
was merged at the owner's explicit request ("merge all pr") while these
findings were open; this follow-up addresses them.

## Findings and disposition

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| M1 | Medium | `ServerClipboardRouter.inbound` refused a client copy equal to the last sync even after the local clipboard moved on; the stale local then overwrote the client's newer copy on the next enter | Fixed: `inbound(_:from:generation:)` takes the current local generation and resets that client's guard when it differs from the generation recorded for the client. Test `clientCopyAfterLocalChange` |
| L1 | Low | The guard remembered an inbound payload before the local write succeeded, so after a failed write the same content was refused for good | Fixed: `applyFailed(from:)` forgets the admission; `ServerClipboard` calls it when the pasteboard write fails. Test `failedApplyIsForgotten` |
| L2 | Low | `ServerRuntime.serve` forgot the client before the sender task finished, so a late enter could record the reused client screen again and the next client would not get the clipboard | Fixed: `forget` runs after `await sender.value`. The app has no unit test target; covered by reading the code and the smoke |
| L3 | Low | A single `DCLP` frame over 64 KiB still ends the session, while the docs said transfers are dropped | Documented in the session header, the M2-028 doc and the M2-029-FOLLOWUP-001 doc. The bound stays at 64 KiB so an unauthenticated peer cannot make the server buffer more per frame; it rests on the Barrier 2.4.0 measurement |
| L4 | Low | The pasteboard is read after input is already remote; a pasteboard permission prompt would block the sender while the user cannot answer it | Open: needs the read moved to before the enter, which is a design change. The owner run on macOS 26.6.2 showed no prompt |
| L5 | Low | `ClipboardPayload` and `KVMEvent` renderings are not redacted although they now carry clipboard text | Open: no current path prints them; redacting a frozen KVMContracts public type needs the contract-change process |
| L6 | Low | Tests that would pass with plausible bugs | Fixed for the session and codec: `clientClipboardIgnored` now proves no event came before a marker, `clipboardTextLimit` pins the 1 MiB inbound text cap, `malformedFrames` pins sequence, mark, length, size-string and restart rules. `ServerClipboard` itself remains covered only by the smoke |

## Verification of the fixes

- RED: the new router tests failed to build against the old API. Mutation
  check: without the guard reset and with an empty `applyFailed`, both new
  router tests failed on their assertions; restored, all 13 passed.
- Mutation check for the new characterization tests: without the 1 MiB text
  guard, `clipboardTextLimit` failed; without the chunk sequence check,
  `malformedFrames` failed; restored, all 245 BarrierCompatibility tests passed.
- Gates and smoke for the follow-up commit are in the PR.
