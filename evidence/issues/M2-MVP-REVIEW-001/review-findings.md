# M2 Mac Server MVP — Fresh-context Review Disposition

Reviewer: a separate fresh-context Claude Opus subagent, read-only, over
`main..7c64250`. This is an AI self-review aid; it does not replace the
required independent human/Codex review.

Result: Critical 0, Medium 4, Low/Medium 1, Low 5 (including weak tests).
Wire bytes matched BARRIER-EVID-0004/0005; no guessed bytes, no logging, no
architecture violations, no new public API.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | Medium | Cancelling `BarrierServerProtocolSession.connect()` disabled the handshake timeout | Fixed `39859ad`; regression test hung before the fix |
| 2 | Medium | Listener connect timeout depended on transport cancellation | Fixed `dc5a1ee`; non-cooperative fake hung before the fix |
| 3 | Medium | Leave during an in-flight enter could leave the client entered | Fixed `15ca0fc` (`entering` state; leave closes the session) |
| 4 | Medium | Keys/buttons held at switch time could stay stuck after return | ADR amended `13a2437`; fixed `defda26` (no activation while local input held) |
| 5 | Low/Medium | Server never sends keepalive (`CALV`) | Open: keepalive timing is not frozen (M2-023); a periodic sender also needs a write path serialized with session sends. Live sessions may drop; failure direction is local |
| 6 | Low | Opaque `CINN` mask `0x2000` replayed | Accepted in the proposed M2-023; reviewer attention item |
| 7 | Low | `recoverAll` discarded the cleared active target | Fixed `2dab44d` (`RecoveryOutcome.recoveryAction`) |
| 8 | Low | Failed preferred warp did not fall through | Fixed `821b381` |
| 9 | Low | Second concurrent `CaptureQueue.next()` overwrote the first waiter | Fixed `9076883` |
| 10 | Low | Tautological suppressor concurrency test; no effect executor | Test replaced `7ebbdab`; the effect executor / app composition root remains open (blocked with the live path) |
