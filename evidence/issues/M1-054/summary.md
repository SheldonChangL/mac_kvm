# M1-054 Evidence Summary

## Issue / Commit

- Issue: M1-054 — `實作 Clipboard Origin／Hash Loop Prevention 與 Size Limit`,
  GitHub #33; P1, risk high, execution tier `B`,
  `low_model_autonomous_merge: false`.
- Branch: `feat/m1-054-clipboard-loop-guard`
- Base: `5ecdc30beb6607e66c3b9c8e53b3c3d20b52b5fb`
- Implementation commit under test:
  `820c57b321611cc4065e1e6d0babfc0f92689146`.
- Evidence commit: **pending**. Its SHA is not known when this package is
  written.
- Status: **reviewer validation complete at the implementation commit.** The
  Codex root reviewer's five-axis review passed, with no Critical or High
  finding. Pending: the evidence commit, push, PR, GitHub CI, a current-head
  conflict check, a PR review comment, merge, and a post-merge audit.
- Authorship: **Claude Opus** authored all repository content: source, tests,
  the component document and this evidence. The **Codex root reviewer**
  authored no repository content. It performed the review, ran every command,
  made the commit, and handles the workflow operations. The author ran no
  commands. Every result below is the reviewer's, transcribed.

## Change Summary

A package-scoped `Sendable` value, `ClipboardLoopGuard`, in `KVMCore`:

- **Size first:** the payload's UTF-8 byte count is checked against a
  caller-supplied `ClipboardByteLimit` before any other check. Over the limit
  is `clipboard.oversized`; exactly at the limit is accepted.
- **Origin:** `admitOutbound` requires `.local`; `admitInbound` requires
  `.remote`. Anything else is `clipboard.loopRejected`.
- **Replay/echo:** the guard remembers only the transaction ID and opaque
  content hash of the last admitted payload. A payload that repeats either one
  is `clipboard.loopRejected`. This suppresses immediate replay and echo.
- **State:** a rejection leaves state unchanged. `reset()` is idempotent.
- **Privacy:** no logging. Errors carry only the four fixed taxonomy fields.
  The guard's `description`, `debugDescription` and mirror are redacted, so
  content, IDs and the hash are never rendered.
- **Not added:** a public contract, protocol message, network, Barrier,
  platform or UI code, a timer, retry or I/O, and global mutable state.

Design detail is in `docs/components/M1-054-clipboard-loop-guard.md`.

## Exact Files Changed

Implementation commit `820c57b321611cc4065e1e6d0babfc0f92689146` (exactly
these three):

- `Packages/KVMCore/Sources/KVMCore/ClipboardLoopGuard.swift`
- `Packages/KVMCore/Tests/KVMCoreTests/ClipboardLoopGuardTests.swift`
- `docs/components/M1-054-clipboard-loop-guard.md`

Evidence (this package, required by the Issue): `summary.md`, `commands.json`,
`environment.json`, `tests/results.json`, `tests/review-findings.json`.

No existing file was modified. The protected untracked owner artifacts at the
repository root were not touched or staged.

## Acceptance Criteria Evidence

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met.** Each Scope focus item has a source location and named tests. Origin transaction ID/hash: the origin, transaction and hash checks. 相同 payload 不回送: echo and replay suppression. Oversize rejected without leaking content: the size-first check plus the privacy tests. | component doc; `tests/results.json` `focusMapping` |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** `swift test --package-path Packages/KVMCore`: 47 passed, 0 failures, 1 system opt-in skipped. See the category table below. | `tests/results.json` |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** Every declaration is `package` or narrower. It uses only the frozen `ClipboardPayload`, `ClipboardByteLimit` and `CoreError` values, with no taxonomy case added. The reviewer found no conflict with the canonical, frozen or guardrail sources. | source; component doc; `tests/review-findings.json` |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met.** architecture-check 0; strict lint 0 with empty output; warnings-as-errors 0; xcodebuild `** BUILD SUCCEEDED **` with only nonfatal, preexisting destination/platform-discovery warnings and no source warning attributed to M1-054; unit tests 0; `make verify` 19/19. | `commands.json` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** The guard has no logging call and emits no diagnostic. Tests render rejections and the guard through description, reflection, interpolation, `dump` and JSON, and find no text, hash, ID or byte count. | `tests/results.json` `coverage.privacy` |

### Automated test categories

| Category | Evidence |
| --- | --- |
| Happy path | first outbound and inbound admission; successive distinct payloads; content admitted again after other content |
| Boundary / limit | exactly at the limit; one byte over, in both directions; UTF-8 bytes, not characters; empty text; oversized value equal to M1-052; size checked before origin and identity |
| Invalid input / failure | remote payload offered outbound; local-origin payload inbound; repeated transaction; repeated hash; exact same payload twice; cross-device duplicate |
| Cancel / cleanup / idempotency | **No async work or resource to cancel.** The cleanup evidence is: `reset()` forgets state; repeated `reset()` is idempotent; every rejection leaves state unchanged; copies are independent; replay is deterministic |
| Concurrency | `Sendable`; detached task; independent owners in a task group; one owning actor serializing concurrent admissions |

## Commands

