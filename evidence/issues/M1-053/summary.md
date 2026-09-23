# M1-053 Evidence Summary

## Issue / Commit

- Issue: M1-053 — `實作 NSPasteboard Read／Write Adapter`, GitHub #29; P1, risk
  high, execution tier `B/H`, `low_model_autonomous_merge: false`.
- Branch: `feat/m1-053-mac-pasteboard-adapter`
- Base: `e84ecee5e269912e46298b3a48f8911c97f86c07`
- Commit under test: `5ca459acea932fd7324450d34224934ac12de22a`
- Evidence commit verified: `b940d166bb68f1fa56572dc687bf5153cc6c6faf`
- Status: **non-author review complete.** The Codex root reviewer's five-axis
  review passed. `make verify` passed 19/19 at the evidence commit. Remote
  `main` is still the base, with no merge conflict.
- PR, GitHub CI and merge: **pending.** The evidence-finalization commit SHA is
  not known yet. A final-head re-run and GitHub CI remain reviewer duties
  before merge.
- Authorship: **Claude Opus 5.5** authored all repository content: source,
  tests, the component document and this evidence. The **Codex root reviewer**
  found the review findings, ran every command and the Tier-H probe, and drove
  remediation; it authored no repository content. The author had no shell tool
  in any M1-053 session, so every result below is the reviewer's, transcribed.

## Change Summary

A package-scoped, immutable `Sendable` `MacPasteboardAdapter` over AppKit
`NSPasteboard`, with the following behavior:

- **Content:** reads and writes UTF-8 plain text only, bounded by a
  caller-supplied `ClipboardByteLimit`.
- **Change count:** observes it on demand as an opaque value. A read observes
  it before content; a write returns the count observed after success.
- **Failures:** each one maps to the frozen M1-015 `CoreError` taxonomy:
  - `clipboard.unsupportedType` for an empty or non-text pasteboard;
  - `clipboard.oversized`, identical to M1-052;
  - `internal.unclassified` for an advertised string that reads as nil, a
    refused clear, or a refused write;
  - `permission.capabilityUnavailable` for an explicit macOS 15.4+
    `.alwaysDeny` read, checked before anything is observed.
- **Seam:** an internal six-closure seam keeps ordinary tests off every real
  pasteboard.

Design detail is in `docs/components/M1-053-mac-pasteboard-adapter.md`.

## Exact Files Changed

Implementation commit (exactly these three):

- `Packages/MacPlatform/Sources/MacPlatform/MacPasteboardAdapter.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/MacPasteboardAdapterTests.swift`
- `docs/components/M1-053-mac-pasteboard-adapter.md`

Evidence (this package): `summary.md`, `commands.json`, `environment.json`,
`manual.md`, `manual-output.log`, `tests/results.json`,
`tests/tier-h-probe.json`, `tests/review-findings.json`.

The protected untracked owner artifacts at the repository root were not read,
modified, staged or deleted.

## Acceptance Criteria Evidence

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met.** changeCount monitoring, plain-text read/write, and the permission/empty/invalid-data behaviors each have a source location and named tests. | component doc; `tests/results.json` `coverage` |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** 63 passed, 0 failures, 3 opt-in probes skipped by default. Cancellation is not applicable (synchronous, no owned resource); cleanup and idempotency are covered by the repetition/recovery tests and the probe's `releaseGlobally()` defer. | `tests/results.json` |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** Every declaration is `package` or narrower; no AppKit type on the package surface; no taxonomy case added; C-007 UTF-8-only and caller limit honored. Source/canonical/frozen review found no conflict. | component doc; source |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met at the implementation commit.** architecture-check 0; strict lint 0 findings; warnings-as-errors 0; xcodebuild `** BUILD SUCCEEDED **` with nonfatal destination warnings only, none attributed to M1-053; unit tests 0. `make verify` 19/19 at evidence commit `b940d16`. | `commands.json` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** No production logging call. Failure encoding, renderings, and `MacPasteboardText` redaction are tested. The probe output is closed vocabulary. | `tests/results.json` `privacy`; `manual-output.log` |
| 6 | Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證 | **Met for the unique-pasteboard path:** the Codex root reviewer (not the author) ran the probe, which passed. **Not covered:** the general clipboard, access prompts, and a real `.alwaysDeny`. | `manual.md`; `tests/tier-h-probe.json` |

