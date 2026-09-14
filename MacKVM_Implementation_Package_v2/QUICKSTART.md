# Quick Start

## 1. 驗證下載內容

```bash
python3 tools/validate_package.py
swift test --package-path reference/KVMContracts
```

兩個命令都必須成功。否則先不要交給 Agent。

## 2. 建立進度檔

複製：

```bash
cp progress.example.json progress.json
```

完成 Issue 後，把 ID 加到 `completed`；被阻擋的 Issue 加到 `blocked` 並寫原因。

## 3. 選下一張任務

輕量模型候選：

```bash
python3 tools/next_issue.py --completed progress.json --tier A,B
```

強模型／工程師任務：

```bash
python3 tools/next_issue.py --completed progress.json --tier C,S
```

實機任務：

```bash
python3 tools/next_issue.py --completed progress.json --tier H
```

## 4. 交給 Agent

把下列內容一起提供：

- `AGENT_EXECUTION_PROMPT.md`
- 指定 Issue
- Issue 引用的 contract／ADR／fixture
- repository 當前狀態

不要把整個專案丟給低階模型並要求「全部做完」。

## 5. Review 與 Merge

- A：可由輕量模型實作，CI 通過後抽查 review。
- B：可由輕量模型實作，但必須完整 code review。
- C：由強模型或工程師主導。
- S：強制 security review。
- H：強制實機／人工證據。

任何 tier 都不得由執行 Agent 自主 merge。
