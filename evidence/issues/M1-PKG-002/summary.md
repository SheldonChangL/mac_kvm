# M1-PKG-002 Evidence Summary

GitHub Issue: [#263](https://github.com/SheldonChangL/mac_kvm/issues/263)

Branch: `feat/m1-pkg-002-macplatform-child-package`

Base commit: `ea153ed39976df5ca22ea05fb664dc18951e3ed1`

Implementation commit:
**`3e8ccb94b0a71edd882471913994fef385f12229`** —
`test(macplatform): add child package CI gate`.

Status: **reviewer_verified.** The commit exists and every Required Command was
re-run by the reviewer in its exact frozen form and passed. Record time of this
update: `2026-09-22T01:09:03Z`.

Authorship and review: the implementation author is **Claude Opus 5**, which
wrote the implementation and this evidence package and remains the sole author
of repository content. The **coordinating Codex agent** is a separate executor:
it performed the independent five-axis review, ran the authoritative Required
Command sweep against the committed tree, and created the implementation commit
because the author environment denies writes to `.git`. Author and reviewer are
therefore not the same executor, so the review of this change is independent. No
review waiver is invoked, relied on, or extended for this Issue.

## Outcome

M1-035's frozen Required Command `swift test --package-path Packages/MacPlatform`
now resolves a real child package and executes `MacPlatformTests`, instead of
walking upward to the repository package and passing while running fifteen
unrelated root tests. No Accessibility permission behavior, public API, or
product contract is introduced.

## Required command results (authoritative, reviewer)

Reviewer environment: arm64 macOS with Xcode installed, outside the author's
seatbelt sandbox. Every command below was run in its exact frozen form against
the committed content of `3e8ccb9` — no `--disable-sandbox` flag and no `PATH`
shim. Full detail in `commands.json` under `commands`.

| Command | Exit | Result |
| --- | --- | --- |
| `swift package --package-path Packages/MacPlatform describe --type json` | 0 | Package `MacPlatform`, tools `6.2`, macOS 14, `fileSystem` `KVMContracts` dependency, expected source and test targets |
| `swift test --package-path Packages/MacPlatform` | 0 | Exactly 1 Swift Testing test, `childPackageOwnsMacPlatformTests()`, passed |
| `python3 -m unittest discover -s Tools/cigates/tests -p test_cigates.py -v` | 0 | Ran 23 tests, OK |
| `git diff --cached --check` (after staging the authorized files) | 0 | No output |
| `docs-check` (after staging the authorized files) | 0 | `docs check OK` |
| backlog validator | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| architecture check | 0 | `architecture check OK` |
| `make verify REPORT=artifacts/ci/m1-pkg-002-review.json` | 0 | All 19 named gates passed, `swift-package-test:MacPlatform` exactly once |
| `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 | `** BUILD SUCCEEDED **` |

The author's own earlier runs are retained in `commands.json` under
`authorRuns`. Several frozen Required Commands could not execute at all in the
author's seatbelt sandbox, which forbids the nested sandbox SwiftPM creates;
each failed identically on unmodified HEAD, and each was retried with
`--disable-sandbox` or a temporary `PATH` shim. Those entries are historical and
non-authoritative: the reviewer has since run every one of them in the exact
frozen form, so no workaround is load-bearing for acceptance.

## Source traceability

- GitHub Issue #263, `[M1-PKG-002] Make MacPlatform issue-scoped test package
  executable`, state OPEN, owner @SheldonChangL, priority P0, risk high,
  milestone `M1 — Mac Client MVP（Barrier 驗證）`. It supplies the exact file
  list, acceptance criteria, TDD evidence requirement, out-of-scope list, and
  rollback used here. Read live with `gh issue view 263`.
- The Issue records `Depends on: M1-006, M1-008` and `blocks #23 (M1-035)`.
- `Package.swift` (root) supplied the frozen `MacPlatform -> KVMContracts`
  target edge, the Swift tools version `6.2`, and the `macOS 14` floor that the
  child manifest reproduces.
- `Packages/KVMContracts/Package.swift` supplied the child-manifest shape
  approved by M1-PKG-001.
- `Packages/MacPlatform/Sources/MacPlatform/MacPlatform.swift` is the existing
  module-boundary-only source and is unchanged.
- `Tools/cigates/cigates.py`, `Tools/cigates/tests/test_cigates.py` and
  `docs/tooling/M1-008-cigates.md` supplied the cumulative gate contract.
- `evidence/issues/M1-PKG-001/` supplied the evidence layout and the precedent
  for a child-package ownership test.
- No `AGENTS.md` exists anywhere in the repository. Nothing was inferred in its
  place; the Issue text is the sole scope authority.

## Deliverables

Committed in `3e8ccb9` — exactly these five files, nothing else:

- `Packages/MacPlatform/Package.swift`: Swift tools 6.2, `macOS(.v14)`, library
  product and target `MacPlatform`, test target `MacPlatformTests`, and the
  local `.package(path: "../KVMContracts")` dependency.
- `Packages/MacPlatform/Tests/MacPlatformTests/PackageOwnershipTests.swift`: one
  `#fileID` ownership test.
- `Tools/cigates/cigates.py`: the named cumulative gate
  `swift-package-test:MacPlatform`, added exactly once, immediately after
  `swift-package-test:KVMContracts`.
- `Tools/cigates/tests/test_cigates.py`: two regression tests, plus the
  `EXPECTED_CUMULATIVE_GATE_COUNT = 19` constant.
- `docs/tooling/M1-008-cigates.md`: updated gate order, child-package paragraph,
  and the gate-inventory pinning rule.

This evidence package is intentionally not part of `3e8ccb9`: that commit
carries only the five authorized Exact Files above. The evidence is delivered
separately, in an evidence-only follow-up commit created by the Codex reviewer
after verification. A commit cannot contain its own hash, so that follow-up
SHA is deliberately left unstamped inside this package rather than invented; it
is discoverable from git history with
`git log --oneline -- evidence/issues/M1-PKG-002/`. The Claude author neither
staged nor committed these files at any point.

## TDD

Red is recorded in `tests/red-phase.json` and was produced before any
implementation existed on disk:

1. `swift package ... describe --type json` on the M1-035 package path reported
   package `MacKVM` at the repository root with no `MacPlatformTests` target.
2. `swift test --package-path Packages/MacPlatform` exited zero while running 15
   root-package tests and zero MacPlatform tests. Exit zero is the defect.
3. The two new gate-inventory tests were written first and failed 2 of 23
   against the unmodified `cigates.py`, while the 21 pre-existing tests stayed
   green.

Green is recorded in `tests/results.json`.

## Acceptance criteria mapping

| Issue criterion | Result |
| --- | --- |
| `describe --type json` identifies the package, its targets, and the local `KVMContracts` dependency | Passed, reviewer-verified. Package `MacPlatform`, tools `6.2`, macOS 14; library target `MacPlatform` at `Sources/MacPlatform`; test target `MacPlatformTests` at `Tests/MacPlatformTests`; dependency type `fileSystem` on `KVMContracts`. |
| `swift test --package-path Packages/MacPlatform` executes the child ownership test, not parent tests | Passed, reviewer-verified. Exactly 1 Swift Testing test, `childPackageOwnsMacPlatformTests()`, versus 15 root tests before the change. |
| The future exact M1-035 test path is owned by `MacPlatformTests` | Passed. Proven in a throwaway copy outside the repository: a stub named exactly `AccessibilityPermissionServiceTests.swift` appeared in the target's source list and executed. The scratch copy was deleted and its absence re-verified. |
| The local `KVMContracts` dependency resolves without a network dependency | Passed. The only dependency is `.package(path: "../KVMContracts")`, reported by SwiftPM as type `fileSystem`. The manifest declares no URL, no registry, and no version requirement, and no `Package.resolved` is produced. |
| The root package/workspace still builds and tests | Passed, reviewer-verified. The reviewer's `make verify` run passed all 19 gates, including `code-quality`, `swift-test-targets` and `native-arm64-build`, and the exact `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` reported `** BUILD SUCCEEDED **`. |
| `make verify` and GitHub CI run `swift-package-test:MacPlatform` exactly once as a named blocking gate | Passed, reviewer-verified. The reviewer's 19-gate run records the gate once, and CI runs the identical `make verify`, so no workflow edit is needed or made. |
| The cumulative gate count increases from 18 to 19 and all gates pass | Passed, reviewer-verified. 19/19 named gates passed. |
| Architecture, docs, backlog/package, code-quality, and diff hygiene checks pass | Passed, reviewer-verified. `architecture check OK`; staged `docs check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `code-quality` gate green inside `make verify`; `git diff --cached --check` produced no output after staging. |
| No Accessibility permission behavior, public API, runtime, protocol, networking, TLS, or frozen-decision change | Held. The only Swift added is a declarative manifest and one `#fileID` assertion. `MacPlatform.swift` is untouched and still contains no symbol. |
| Owner artifacts, secrets, private data, and generated products remain excluded | Held. See Scope and hygiene. |

## Scope and hygiene

- Exactly the authorized Exact Files plus this evidence directory were touched.
  No other file was created, modified, or deleted. `3e8ccb9` carries the five
  Exact Files; this evidence directory is delivered separately in the reviewer's
  evidence-only follow-up commit.
- `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were never read, opened,
  written, staged, deleted, or described. They remain untracked and unchanged.
- `Packages/MacPlatform/.build` was generated by the test runs, is covered by
  the existing `**/.build/` ignore rule, and was not staged.
- `artifacts/` is Git-ignored, so no gate report is committed.
- No secret, credential, token, private key, network endpoint, or personal data
  was added.
- The Claude author did not commit, stage, push, branch, merge, or open a pull
  request, and did not modify `.git`. That holds for the implementation and for
  every revision of this evidence package alike: the Codex reviewer is the
  executor that stages and commits, in `3e8ccb9` for the Exact Files and in the
  separate evidence-only follow-up commit for this directory.

## Review findings

Independent reviewer (the coordinating Codex agent), five-axis verdict:
**Critical 0, High 0, Medium 1, Low 1.**

Axes verified:

1. **Source validity and traceability** — passed.
2. **Product contract and architecture boundaries** — passed. No runtime and no
   Accessibility behavior is introduced.
3. **Security, fail-safe and compatibility** — passed. Local filesystem
   dependency only, no secret or private data, Xcode workspace build passed.
4. **Tests, validation and acceptance** — passed.
5. **Scope, repository hygiene and rollback** — passed. Only the Issue's Exact
   Files and the evidence paths were touched; protected owner artifacts
   untouched.

**Medium (found and fixed by this evidence update): evidence traceability
accuracy.** Two statements in earlier revisions of this package were inaccurate.
Both are corrections to the accuracy of the evidence's own traceability claims,
so they are one Medium finding, not two.

1. *Same-executor review and required backfill.* The previous revision described
   the five-axis review as performed by the implementation author under a review
   waiver, and stated that independent Critical/High review had to be backfilled
   before M1 completion. That was inaccurate. The implementation author is
   Claude Opus 5 and the reviewer is a separate Codex executor, so the review of
   this change is independent, and the earlier M1-001–M1-003 waiver is neither
   invoked nor applicable to M1-PKG-002.
2. *Evidence current-state claims that go stale on commit.* The previous
   revision asserted that the four evidence files were untracked and not
   committed. That is a snapshot of the author's working tree, and it becomes
   false the moment the reviewer creates the required evidence-only follow-up
   commit — which is exactly how this package is meant to be delivered. The
   current-state wording is replaced with the durable description in
   Deliverables: the package is intentionally outside `3e8ccb9`, it ships in a
   separate evidence-only follow-up commit by the reviewer, that commit's SHA
   cannot be self-referenced and is read from git history instead, and the
   author staged and committed nothing.

Both inaccurate statements have been removed here and in `commands.json`.

**Low (remaining, nonblocking).** The strict 19-name gate inventory adds
deliberate maintenance coupling: any future dynamic test gate addition must
update the inventory constant and `docs/tooling/M1-008-cigates.md` together, or
`test_cumulative_gate_inventory_is_the_expected_named_gates` fails. This is
intended fail-closed behavior and is accepted as a known cost; see Remaining
risks.

## Remaining risks

- **Inventory maintenance coupling.** The gate-inventory test pins the exact
  ordered 19-name list, so any future tool or evidence `test_*.py` file — or any
  other dynamically discovered gate — will fail it until the inventory constant
  and `docs/tooling/M1-008-cigates.md` are updated together. That is deliberate
  fail-closed behavior, but it is a real maintenance cost. This is the Low
  finding above, carried forward.
- **Gate without `-Xswiftc -warnings-as-errors`.** Unlike the `KVMContracts`
  gate, `swift-package-test:MacPlatform` omits that flag so it stays
  byte-identical to the frozen M1-035 Required Command. The `MacPlatform`
  library sources are still compiled with warnings as errors by the root
  `code-quality` gate; the child *test* target is not. If M1-035 wants
  warnings-as-errors over its own test sources, that is a follow-up decision,
  not a silent change here.
- **Pre-existing doc drift.** The `Gate order` list in
  `docs/tooling/M1-008-cigates.md` never listed the evidence-test discovery gate
  or the per-file evidence-test gates added by M1-CI-003. This change does not
  introduce that gap and deliberately does not widen scope to repair it. It is
  flagged for a documentation Issue.

Risks recorded in earlier revisions of this package are now closed: the
author-environment sandbox restriction, the unrun exact Required Command forms,
the uncommitted-file `docs-check` coverage gap, the unverified Xcode workspace
build, and the claim of a pending independent review. The reviewer ran every
exact Required Command form, ran `docs-check` after staging, built the Xcode
workspace successfully, and performed the independent five-axis review recorded
above.

## Rollback

Revert `3e8ccb9` or its pull request. That removes the child manifest, the
ownership test, the nineteenth gate, its regression tests, and the documentation
update in one operation, restoring the 18-gate inventory. M1-035 must then be
re-blocked until an equivalent canonical child package manifest and blocking CI
gate exist. No production runtime, user data, protocol, or frozen decision is
affected by either direction.
