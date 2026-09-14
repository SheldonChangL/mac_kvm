---
id: "M1-037"
title: "實作 Mouse Button Injector 與 Pressed-button Ledger"
milestone: "M1 - Mac Client MVP（Barrier 驗證）"
epic: "E04 - macOS Client Mouse/Coordinate"
priority: "P1"
size: "M"
risk: "critical"
execution_tier: "B/H"
low_model_autonomous_merge: false
depends_on:
  - "M1-033"
  - "M1-035"
contract_refs:
  []
source_refs:
  []
labels:
  - "milestone:M1"
  - "epic:E04"
  - "priority:P1"
  - "risk:critical"
  - "tier:B"
  - "tier:H"
  - "mac"
---

# M1-037 — 實作 Mouse Button Injector 與 Pressed-button Ledger

## Outcome

實作 Mouse Button Injector 與 Pressed-button Ledger

## Model Routing

- **B**：可由輕量模型實作，但必須由較強模型或工程師完整 review。
- **H**：需要實機、憑證、OS 權限或人工操作才能驗收。

**規則：** 任何模型都不得自主 merge；C/S/H 任務尤其需要指定 reviewer 或實機驗證。

## Preconditions

- 所有 dependencies 已完成：M1-033, M1-035。

## Exact Files

- `Packages/MacPlatform/Sources/MacPlatform/MacMouseButtonInjector.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/MacMouseButtonInjectorTests.swift`
- `docs/components/M1-037-mac-mouse-button-injector.md`

Exact Files 以外若必須修改，停止並提出 follow-up，不得偷偷擴大 PR。

## Frozen Contract References

- 本 Issue 不新增 public contract；如需要，停止並先建立 ADR/contract Issue。

## Scope

- down/up idempotency
- 維護 pressed buttons
- 提供 releaseAllMouseButtons
- 只建立或修改「Exact Files」列出的檔案；其他檔案如需變更，先停止並提出 follow-up。
- 遵守 E04 與所有 Architecture Guardrails。
- 加入成功、邊界、錯誤與 cancellation/cleanup 測試。

## Out of Scope

- 不實作未列在 Scope 的 UI、protocol message、平台或重構。
- 不改變已凍結 contract、ADR 或 wire format；若不一致，必須停止。
- 不以跳過測試、放寬安全預設、吞掉錯誤或寫死 demo 值來通過驗收。
- 不把 OS-specific key code 或 event type 放進 KVMEvent/Native wire schema。

## Implementation Procedure

- 1. 讀取 README、FROZEN_DECISIONS、ARCHITECTURE_GUARDRAILS、CONTRACT_CATALOG、Definition of Ready/Done 與本 Issue。
- 2. 檢查 depends_on 全部完成，且所需 ADR/fixture/toolchain.lock 已存在；否則停止。
- 3. 先新增或更新失敗測試／fixture assertion，再進行最小實作。
- 4. 只依凍結 contract 實作；不得自行推測 wire bytes、security policy 或平台權限行為。
- 5. 執行 Required Commands，保存 machine-readable report 與必要實機 evidence。
- 6. 逐條填寫 Acceptance Criteria 對照、known limitations、rollback 與 follow-up。

## Acceptance Criteria

- [ ] 所有 Focus 項目均有可定位的 implementation、test 或簽核證據。
- [ ] Happy path、boundary、invalid input、error/cancel/cleanup tests 全部通過。
- [ ] Public behavior 與 CONTRACT_CATALOG／凍結 ADR 一致，沒有新增隱含 API。
- [ ] Architecture checker、lint、build、unit tests 全部通過且沒有新增 warning。
- [ ] Production logs 不包含 typed text、clipboard payload、secret/private key 或可還原內容。
- [ ] Manual/實機 evidence 已由非執行 Agent 的 reviewer 驗證。

## Automated Tests

- [ ] 至少一個 happy-path test。
- [ ] 至少一個 boundary/limit test。
- [ ] 至少一個 invalid input 或 failure test。
- [ ] 如有 async/state/resource：至少一個 cancel/cleanup/idempotency test。

## Required Commands

```bash
swift test --package-path Packages/MacPlatform
xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build
python3 Tools/Backlog/validate_package.py
make architecture-check
```

若 command contract 尚未由 dependency 建立，本 Issue 不得宣稱完成。

## Expected Evidence

- [ ] `evidence/issues/M1-037/summary.md`：變更摘要與 AC 對照。
- [ ] `evidence/issues/M1-037/commands.json`：命令、exit code、起訖時間與 commit。
- [ ] `evidence/issues/M1-037/tests/`：machine-readable test report。
- [ ] `evidence/issues/M1-037/environment.json`：OS/hardware/network/peer metadata。
- [ ] `evidence/issues/M1-037/manual.md`：步驟、預期、實際、reviewer。

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
- 沒有指定的實機／權限／對端／憑證環境，不能以 mock 宣稱完成。

## Deliverables

- [ ] Exact Files 中列出的 production/test/docs 變更。
- [ ] 完整 evidence package：`evidence/issues/M1-037/`。
- [ ] 建議 PR title、PR body、rollback instructions 與 follow-up list。

## Rollback Conditions

- 新增 crash、stuck input、local input suppression、silent trust bypass、data leak 或 compatibility regression。
- Tests 只能在放寬 assertion、跳過案例或使用不穩定 sleep 後通過。
- 實作偏離 frozen contract/ADR/fixture。

## Required Agent Handoff

完成回報必須依 `AGENT_HANDOFF_TEMPLATE.md`，逐條貼出 AC、命令結果、evidence path、known limitations 與 reviewer requirement。