### Automated test categories

| Category | Evidence |
| --- | --- |
| Happy path | round trip, ordered read/write, empty text, plain text among other types |
| Boundary / limit | exact limit accepted and one byte over rejected for eight texts, in both directions; bytes, not characters; parity with M1-052 |
| Invalid input / failure | empty, non-text, advertised-but-nil, clear refusal, write refusal, explicit denial |
| Cancel / cleanup / idempotency | repeated reads and writes, recovery after every failure kind, denial recovery; cancellation not applicable |

## Commands

| # | Command | Exit | Report |
| --- | --- | --- | --- |
| 1 | `swift test --package-path Packages/MacPlatform` | 0 — 63 passed, 0 failures, 3 skipped | `tests/results.json` |
| 2 | `env MACKVM_M1_053_MANUAL_PROBE=unique-pasteboard-round-trip swift test --package-path Packages/MacPlatform --filter manualUniquePasteboardProbeRunsTheRealAdapterPath` | 0 — 1 passed | `tests/tier-h-probe.json` |
| 3 | `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 — `** BUILD SUCCEEDED **`, `arm64-apple-macos14.0` | `commands.json` |
| 4 | `python3 Tools/Backlog/validate_package.py` | 0 — `PACKAGE OK: 217 issues, 5 milestones, 17 epics` | `commands.json` |
| 5 | `make architecture-check` | 0 | `commands.json` |
| 6 | `make code-quality-check` | 0 — swift-format 6.2.3; strict lint 0; warnings-as-errors 0 | `commands.json` |
| 7 | `git diff --check HEAD^ HEAD` | 0, no output | `commands.json` |
| 8 | `git merge-tree FETCH_HEAD HEAD` at evidence commit `b940d16`, with remote `main` fetched at `e84ecee` (the base) | 0 — tree `0f57ab7a940359625fbebe7180d8c5e01ccc3cf3`, no conflict | `commands.json` |
| 9 | `make verify` at evidence commit `b940d166bb68f1fa56572dc687bf5153cc6c6faf` | 0 — 19/19 gates passed; report `artifacts/ci/m1-008-report.json` (ignored), SHA-256 `ae6c6cd731704ed68be2cd7fa2b7b8f4c8ab9438916d456be3527d9ad54abc50` | `commands.json` `evidenceCommitCommands` |

The timestamps in `commands.json` are UTC wrapper times that include
orchestration overhead. They are not process-runtime claims.

## Manual Verification

- Environment: macOS 26.6.2 (25G83), arm64, Apple M4 Pro, SDK 26.2, Swift
  6.2.3. Display is not collected and not required. Network and peer are not
  applicable.
- Steps: the single opt-in `unique-pasteboard-round-trip` action, run on an
  `NSPasteboard.withUniqueName()` pasteboard with `releaseGlobally()` in
  `defer`.
- Actual: exit 0; the closed line matched the expected result exactly.
- Reviewer: Codex root reviewer, distinct from the author.
- **Not verified:** the general clipboard, access prompts, and a real System
  Settings `.alwaysDeny`.

## Architecture & Security Checks

- **Architecture boundary:** native Swift/AppKit only. No Protocol, KVMCore,
  Barrier, network, TLS or UI change. `make architecture-check` passed.
- **Public surface:** no public contract added, and no AppKit type on the
  package surface.
- **Accessibility:** no dependency.
- **Fail-closed:**
  - an oversized write is rejected before any mutation;
  - a failed clear prevents the write;
  - a failed write leaves the pasteboard cleared;
  - unknown prior content is never restored;
  - there is no retry, sleep or latched state.
- **Permission:** only an explicit `.alwaysDeny` is treated as denial. Every
  other behavior, and every macOS before 15.4, lets the read decide. Writes
  are not blocked, because the verified SDK facts do not say access behavior
  denies writes.
- **Privacy:** no production logs. Errors carry only the four closed taxonomy
  fields. `MacPasteboardText` redacts its description, debug description,
  `dump` and reflection. The evidence contains no clipboard payload, bytes,
  content hash, pasteboard name or device identifier.

## Review Findings (history, all fixed before the commit)

1. **Source-audit self-trigger.** The first run exited 1: 59 tests, 1 failed
   test, 2 issues. Fixed by splitting the forbidden tokens; the assertion was
   not weakened.
2. **High: explicit `.alwaysDeny` not modeled.** Fixed with an
   availability-safe read-access seam, the frozen
   `permission.capabilityUnavailable` failure, and four tests.
3. **Formatter: 3 findings** (two line-length, one trailing comma). Fixed with
   formatting-only edits.

## Final five-axis review (Codex root reviewer, evidence commit `b940d16`)

This is a **non-author Codex review, not a human review.** The reviewer is
distinct from the author.

1. **Source validity and traceability: pass.** Dependency Issues M1-035 and
   M1-052 are closed and their evidence is readable. The canonical, frozen and
   guardrail sources are consistent, with no conflict.
2. **Product and architecture: pass.** Only the Swift/AppKit `MacPlatform`
   backend changed. There is no Barrier, NativeProtocol, network, KVMCore or UI
   change. Declarations are package or internal only, and no public contract
   is added.
3. **Security, fail-safe and compatibility: pass.**
   - An explicit `.alwaysDeny` fails closed.
   - No payload is logged, and the read value is redacted.
   - An oversized write is rejected before any mutation.
   - A failed clear or write fails in a fixed order.
   - The code is availability-safe on macOS 14.
   - The real unique-pasteboard cleanup passed.
4. **Tests, validation and acceptance: pass.** The required commands passed at
   the implementation commit. The Tier-H probe passed. `make verify` passed
   19/19 at the evidence commit. Every acceptance criterion is mapped.
5. **Scope, hygiene and rollback: pass.**
   - Only the 3 Exact Files and the required evidence changed.
   - The secret and whitespace scans passed.
   - The owner artifacts were not staged or modified.
   - Rollback is additive.
   - The latest `main` is unchanged, with no merge conflict.

Current findings: Critical 0, High 0, Medium unresolved 0, **Low 4** — exactly
the four listed under Known Limitations. The findings above remain on record as
fixed history. **Independent (non-author) review: complete.** Details are in
`tests/review-findings.json`.

## Scope exclusions (not implemented)

- Loop suppression and content hashing or hash verification (M1-054).
- Protocol messages, wire format, networking and UI.
- A default byte limit.
- A polling observer or timer.
- Any automated test of the general pasteboard.
- Representations other than UTF-8 plain text.

## Known Limitations

These are all open, and none is permanently waived:

1. **Low: no real `.alwaysDeny` test.** A real general-pasteboard denial was
   not exercised, because changing OS state and reading the global clipboard
   would be intrusive. Coverage is the seam tests plus compilation.
2. **Low: `changeCount` is not an atomic transaction token.** Concurrent
   writers can change the pasteboard between observations.
3. **Low: content is materialized before it is measured.** `NSPasteboard`
   returns the full `String` before the byte limit can be checked.
4. **Low: the test file is long (1231 lines).** This is intentional and may
   cost maintainability; the coverage and repository precedent support it.

Also:

- The unique pasteboard validates the AppKit path without prompting or
  overwriting the user's clipboard, so it cannot show prompt behavior.
- Empty and non-text pasteboards share `unsupportedType`.
- A refused write leaves the user's clipboard cleared.
- No TDD red-phase run exists. Tests were written before the source, but the
  author could not run them.

## Follow-up Issues

- **M1-054:** clipboard loop guard, content hashing and suppression policy.
- A future manual check of the general pasteboard under `.alwaysDeny` and
  `.ask`, if the owner accepts touching OS state. Not scheduled here.

## Rollback Instructions

Revert implementation commit `5ca459acea932fd7324450d34224934ac12de22a`, and
revert the evidence commit or delete `evidence/issues/M1-053/`. There is no
migration, persisted state, permission grant or runtime resource to clean up.
Issue rollback conditions — a crash, data leak, silent trust bypass, weakened
assertions, or deviation from the frozen contract — would each trigger this
revert. None has been observed.

## Reviewer Required

- **B:** full review of the implementation by a stronger model or an engineer.
  The Codex root reviewer found and drove the three fixes. Its final non-author
  five-axis review is **complete and passed**. It is a model review, not a human
  review.
- **H:** real-machine verification. The unique-pasteboard probe was executed
  by the reviewer and passed. General-clipboard prompts and a real
  `.alwaysDeny` remain unverified.
- **No autonomous merge** (`low_model_autonomous_merge: false`). The PR,
  GitHub CI, merge, and a final-head re-run are pending as reviewer duties.
