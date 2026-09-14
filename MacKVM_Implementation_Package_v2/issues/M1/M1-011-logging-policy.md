---
id: "M1-011"
title: "定義 Privacy-safe Logging 與 Error Taxonomy"
milestone: "M1 - Mac Client MVP（Barrier 驗證）"
epic: "E01 - Repository、Build、CI 與診斷"
priority: "P1"
size: "M"
risk: "high"
execution_tier: "B"
low_model_autonomous_merge: false
depends_on:
  - "M1-002"
contract_refs:
  - "C-010"
source_refs:
  []
labels:
  - "milestone:M1"
  - "epic:E01"
  - "priority:P1"
  - "risk:high"
  - "tier:B"
  - "decision"
---

# M1-011 — 定義 Privacy-safe Logging 與 Error Taxonomy

## Outcome

定義 Privacy-safe Logging 與 Error Taxonomy

## Model Routing

- **B**：可由輕量模型實作，但必須由較強模型或工程師完整 review。

**規則：** 任何模型都不得自主 merge；C/S/H 任務尤其需要指定 reviewer 或實機驗證。

## Preconditions

- 所有 dependencies 已完成：M1-002。
- 以下 contracts 版本已凍結：C-010。

## Exact Files

- `docs/adr/M1-011-logging-policy.md`

Exact Files 以外若必須修改，停止並提出 follow-up，不得偷偷擴大 PR。

## Frozen Contract References

- `C-010` — 詳見 `CONTRACT_CATALOG.md`。

## Scope

- 不得記錄 typed text、password、clipboard payload
- 定義 category、event id、correlation id
- 錯誤可診斷但不可還原使用者內容
- 只建立或修改「Exact Files」列出的檔案；其他檔案如需變更，先停止並提出 follow-up。
- 遵守 E01 與所有 Architecture Guardrails。

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

- [ ] `evidence/issues/M1-011/summary.md`：變更摘要與 AC 對照。
- [ ] `evidence/issues/M1-011/commands.json`：命令、exit code、起訖時間與 commit。
- [ ] `evidence/issues/M1-011/tests/`：machine-readable test report。

## Manual Verification

- [ ] 無強制實機步驟；reviewer 仍需重跑 Required Commands。

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

## Deliverables

- [ ] Exact Files 中列出的 production/test/docs 變更。
- [ ] 完整 evidence package：`evidence/issues/M1-011/`。
- [ ] 建議 PR title、PR body、rollback instructions 與 follow-up list。

## Rollback Conditions

- 新增 crash、stuck input、local input suppression、silent trust bypass、data leak 或 compatibility regression。
- Tests 只能在放寬 assertion、跳過案例或使用不穩定 sleep 後通過。
- 實作偏離 frozen contract/ADR/fixture。

## Required Agent Handoff

完成回報必須依 `AGENT_HANDOFF_TEMPLATE.md`，逐條貼出 AC、命令結果、evidence path、known limitations 與 reviewer requirement。
