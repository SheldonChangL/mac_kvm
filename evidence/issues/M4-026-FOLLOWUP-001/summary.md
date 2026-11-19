# M4-026-FOLLOWUP-001 Evidence Summary

## Scope

Files: `Apps/Linux/MacKVMClient/ClientRuntime.swift`,
`Packages/KVMCore/Sources/KVMCore/ClientCoordinator.swift`,
`Tests/Integration/LinuxClientRuntimeTests.swift`, and this directory.
Issue #375, PR #376, Tier C (client runtime and coordinator; TLS transport and protocol session
untouched). Base `42a7691feb7b`; reviewed at `f1cd4a6`; review fixes at `3c34134`.

Defect (found by the #351 E2E rerun after #373, case `clipboard-large-to-client`): a 600 KB server
clipboard was never pasted on the Linux client display. The session stayed up and the server logged
the clipboard as sent, but `xclip -o` on the client kept returning the previous text.

## Root cause

Not the X11 layer, not size, not timing. `BarrierClientProtocolSession` emits every inbound clipboard
with `contentHash: ""` (`Packages/BarrierCompatibility/.../BarrierClientProtocolSession.swift:640-643`).
The runtime relayed it unchanged (`ClientRuntime.swift:386-388`, before the fix) into
`ClientCoordinator.applyInbound` (`ClientCoordinator.swift:423`), which calls
`ClipboardLoopGuard.admitInbound`. Rule 4 of that guard (`ClipboardLoopGuard.swift:94-99`) rejects a
payload whose hash equals the last admitted one. The first inbound clipboard stores `""`, so every
later server clipboard in the same session is dropped as `loopRejected` and never reaches
`LinuxX11Clipboard`. `beginSession()` resets the guard, so the first clipboard after each reconnect
passes. In the E2E the reconnect clipboard is first, so the 600 KB one is second.

Diagnosis (`commands.json`):

- `diagnose-e2e-baseline`: reproduces on origin/main, `clipboard-large-to-client=fail`,
  `automated=1 failed of 22`.
- `diagnose-x11-serving`: `LinuxX11Clipboard` serves 600015 bytes to real `xclip -o` through INCR,
  exact, in 0.0078 s. This rules out the X11 layer.
- `diagnose-instrumented-repro`: with temporary stderr lines (not committed) the session reassembled
  all 600027 bytes, then `admit refused clipboard(...loopRejected)`; `xclip` returned the 11-byte
  earlier text for 28.2 s of polling. The 3 s window is therefore not the cause and is unchanged.

## Fix

`ClientRuntime` gives each inbound clipboard event a content hash before the coordinator sees it,
using `LinuxX11ClipboardRules.contentHash` (SHA-256 of the UTF-8 bytes), the same function
`LinuxX11Clipboard` uses for local reads (`LinuxX11Clipboard.swift:56-61, 656`). Both directions now
agree as rule 4 requires, which also restores client-side echo suppression when a third-party
clipboard manager re-takes the selection with identical content.

Review fix F2: `ClientCoordinator.applyInbound` rejects an empty hash (`assertionFailure` in debug,
counted as `loopRejected` in release and the payload is dropped). Guard semantics are unchanged.

## Tests

- RED then GREEN: `M4-026-FOLLOWUP-001: a second server clipboard in one session, 600 KB, is applied`.
  - `red` (origin/main sources): exit 1, `Time limit was exceeded: 60.000 seconds`.
  - `review-followup-red` (after F4): fails after 5.111 seconds with
    `inbound clipboards applied 1 of 2, loopRejected 1`.
  - `green`: passes in 0.134 s.
- `M4-026-FOLLOWUP-001: a local re-read of an applied server clipboard is not echoed` (review F1). The
  fake clipboard hashes local reads with `LinuxX11ClipboardRules.contentHash`.
  `review-followup-mutant-other-hash` (a different hash in `withContentHash`) is killed by it:
  `outboundClipboardAdmitted → 1` expected 0.
- Why fake-clipboard tests and not Xvfb: the failing layer is runtime plus coordinator loop guard.
  The Xvfb probes showed X11 serving is correct. Existing Xvfb clipboard, INCR and size-limit tests
  stay green.

Gates (`commands.json`):

| Gate | Result | Commit |
| --- | --- | --- |
| Linux arm64 `swift:6.2.3-jammy`, focused, `-warnings-as-errors` | `✔ Test run with 93 tests in 6 suites passed` (`review-followup-linux-focused`) | `3c34134` |
| Linux full, `MACKVM_X11_TESTS=1`, xvfb-run | `✔ Test run with 522 tests in 54 suites passed after 6.372 seconds` (`review-followup-linux-full-xvfb`) | `3c34134` |
| macOS `swift test` | `✔ Test run with 332 tests in 29 suites passed` (`review-followup-mac-swift-test`) | `3c34134` |
| `make verify` | three `[PASSED]` lines, exit 0 | `f1cd4a6` |
| `make code-quality-check` | passed | `f1cd4a6` |
| `make docs-check` | `docs check OK` | see Residual notes |
| `validate_package.py` | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` | `f1cd4a6` |
| Evidence tool tests | `Ran 246 tests`, `OK` | recorded in `commands.json` |
| E2E rerun, PR #371 script | `clipboard-large-to-client=pass`, `automated=0 failed of 22` | `f1cd4a6` |

The XML header reads `tests="521" failures="0" skipped="1"` with 522 `testcase` elements, the same
counting difference as M1-055-FOLLOWUP-002.

## Acceptance mapping

| Criterion (issue #375) | Evidence | Status |
| --- | --- | --- |
| Diagnose first: locate the failing layer with evidence; change the 3 s window only if data arrives late | `diagnose-*` entries; the window is unchanged because the data never arrived | Met |
| RED: an Xvfb-backed test reproduces the failure at the failing layer | Fake-clipboard runtime test, `red` and `review-followup-red` | Met with deviation (see Residual notes) |
| GREEN: that test passes; existing clipboard, INCR and size-limit tests stay green | `green`; `review-followup-linux-full-xvfb` 522 passed | Met |
| The #351 case `clipboard-large-to-client` passes when rerun (arm64 container + Xvfb, Mac smoke server on loopback) | `e2e-rerun`: `clipboard-large-to-client=pass`, `automated=0 failed of 22` | Met, at `f1cd4a6` |
| Outcome: memory and time bounded; a stalled INCR requestor must not hang the client | Existing INCR stall bound (5 s after the last chunk) unchanged and not re-tested beyond the existing suite | Unchanged, not re-tested |

Because the last open item of #372 (`clipboard-large-to-client` passing on rerun) is now met by this
PR's E2E rerun, the PR also closes #372.

## Independent review

Tier C, fresh-context Opus, at `f1cd4a6`: APPROVE with notes, no Blocker, High or Medium; 3 Low
(F1 to F3) and 2 Nit (F4, F5). Details and per-finding disposition are in `independent-review.md`.

## Residual notes

- The E2E rerun (22 of 22 automated cases) ran at `f1cd4a6`, before the review fixes. Those fixes add
  tests and a 4-line empty-hash guard in `ClientCoordinator`. The E2E was not rerun at `3c34134`.
- `make verify` and `make code-quality-check` were last run at `f1cd4a6`.
- The E2E script and its output belong to PR #371 and are not committed here, so the E2E result
  cannot be reproduced from this branch alone.
- The issue asked for an Xvfb-backed RED test. It is fake-clipboard based because the diagnosis ruled
  X11 out; the Xvfb probes are recorded in `commands.json`.
- F3 (the client loop guard is not reset by a local copy made while inactive, so an identical later
  server clipboard is dropped) is pre-existing, not a regression, and still open.
- The owner-hardware half of M4-036-FOLLOWUP-001 has not been run.
- CI result: see PR checks.
