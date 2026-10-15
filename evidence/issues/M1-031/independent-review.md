# M1-031 Independent Review

Reviewer: Codex, independent from the Claude Code implementation author

Date: 2026-10-15 Asia/Taipei

Base commit: `5277134a75b1fcea9370203b08d65d1d213bdaf4`

## Findings

- Critical: none.
- High: none.
- Medium: none.
- Low: none remaining. Three author-side test-strength findings were resolved
  before this review: all bits of golden payloads are mutated, privacy reflection
  rejects fixed-width integers, and the error switch is exhaustive.

## Five-axis review

### Source validity and traceability

Passed. M1-025 and M1-026 are merged. BARRIER-EVID-0005 and the accepted
M1-PROTOCOL-002 ADR are approved for M1-031 only. Golden bytes, directions,
lengths, coordinate rules, and exclusions match those sources.

### Product contract and architecture

Passed. Barrier types remain internal to BarrierCompatibility. KVMCore,
KVMEvent, NativeProtocol, networking, platform code, and TLS are untouched.
Keepalive/no-op outcomes are structurally separate from control events. Opaque
sequence and modifier values acquire no invented semantics.

### Security, fail-safe, and compatibility

Passed. Unknown tokens, wrong directions, malformed lengths, non-zero DSOP,
invalid reserved fields, unsupported coordinates, and inconsistent session
state fail closed with sticky typed errors. Excluded-frame diagnostics contain
only token, direction, payload length, and a fixed reason; no body is retained.
Windows and full Barrier interoperability are not claimed.

### Tests, validation, and acceptance criteria

Passed. Tests cover every accepted token/direction, DINF/CINN boundary and
failure cases, exact fixture bytes, fragmentation/coalescing/truncation,
excluded-frame bounds, sticky failure/reset, deterministic state, and
keepalive isolation. Cancellation is not applicable because the decoder owns no
I/O, task, timer, or resource.

Reviewer results:

- Focused suite: 34/34 passed.
- BarrierCompatibility with warnings as errors: 185/185 passed.
- Xcode workspace build: `BUILD SUCCEEDED`.
- Swift format lint: passed.
- Backlog validator: `PACKAGE OK: 217 issues, 5 milestones, 17 epics`.
- Architecture checker: `architecture check OK`.
- Staging-aware docs check and `git diff --cached --check`: passed.
- Full formal gate, `make verify`: passed every reported step, including all
  package tests, repository contract tests, test-target validation, and the
  native arm64 build.

### Scope, hygiene, performance, and rollback

Passed. Only the three Exact Files and required evidence are included. Existing
untracked bootstrap artifacts remain untouched. Parsing is bounded by a
caller-supplied payload limit and uses constant-size field reads. Rollback is a
single atomic revert with no persisted-data impact.

## Acceptance criteria

- Control packets map to platform-neutral adapter outcomes: passed.
- Coordinate and size bounds are validated fail-closed: passed.
- Keepalive/no-op cannot enter the control-event/input path: passed.
- Happy, boundary, invalid, error, cleanup/idempotency, golden-byte, and stream
  framing tests: passed.
- No sensitive production logging or architecture boundary violation: passed.

## Verdict

Approved for commit and PR. Staging-aware docs/whitespace gates and full
`make verify` passed. Merge remains conditional on green GitHub CI on the
unchanged reviewed head. No unresolved finding blocks commit or PR.

## Remaining risks

- The deliberately conservative state machine may reject legitimate but
  unobserved ordering. Relaxation requires new approved evidence.
- The caller must use the same bounded payload limit in the reassembler and
  decoder and must feed outbound DINF with the correct direction.
