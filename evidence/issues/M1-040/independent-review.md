# M1-040 Independent Review

- Reviewer: Claude independent reviewer (did not implement the M1-040 capture package)
- Review round: 4 (narrow delta review of the e2e script privacy-scan whitelist; round 3 content retained below)
- Review date (UTC): 2026-10-06
- Branch: `feat/m1-040-barrier-keyboard-fixtures`
- Reviewed commit: HEAD `e6220368ca7a9d28906ff26de35ba41d245219bc` plus uncommitted working-tree changes (1 modified tracked file, 12 untracked M1-040 files)
- Scope: M1-040 only. This file is the only file written by the reviewer.

## Files reviewed

- `MacKVM_Implementation_Package_v2/issues/M1/M1-040-barrier-keyboard-fixtures.md`
- `docs/adr/M1-040-UNBLOCK-001-keyboard-capture-scope.md`
- `MacKVM_Implementation_Package_v2/toolchain.lock.json`
- `Tests/SystemTests/Plans/M1-040-barrier-keyboard-fixtures.md`
- `Tests/SystemTests/Scripts/M1-040-barrier-keyboard-fixtures.sh`
- `Tests/Fixtures/Barrier/m1-040-linux-keyboard/metadata.json`, `keyboard-capture.json`
- `evidence/e2e/M1-040/README.md`, `evidence/e2e/M1-040/result.json`
- `evidence/issues/M1-040/summary.md`, `commands.json`, `environment.json`, `manual.md`, `tests/e2e-validation.json`
- `Tests/Contracts/test_m1_040_keyboard_capture_scope.py` (current working tree; diff vs HEAD +87/−7)
- GitHub Issue #25 comment 6012604371 (Product Owner authorization)

## Critical findings

None.

## High findings

None.

## Resolution of prior High findings

- H1 (contract test outside Exact Files): Resolved. `gh api repos/SheldonChangL/mac_kvm/issues/comments/6012604371` returns a comment on Issue #25 by `SheldonChangL` with `author_association: OWNER` (repository owner = Product Owner), created 2026-10-06T08:40:38Z, stating "The Product Owner approved including `Tests/Contracts/test_m1_040_keyboard_capture_scope.py` in the M1-040 capture PR scope" and limiting the authorization to the M1-040 capture PR without broadening architecture, public contract, protocol semantics or M1-041/M1-042 scope.
- H2 (gate regexes could not match `None.`): Resolved. `completion_blockers()` and `test_independent_review_approves_without_critical_or_high_findings` now use `None\.` (single backslash in raw strings). Probe: positive pattern against `"## High findings\n\nNone.\n"` → match `True`; negative-lookahead "has findings" pattern → `False`.
- H3 (privacy test false positive on the Swift driver version): Resolved. `identifying_content()` skips dotted-quad matches whose ±80-char context contains `swift`, `driver`, `python` or `version`. Scan of all Exact Files with the IPv4 regex finds exactly one evidence hit, the Swift driver version in `evidence/issues/M1-040/commands.json`, which is exempted; no real address is present.

## Medium findings

### M1 — IPv4 exemption is context-based and over-broad (new, non-blocking)

The H3 fix exempts any dotted quad within 80 characters of `swift`, `driver`, `python` or `version`. Probe: `identifying_content("python peer <private-dotted-quad>")` → `[]`, while `identifying_content("peer <private-dotted-quad>")` → `['ipv4']` (a concrete RFC 1918 address was used in the probe; omitted here so this file stays clean under the scan). A real address placed near those words in future evidence would pass the gate. Not blocking because the current evidence contains no address (verified by scan above). Recommended follow-up: exempt only the exact pinned version strings from `toolchain.lock.json`, or require a version prefix immediately before the match.

### M2 — Evidence self-asserts review status (round 1) — unresolved, non-blocking

The e2e script still hardcodes `'reviewStatus':'reviewed'`, `'sanitizationReviewed':True` and `nonclaim-scan` `status: 'passed'` without an executed non-claim check; `environment.json` still sets `"sanitizationReviewed": true`. The script's privacy scan and the contract test's privacy scan are separate implementations.

### M3 — Sanitizer not a repository artifact (round 1) — non-blocking

