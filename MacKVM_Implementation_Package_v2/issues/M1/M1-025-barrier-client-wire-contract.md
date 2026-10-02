---
id: "M1-025"
title: "凍結 Barrier Client Wire Contract v0.1"
milestone: "M1 - Mac Client MVP（Barrier 驗證）"
epic: "E03 - Barrier Compatibility Evidence 與 Codec"
priority: "P0"
size: "M"
risk: "critical"
execution_tier: "C/H"
low_model_autonomous_merge: false
depends_on:
  - "M1-024"
contract_refs:
  []
source_refs:
  []
labels:
  - "milestone:M1"
  - "epic:E03"
  - "priority:P0"
  - "risk:critical"
  - "tier:C"
  - "tier:H"
  - "decision"
---

# M1-025 — 凍結 Barrier Client Wire Contract v0.1

## Outcome

凍結 Barrier Client Wire Contract v0.1

## Model Routing

- **C**：需要強模型或資深工程師主導；輕量模型只能協助。
- **H**：需要實機、憑證、OS 權限或人工操作才能驗收。

**規則：** 任何模型都不得自主 merge；C/S/H 任務尤其需要指定 reviewer 或實機驗證。

## Preconditions

- 所有 dependencies 已完成：M1-024。
- 修正前置條件：GitHub Issue #278（M1-WIRE-001，[`docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`](../../../docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md)）已 merge，`evidence/registers/M1-023.json` 中 `BARRIER-EVID-0002` 的 disposition 為 `approved`，且 `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json` 存在。M1-WIRE-001 不在 70 筆 canonical manifest 中，而 manifest validator 只接受 manifest ID，因此此前置條件記錄於此而非 `depends_on`。若未滿足，停止。
- Length-prefix width 前置條件（fail closed）：即使 M1-WIRE-001 已 merge 且 `BARRIER-EVID-0002` 為 `approved`，仍須在凍結 exact length-prefix width 前停止，除非另有 separately approved discriminating evidence（由 GitHub Issue #279（M1-WIRE-002，Acquire discriminating Barrier length-prefix evidence）取得，並在 `evidence/registers/M1-023.json` 中登錄為另一筆 disposition 為 `approved`、且能唯一確定該 width 的 entry）。GitHub Issue #279（M1-WIRE-002）是取得該 evidence 的 separately approved workflow；它不在 70 筆 canonical manifest 中，因此此 blocker 記錄於此而非 `depends_on`，且在 #279 完成並取得 `approved` entry 前，M1-025 不得完成 exact length-prefix width 凍結。`BARRIER-EVID-0002` 與 `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json` 只記錄 candidate 4-byte unsigned big-endian interpretation 可切分保留的 bytes，而較窄的 2-byte big-endian reading 同樣可切分全部 run，因此不足以證明 exact length-prefix width；未取得該 evidence 前，width 維持 unknown 並列為 blocker，不得推定。
- 本 Issue 不依賴 M1-021 或 M1-022；本 Issue 凍結的 wire contract 是它們的前置條件，順序為 M1-WIRE-001 → M1-025 → M1-021 → M1-022。

## Exact Files

- `docs/adr/M1-025-barrier-client-wire-contract.md`

Exact Files 以外若必須修改，停止並提出 follow-up，不得偷偷擴大 PR。

## Frozen Contract References

- 本 Issue 不新增 public contract；如需要，停止並先建立 ADR/contract Issue。
- Evidence 輸入僅限 `evidence/registers/M1-023.json` 中 disposition 為 `approved` 的 `BARRIER-EVID-0001`、`BARRIER-EVID-0002` 與 `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`；未被這些 entry 的 claim 建立的欄位維持 unknown，不得猜測；exact length-prefix width 另受 Preconditions 的 fail-closed 前置條件限制。
- M1-WIRE-001 提出的 fail-closed exact-supported-version policy（`exact-supported-version-fail-closed`）由本 Issue 採納或拒絕並記錄理由；不得宣稱一般版本協商或跨版本相容。

## Scope

- 精確 frame layout、field width、endian、version behavior
- 列出 unknown/unsupported variants
- 後續 parser 只能依此文件與 fixtures
- 只建立或修改「Exact Files」列出的檔案；其他檔案如需變更，先停止並提出 follow-up。
- 遵守 E03 與所有 Architecture Guardrails。

## Out of Scope

- 不實作未列在 Scope 的 UI、protocol message、平台或重構。
- 不改變已凍結 contract、ADR 或 wire format；若不一致，必須停止。
- 不以跳過測試、放寬安全預設、吞掉錯誤或寫死 demo 值來通過驗收。

