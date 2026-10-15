# M1-030 Independent Review

Reviewer: Codex (independent from the Claude Code implementation author)

Review date: 2026-10-15 Asia/Taipei

Base commit: `3a75589acb7028fb8148c85b62c508bcc1fd3368`

Scope: GitHub Issue #53, M1-030 handshake fragmentation, timeout, mismatch,
cleanup, and idempotency tests.

## Findings

- Critical: none.
- High: none.
- Medium: one, resolved before approval. The first cleanup helper recursively
  expanded class instances before identifying them as retained references. A
  future self-referential reference graph could therefore recurse indefinitely
  instead of failing cleanly. The Claude implementation author changed the
  helper to return immediately for `String` or `.class` nodes and recurse only
  through value-type children. Focused and full-package tests passed afterward,
  and the machine-readable xUnit report was regenerated against the fixed code.
- Low: none.

## Five-axis review

### 1. Source validity and traceability

Passed. M1-020 and M1-029 are closed and their merged source/evidence is
readable. M1-030 uses the corrected Exact Files merged by #318. The server hello,
HelloBack bytes, supported version, and fixed errors are traced to the frozen
M1-025, M1-PROTOCOL-001, M1-027, and M1-029 sources. No new protocol inference
or unsupported compatibility claim is introduced.

### 2. Product contract and architecture boundaries

Passed. All Barrier-specific tests remain in `BarrierCompatibilityTests`.
KVMCore is untouched and does not import BarrierCompatibility. The change adds
no production source, public API, package dependency, wire behavior, networking,
or platform behavior. M1 remains Linux-server-only for execution evidence;
Windows is not claimed.

### 3. Security, fail-safe, and compatibility

Passed. Unsupported versions fail closed with
`.serverHelloRejected(.unsupportedVersion)` and cannot be revived. Timeout and
cancel preserve the first terminal reason, release the screen name, and produce
no later HelloBack. Late signals cannot tear down an established connection.
No logging site, credential, token, key material, typed text, clipboard payload,
private endpoint, or personal data is added. Production TLS behavior is
unchanged.

### 4. Tests, validation, and acceptance criteria

Passed. The supported 15-byte hello frame is exercised under all 16,384 subsets
of its 14 internal fragmentation boundaries. Unsupported versions cover every
single-byte version mutation at every single split boundary plus seven
multi-byte cases. Timeout and cancel are injected deterministically at each byte
boundary without sleeps, retries, polling, tasks, or wall-clock tolerances.
Boundary, invalid-input, sticky-error, cleanup, and post-connection idempotency
cases are present.

The first test-first run passed 11/11 against unchanged M1-029 production code;
no false RED claim is made. Three throw-away mutants outside the repository
caused the expected tests to fail, demonstrating sensitivity without modifying
the worktree production source.

Reviewer-executed validation:

- Focused M1-030 suite: 11 tests passed; exhaustive fragmentation completed in
  0.423 seconds.
- BarrierCompatibility full package with warnings as errors: 151 tests passed.
- Xcode workspace build for scheme `MacKVM`, destination macOS: `BUILD
  SUCCEEDED`.
- `swift format lint --strict` on the new test: passed with no output.
- Backlog/package validator: `PACKAGE OK: 217 issues, 5 milestones, 17 epics`.
- Architecture checker: `architecture check OK`.
- Staging-aware docs check: `docs check OK`.
- Staged whitespace check: passed with no output.
- `make verify` outside the restricted Swift sandbox: every manifest, docs,
  architecture, code-quality, tool/evidence test, KVMContracts, MacPlatform,
  BarrierCompatibility, repository-contract, Swift-target, and native arm64
  build gate passed.

### 5. Scope control, repository hygiene, performance, and rollback

Passed. The staged change contains only the two Exact Files and the four required
evidence files; this review file is the independent review artifact. Existing
untracked `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` artifacts remain
unstaged and untouched. Exhaustive tests complete in well under one second and
do not add runtime cost because they are test-target-only. Rollback is one atomic
revert and removes no production behavior or persisted data.

## Verified acceptance criteria

- Every focus item has a named test and evidence mapping: passed.
- Happy, boundary, invalid input, error, cancel, cleanup, and idempotency tests:
  passed.
- Public behavior remains aligned with frozen contracts and adds no implied API:
  passed.
- Architecture, lint, build, unit tests, warnings-as-errors, and full gates:
  passed.
- Production logs contain no sensitive or reconstructable content: passed; no
  production logging code changed.

## Verdict

Approved for commit and PR. There are no unresolved Critical, High, Medium, or
Low findings. Before merge, preserve this exact reviewed head, require green
GitHub checks, confirm no merge conflict, and merge only through the protected PR
workflow.

## Remaining risks

- Cleanup ownership is proven for the synchronous M1-029 handshake value. The
  future session adapter that owns transport tasks and timers requires its own
  lifecycle tests in its owning Issue; M1-030 does not claim that later behavior.
- Golden bytes are intentionally copied from frozen evidence. A future accepted
  wire-contract replacement must update both production tests and this suite.
