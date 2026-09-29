---
id: "M1-068"
title: "記錄 Windows Barrier Server 不執行處置（M1 Windows Non-execution Disposition）"
milestone: "M1 - Mac Client MVP（Barrier 驗證）"
epic: "E08 - Reliability、Fail-safe 與 Client UX"
priority: "P0"
size: "M"
risk: "critical"
execution_tier: "C/H"
low_model_autonomous_merge: false
depends_on:
  - "M1-051"
  - "M1-054"
  - "M1-059"
  - "M1-065"
  - "M1-067"
contract_refs:
  []
source_refs:
  []
labels:
  - "milestone:M1"
  - "epic:E08"
  - "priority:P0"
  - "risk:critical"
  - "tier:C"
  - "tier:H"
  - "gate"
---

# M1-068 — 記錄 Windows Barrier Server 不執行處置（M1 Windows Non-execution Disposition）

## Outcome

記錄 Product Owner 核准的 Windows Barrier Server 不執行處置（M1 Windows Non-execution Disposition）

依 `docs/adr/M1-SCOPE-001-linux-only-validation.md`（Accepted 2026-09-29，Issue #270），Windows 在 M1 不執行、不測試。本 Issue 是可稽核的處置 gate，不是 E2E 執行，不產生任何 Windows pass 或相容性結論。

## Model Routing

- **C**：需要強模型或資深工程師主導；輕量模型只能協助。
- **H**：需要 Product Owner 核准與非執行 Agent 的 reviewer 簽核才能驗收。

**規則：** 任何模型都不得自主 merge；C/S/H 任務尤其需要指定 reviewer 或實機驗證。

## Preconditions

- 所有 dependencies 已完成：M1-051, M1-054, M1-059, M1-065, M1-067。
- `docs/adr/M1-SCOPE-001-linux-only-validation.md` 狀態為 Accepted。

## Exact Files

- `Tests/SystemTests/Plans/M1-068-windows-barrier-client-e2-e.md`
- `Tests/SystemTests/Scripts/M1-068-windows-barrier-client-e2-e.sh`
- `evidence/e2e/M1-068/README.md`
- `evidence/e2e/M1-068/result.json`

Exact Files 以外若必須修改，停止並提出 follow-up，不得偷偷擴大 PR。

## Frozen Contract References

- `docs/adr/M1-SCOPE-001-linux-only-validation.md`
- 本 Issue 不新增 public contract；如需要，停止並先建立 ADR/contract Issue。

## Scope

- 記錄 Product Owner 決策（2026-09-29，Issue #270）與 M1-SCOPE-001 ADR 引用
- machine-readable disposition：`result.json` 的 disposition 為 `not_executed`，不得為 pass/fail 或相容性結論
- Plan 與 README 明示 Windows 在 M1 未執行、未測試，不得宣稱 Windows 相容
- Script 只驗證 disposition 記錄，不啟動、不連線、不執行任何 Windows 測試
- 只建立或修改「Exact Files」列出的檔案；其他檔案如需變更，先停止並提出 follow-up。
- 遵守 E08 與所有 Architecture Guardrails。

## Out of Scope

- 執行 Windows Barrier Server → Mac Client E2E 或擷取 Windows fixture。
- 以 Linux、mock 或推測結果代替 Windows 結果。
- 不實作未列在 Scope 的 UI、protocol message、平台或重構。
- 不改變已凍結 contract、ADR 或 wire format；若不一致，必須停止。
- 不以跳過測試、放寬安全預設、吞掉錯誤或寫死 demo 值來通過驗收。

## Implementation Procedure

- 1. 讀取 README、FROZEN_DECISIONS、ARCHITECTURE_GUARDRAILS、CONTRACT_CATALOG、Definition of Ready/Done、M1-SCOPE-001 ADR 與本 Issue。
- 2. 檢查 depends_on 全部完成，且 M1-SCOPE-001 為 Accepted；否則停止。
- 3. 先新增會在 disposition 缺漏或宣稱 pass/相容時失敗的 script assertion，再建立 disposition 記錄。
- 4. 只依 M1-SCOPE-001 記錄處置；不得執行 Windows 測試或推測 Windows 行為。
- 5. 執行 Required Commands，保存 machine-readable report。
- 6. 逐條填寫 Acceptance Criteria 對照、known limitations、rollback 與 follow-up。

