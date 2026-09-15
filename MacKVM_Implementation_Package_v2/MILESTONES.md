## M1 — Mac Client MVP（Barrier 驗證）

使用既有 Windows/Linux Barrier Server 驗證第一方 macOS Client、KVM Core、Input Injection、Clipboard、TLS 與 Fail-safe。

### Exit Criteria

- [ ] Apple Silicon arm64 原生執行，不依賴 Rosetta。
- [ ] Windows 與 Linux Barrier Server 均可控制 Mac 的 mouse、keyboard、scroll 與 UTF-8 clipboard。
- [ ] Barrier wire code 僅存在 BarrierCompatibility；Core 僅接收 KVMEvent。
- [ ] TLS 預設開啟，未知/變更 fingerprint 不會被靜默接受。
- [ ] 所有 disconnect/error/cancel/sleep 路徑均執行可重入的 input cleanup。
- [ ] 具備可供內部測試的最小 Menu Bar Alpha build 與 E2E 證據。

## M2 — Mac Server MVP（Barrier 驗證）

使用既有 Windows/Linux Barrier Client 驗證第一方 macOS Server 的 input capture、screen routing、coordinate switching 與 multi-session。

### Exit Criteria

- [ ] macOS 實體 mouse/keyboard 可安全捕捉、轉成 KVMEvent，且不回收第一方注入事件。
- [ ] Local/EnteringRemote/Remote/LeavingRemote 狀態轉換有固定表格、測試與 emergency escape。
- [ ] Mac 可控制 Windows/Linux Barrier Client，並可安全返回本機。
- [ ] 支援多 Client session、screen links、edge delay、dead zone、coordinate normalization。
- [ ] Server 斷線或例外時不會永久抑制本機輸入。

## M3 — Native Protocol Alpha（Mac ↔ Mac）

建立第一方 Native Protocol，完成第一方 Mac Server 與第一方 Mac Client 在完全不啟動 Barrier 的情況下工作。

### Exit Criteria

- [ ] Native framing、版本/能力協商、identity、pairing、trust、session、keepalive、reconnect 均有凍結規格。
- [ ] Mouse、keyboard、clipboard、screen control 均透過 Native Protocol 傳送。
- [ ] Mac ↔ Mac E2E、fault injection、malformed frame 與 conformance vectors 通過。
- [ ] BarrierCompatibility 可在 build/runtime 中完全關閉，且不影響正常流程。

## M4 — Cross-platform Beta（macOS / Windows / Linux）

完成第一方 Windows 與 Linux 應用，使主要 Server/Client 組合都使用第一方 App 與 Native Protocol。

### Exit Criteria

- [ ] macOS、Windows、Linux 皆有第一方 Client。
- [ ] macOS、Windows 具備第一方 Server；Linux Server 依凍結支援矩陣交付。
- [ ] 主要 OS 組合通過 keyboard、mouse、clipboard、DPI/scaling 與 reconnect matrix。
- [ ] 正常 Beta 工作流程完全不依賴 Barrier。
- [ ] 各平台均有可安裝、可啟動、可診斷的 Beta artifact。

## M5 — 1.0 Production Release

完成 discovery、pairing UX、device/screen management、可靠性、安全、簽章、更新與正式發佈。

### Exit Criteria

- [ ] 第一方 Server/Client 與 Native Protocol 為預設且完整可用。
- [ ] Discovery、pairing、trust/revoke、multi-device、multi-monitor、hot-plug 均可用。
- [ ] 完成長時間 soak、sleep/wake、network fault、crash recovery 與 performance gate。
- [ ] 完成 macOS notarization、Windows signing、Linux packages 與簽名更新/rollback。
- [ ] Barrier 僅為可選相容模組；移除 Barrier 不影響 1.0 的核心工作流程。