All were run by the Codex root reviewer against implementation commit
`820c57b321611cc4065e1e6d0babfc0f92689146`.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `swift test --package-path Packages/KVMCore` | 0 | build complete (2.42s); 47 passed, 0 failures, 1 system opt-in skipped; `arm64e-apple-macos14.0` |
| 2 | `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 | `** BUILD SUCCEEDED **`; `arm64-apple-macos14.0` |
| 3 | `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| 4 | `make architecture-check` | 0 | `architecture check OK` |
| 5 | `make docs-check` | 0 | `docs check OK` |
| 6 | `make code-quality-check` | 0 | swift-format version, strict lint and warnings-as-errors all exit 0 |
| 7 | `git diff --check 5ecdc30beb6607e66c3b9c8e53b3c3d20b52b5fb..820c57b321611cc4065e1e6d0babfc0f92689146` | 0 | no output |
| 8 | `make verify` | 0 | 19/19 gates passed; report `artifacts/ci/m1-008-report.json` (ignored, not committed), SHA-256 `074c4c85a2cab9d1a2efe834b788283495654dc0d5e7032fdf9326a2260da6da` |

Commands 1, 2, 6 and 8 were run outside the managed sandbox. The first
attempts inside the managed sandbox failed only because of nested-sandbox and
user-Library restrictions. That is an environment limitation, not a product
failure. The equivalent direct reruns outside the sandbox passed.

Command 1 was run in its exact form. It resolves the repository-root
`Package.swift` and passes. The component document records the same fact.

Start and end timestamps were not captured, so they are recorded as `null` in
`commands.json`.

## Manual Verification

None is required for M1-054. The Issue states that there are no mandatory
real-machine steps, and the reviewer re-ran the Required Commands. The guard
has no platform, pasteboard, network or UI dependency.

## Architecture & Security Checks

- **Boundary:** `KVMCore` only, with a `package` API. It imports only
  `KVMContracts` and uses the frozen values. There is no Protocol, network,
  Barrier, platform or UI change. `make architecture-check` passed.
- **Fail-closed:** size is checked first, then origin, then identity. Each
  rejection leaves state unchanged. There is no retry, sleep, timer or latch.
- **Bounded state:** the guard retains exactly one identity. See Low finding
  L2 on the hash string's length.
- **Privacy:** no logging. The fixed four-field taxonomy has no free text. The
  guard's renderings are redacted. This evidence contains no clipboard text,
  hash, transaction ID, device ID, secret or token.

## Five-axis review (Codex root reviewer)

This is a **non-author Codex review, not a human review.**

1. **Source validity and traceability: pass.** Dependencies M1-052 and M1-053
   are closed, and their evidence is readable. Issue #33 is current and matches
   the source. The canonical, frozen and guardrail sources do not conflict.
2. **Product and architecture: pass.** The API is package-only in `KVMCore`
   and uses the frozen `KVMContracts` values. There is no public API and no
   cross-boundary implementation.
3. **Security, fail-safe and compatibility: pass.** It fails closed. Retained
   state is bounded to one identity. No content is logged, and the taxonomy is
   fixed. Rejection leaves state unchanged, and reset is idempotent.
4. **Tests, validation and acceptance: pass,** with the command results above.
5. **Scope, hygiene and rollback: pass.** The implementation commit contains
   exactly the 3 Exact Files, and the evidence is the package the Issue
   requires. The protected owner artifacts were not touched or staged.
   Rollback is additive.

Findings: **Critical 0, High 0, Medium 1 (open, non-blocking), Low 2 (open).**
There is no blocker. Details are in `tests/review-findings.json`.

## Known Limitations

1. **Medium, open, non-blocking — GitHub #268** (owner: Product Owner, P1).
   Consider a delayed echo of superseded payload A that arrives after B.
   Current payload metadata cannot tell that apart from a user deliberately
   copying A, then B, then A again. So the guard admits it. #268 blocks only a
   future claim of delayed-history suppression; it does not block M1-054 or the
   M1 exit. A frozen policy is required before any implementation.
2. **Low, open:** the content hash is caller-provided and not verified against
   the text. A wrong hash can suppress one transfer or let one extra echo
   through. It cannot bypass the origin or size checks.
3. **Low, open:** the retained hash string's length is whatever the caller
   supplied. The number of retained identities is fixed at one.

Also documented in the component document: reset timing is left to the owner
of the clipboard link. Loop rejection reuses the M1-052 `warning` severity.

## Scope exclusions (not implemented)

- Protocol messages, wire format, networking, pasteboard access and UI.
- Hash computation, algorithm choice and verification.
- A default, minimum or maximum byte limit.
- A history window, capacity, expiry, timer or retry.

## Follow-up Issues

- **GitHub #268:** a policy for suppressing delayed echoes of superseded
  payloads. A frozen policy is required first.

## Rollback Instructions

Revert implementation commit `820c57b321611cc4065e1e6d0babfc0f92689146` and
the M1-054 evidence commit. There
is no persistence, migration, wire format or runtime resource to clean up.
Any Issue rollback condition would trigger this revert: a crash, a data leak, a
silent trust bypass, weakened assertions, or deviation from the frozen
contract. None has been observed.

## Reviewer Required

- **B:** full review by a stronger model or an engineer. The Codex root
  reviewer's non-author five-axis review is complete and passed. It is a model
  review, not a human review.
- **No autonomous merge** (`low_model_autonomous_merge: false`). The following
  remain reviewer duties: the evidence commit, push, PR, GitHub CI, a
  current-head conflict check, a PR review comment, merge, and a post-merge
  audit.
