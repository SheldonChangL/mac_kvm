# Frozen Decisions

下列決策已凍結，Agent 不得自行改寫：

1. **產品終局：** 正式產品的 Server 與 Client 都必須使用第一方應用與 Native Protocol 工作；Barrier 僅用於 M1/M2 的前期驗證，以及正式版中的可選相容模組。
2. **Client-first 是驗證策略，不是產品縮限。**
3. **KVMEvent 是唯一 Core event language。** Barrier/Native/platform code 必須在 adapter 邊界轉換。
4. **Barrier-specific tokens/types 不可進 KVMCore。**
5. **macOS M1～M3 使用 Swift／SwiftUI+AppKit／Network.framework／CGEvent／NSPasteboard／Keychain。**
6. **TLS/security 預設 fail closed。** 未知或變更 identity 不得自動接受。
7. **Fail-safe 高於功能完整度。** 任何 terminal path 必須釋放 keys/buttons、停止 suppression、恢復 local state。
8. **Privacy-safe logging。** 不記錄 typed text、clipboard payload、password、private key 或可重建內容。
9. **獨立實作。** 不複製 Barrier/Deskflow GPL implementation 到第一方核心。
10. **一張 Issue 一個 PR。** 只修改 Exact Files；跨界變更需 follow-up/ADR。
11. **任何模型都不得自主 merge。** C/S/H 另有強制 reviewer/evidence。
12. **M4 toolchain/Wayland 等未凍結決策必須先完成指定 ADR，後續 Agent 不可自行選。**