## Implementation Procedure

- 1. 讀取 README、FROZEN_DECISIONS、ARCHITECTURE_GUARDRAILS、CONTRACT_CATALOG、Definition of Ready/Done 與本 Issue。
- 2. 檢查 depends_on 全部完成，且所需 ADR/fixture/toolchain.lock 已存在；否則停止。
- 3. 列出選項、限制、威脅、相容性與不可逆成本；產出可簽核 ADR，不先寫 production code。
- 4. 只依凍結 contract 實作；不得自行推測 wire bytes、security policy 或平台權限行為。
- 5. 執行 Required Commands，保存 machine-readable report 與必要實機 evidence。
- 6. 逐條填寫 Acceptance Criteria 對照、known limitations、rollback 與 follow-up。

## Acceptance Criteria

- [ ] 所有 Focus 項目均有可定位的 implementation、test 或簽核證據。
- [ ] ADR/spec 明確列出 Selected、Rejected、Consequences、Security/Compatibility impact 與 Rollback。
- [ ] 所有 open questions 都有 owner 與阻擋條件；不得以「之後再決定」通過。
- [ ] 需要 Owner/Security/Human 的簽核已記錄。
- [ ] Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證。

## Automated Tests

- [ ] Markdown/schema lint。
- [ ] 所有 referenced contract/issue/evidence path 存在。
- [ ] 決策文件沒有 unresolved placeholder（TODO/TBD 除非有 owner/date/blocker）。

## Required Commands

```bash
make docs-check
python3 Tools/Backlog/validate_package.py
make architecture-check
```

若 command contract 尚未由 dependency 建立，本 Issue 不得宣稱完成。

## Expected Evidence

- [ ] `evidence/issues/M1-025/summary.md`：變更摘要與 AC 對照。
- [ ] `evidence/issues/M1-025/commands.json`：命令、exit code、起訖時間與 commit。
- [ ] `evidence/issues/M1-025/tests/`：machine-readable test report。
- [ ] `evidence/issues/M1-025/environment.json`：OS/hardware/network/peer metadata。
- [ ] `evidence/issues/M1-025/manual.md`：步驟、預期、實際、reviewer。

## Manual Verification

- [ ] 依 Issue Focus 在指定 OS／硬體／對端版本執行，不可用 mock 取代。
- [ ] 記錄日期、build commit、OS/build、CPU architecture、display/layout、keyboard layout、network 與對端版本。
- [ ] 保存 sanitized log、result.json、必要 screenshot/video；不得包含 typed text、clipboard payload 或 secret。
- [ ] 由 reviewer 確認操作結果與 cleanup/fail-safe，而不只接受 Agent 自述。

## Prohibited Shortcuts

- 不得將 Acceptance Criteria 改成符合目前實作。
- 不得新增 sleep/retry 來掩蓋 race condition。
- 不得 catch-all 後忽略錯誤或永遠回傳成功。
- 不得修改 dependency Issue 的 frozen output；需另開變更 ADR。
- 不得在未取得 evidence 時猜測 protocol bytes、platform API 或 security behavior。

## Stop Conditions

遇到任一條件就停止實作、保留目前 evidence，回報 blocker：

- 任一 depends_on 未完成、未 merge 或 evidence 不可讀。
- CONTRACT_CATALOG、ADR、fixture 與現有 repository 行為互相衝突。
- 需要修改 Exact Files 以外的架構或 public API 才能完成。
- 無法寫出會先失敗、能客觀驗證需求的測試。
- 發現安全、授權、資料隱私或 stuck-input 風險未被規格涵蓋。
- 只有低階模型可用而沒有強模型/工程師 reviewer。
- 沒有指定的實機／權限／對端／憑證環境，不能以 mock 宣稱完成。

## Deliverables

- [ ] Exact Files 中列出的 production/test/docs 變更。
- [ ] 完整 evidence package：`evidence/issues/M1-025/`。
- [ ] 建議 PR title、PR body、rollback instructions 與 follow-up list。

## Rollback Conditions

- 新增 crash、stuck input、local input suppression、silent trust bypass、data leak 或 compatibility regression。
- Tests 只能在放寬 assertion、跳過案例或使用不穩定 sleep 後通過。
- 實作偏離 frozen contract/ADR/fixture。

## Required Agent Handoff

完成回報必須依 `AGENT_HANDOFF_TEMPLATE.md`，逐條貼出 AC、命令結果、evidence path、known limitations 與 reviewer requirement。