`commands.json` records concrete commands, timestamps, commit and exit codes, but the generator `/private/tmp/m1_040_generate.py` is not in the repository, so the pcap→fixture transformation cannot be re-run by a reviewer. Acceptable if the Product Owner accepts a private sanitizer.

### M4 — Pre-capture declaration not independently provable (round 1) — non-blocking

`environment.json` `recordedBeforeCapture: true` and `manual.md` remain self-report with no timestamped pre-capture artifact. Mitigation: the declared sequence (Right, Shift+Left, Caps Lock ×2, Down hold/release) is non-text, and the retained payload shows no identifiable text.

### M5 — Human sign-off of cleanup/fail-safe (round 1) — non-blocking for this review

Absence of stuck keys/suppressed local input rests on operator self-report in `manual.md`. The ADR's designated QA/Human Reviewer sign-off is still required before M1-040 is reported complete.

## Low findings

- L1: `evidence/e2e/M1-040/README.md` still says `result.json` is written "atomically through the e2e runner"; the script writes it directly.
- L2: Untracked `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/*` are unrelated to M1-040 and must not be staged.
- L3: Privacy regexes do not cover hostnames, MAC addresses or IPv6.
- L4: `tests/e2e-validation.json` still records `"independentReview": "pending"`; update after this approval if the evidence is meant to reflect it.
- L5: The approval gate checks `"APPROVED FOR M1-040 MERGE"` as a substring anywhere in this file, not specifically in the Final disposition section; round-2's BLOCKED review already contained the phrase in prose. The `## Critical findings` / `## High findings` `None.` checks are the effective gate.

## Verified acceptance criteria / validation targets

| Check | Result | Basis |
|---|---|---|
| Raw pcap not committed | Verified | `test_evidence_has_no_identifying_content_or_raw_capture` rglob suffix check passes after this rewrite |
| Fixture holds only ordered direction + uninterpreted payload bytes | Verified | `test_keyboard_fixture_is_sanitized_uninterpreted_payload` ok |
| Metadata integrity (sha256, byteLength) | Verified | Same test |
| No semantic / compatibility / Windows claim | Verified | Unchanged from round 1 |
| Privacy | Verified | Only IPv4-regex hit in evidence is the Swift driver version (exempted); see M1 |
| Toolchain lock match | Verified (self-recorded) | `commands.json` host and peer preflight exit 0; `test_lock_scopes_m1_040_after_acceptance` ok |
| Changes limited to Exact Files + authorized test | Verified | `git status`; test file covered by PO comment 6012604371 |
| Contract tests pass | See validation table | Re-run after this rewrite |

## Executed validation commands

All run from the repository root on 2026-10-06 by the reviewer.

| Command | Result |
|---|---|
| `git rev-parse HEAD` | `e6220368ca7a9d28906ff26de35ba41d245219bc` |
| `git status --porcelain --untracked-files=all` | 1 modified (`Tests/Contracts/test_m1_040_keyboard_capture_scope.py`); 12 untracked M1-040 files; plus unrelated `MacKVM_M1-001_unblock.zip`, `mackvm-unblock/` (3 files) |
| `git diff --stat` | `test_m1_040_keyboard_capture_scope.py | 94 ++++++++++++++++++++--`, 87 insertions, 7 deletions |
| `gh api repos/SheldonChangL/mac_kvm/issues/comments/6012604371` | user `SheldonChangL`, `author_association` `OWNER`, issue #25, created `2026-10-06T08:40:38Z`, body explicitly authorizes the test file in M1-040 capture PR scope |
| `gh api repos/SheldonChangL/mac_kvm --jq .owner.login` | `SheldonChangL` |
| `python3 -m unittest Tests.Contracts.test_m1_040_keyboard_capture_scope -v` (against round-2 BLOCKED review, before this rewrite) | `Ran 10 tests in 0.011s` / `FAILED (failures=3)`: `test_evidence_has_no_identifying_content_or_raw_capture` (`['ipv4'] != []`, caused by version strings quoted in the old review text without nearby exemption markers), `test_independent_review_approves_without_critical_or_high_findings` (High section not `None.`), `test_m1_040_cannot_be_claimed_complete_before_real_fixture` (`['independent review has high findings']`). All three failures were caused solely by the old BLOCKED review content |
| Python probe of fixed gate regexes against `"## High findings\n\nNone.\n"` | positive match `True`; negative-lookahead `False` |
| Python probe of `identifying_content` | `"python peer <private-dotted-quad>"` → `[]`; `"peer <private-dotted-quad>"` → `['ipv4']` (M1) |
| Python IPv4-regex scan of Exact Files | evidence hit only in `evidence/issues/M1-040/commands.json` (Swift driver version); other hits were in the old review text |
| `python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-040/result.json` | `evidence valid: issue=M1-040 status=passed` |
| `python3 Tools/Backlog/validate_package.py` | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| `python3 -m unittest Tests.Contracts.test_m1_040_keyboard_capture_scope -v` (after this rewrite) | `Ran 10 tests in 0.346s` / `OK` |

