# M1-055-FOLLOWUP-002 Independent Review

- Reviewer: fresh-context Opus agent, Tier C
- Date: 2026-11-18
- Target: PR #373 at `a769b94`
- Verdict: APPROVE with minor notes; 3 Low, 2 Nit; static review only (Docker was degraded)

## Review (reviewer findings, as recorded)

The lines below are the reviewer's findings from the review record. Text after `FIX:` in the
record was added later by the implementer and is moved to the Resolution table.

> State machine traced: pause/resume race-safe (no lost wakeup, re-pause keeps heldRead, repeated resume harmless), no double resume / continuation leak, EOF/error/close while paused delivers queued data then ending, 1 MiB hard cap never bypassed. All suites have .timeLimit(.minutes(1)).
> 1. Low: doc comment overstated overshoot ("one read"): real = one read event (maxMessagesPerRead 4 x up to 64 KiB) + NIOSSL's own context.read(); bounded by 1 MiB.
> 2. Low: dropping/breaking out of incomingBytes no longer ends lifecycle (connection stays open, reads paused until disconnect).
> 3. Low: stalledConsumerIsBounded proved pause only indirectly.
> 4. Nit: slowConsumerLargePayload weakly exercises stall. 5. Nit: weak PullSource back-reference ends stream with nil — acceptable.

## Resolution (later FIX notes, implementer, at `656ef69`)

| Finding | Resolution |
| --- | --- |
| Low 1: overshoot overstated | Fixed: doc reworded (class comment and platform doc); `maxMessagesPerRead` unchanged. |
| Low 2: dropping `incomingBytes` keeps the connection open | Documented as intended. |
| Low 3: pause proved only indirectly | Fixed: `stalledConsumerIsBounded` asserts peak <= `inboundHighWaterBytes` + 512 KiB. |
| Nit 4 | Not changed. |
| Nit 5 | Accepted by the reviewer; not changed. |

Gates after the fixes: Linux arm64 focused 49 of 49 (`-warnings-as-errors`); macOS `swift test` 332;
`docs-check`; `validate_package.py`; swift-format strict lint; CI build-test-manifest and
verify-linux SUCCESS at `656ef69`.
