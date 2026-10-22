# M1-055 Evidence Summary

## Issue / Commit

- Issue: M1-055 — `實作 Network.framework TLS Transport Wrapper`, GitHub #54;
  P1, risk critical, execution tier `C/S`, `low_model_autonomous_merge: false`.
- Branch: `codex/m1-055-mac-tls-transport`
- Base: `17687e505c45ab7bb8e9b813bffc0b9ba953de8e`
- Implementation commit: `1c7ad3f99a3cb53772ec46078800ce624c00c22a`
- Status: **Commands 1-8 passed at the implementation commit.** Pending: the
  evidence commit, `make verify` at that commit, PR, GitHub CI and merge.
  None of these is claimed as passed.
- Authorship: **Claude Opus** authored all repository content (source, tests,
  component document, this evidence). The **Codex root reviewer** ran every
  command, reviewed, and drove fixes. Claude ran no commands; every result
  below is the reviewer's, transcribed. No human or independent external
  review is claimed.

## Change Summary

`MacPlatform` gains `MacTLSTransport`, a single-use `package` conformer of the
frozen M1-017 `Transport` contract over Network.framework:

- TLS by default; release builds can express no other mode.
- Peer certificates are handed as DER, in platform callback order with no
  index semantics, to an injected synchronous trust evaluator. System trust is
  not consulted; nothing is auto-accepted.
- Chains are bounded to 10 certificates and 262,144 bytes. Each verify
  callback is evaluated once; rejection is sticky.
- A plaintext development path exists only inside `#if DEBUG`.
- Typed `CoreError` failures only; no logging; no key or storage behavior.

Design detail: `docs/components/M1-055-mac-tlstransport.md`.

## Exact Files Changed

Implementation commit `1c7ad3f99a3cb53772ec46078800ce624c00c22a` contains
exactly these three:

- `Packages/MacPlatform/Sources/MacPlatform/MacTLSTransport.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/MacTLSTransportTests.swift`
- `docs/components/M1-055-mac-tlstransport.md`

Evidence package: `summary.md`, `commands.json`, `environment.json`,
`security-review.md`, `tests/results.json`, `tests/review-findings.json`. The
component document received validation/count corrections only.

The protected owner files `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/`
were not read, modified, staged or committed.

## Acceptance Criteria Evidence

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | 所有 Focus 項目均有可定位的 implementation、test 或簽核證據 | **Met.** TLS default, certificate handoff to evaluator, and DEBUG isolation each map to source and named tests. | `tests/results.json` `focusMapping` |
| 2 | Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過 | **Met.** 118 passed, 0 failed, 3 unrelated opt-in probes skipped. | `tests/results.json`; table below |
| 3 | Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API | **Met.** Nothing `public`; `package` surface only; frozen `Transport`, `CoreError` and `SecurityErrorCode` unchanged. | component doc; `security-review.md` |
| 4 | Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning | **Met at implementation commit.** architecture-check, strict lint (0 findings), warnings-as-errors, xcodebuild, release build and unit tests all exit 0; only existing nonfatal destination warnings. `make verify` pending. | `commands.json` |
| 5 | Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容 | **Met.** No production logging; failures carry only fixed taxonomy fields; privacy test checks renderings. | `tlsTransportFailuresCarryNoPeerBytesHostOrDiagnosticPayload` |
| 6 | Security reviewer 已檢查 fail-closed、key/secret handling、identity change 與 abuse path | **Met (non-author Codex review).** | `security-review.md` |

### Automated test categories

`MacTLSTransportTests.swift` declares 34 unconditional `@Test` functions plus
one DEBUG-only `@Test`. The full MacPlatform run reports 118 tests (package
total, including parameterized cases and other issues' tests).

| Category | Evidence |
| --- | --- |
| Happy path | contract conformance; TLS request at connect; chain evaluated once before ready; ordered receive; ordered send |
| Boundary / limit | fixed chain bounds; chain at both bounds accepted; 11 certs or 256 KiB + 1 rejected; 64 KiB read cap; read above cap; 16-chunk buffer overflow |
| Invalid input / failure | send before connect; single-use and concurrent connect; connect (7), receive (4), send (4) failure mappings; invalid endpoint on the production backend; peer EOF |
| Cancel / cleanup / idempotency | disconnect before, during and after connect; idempotent disconnect; disconnect from a cancelled task; task cancellation during connect; consumer cancellation |
| Fail-closed | every `SecurityErrorCode` rejection; empty chain; ready without verification; rejected peer cannot send or reconnect; repeated callbacks |
| Identity changed / invalid | `identityChanged` distinct from `trustRejected`; later-callback `identityChanged` fails closed despite earlier accept |

## Commands

Run by the Codex root reviewer at the implementation commit; UTC wrapper
timestamps are in `commands.json`.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `swift test --package-path Packages/MacPlatform` | 0 | 118 passed, 0 failed, 3 unrelated opt-in probes skipped; `arm64e-apple-macos14.0` |
| 2 | `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 | `** BUILD SUCCEEDED **`; `arm64-apple-macos14.0`; no M1-055 source warning |
| 3 | `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| 4 | `make architecture-check` | 0 | `architecture check OK` |
| 5 | `make docs-check` | 0 | `docs check OK` |
| 6 | `make code-quality-check` | 0 | swift-format 6.2.3; strict lint 0 findings; warnings-as-errors pass |
| 7 | `swift build --package-path Packages/MacPlatform -c release` | 0 | `Build complete!`; DEBUG-only path compiled out |
| 8 | `git diff --check HEAD^ HEAD` | 0 | no output |

### TDD and review history (not final failures)

- Initial RED: exit 1, `MacTLSTransport` and seam types absent.
- First compile fixes: `Task<()?, Never>` inference; `.wifiAware` missing from
  the `NWError` switch. Then 112 passed.
- Review fixes H-1, H-2 (with security regression RED, exit 1), H-3 and M-1;
  118 passed after each. See `tests/review-findings.json`.
- Formatter: 23 findings, then 5 tuple-layout findings, fixed formatting-only.

## Manual Verification

None is mandatory for M1-055, and none was performed. No real peer or network
interoperability has been tested.

## Review

Non-author Codex review, not human or independent external review.
Critical 0, High 0, Medium 0 unresolved; 8 Low open, non-blocking. Details in
`security-review.md`.

## Known Limitations

No real network/peer handshake exercised; synchronous evaluator may stall the
handshake; no transport-owned timeout; `.waiting` fails immediately as
unavailable; clean peer EOF is a disconnected failure; outbound `Data` has no
size cap; certificate indices have no documented meaning; source and tests are
large (826 + 1174 lines).

## Scope Exclusions (not implemented)

- Trust store, fingerprint computation or comparison, pinning, pairing,
  trust-on-first-use, identity-change policy, or any persistence (later E07).
- Key or secure-storage behavior.
- Session wiring, protocol messages, framing.
- Reconnect, retry, backoff, transport-owned timeouts.
- Client certificates, ALPN, custom TLS versions or ciphers.
- UI, diagnostics, any `public` API.

## Rollback Instructions

Revert implementation commit `1c7ad3f99a3cb53772ec46078800ce624c00c22a` and
the M1-055 evidence commit. No caller uses `MacTLSTransport`; there is no
persisted state, trust data, migration or runtime resource to clean up.
Revert on any issue rollback condition: crash, stuck input, silent trust
bypass, data leak, compatibility regression, weakened assertions, or deviation
from the frozen contract. None has been observed.

## Reviewer Required

Tier `C/S`: security-critical; no autonomous merge. Remaining: evidence
commit, `make verify` at that commit, PR, GitHub CI and merge.
