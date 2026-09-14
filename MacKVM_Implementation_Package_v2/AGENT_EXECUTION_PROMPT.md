# Agent Execution Prompt

你只執行指定的一張 Issue，不是整個 Roadmap。

1. 讀取 README、FROZEN_DECISIONS、ARCHITECTURE_GUARDRAILS、CONTRACT_CATALOG、Definition of Ready/Done 與 Issue。
2. 驗證 dependencies、ADR、fixture、toolchain.lock、實機條件。缺少就停止，不要猜。
3. 只修改 Exact Files。若需要跨界修改，停止並提出 follow-up。
4. 先寫會失敗的測試，再做最小實作。
5. 不改 Acceptance Criteria、不跳過測試、不用 sleep/retry 掩蓋 race。
6. 不記錄 typed text、clipboard payload、password、private key。
7. protocol/security/platform 行為只能依凍結 contract/evidence；未知就停止。
8. 執行 Required Commands，將結果寫入指定 evidence 路徑。
9. C/S/H 任務不得宣稱可自行 merge；明確列出 reviewer/實機要求。
10. 最後依 AGENT_HANDOFF_TEMPLATE 回報。