Not executed:

- `make e2e ISSUE=M1-040`: would rewrite `evidence/e2e/M1-040/result.json`; reviewer may write only this file.
- `make architecture-check`: not run; result unverified.

## Round 4 delta review (2026-10-06)

Delta: `Tests/SystemTests/Scripts/M1-040-barrier-keyboard-fixtures.sh` lines 68–78 add `allowed_public_versions = {'1.127.14.1'}` (the locked Swift driver version) and skip a privacy-scan match only when `match.group(0)` is exactly in that set. No other file changed since round 3 except `evidence/e2e/M1-040/result.json`, regenerated by the reviewer's `make e2e` run below.

Assessment:

- Narrowness: Exact full-match string equality against a single-element set. The IPv4 regex keeps its `(?<![0-9])` / `(?![0-9])` digit guards, so longer or prefixed dotted quads cannot be truncated into the whitelisted value. Probe results: the exact Swift driver version → pass; RFC 1918 addresses in 10/8, 172.16/12 and 192.168/16 → blocked; the driver version with an extra trailing digit in the last octet → blocked; with an extra leading digit in the first octet → blocked; a private address on the same line as the whitelisted version → blocked; a private address immediately preceding the version digits → blocked (leftmost match is the private prefix). The whitelisted value itself is in public 1.0.0.0/8 space, not a private address, and is the pinned toolchain version, not a host value.
- This is narrower than the contract test's context-based exemption (M1), which is unchanged; M1 remains open and non-blocking.
- Low L6 (new): a string consisting of the whitelisted version followed by `.` and further digits (five or more dotted groups) also passes, because the trailing guard only rejects digits. Such a string is not a valid IPv4 address, so no address can leak through this path.
- Only evidence occurrence of the whitelisted value: `evidence/issues/M1-040/commands.json` line 18 (Swift 6.2.3/driver version).

Round 4 executed validation commands (repository root, HEAD `e6220368ca7a9d28906ff26de35ba41d245219bc` plus working tree):

| Command | Result |
|---|---|
| `python3 -m unittest Tests.Contracts.test_m1_040_keyboard_capture_scope -v` | `Ran 10 tests in 0.218s` / `OK` |
| `make e2e ISSUE=M1-040` | `e2e script exit: 0`, `e2e disposition: passed`, `e2e exit: 0` |
| `python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-040/result.json` | `evidence valid: issue=M1-040 status=passed` |
| `python3 MacKVM_Implementation_Package_v2/tools/validate_package.py` | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| Python probe of script regex + whitelist (cases listed above) | Only the exact version string and the non-IPv4 five-group form pass |

Round 4 introduces no Critical or High finding. The round-3 "Not executed" note for `make e2e` is superseded: it was run in round 4 at the requester's instruction.

## Remaining risks

- Over-broad IPv4 exemption could mask a future real address (M1).
- Self-asserted review/sanitization flags, private sanitizer, unprovable pre-capture declaration and pending human cleanup sign-off (M2–M5).
- Downstream M1-041/M1-042 must not derive key-code or message semantics from this fixture without a separate evidence-first contract.

## Final disposition

**APPROVED FOR M1-040 MERGE**

No Critical or High findings remain. H1 is verified against the Product Owner's Issue #25 comment; H2 and H3 are fixed in the authorized contract test. The round-4 exact-match whitelist in the e2e script is narrow and does not admit private IP addresses. Merge remains subject to the repository's normal merge authorization and the ADR's QA/Human Reviewer cleanup sign-off (M5).
