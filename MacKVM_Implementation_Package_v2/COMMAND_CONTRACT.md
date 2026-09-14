# Command Contract

Repository scaffold 必須提供下列穩定命令；Issue 可依賴名稱，不得各自發明命令。

```text
make verify                 # all fast checks
make architecture-check
make docs-check
make verify-windows ISSUE=Mx-xxx
make verify-linux ISSUE=Mx-xxx
make verify-release ISSUE=Mx-xxx
make e2e ISSUE=Mx-xxx
```

命令必須：

- 非零 exit code 表示失敗。
- 產生 machine-readable report。
- 不自動改檔、不自動略過失敗、不要求互動式輸入（實機 E2E 除外）。
- 顯示 toolchain/version/commit。
