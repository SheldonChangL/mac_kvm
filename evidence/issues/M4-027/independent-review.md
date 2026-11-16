# M4-027 Independent Review

- Reviewer: fresh-context Opus agent, Tier C/H (STRONG_REVIEW_PROMPT)
- Date: 2026-11-17
- Target: `74ddbf2` (PR #364)
- Verdict: approve with nits; nothing blocks the merge

## Review (verbatim)

> Reviewer: fresh-context Opus agent, Tier C/H (STRONG_REVIEW_PROMPT), 2026-11-17, target head 74ddbf2 (PR #364).
> Verdict: APPROVE WITH NITS. Nothing blocks the merge.
> Ran: detached worktree in scratchpad (removed; main checkout untouched); Docker native arm64 swift:6.2.3-jammy built from the PR's evidence Dockerfile, `MACKVM_X11_TESTS=1 xvfb-run … swift test --filter LinuxScreen`; baseline 3 runs, each "18 tests in 3 suites passed", about 0.59s. Without MACKVM_X11_TESTS the Xvfb suite skips silently (still "18 passed", 0.001s). CI run 43873949286 X11 stage: "33 tests in 6 suites passed after 1.001 seconds", matching the PR's 33 Xvfb cases.
> Own mutants: M2 remove the `stopped` guard in currentGeometry (LinuxScreenBackend.swift:194) caught (SIGSEGV on the closed Display after stop); M3 pointer motion counted as a change and published unconditionally caught; M1 remove the EOF peek (:260 `|| connectionClosed(...)`) survived, serverLoss still passes; M4 XEventsQueued QueuedAfterReading in the drain loop (:293) survived.
> MEDIUM :191-195, 308: the query connection has no EOF guard; only the event thread detects loss. If the X server dies before markLost and currentGeometry or publish runs, XGetGeometry on the dead socket triggers Xlib's default IO handler and the process exits, contradicting the doc at :74-76 ("currentGeometry fails with subsystemUnavailable"). serverLoss passes only because it waits for the stream to finish before querying. Fix: document that the process may exit on display loss, or poll/peek the query connection too.
> LOW :260 EOF peek redundant on Linux and untested (M1 survives because poll already reports POLLHUP); M4 survives: the QueuedAlready-only defence has no test. Design is right but both defences are unverified.
> LOW :224: with multiple screens, a pointer on another screen makes XQueryPointer return False and the whole geometry fails; fail-closed, acceptable, not written in the issue.
> LOW :346-352: after loss both Displays are deliberately left open (fd and memory); documented on the assumption the composition root exits on display loss; confirm the plan carries that assumption.
> LOW tests LinuxScreenBackendTests.swift:282-291: openBackend retries up to 8 times on any error, including capabilityUnavailable, not only refused connections; the ~8% refusals are unexplained (Xvfb -displayfd writes the number after the socket exists). Not a product bug (the product opens once and fails), but restrict the retry to refused connections and record the cause.
> Extras LinuxScreenError and LinuxScreenGeometryRules: package-level, small, acceptable.
> Holding: no XInitThreads; the query connection used under a lock throughout, the event connection only by the event thread (h.8). stop idempotent, concurrent stops serialized by shutdownLock; wake pipe then thread join, then connections closed. poll does not busy-loop (timeout -1, EINTR retried, wake pipe ends the loop). Every open failure path closes opened connections and the pipe. No RandR returns capabilityUnavailable (fail closed). No logging. XGetGeometry on the root clamped to 1...0x7FFF, consistent with DINF. Stream finishes on display loss. Error shapes terminal, no cleanup needed.

## Resolution

| Finding | Resolution |
| --- | --- |
| Medium, query connection has no EOF guard | Fixed at `1b3b460`. `currentGeometry` and the report path peek the query connection for EOF first; on EOF they mark the session lost, finish `changes` and return `subsystemUnavailable`. The package test seam `init(displayName:runsEventThread:)` lets a test query a dead server with no event thread; mutant Q3 (guard removed) is killed, and a second test kills the server then queries with the event thread running. A server dying in the middle of a query cannot be guarded (Xlib's IO handler cannot return); documented. |
| Low, EOF peek untested, `QueuedAfterReading` defence untested | L1 (no POLLHUP and no EOF check) is killed by the server-loss test. L2 (`QueuedAfterReading`) cannot be scheduled by a test; recorded as a documented survivor. 25 mutants, 24 killed. |
| Low, pointer on another screen fails the whole geometry | Documented as fail-closed. |
| Low, lost Displays left open | The doc states the composition root exits on display loss (plan b.16, amendment h.8 continued). |
| Low, test retry covers any error and the refusals are unexplained | Cause confirmed with a raw Xlib loop in the arm64 container: Xvfb resets when its last client disconnects and a connection made during the reset is dropped (556 of 600 opens failed without a kept client, 0 of 600 with one). Each test Xvfb now keeps one sentinel connection and the retry is removed. The X11 suite is `.serialized`; the descriptor-leak test runs 40 iterations. |
| Extras `LinuxScreenError`, `LinuxScreenGeometryRules` | Accepted by the reviewer; recorded in `summary.md`. |

Verification after the fixes (head `1b3b460`): the Linux container passed 15 of 15 runs (20 tests
in 3 suites); macOS `swift test`, `-warnings-as-errors` and `make verify` (24 gates) exit 0; both
CI jobs pass at `1b3b460`. The first `verify-linux` attempt failed on an unrelated flaky M1-064
test (thread name), passed on rerun, and is fixed separately.
