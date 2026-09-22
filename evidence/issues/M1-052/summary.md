# M1-052 Evidence Summary

Issue: M1-052 — define `ClipboardPayload` and the UTF-8 text codec.
Branch: `feat/m1-052-clipboard-payload`.
Base commit: `f67d9b2d03a325bd2adc0c5f7ade96e019262ac2`.
Implementation commit: **`2c67f5a7d3b49046f81714ad85089e1fdc099861`** —
`feat(contracts): add bounded UTF-8 clipboard codec`.

Status: **reviewer_verified.** The commit exists and every Required Command
passed. Record time of this update: `2026-09-22T00:01:45Z`.

Authorship note: this evidence package is author-written. The reviewer created
the implementation commit and ran the authoritative command sweep, because the
author environment denied writes to `.git` and blocked two Required Commands.

## Deliverables

Committed in `2c67f5a` — exactly three files, nothing else:
`Packages/KVMContracts/Sources/KVMContracts/ClipboardPayload.swift`,
`Packages/KVMContracts/Tests/KVMContractsTests/ClipboardPayloadTests.swift`,
`docs/components/M1-052-clipboard-payload.md`. Plus this untracked evidence
package (`summary.md`, `commands.json`, `tests/red-phase.json`,
`tests/clipboard-payload-tests.json`). `MacKVM_M1-001_unblock.zip` and
`mackvm-unblock/` were never read, written, staged, or committed and remain
untracked.

## What was implemented

`ClipboardPayload` stays where M1-013 froze it, in `KVMEvent.swift`; it was not
moved, duplicated, or restructured, and its coding shape is asserted unchanged.
The new file adds five public declarations and nothing more:

- `ClipboardByteLimit` — `Hashable`/`Sendable` wrapper over a strictly positive
  `Int`, failable initializer.
- `ClipboardTextCodec.encode(_:limit:)` / `decode(_:limit:)` — pure static
  functions over UTF-8 plain text.
- `ClipboardPayload.utf8ByteCount` and `validate(against:)`.

Everything is an immutable value or a pure static function.

**Three decisions a reviewer should check first** (full rationale in the
component doc). (1) The byte limit is caller-supplied with no default: C-007
freezes that clipboard content is bounded but freezes no number, and no merged
Issue has produced evidence for a real one. (2) A non-positive limit is rejected
by the initializer, not by a new error code — the frozen `ClipboardErrorCode`
allowlist (`unsupportedType`, `invalidUTF8`, `oversized`, `loopRejected`) has no
case for a misconfigured limit and must not be extended here. (3) Only
`oversized` and `invalidUTF8` are reachable: the codec has no representation
parameter, so no caller can request a non-UTF-8 type; `unsupportedType` belongs
to the platform backend and `loopRejected` to loop suppression.

**Two non-stylistic details.** `decode` checks size *before* decoding or
allocating (Architecture Guardrails), which is observable and pinned by
`oversizedInputIsRejectedBeforeUTF8Validation`. `decode` validates with
`Unicode.UTF8.ForwardParser`, not `String(data:encoding:.utf8)`, which silently
strips a leading U+FEFF and so cannot be half of a lossless codec;
`String(validating:as:)` is strict but macOS 15+, above this package's macOS 14
target. Malformed input is rejected, never repaired into U+FFFD.

## Required command results (authoritative, reviewer)

Reviewer environment: arm64 macOS, Xcode 26.2, Swift 6.2.3. Run outside the
workspace sandbox after implementation and reviewed again against the committed
content of `2c67f5a`. Full detail in `commands.json`.

