# Evidence Standard

每張 Issue 的 evidence 置於：`evidence/issues/<ID>/`。

最少包含：

- summary.md
- commands.json
- tests/*
- environment.json（H/E2E）
- manual.md（H/E2E）
- security-review.md（S/security/release）

所有 evidence 必須：

- 包含 commit、toolchain、日期與 exit code。
- 可由 reviewer 重跑或核對。
- 不包含 typed text、clipboard payload、password、private key、token。
- 失敗 evidence 不可刪除，只能附 remediation/retest。