## Acceptance Criteria

- [ ] `evidence/e2e/M1-068/result.json` 記錄 disposition `not_executed`、Product Owner decision 日期 2026-09-29、Issue #270 與 ADR path。
- [ ] `result.json` 不含 pass、compatible、任何 Windows 執行結果或推測的 Windows 行為。
- [ ] Plan 與 README 明示 Windows 在 M1 未執行、未測試，且 M1 evidence 不得宣稱 Windows 相容。
- [ ] Script 在 disposition 缺漏、非 `not_executed` 或宣稱 pass/相容時以非零 exit code 失敗，且不啟動任何 Windows 或網路連線。
- [ ] Product Owner 核准與非執行 Agent 的 reviewer 簽核已記錄。

## Automated Tests

- [ ] Disposition result JSON 符合 schema，且 disposition 必須為 `not_executed`。
- [ ] Script 可重跑且 exit code 正確；宣稱 pass/相容的 negative case 必須失敗。
- [ ] evidence validator 驗證 metadata、artifacts 與 redaction。

## Required Commands

```bash
bash Tests/SystemTests/Scripts/M1-068-windows-barrier-client-e2-e.sh
python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-068/result.json
python3 Tools/Backlog/validate_package.py
make docs-check
make architecture-check
```

若 command contract 尚未由 dependency 建立，本 Issue 不得宣稱完成。

## Expected Evidence

- [ ] `evidence/issues/M1-068/summary.md`：變更摘要與 AC 對照。
- [ ] `evidence/issues/M1-068/commands.json`：命令、exit code、起訖時間與 commit。
- [ ] `evidence/issues/M1-068/tests/`：machine-readable test report。
- [ ] `evidence/issues/M1-068/manual.md`：Product Owner 核准引用與 reviewer 簽核。

## Manual Verification

- [ ] Reviewer 確認未執行任何 Windows 測試，且 disposition 未宣稱 pass/相容。
- [ ] Reviewer 確認 Product Owner decision、Issue #270 與 ADR 引用一致。
- [ ] 保存的 evidence 不得包含 typed text、clipboard payload 或 secret。

## Prohibited Shortcuts

- 不得將 Acceptance Criteria 改成符合目前實作。
- 不得將 disposition 記錄為 pass、skip-as-pass 或 Windows 相容。
- 不得以 Linux 或 mock 結果填入 Windows 結果。
- 不得 catch-all 後忽略錯誤或永遠回傳成功。
- 不得修改 dependency Issue 的 frozen output；需另開變更 ADR。

## Stop Conditions

遇到任一條件就停止實作、保留目前 evidence，回報 blocker：

- 任一 depends_on 未完成、未 merge 或 evidence 不可讀。
- M1-SCOPE-001 非 Accepted，或 Product Owner decision 被撤回。
- CONTRACT_CATALOG、ADR、fixture 與現有 repository 行為互相衝突。
- 需要修改 Exact Files 以外的架構或 public API 才能完成。
- 有人要求在 M1 執行 Windows 或宣稱 Windows 相容；需先有新的 superseding ADR。
- 只有低階模型可用而沒有強模型/工程師 reviewer。

## Deliverables

- [ ] Exact Files 中列出的 disposition plan、script、README 與 result.json。
- [ ] 完整 evidence package：`evidence/issues/M1-068/`。
- [ ] 建議 PR title、PR body、rollback instructions 與 follow-up list。

## Rollback Conditions

- Disposition 被解讀或記錄為 Windows pass/相容。
- Tests 只能在放寬 assertion 或跳過案例後通過。
- 實作偏離 frozen contract/ADR。

## Required Agent Handoff

完成回報必須依 `AGENT_HANDOFF_TEMPLATE.md`，逐條貼出 AC、命令結果、evidence path、known limitations 與 reviewer requirement。