| Command | Exit | Result |
| --- | --- | --- |
| `swift test --package-path Packages/KVMContracts` | 0 | Build complete; 56 passed, 0 failures, 0 skipped |
| `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 | `** BUILD SUCCEEDED **`; compiler target `arm64-apple-macos14.0` |
| `make code-quality-check` | 0 | swift-format 6.2.3, strict lint 0, root warnings-as-errors 0 |
| `make docs-check` | 0 | docs check OK |
| `python3 Tools/Backlog/validate_package.py` | 0 | PACKAGE OK: 217 issues, 5 milestones, 17 epics |
| `make architecture-check` | 0 | architecture check OK |
| `git diff --check` (staged, pre-commit) | 0 | no violation |
| staged secret scan | 0 | no credential, private-key, or token material |

The `xcodebuild` run reported `** BUILD SUCCEEDED **`. It emitted a
multiple-matching-destinations warning that listed arm64e, arm64 and x86_64
variants of the macOS destination and selected the first of them; the compiler
invocation and the built target were `-target arm64-apple-macos14.0`. No claim
is made that both arm64 and arm64e were built. Apart from that
destination-selection warning and platform-discovery warnings, the run produced
no compile warning attributable to this change.

The author's own earlier attempts at `swift test`, `xcodebuild`,
`make code-quality-check` and `git add`/`git commit` failed for
author-sandbox reasons, each reproduced on unmodified HEAD. Those are retained
in `commands.json` under `historicalAuthorEnvironmentAttempts` as historical
author-environment observations only; they are non-authoritative and superseded
by the table above.

## Red phase

`tests/red-phase.json` records two genuine failing runs, both author-run before
the commit existed. **Round 1 — missing implementation:** with the test file
present and `ClipboardPayload.swift` absent, the run exited `1` with 165 compile
errors and zero tests executed. **Round 2 — naive implementation:**
`Packages/KVMContracts` was copied to a scratch directory outside the
repository, and a compiling implementation with seven seeded defects (zero limit
accepted, wrong severity, observed size leaked through
`underlyingDiagnosticCode`, off-by-one at the boundary, BOM-stripping decoder,
size enforced after decoding, character count used as byte count) was written
*only into that copy*. The unchanged test file failed with exit `1`, 33 recorded
issues across 11 of the 19 new tests. The repository working tree never
contained the naive implementation; the scratch copy was re-checked at this
update and still exists outside the repository, never staged or committed.

Eight of nineteen stayed green against the naive implementation and the report
says so: they pin documented guarantees rather than detect defects.
`clipboardFailuresCarryNoTextOrHash` in particular cannot be made red by any
plausible implementation, because M1-015's `CoreError` has no free-text field.
Neither red report contains assertion text, diffs, or failure renderings — only
names, counts, exit codes, and content-free reasons.

## Acceptance Criteria mapping

**Focus 項目均有可定位證據.** "V1 只允許 UTF-8 plain text" → no representation
parameter on the codec, plus `decodingRejectsEveryInvalidUTF8Shape` over twelve
malformed shapes. "明確 size/encoding error" → `clipboardFailure` and
`clipboardFailuresUseTheFrozenClipboardTaxonomy`. "不得在 log 顯示 payload" →
no logging in the file, plus `clipboardFailuresCarryNoTextOrHash`.

**Happy path / boundary / invalid input / error / cancel / cleanup 全部通過.**
56/56 pass (37 pre-existing, 19 new). The 19 new tests break down as 4 happy
path, 8 boundary (including exactly-at-limit, one byte over, one-byte minimum,
`Int.max`, empty content, and bytes-not-characters), 3 invalid input, 2
privacy/taxonomy, 1 compatibility, 1 determinism. Per-test names by category are
in `tests/clipboard-payload-tests.json`.

No cancel/cleanup test was written; the Issue makes it conditional on "如有
async/state/resource" and there is none — nothing owns a task, clock, timer,
buffer, connection, pasteboard handle, or input state.
`codecIsPureAcrossRepeatedSuccessAndFailure` asserts the property that matters:
a failure leaves nothing behind for a later call to observe.

**Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API.** Five
public declarations, all listed above. C-007's frozen elements hold: UTF-8 plain
text only, size limits present, payload never logged. The frozen M1-013
`ClipboardPayload`/`KVMEvent` coding shape is asserted unchanged by
`clipboardPayloadCodingShapeIsUnchanged`; the frozen M1-015 `CoreError` taxonomy
is used as-is with no new code, domain, or severity.
`transaction`/`origin`/`hash` are M1-013's fields and were not touched.

**Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning.**
See the command table: all exit 0, 56/56 tests, no new compile warning.

**Production logs 不包含 typed text、payload、secret 或可還原內容.** No logging
call, `print`, diagnostic emission, or interpolation of input anywhere in the
new file. Privacy is structural: `CoreError` has no free-text field, and
`underlyingDiagnosticCode` is left `nil` so not even a byte count escapes.
`clipboardFailuresCarryNoTextOrHash` renders every failure through
`String(describing:)`, `String(reflecting:)` and JSON encoding and asserts a
synthetic probe text, its hash sentinel, and its non-ASCII scalars appear in
none of them. Every fixture and every string in this package is synthetic.

## Determinism

No sleep, wall clock, timer, retry, poll, thread, task, randomness, network
call, file I/O, or subprocess in any test or source line; every assertion is on
an exact value, and the codec is a pure function of its two arguments.

## Review findings

Reviewer verdict: **Critical 0, High 0, Medium 0, Low 1.** Axes verified:
(1) source/traceability — M1-013 and M1-015 merged; C-007 and Issue #24 directly
followed. (2) product/architecture — `KVMEvent` unchanged; no
Barrier/platform/network code; codec confined to `KVMContracts`.
(3) security/fail-safe/compatibility — oversize-before-decode, strict UTF-8, no
payload or error leakage, existing `Codable` shape unchanged, pure code owns no
cleanup resource. (4) tests/AC — 19 new + 37 existing = 56 pass; real RED
evidence remains. (5) scope/hygiene/rollback — only the three implementation
files plus evidence; protected artifacts untouched; additive rollback.

**Low (remaining, nonblocking).** `ClipboardByteLimit` accepts `Int.max`. It is
a valid positive value but approximates disabling a meaningful bound. C-007 does
not freeze a numeric limit and this Issue must not invent one, so downstream
policy owners must supply a materially bounded value. Documented, accepted.

## Known limitations and remaining risks

- No limit value exists in the repository yet, so the API is unproven against a
  real caller until a later Issue supplies one.
- `validate(against:)` checks size only; `contentHash` is carried, never
  computed or verified.
- No streaming form; a caller holds the whole value in memory.
- Nothing is said about normalization, line endings, control characters, or
  bidirectional overrides. Byte-faithful UTF-8 in and out.
- `unsupportedType` and `loopRejected` remain unused across the repository.
- The narrowest-API reading — that "V1 只允許 UTF-8 plain text" is satisfied by
  having no way to request anything else, rather than by a representation enum —
  is the decision most open to challenge. Rationale is in the component doc.
- Round-2 redness covers 11 of 19 tests; the other eight are argued, not
  demonstrated. UTF-8 validity was checked against twelve malformed and nine
  valid shapes, not exhaustively; `Unicode.UTF8.ForwardParser` is trusted for
  the general case.

## Rollback

Revert `2c67f5a` and delete `evidence/issues/M1-052/`. Nothing depends on the
new declarations yet, the frozen M1-013 and M1-015 surfaces are untouched, and
no wire format, persisted state, migration, trust state, or platform input state
is involved — the change is purely additive, so rollback needs no cleanup and
cannot leave input suppressed or keys held.
