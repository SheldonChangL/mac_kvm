# M1-030-SCOPE-001 Independent Review

Reviewer: Codex (independent from the Claude Code implementation author)

Review date: 2026-10-15 Asia/Taipei

Base commit: `1964732e18ceebafb1fca67f953cb94adbb18bd5`

Scope: GitHub Issue #317, which corrects the M1-030 Exact Files and Swift
package command without implementing M1-030 behavior.

## Findings

- Critical: none.
- High: none.
- Medium: none.
- Low: one resolved before approval. The author evidence named an unverified
  exact model version. The author changed it to the directly verifiable
  invocation `Claude Code (--model opus)` in `summary.md` and `commands.json`.

## Five-axis review

### 1. Source validity and traceability

Passed. The correction is anchored to M1-030 (#53), M1-030-SCOPE-001 (#317),
Frozen Decision 4, and the Architecture Guardrails. The Issue source and
`issues_manifest.json` agree, and the traceability index clearly states that
this correction is not M1-030 completion evidence.

### 2. Product contract and architecture boundaries

Passed. The future handshake test moves from KVMCore to
BarrierCompatibilityTests. No production helper is authorized or added.
M1-020 and M1-029 remain the dependencies, and no wire bytes, product scope,
public API, or architecture rule changes.

### 3. Security, fail-safe, and compatibility

Passed. The change is backlog, traceability, test, and evidence metadata only.
It does not alter runtime TLS, trust, fail-safe, input, networking, or protocol
behavior. A targeted scan found no credential, token, key material, private
endpoint, typed text, clipboard payload, or personal data introduced by this
change. Windows remains outside M1 execution scope.

### 4. Tests, validation, and acceptance criteria

Passed. The focused regression suite rejects the old KVMCore paths and command,
requires the corrected BarrierCompatibility test path, preserves dependency
order, verifies the frozen boundary, and requires traceability. The author
recorded a legitimate RED run before the metadata correction and a GREEN run
after it. The reviewer independently obtained these exact results:

- Focused correction suite: 8 tests, 8 passed.
- Full contract suite outside the restricted Swift sandbox: 155 tests, 155
  passed in 53.150 seconds.
- `make docs-check`: passed, `docs check OK`.
- `python3 Tools/Backlog/validate_package.py`: passed,
  `PACKAGE OK: 217 issues, 5 milestones, 17 epics`.
- `make architecture-check`: passed, `architecture check OK`.
- `git diff --check`: passed with no output before staging.
- `make verify` outside the restricted Swift sandbox: passed. All manifest,
  documentation, architecture, code-quality, tool/evidence tests, KVMContracts,
  MacPlatform, BarrierCompatibility, repository contract tests, Swift test
  targets, and native arm64 build gates passed.

The same full contract suite inside the restricted sandbox produced exactly the
nine documented SwiftPM `sandbox_apply: Operation not permitted` failures. The
outside-sandbox pass verifies that those failures were environmental rather
than repository regressions.

## 5. Scope control, repository hygiene, and rollback

Passed. No Swift source, package manifest, fixture, unrelated Issue, or
unrelated tracked file changed. The existing untracked
`MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` artifacts were not staged or
modified. Rollback is one atomic revert; doing so intentionally restores the
known invalid KVMCore scope and therefore re-blocks M1-030.

## Verified acceptance criteria

- M1-030 no longer requires Barrier-specific code or tests in KVMCore: passed.
- Corrected Exact Files remain a narrow one-Issue/one-PR scope: passed.
- Dependency order remains M1-020, M1-029, then M1-030: passed.
- No M1-030 behavior was implemented early: passed.
- Source, manifest, traceability, test, and evidence agree: passed.

## Verdict

Approved for commit and PR. There are no unresolved Critical, High, Medium, or
Low findings. Before merge, stage only the reviewed files, rerun the staged-file
documentation and whitespace gates, require green GitHub checks, confirm no
merge conflict, and preserve PR-based merge without direct push to `main`.

## Remaining risks

- `BarrierHandshakeTestsTests.swift` is an unusual future filename but matches
  the existing canonical naming and is valid; changing it is outside #317.
- This correction only unblocks M1-030. It does not prove or claim M1-030
  handshake behavior.
