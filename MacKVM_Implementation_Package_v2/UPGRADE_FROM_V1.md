# Upgrade from Backlog Package v1

v1：74 張 work packages；多個 L/XL Issue 仍要求 Agent 自行補設計。

v2：217 張 execution issues；最大只到 M，並加入：

- Barrier evidence/wire-contract gates
- TLS fingerprint/trust/Keychain 分拆
- input ledger/fail-safe/cleanup/fault injection 分拆
- Native protocol requirements/threat/encoding/identity/pairing/codec/session/conformance 分拆
- Windows/Linux backend 與 E2E 分拆
- Wayland/uinput privilege/security gate
- signed update/rollback/release gates
- A/B/C/S/H model routing
- exact files/commands/evidence/stop conditions

不要同時使用 v1、v2 ID 執行同一 repository。新專案直接採 v2。
