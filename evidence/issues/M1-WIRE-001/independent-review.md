# M1-WIRE-001 Independent Five-Axis Review

## Review identity and verdict

- Reviewer: Codex independent reviewer
- Independence: the reviewer did not author the M1-WIRE-001 implementation; Claude Opus 5 authored the implementation and corrective edits.
- Reviewed at: `2026-10-02T08:20:10Z`
- GitHub Issue: `#278`
- Base: `origin/main` at `99c9cbb110b04d3dd6713a632d3a98ba812e09fb`
- Verdict: **APPROVED** for the scoped corrective change.
- Critical findings: **0 open**
- High findings: **0 open**
- Medium findings: **0 open**
- Low findings: **0 open**

The evidence approval is intentionally narrow. `BARRIER-EVID-0002` proves only the claims and candidate interpretation recorded in the entry. It does not establish an exact length-prefix width. That unresolved decision is owned by M1-WIRE-002, GitHub Issue `#279`, which remains open and blocks completion of the M1-025 exact-width freeze.

## 1. Source validity and traceability

- The canonical specification and frozen decisions remain unchanged.
- The source fixture is the already approved M1-024 sanitized fixture. Its SHA-256 remains `57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2` and its byte length remains 1079.
- `BARRIER-EVID-0001` is structurally equal to `origin/main`; canonical-object SHA-256 is `786bec605220b46dcd337c227ef0dfd2864e4344c58bf5aa563770cb66617026` on both sides.
- `BARRIER-EVID-0002` is appended, not substituted for or merged into `BARRIER-EVID-0001`.
- Issue #278, the ADR, source traceability, package issues, derived artifact and contract test point to one another.
- GitHub Issue #279 records the remaining owner, P0 priority and blocking relation for discriminating exact-width evidence.

## 2. Product contract and architecture boundaries

- No production Swift source changed and no parser, codec or reassembler was implemented early.
- Barrier remains confined to the Protocol Adapter boundary.
- `KVMEvent` remains the Core/Protocol event boundary.
- Protocol and KVM Core remain separate, and Input Engine has no Barrier message-code or networking dependency.
- Client-before-server ordering and production TLS default-on/fail-closed behavior are unchanged.
- The corrected dependency sequence is M1-WIRE-001 → M1-025 → M1-021 → M1-022. M1-025 additionally stops before exact-width freeze until approved M1-WIRE-002 evidence exists.

## 3. Security, fail-safe and compatibility

- No new capture, raw packet material or external source code entered the repository.
- The derived artifact copies only allowed structural bytes and records all other payload as offsets and lengths.
- Windows was not executed and no Windows compatibility is claimed.
- TLS was off only in the already approved bounded observation; the production TLS default remains enabled and fail closed.
- General version negotiation, downgrade, cross-version compatibility, message-code meaning and exact prefix width are explicit non-claims.
- The initial overclaim that the current fixture established a 4-byte prefix was corrected. The current artifact records a candidate 4-byte big-endian interpretation and the equally fitting narrower 2-byte big-endian alternative.

## 4. Tests, validation and acceptance criteria

Verified acceptance criteria:

- `BARRIER-EVID-0001` is unchanged from `origin/main`.
- Every `BARRIER-EVID-0002` claim resolves to retained fixture and derived-artifact locations.
- Version behavior is limited to observed bytes plus a proposed exact-supported-version fail-closed policy owned by M1-025.
- Candidate framing, exact-width unknown state, observed coalescing in runs 5 and 6, and unobserved split delivery are recorded consistently.
- Dependency order and direct #279 blocking traceability are consistent across package files, ADR, summary and tests.
- Mutation checks fail closed for fixture, artifact, evidence, dependency, architecture, TLS, Windows and width-proof drift.
- The change contains no production Swift or protocol parser.

Executed validation commands and exact results:

| Command | Exact result |
|---|---|
| `python3 -m unittest Tests.Contracts.test_m1_wire_001_contract_sequence -v` | exit 0; 20 tests ran in 0.161s; `OK` |
| `make verify` | exit 0; all 22 reported gates `PASSED`, including manifest, docs, architecture, code quality, evidence/tool tests, repository contract tests, Swift tests and native arm64 build |
| `git diff --check` | exit 0; no output |
| canonical JSON comparison of `BARRIER-EVID-0001` against `git show origin/main:evidence/registers/M1-023.json` | equal `True`; both canonical-object SHA-256 values `786bec605220b46dcd337c227ef0dfd2864e4344c58bf5aa563770cb66617026` |
| changed-path Swift scan | exit 0; no changed `.swift` path |
| targeted secret-pattern scan over M1-WIRE-001 documents, evidence and register | no credential value found; the test file contains only deliberate denylist literals used by the scanner |
| `gh issue view 278 ...` and `gh issue view 279 ...` | both readable; #278 and #279 are open, labeled for M1/P0/critical/C/H, and record the corrected blocking relation |

## 5. Scope control, repository hygiene and rollback

- Changes are limited to evidence, tests, ADR/docs, package dependency metadata and traceability for Issue #278.
- The owner artifacts `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were neither inspected nor modified and remain untracked.
- `issues_index.csv` changes only the three intended rows; unrelated CRLF lines were preserved.
- Generated `artifacts/` output remains ignored.
- Before merge, rollback is a single PR revert. After merge, the register is append-only; a reviewed follow-up must mark an entry rejected or superseded instead of deleting or rewriting it.

## Findings resolved during review

- **High — resolved:** the first author draft overclaimed a proven 4-byte length prefix even though the 2-byte big-endian reading also partitioned all runs. Claims, field IDs, tests, ADR and M1-025 gate were downgraded to candidate-only, and Issue #279 was created for discriminating evidence.
- **High — resolved:** the first draft said no coalescing was observed, despite runs 5 and 6 containing multiple complete candidate frames. The evidence now records coalescing and distinguishes it from unobserved split delivery.
- **Medium — resolved:** focused tests initially failed after the claim downgrade because expected field IDs and derivation shape were stale. They were synchronized and now pass.
- **Low — resolved:** full-file CSV newline normalization caused unnecessary churn. The diff now changes only the three intended rows and passes `git diff --check`.

## Remaining risks

- Exact Barrier length-prefix width remains unknown. This is an explicit blocking risk, not an accepted assumption; Issue #279 owns the discriminating evidence work.
- The observation covers one version pair on one Linux/macOS setup with TLS disabled on the bounded evidence leg. It establishes no general compatibility, TLS behavior or Windows result.
- GitHub-hosted PR checks must still pass at the committed PR head before merge.
