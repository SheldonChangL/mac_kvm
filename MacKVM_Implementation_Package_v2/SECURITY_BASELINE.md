# Security Baseline

- TLS/secure channel 預設開啟。
- Unknown/changed/revoked identity 預設拒絕。
- Private keys/trust records 使用 OS secure storage。
- Pairing 需要雙方使用者驗證，不可只靠 LAN discovery。
- Decoder 在 allocation 前驗證 size/limits。
- Queue/session/rate 有明確上限。
- Privileged helper 使用最小權限、認證 IPC、嚴格 validation。
- Update manifest/artifact 必須簽章並具 anti-rollback policy。
- Logs、crash dumps、diagnostic bundles 不含使用者輸入內容或 secrets。
- Security-critical Issue 需要 S review evidence。
