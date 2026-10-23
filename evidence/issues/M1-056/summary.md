# M1-056 Evidence Summary

## Issue / Commit

- Issue: M1-056 — `實作 SHA-256 Certificate Fingerprint Formatter`, GitHub #61
  (<https://github.com/SheldonChangL/mac_kvm/issues/61>); P1, risk high,
  execution tier `A/S`, `low_model_autonomous_merge: false`; depends on
  M1-055.
- Branch: `codex/m1-056-certificate-fingerprint`
- Parent in branch history: `221c6281646e5a58e9e1c515f7e43cf3fca7957e`
  (merge commit of PR #322, M1-055).
- Implementation commit: `27300d6dadb5506b8a0825cab2c2fb04a996e882`
- Status: **Commands 1-8 passed at the implementation commit.** Pending:
  `make verify` and GitHub CI at the evidence commit, PR review and merge.
  None of these is claimed as passed.
- Authorship: **Claude Opus** authored all repository content (source, tests,
  component document, this evidence) using only Read, Grep, Glob and Edit.
  Claude ran no build, test, validation, formatter, git mutation, push, PR,
  merge, network or runtime verification command. The **Codex root reviewer**
  executed every recorded command, reviewed, and drove the workflow. Every
  result below is the reviewer's, transcribed. No human or independent
  external review is claimed.

## Change Summary

`MacPlatform` gains `CertificateFingerprint`, an internal caseless enum with
two separate, pure, synchronous operations:

- `sha256Digest(ofCertificateDER:)` returns the raw 32-byte CryptoKit SHA-256
  digest of non-empty DER, or `.emptyCertificate`.
- `canonicalDisplay(ofSHA256Digest:)` renders an exactly 32-byte digest as
  uppercase two-digit hex groups joined by single colons (95 characters), or
  `.invalidDigestLength`.
- `CertificateFingerprintFailure` is a closed, payload-free reason set.
- Raw digest and display string are separate: neither function calls the
  other. Nothing here decides trust, parses DER, selects a chain element,
  logs, stores, or touches the network.

Design detail: `docs/components/M1-056-certificate-fingerprint.md`.

## Exact Files

The issue's three Exact Files:

- `Packages/MacPlatform/Sources/MacPlatform/CertificateFingerprint.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/CertificateFingerprintTests.swift`
- `docs/components/M1-056-certificate-fingerprint.md`

Evidence package: `summary.md`, `commands.json`, `environment.json`,
`security-review.md`, `tests/results.json`, `tests/review-findings.json`.
Writing this evidence changed no source, test, component document or other
evidence file.

The protected owner files `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/`
were not read or modified by Claude.

## Acceptance Criteria Evidence

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met.** Canonical uppercase colon format, raw digest/display separation, and fixed test vectors each map to source and named tests. | `tests/results.json` `focusMapping` |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** 144 passed, 0 failed, 3 unrelated existing opt-in manual probes skipped. Cancel/cleanup is not applicable to a pure synchronous unit; statelessness and determinism are tested instead. | `tests/results.json`; table below |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** All declarations `internal`; no `public` or `package` API; no frozen contract, ADR or wire format changed. | component doc; `security-review.md` |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met at implementation commit.** architecture-check, strict lint, warnings-as-errors Swift tests, xcodebuild, release build and unit tests all exit 0. Repository-wide `make verify` at the evidence commit is pending. | `commands.json` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** No logging; failures carry no payload; a privacy test checks failure renderings for input bytes and length. | `failureRenderingsCarryNoInputBytes` |
| 6 | Security reviewer 已檢查 fail-closed、key/secret handling、identity change 與 abuse path | **Met (non-author Codex review).** | `security-review.md` |

### Automated test categories

`CertificateFingerprintTests.swift` declares 26 `@Test` functions; one is
parameterized over 9 invalid digest lengths. The full MacPlatform run reports
144 tests passed (package total, including other issues' tests).

| Category | Evidence |
| --- | --- |
| Happy path | digest length constant; FIPS `abc` digest and display; hash-then-format end to end; explicit `0x00...0x1F` display; uppercase for every byte value |
| Boundary / limit | single-byte input; FIPS two-block input; 256 KiB input; `Data` slices with non-zero start index |
| Invalid input / failure | empty DER; empty slice of a non-empty buffer; 9 wrong digest lengths; display text offered as a digest; closed distinct failure set |
| Cancel / cleanup / idempotency | not applicable (pure, synchronous, no resource); caseless enum has zero size; determinism; failures do not poison later calls |
| Fail-closed | empty DER refused and never yields the empty-input digest; wrong-length digest refused, not truncated, padded or rehashed |
| Fingerprint changed / invalid | different certificates; every single-bit flip; appended or truncated certificate |

Fixed vectors (`abc`, single byte `0x00`, FIPS 56-byte message) were
independently checked by the reviewer with `shasum`.

## Commands

Run by the Codex root reviewer at the implementation commit; UTC timestamps
are in `commands.json`.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `swift test --package-path Packages/MacPlatform` | 0 | 144 passed, 0 failed, 3 unrelated existing opt-in manual probes skipped |
| 2 | `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination platform=macOS build` | 0 | `BUILD SUCCEEDED` |
| 3 | `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| 4 | `make architecture-check` | 0 | `architecture check OK` |
| 5 | `make docs-check` | 0 | `docs check OK` |
| 6 | `git diff --check HEAD^ HEAD` | 0 | no output |
| 7 | `make code-quality-check` | 0 | swift-format 6.2.3; strict lint exit 0; Swift tests warnings-as-errors exit 0 |
| 8 | `swift build --package-path Packages/MacPlatform -c release` | 0 | `Build complete` |

### TDD history (not final results)

- An initial in-sandbox RED attempt was rejected as evidence: SwiftPM could
  not invoke nested `sandbox-exec`.
- Valid RED, run outside the outer sandbox: exit 1, exactly because
  `CertificateFingerprint` and `CertificateFingerprintFailure` did not exist.
- GREEN passed after the implementation; superseded by command 1 above.

## Manual Verification

None is required for M1-056, and none was performed.

## Review

Non-author Codex review, not human or independent external review.
Critical 0, High 0, Medium 0; 3 Low, non-blocking. Details in
`security-review.md`.

## Known Limitations

As in the component document: no DER parsing or certificate validation
(malformed non-empty bytes are hashed); no chain selection; display and any
future comparison are not constant-time (fingerprints are not secrets);
input size is not capped by this unit (M1-055 bounds the peer chain to
256 KiB); the display form is fixed to SHA-256, uppercase, colon-separated.

## Scope Exclusions (not implemented)

- Trust decision, comparison, pinning, trust-on-first-use or identity-change
  policy (M1-057 / C-009 trust policy).
- Choice of which chain certificate is the leaf.
- Storage, persistence, logging, diagnostics, network, UI or protocol message.
- Other algorithms, lowercase or unseparated forms, display-string parsing.

The three Low findings are documented scope boundaries; no follow-up issue is
required for them.

## Rollback Instructions

Revert the M1-056 PR/commits. No caller uses `CertificateFingerprint`; there
is no persisted data, trust data, migration or runtime resource to clean up.

## Reviewer Required

Tier `A/S`: security-critical; no autonomous merge. Remaining: `make verify`
and GitHub CI at the evidence commit, PR review and merge by an authorized
reviewer.
