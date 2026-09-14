# MacKVM Implementation Package v2

這是可交給 Codex／Claude Code／人工團隊逐張執行的 **Agent-ready implementation backlog**。

## 不可誤解的產品終局

> 正式產品的 Server 與 Client 都必須使用第一方應用與 Native Protocol 工作；Barrier 僅用於 M1/M2 的前期驗證，以及正式版中的可選相容模組。

M1/M2 使用 Barrier 只是為了降低早期驗證風險。M3 起第一方 Native Protocol 成為主路徑；M5-028 才代表真正完成「取代 Barrier」。

## v2 與舊版差異

- 原本 74 張較大的 Issue，重新拆成 **217 張 XS/S/M execution units**。
- 每張都有 exact files、contract references、required commands、expected evidence、prohibited shortcuts 與 stop conditions。
- 以 A/B/C/S/H 標示模型與驗證等級；低階模型不得自行處理架構/security/實機決策。
- Barrier codec 之前加入「evidence capture → wire contract freeze」硬性 Gate，禁止猜 bytes。
- TLS、Fail-safe、Native Protocol、Wayland、更新簽章都拆成可 review 的獨立任務。
- 提供可編譯的 `reference/KVMContracts`、manifest/schema、next-issue 工具與 package validator。

## 統計

- Milestones：5
- Epics：17
- Execution Issues：217
- M1/M2/M3/M4/M5：70 / 38 / 39 / 42 / 28
- A/B/C/S/H 標記數：23 / 89 / 82 / 49 / 118

## 開始方式

1. 閱讀 `QUICKSTART.md`。
2. 執行：`python3 tools/validate_package.py`。
3. 執行 reference contracts：`swift test --package-path reference/KVMContracts`。
4. 先完成並簽核 M1-001～M1-003。
5. 用 `python3 tools/next_issue.py --completed progress.example.json --tier A,B` 找出可交給輕量模型的下一張 Issue。
6. 一張 Issue = 一個 branch = 一個 PR；任何模型都不能自主 merge。

## 核心文件

- `FROZEN_DECISIONS.md`
- `ARCHITECTURE_GUARDRAILS.md`
- `MODEL_ROUTING.md`
- `CONTRACT_CATALOG.md`
- `REPOSITORY_BLUEPRINT.md`
- `COMMAND_CONTRACT.md`
- `DEFINITION_OF_READY.md`
- `DEFINITION_OF_DONE.md`
- `EXECUTION_ORDER.md`
- `issues_manifest.json`
