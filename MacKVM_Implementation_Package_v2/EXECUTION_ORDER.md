# Execution Order

依 topological order 執行；同時只能挑 dependencies 全部完成的 Issue。

## M1 — Mac Client MVP（Barrier 驗證）

| Order | Issue | Tier | Risk | Title | Depends on |
|---:|---|---|---|---|---|
| 1 | [M1-001](issues/M1/M1-001-product-contract.md) | C/H | critical | 凍結產品合約與 Barrier 退場條件 | — |
| 2 | [M1-002](issues/M1/M1-002-architecture-boundary.md) | C | critical | 凍結 KVMEvent／Adapter／Core 架構邊界 | M1-001 |
| 3 | [M1-003](issues/M1/M1-003-independent-implementation-policy.md) | C/S | critical | 凍結獨立實作與授權／證據政策 | M1-001 |
| 4 | [M1-004](issues/M1/M1-004-repository-skeleton.md) | A | low | 建立 macOS Repository／Workspace 骨架 | M1-001, M1-002 |
| 5 | [M1-011](issues/M1/M1-011-logging-policy.md) | B | high | 定義 Privacy-safe Logging 與 Error Taxonomy | M1-002 |
| 6 | [M1-005](issues/M1/M1-005-mac-arm64-build.md) | A | medium | 設定 Apple Silicon arm64 原生 Build | M1-004 |
| 7 | [M1-006](issues/M1/M1-006-package-boundaries.md) | B | medium | 建立 Swift Package 模組邊界 | M1-004, M1-002 |
| 8 | [M1-012](issues/M1/M1-012-diagnostic-bundle.md) | A | medium | 建立 Redacted Diagnostic Bundle 骨架 | M1-011 |
| 9 | [M1-007](issues/M1/M1-007-test-targets.md) | A | low | 建立 Unit／Integration／System Test Targets 與 Fixtures 目錄 | M1-006 |
| 10 | [M1-013](issues/M1/M1-013-kvmevent.md) | B | critical | 定義 Canonical KVMEvent Domain Model | M1-002, M1-006 |
| 11 | [M1-008](issues/M1/M1-008-cigates.md) | A | medium | 建立 Pull Request CI Build／Test Gate | M1-005, M1-007 |
| 12 | [M1-023](issues/M1/M1-023-barrier-evidence-register.md) | C/H | high | 建立 Barrier Compatibility Evidence Register | M1-003, M1-007 |
| 13 | [M1-014](issues/M1/M1-014-domain-identifiers.md) | A | medium | 定義 Device／Screen／Session Identifier Types | M1-013 |
| 14 | [M1-015](issues/M1/M1-015-core-errors.md) | A | medium | 定義 Core Error／Result／Cancellation Taxonomy | M1-013, M1-011 |
| 15 | [M1-009](issues/M1/M1-009-code-quality.md) | A | low | 加入 Format／Lint／Warnings-as-errors 規則 | M1-008 |
| 16 | [M1-010](issues/M1/M1-010-architecture-check.md) | B | high | 建立 Architecture Boundary Checker | M1-006, M1-008 |
| 17 | [M1-024](issues/M1/M1-024-barrier-client-handshake-fixtures.md) | H | critical | 擷取並 Sanitise Barrier Client Handshake Fixtures | M1-023 |
| 19 | [M1-016](issues/M1/M1-016-kvmprotocol-session.md) | B | critical | 定義 KVMProtocolSession Interface | M1-013, M1-015 |
| 20 | [M1-017](issues/M1/M1-017-transport.md) | B | critical | 定義 Transport Interface 與 Byte Stream Semantics | M1-015 |
| 21 | [M1-018](issues/M1/M1-018-kvmclock.md) | B | medium | 建立 Clock／Timeout／Scheduler 可測試抽象 | M1-015 |
| 22 | [M1-021](issues/M1/M1-021-barrier-binary-codec.md) | B | high | 實作 Bounded BinaryReader／BinaryWriter | M1-015 |
| 23 | [M1-035](issues/M1/M1-035-accessibility-permission-service.md) | B/H | high | 實作 macOS Accessibility Permission Service | M1-006, M1-015 |
| 24 | [M1-052](issues/M1/M1-052-clipboard-payload.md) | A | medium | 定義 ClipboardPayload 與 UTF-8 Text Codec | M1-013, M1-015 |
| 25 | [M1-040](issues/M1/M1-040-barrier-keyboard-fixtures.md) | H | critical | 擷取並 Sanitise Barrier Keyboard Fixtures | M1-023, M1-024 |
| 27 | [M1-019](issues/M1/M1-019-mock-transport.md) | A | medium | 實作 MockTransport | M1-017 |
| 28 | [M1-036](issues/M1/M1-036-mac-mouse-move-injector.md) | B/H | high | 實作 macOS Mouse Move Injector | M1-013, M1-035 |
| 29 | [M1-053](issues/M1/M1-053-mac-pasteboard-adapter.md) | B/H | high | 實作 NSPasteboard Read／Write Adapter | M1-035, M1-052 |
| 30 | [M1-042](issues/M1/M1-042-virtual-key-catalog.md) | B | critical | 凍結 VirtualKey Catalog 與 Unknown-key Policy | M1-013, M1-040 |
| 32 | [M1-020](issues/M1/M1-020-async-harness.md) | B | high | 建立 Deterministic Async Test Harness | M1-018, M1-019 |
| 33 | [M1-054](issues/M1/M1-054-clipboard-loop-guard.md) | B | high | 實作 Clipboard Origin／Hash Loop Prevention 與 Size Limit | M1-052, M1-053 |
| 34 | [M1-044](issues/M1/M1-044-mac-key-code-mapper.md) | B | critical | 實作 VirtualKey → macOS CGKeyCode Mapper（US Baseline） | M1-042, M1-035 |
| 36 | [M1-022](issues/M1/M1-022-barrier-frame-reassembler.md) | B | critical | 實作 TCP Stream Frame Reassembler 與 Size Limits | M1-019, M1-020, M1-021 |
| 37 | [M1-045](issues/M1/M1-045-keyboard-layout-strategy.md) | C/H | critical | 建立 Keyboard Layout Strategy 與 Unsupported-layout 行為 | M1-044 |
| 38 | [M1-025](issues/M1/M1-025-barrier-client-wire-contract.md) | C/H | critical | 凍結 Barrier Client Wire Contract v0.1 | M1-024, M1-021, M1-022 |
| 39 | [M1-026](issues/M1/M1-026-barrier-message-registry.md) | B | high | 實作 Barrier Message Registry 與 Unknown-message Policy | M1-025 |
| 40 | [M1-027](issues/M1/M1-027-barrier-server-hello.md) | A | high | 實作 Barrier Server Hello Parser | M1-025, M1-026 |
| 41 | [M1-028](issues/M1/M1-028-barrier-client-hello-back.md) | A | high | 實作 Barrier Client HelloBack Encoder | M1-025, M1-026 |
| 42 | [M1-031](issues/M1/M1-031-barrier-control-messages.md) | B | high | 實作 Screen Info／Enter／Leave／Keepalive Control Decoder | M1-025, M1-026 |
| 43 | [M1-032](issues/M1/M1-032-barrier-mouse-move-decoder.md) | A | medium | 實作 DMMV Mouse Move Decoder → KVMEvent | M1-013, M1-025, M1-026 |
| 44 | [M1-033](issues/M1/M1-033-barrier-mouse-button-decoder.md) | A | medium | 實作 Mouse Button Decoder → KVMEvent | M1-013, M1-025, M1-026 |
| 45 | [M1-034](issues/M1/M1-034-barrier-mouse-wheel-decoder.md) | A | medium | 實作 Mouse Wheel Decoder → KVMEvent | M1-013, M1-025, M1-026 |
| 46 | [M1-041](issues/M1/M1-041-barrier-keyboard-decoder.md) | B | critical | 實作 DKDN／DKUP／DKRP Decoder | M1-025, M1-026, M1-040 |
| 47 | [M1-029](issues/M1/M1-029-barrier-client-handshake.md) | B | critical | 實作 Barrier Client Handshake State Machine | M1-016, M1-027, M1-028 |
| 48 | [M1-039](issues/M1/M1-039-client-coordinate-mapper.md) | B/H | critical | 實作 Client Coordinate Normalization／Bounds／Retina Handling | M1-031, M1-032, M1-036 |
| 49 | [M1-037](issues/M1/M1-037-mac-mouse-button-injector.md) | B/H | critical | 實作 Mouse Button Injector 與 Pressed-button Ledger | M1-033, M1-035 |
| 50 | [M1-038](issues/M1/M1-038-mac-scroll-injector.md) | B/H | high | 實作 Vertical／Horizontal Scroll Injector | M1-034, M1-035 |
| 51 | [M1-043](issues/M1/M1-043-barrier-virtual-key-mapper.md) | B | critical | 實作 Barrier Key → VirtualKey Mapper | M1-041, M1-042 |
| 52 | [M1-046](issues/M1/M1-046-modifier-state-ledger.md) | B | critical | 實作 ModifierState Ledger | M1-041, M1-042 |
| 53 | [M1-030](issues/M1/M1-030-barrier-handshake-tests.md) | A | high | 補齊 Handshake Fragmentation／Timeout／Mismatch Tests | M1-020, M1-029 |
| 54 | [M1-055](issues/M1/M1-055-mac-tlstransport.md) | C/S | critical | 實作 Network.framework TLS Transport Wrapper | M1-017, M1-029 |
| 55 | [M1-066](issues/M1/M1-066-menu-bar-status.md) | A | medium | 實作最小 Menu Bar Connection Status UI | M1-029, M1-035 |
| 57 | [M1-047](issues/M1/M1-047-caps-lock-synchronizer.md) | B/H | high | 實作 Caps Lock Synchronization Semantics | M1-046 |
| 58 | [M1-048](issues/M1/M1-048-key-repeat-controller.md) | B | high | 實作 Key Repeat Semantics | M1-041, M1-046 |
| 59 | [M1-049](issues/M1/M1-049-mac-keyboard-injector.md) | B/H | critical | 實作 macOS KeyboardInjector | M1-044, M1-046, M1-035 |
| 60 | [M1-062](issues/M1/M1-062-input-state-ledger.md) | B | critical | 建立 Input State Ledger 與 Snapshot API | M1-037, M1-046, M1-054 |
| 61 | [M1-056](issues/M1/M1-056-certificate-fingerprint.md) | A/S | high | 實作 SHA-256 Certificate Fingerprint Formatter | M1-055 |
| 62 | [M1-060](issues/M1/M1-060-reconnect-manager.md) | B | high | 實作 Reconnect Backoff 與 Manual Disconnect Semantics | M1-018, M1-029, M1-055 |
| 64 | [M1-050](issues/M1/M1-050-release-all-keys.md) | B/H | critical | 實作 releaseAllKeys 與 Release Ordering | M1-046, M1-049 |
| 65 | [M1-057](issues/M1/M1-057-trust-policy.md) | C/S | critical | 實作 Trust Policy State Machine | M1-056, M1-015 |
| 66 | [M1-061](issues/M1/M1-061-mac-recovery-coordinator.md) | C/H | critical | 實作 Network Change／Sleep-Wake Recovery | M1-060 |
| 67 | [M1-051](issues/M1/M1-051-keyboard-compatibility-matrix.md) | H | critical | 執行 Keyboard／Shortcut／IME Compatibility Matrix | M1-045, M1-047, M1-048, M1-049, M1-050 |
| 68 | [M1-063](issues/M1/M1-063-fail-safe-coordinator.md) | C | critical | 實作 Idempotent FailSafeCoordinator | M1-050, M1-062 |
| 69 | [M1-058](issues/M1/M1-058-keychain-trust-store.md) | C/S/H | critical | 實作 Keychain Trust Store 與 First-use Coordinator | M1-057 |
| 70 | [M1-064](issues/M1/M1-064-cleanup-hooks.md) | C | critical | 將 Cleanup Hooks 接入所有 Terminal／Error／Cancel 路徑 | M1-060, M1-061, M1-063 |
| 71 | [M1-059](issues/M1/M1-059-fingerprint-change-flow.md) | B/S/H | critical | 實作 Fingerprint Change Warning／Reject Flow | M1-058 |
| 72 | [M1-067](issues/M1/M1-067-client-settings-ui.md) | B/H | medium | 實作 Client Settings 與 Diagnostic Export UI | M1-012, M1-058, M1-060, M1-066 |
| 73 | [M1-065](issues/M1/M1-065-client-fault-injection.md) | B | critical | 建立 Client Fault-injection Regression Suite | M1-020, M1-064 |
| 74 | [M1-068](issues/M1/M1-068-windows-barrier-client-e2-e.md) | H | critical | 執行 Windows Barrier Server → Mac Client E2E | M1-051, M1-054, M1-059, M1-065, M1-067 |
| 75 | [M1-069](issues/M1/M1-069-linux-barrier-client-e2-e.md) | H | critical | 執行 Linux Barrier Server → Mac Client E2E | M1-068 |
| 76 | [M1-070](issues/M1/M1-070-m1-exit-review.md) | C/H | critical | 完成 M1 Alpha Exit Review | M1-069 |

## M2 — Mac Server MVP（Barrier 驗證）

| Order | Issue | Tier | Risk | Title | Depends on |
|---:|---|---|---|---|---|
| 18 | [M2-015](issues/M2/M2-015-mac-screen-inventory.md) | B/H | high | 實作 Screen Inventory 與 Display Change Monitor | M1-014 |
| 26 | [M2-016](issues/M2/M2-016-screen-topology.md) | B | critical | 定義 ScreenTopology／ScreenLinks Validation | M2-015 |
| 31 | [M2-017](issues/M2/M2-017-edge-detector.md) | B/H | high | 實作 EdgeDetector Activation Delay／Dead Zone | M2-016 |
| 35 | [M2-018](issues/M2/M2-018-edge-detector-tests.md) | A | medium | 實作 Corner Exclusion／Activation Cancellation Tests | M2-017, M1-018 |
| 56 | [M2-019](issues/M2/M2-019-outbound-coordinate-mapper.md) | B/H | critical | 實作 Outbound Coordinate Mapper | M2-015, M2-016, M1-039 |
| 63 | [M2-020](issues/M2/M2-020-return-coordinate-mapper.md) | B/H | critical | 實作 Return-edge Coordinate Mapper | M2-019 |
| 77 | [M2-001](issues/M2/M2-001-mac-server-safety-model.md) | C/S/H | critical | 凍結 macOS Server Capture Safety／Threat Model | M1-070 |
| 78 | [M2-002](issues/M2/M2-002-event-tap-permission-service.md) | B/H | high | 實作 CGEventTap Permission／Preflight Service | M2-001, M1-035 |
| 79 | [M2-003](issues/M2/M2-003-capture-queue.md) | C | critical | 建立 Real-time Capture Queue 與 Backpressure Policy | M2-001, M1-020 |
| 80 | [M2-008](issues/M2/M2-008-input-state-table.md) | C/H | critical | 凍結 Local／EnteringRemote／Remote／LeavingRemote Transition Table | M2-001, M1-062 |
| 81 | [M2-004](issues/M2/M2-004-mac-mouse-capture.md) | B/H | critical | 實作 macOS Mouse Capture Adapter | M2-002, M2-003, M1-013 |
| 82 | [M2-005](issues/M2/M2-005-mac-keyboard-capture.md) | B/H | critical | 實作 macOS Keyboard Capture Adapter | M2-002, M2-003, M1-042, M1-046 |
| 83 | [M2-009](issues/M2/M2-009-input-state-reducer.md) | B | critical | 實作純函式 InputState Reducer | M2-008 |
| 84 | [M2-006](issues/M2/M2-006-synthetic-event-filter.md) | C/H | critical | 實作 Synthetic Event Tagging／Self-event Filtering | M2-004, M2-005, M1-036, M1-049 |
| 85 | [M2-022](issues/M2/M2-022-barrier-server-fixtures.md) | H | critical | 擷取並 Sanitise Barrier Server-side Fixtures | M1-023, M2-004, M2-005 |
| 86 | [M2-010](issues/M2/M2-010-enter-remote-trigger.md) | B/H | critical | 實作 Local → EnteringRemote Edge Trigger | M2-009 |
| 87 | [M2-007](issues/M2/M2-007-event-tap-lifecycle.md) | B/H | high | 實作 EventTap Start／Stop／Restart Lifecycle | M2-002, M2-006 |
| 88 | [M2-023](issues/M2/M2-023-barrier-server-wire-contract.md) | C/H | critical | 凍結 Barrier Server Wire Contract v0.1 | M2-022 |
| 89 | [M2-011](issues/M2/M2-011-enter-remote-commit.md) | B/H | critical | 實作 EnteringRemote Commit／Rollback／Timeout | M2-010 |
| 90 | [M2-024](issues/M2/M2-024-barrier-listener-transport.md) | B | critical | 實作 Barrier Listener Transport | M1-017, M2-023 |
| 91 | [M2-026](issues/M2/M2-026-barrier-mouse-encoder.md) | A | high | 實作 Barrier Mouse Event Encoder | M2-023, M2-004, M1-021 |
| 92 | [M2-027](issues/M2/M2-027-barrier-keyboard-encoder.md) | B | critical | 實作 Barrier Keyboard Event Encoder | M2-023, M2-005, M1-043, M1-046 |
| 93 | [M2-012](issues/M2/M2-012-leave-remote-flow.md) | B/H | critical | 實作 Remote → LeavingRemote → Local Flow | M2-011 |
| 94 | [M2-013](issues/M2/M2-013-local-event-suppressor.md) | C/S/H | critical | 實作 Remote State Local Event Suppression | M2-006, M2-009, M2-011 |
| 95 | [M2-025](issues/M2/M2-025-barrier-server-handshake.md) | C | critical | 實作 Barrier Server Handshake／Session Accept | M2-024, M1-026 |
| 96 | [M2-021](issues/M2/M2-021-cursor-restorer.md) | C/H | critical | 實作 Cursor Warp／Restore Local Position | M2-012, M2-020 |
| 97 | [M2-028](issues/M2/M2-028-barrier-clipboard-control-encoder.md) | B | high | 實作 Barrier Clipboard／Control Encoder | M2-023, M1-052, M1-054, M2-010, M2-012 |
| 98 | [M2-014](issues/M2/M2-014-emergency-escape.md) | B/H | critical | 實作 Emergency Escape Hotkey 與 Fail-open Recovery | M2-013, M1-063 |
| 99 | [M2-029](issues/M2/M2-029-server-session.md) | B | critical | 實作 Server Session Lifecycle Actor | M2-025, M2-026, M2-027, M2-028 |
| 100 | [M2-030](issues/M2/M2-030-session-manager.md) | C | critical | 實作 Multi-client SessionManager | M2-029 |
| 101 | [M2-031](issues/M2/M2-031-screen-router.md) | C | critical | 實作 ScreenRouter Target Selection | M2-009, M2-016, M2-030 |
| 102 | [M2-033](issues/M2/M2-033-server-fail-safe.md) | C/H | critical | 實作 Server-side Fail-safe／Local Recovery Coordinator | M2-013, M2-014, M2-021, M2-030, M1-063 |
| 103 | [M2-032](issues/M2/M2-032-server-clipboard-router.md) | B/H | high | 實作 Server Clipboard Routing／Loop Prevention | M1-054, M2-030, M2-031 |
| 104 | [M2-034](issues/M2/M2-034-mac-to-windows-barrier-e2-e.md) | H | critical | 執行 Mac Server → Windows Barrier Client E2E | M2-032, M2-033 |
| 105 | [M2-035](issues/M2/M2-035-mac-to-linux-barrier-e2-e.md) | H | critical | 執行 Mac Server → Linux Barrier Client E2E | M2-034 |
| 106 | [M2-036](issues/M2/M2-036-multi-client-routing-e2-e.md) | H | critical | 執行 Multi-client Routing E2E | M2-035 |
| 107 | [M2-037](issues/M2/M2-037-mac-server-soak.md) | H | critical | 執行 8-hour Server Soak／Fault Test | M2-036 |
| 108 | [M2-038](issues/M2/M2-038-m2-exit-review.md) | C/H | critical | 完成 M2 Exit Review | M2-037 |

## M3 — Native Protocol Alpha（Mac ↔ Mac）

| Order | Issue | Tier | Risk | Title | Depends on |
|---:|---|---|---|---|---|
| 109 | [M3-001](issues/M3/M3-001-native-protocol-requirements.md) | C/H | critical | 撰寫 Native Protocol Goals／Non-goals／Limits | M2-038 |
| 110 | [M3-002](issues/M3/M3-002-native-threat-model.md) | C/S/H | critical | 完成 Native Protocol Threat Model | M3-001 |
| 111 | [M3-003](issues/M3/M3-003-native-transport-adr.md) | C/S/H | critical | 凍結 Native Transport Baseline ADR | M3-001, M3-002 |
| 112 | [M3-004](issues/M3/M3-004-native-encoding-adr.md) | C/S | critical | 凍結 Wire Encoding／Canonicalization ADR | M3-001, M3-002 |
| 113 | [M3-011](issues/M3/M3-011-device-identity.md) | C/S | critical | 定義 Device Identity Model | M3-002, M3-003 |
| 114 | [M3-005](issues/M3/M3-005-native-frame-header.md) | C/S | critical | 定義 Native Frame Header Schema | M3-003, M3-004 |
| 115 | [M3-012](issues/M3/M3-012-pairing-protocol.md) | C/S/H | critical | 定義 Pairing Protocol Sequence／User Verification | M3-011 |
| 116 | [M3-006](issues/M3/M3-006-native-message-registry.md) | B | high | 建立 Native Message Type Registry | M3-005 |
| 117 | [M3-009](issues/M3/M3-009-native-resource-limits.md) | C/S | critical | 定義 Resource／DoS Bounds 與 Decoder Budget | M3-002, M3-005 |
| 118 | [M3-013](issues/M3/M3-013-identity-bootstrap.md) | C/S | critical | 定義 Certificate／Key Bootstrap | M3-011, M3-012 |
| 119 | [M3-007](issues/M3/M3-007-native-version-negotiation.md) | C/S | critical | 定義 Version Negotiation Flow | M3-005, M3-006 |
| 120 | [M3-021](issues/M3/M3-021-native-frame-encoder.md) | B | high | 實作 Canonical Native Frame Encoder | M3-005, M3-006 |
| 121 | [M3-020](issues/M3/M3-020-native-frame-decoder.md) | B/S | critical | 實作 Bounded Native Frame Decoder | M3-005, M3-006, M3-009 |
| 122 | [M3-014](issues/M3/M3-014-trust-lifecycle.md) | C/S | critical | 定義 Trust Revocation／Rotation／Re-pair | M3-013 |
| 123 | [M3-008](issues/M3/M3-008-native-capability-negotiation.md) | C | critical | 定義 Capability Negotiation Flow | M3-007 |
| 124 | [M3-033](issues/M3/M3-033-native-fuzz-harness.md) | C/S | critical | 建立 Malformed Frame／Fuzz Harness | M3-020, M3-021, M3-009 |
| 125 | [M3-028](issues/M3/M3-028-mac-native-trust-integration.md) | C/S/H | critical | 實作 macOS Pairing／Trust Store Integration | M3-012, M3-013, M3-014, M1-058 |
| 126 | [M3-010](issues/M3/M3-010-native-error-codes.md) | B | high | 定義 Native Error Code Taxonomy | M3-007, M3-008, M3-009 |
| 127 | [M3-015](issues/M3/M3-015-native-kvmevent-schema.md) | C | critical | 定義 KVMEvent Native Wire Schema | M1-013, M3-004, M3-008, M3-009 |
| 128 | [M3-022](issues/M3/M3-022-native-session.md) | C | critical | 實作 Native Session State Machine | M3-007, M3-008, M3-010, M3-020, M3-021 |
| 129 | [M3-016](issues/M3/M3-016-native-mouse-codec.md) | B | high | 實作 Native Mouse Codec | M3-005, M3-015 |
| 130 | [M3-017](issues/M3/M3-017-native-keyboard-codec.md) | B | critical | 實作 Native Keyboard Codec | M3-005, M3-015, M1-042 |
| 131 | [M3-018](issues/M3/M3-018-native-clipboard-codec.md) | B | high | 實作 Native Clipboard Codec | M3-005, M3-015, M1-052, M3-009 |
| 132 | [M3-019](issues/M3/M3-019-native-control-codec.md) | B | high | 實作 Native Screen／Control Codec | M3-005, M3-015 |
| 133 | [M3-034](issues/M3/M3-034-conformance-vector-format.md) | B | high | 定義 Cross-language Conformance Vector Format | M3-004, M3-015 |
| 134 | [M3-024](issues/M3/M3-024-native-backpressure.md) | C | critical | 實作 Backpressure／Queue／Coalescing Policy | M3-009, M3-022 |
| 135 | [M3-023](issues/M3/M3-023-native-liveness.md) | B | high | 實作 Keepalive／Liveness Timeout | M3-018, M3-019, M3-022, M1-018 |
| 136 | [M3-026](issues/M3/M3-026-native-client-adapter.md) | B | critical | 實作 Native Client Adapter | M1-016, M3-016, M3-017, M3-018, M3-019, M3-022 |
| 137 | [M3-027](issues/M3/M3-027-native-server-adapter.md) | B | critical | 實作 Native Server Adapter | M2-030, M2-031, M3-016, M3-017, M3-018, M3-019, M3-022 |
| 138 | [M3-035](issues/M3/M3-035-native-canonical-vectors.md) | C/H | critical | 產生 Canonical Native Protocol Test Vectors | M3-016, M3-017, M3-018, M3-019, M3-034 |
| 139 | [M3-025](issues/M3/M3-025-native-resume.md) | C/S | critical | 定義並實作 Reconnect／Resume Semantics | M3-014, M3-022, M3-023 |
| 140 | [M3-029](issues/M3/M3-029-native-mac-mouse-e2-e.md) | H | critical | 執行 First-party Mac → Mac Mouse E2E | M3-026, M3-027, M3-028 |
| 141 | [M3-037](issues/M3/M3-037-optional-barrier-module.md) | B | critical | 將 BarrierCompatibility 改為 Optional Build／Runtime Module | M3-026, M3-027 |
| 142 | [M3-036](issues/M3/M3-036-swift-conformance-runner.md) | B | high | 建立 Swift Native Protocol Conformance Runner | M3-035 |
| 143 | [M3-032](issues/M3/M3-032-native-fault-injection.md) | B | critical | 建立 Native Session Fault-injection Suite | M3-025, M3-026, M3-027 |
| 144 | [M3-030](issues/M3/M3-030-native-mac-keyboard-e2-e.md) | H | critical | 執行 First-party Mac → Mac Keyboard E2E | M3-029 |
| 145 | [M3-031](issues/M3/M3-031-native-mac-clipboard-e2-e.md) | H | high | 執行 First-party Mac ↔ Mac Clipboard E2E | M3-030 |
| 146 | [M3-038](issues/M3/M3-038-barrier-disabled-e2-e.md) | H | critical | 執行 Barrier-disabled Install／E2E | M3-031, M3-032, M3-037 |
| 147 | [M3-039](issues/M3/M3-039-m3-exit-review.md) | C/S/H | critical | 完成 M3 Alpha Exit Review | M3-033, M3-036, M3-038 |

## M4 — Cross-platform Beta（macOS / Windows / Linux）

| Order | Issue | Tier | Risk | Title | Depends on |
|---:|---|---|---|---|---|
| 148 | [M4-001](issues/M4/M4-001-cross-platform-toolchain.md) | C/S/H | critical | 凍結 Cross-platform Toolchain／Language／FFI ADR | M3-039 |
| 149 | [M4-002](issues/M4/M4-002-platform-backend-contracts.md) | C | critical | 定義 Language-neutral Platform Backend Contracts | M4-001, M1-013, M3-034 |
| 150 | [M4-003](issues/M4/M4-003-cross-platform-conformance-runner.md) | B | high | 建立 Cross-platform Conformance Runner Contract | M4-001, M3-035, M4-002 |
| 151 | [M4-004](issues/M4/M4-004-windows-skeleton.md) | A | medium | 建立 Windows App／Build／Test Skeleton | M4-001, M4-002 |
| 152 | [M4-020](issues/M4/M4-020-linux-skeleton.md) | A | medium | 建立 Linux App／Build／Test Skeleton | M4-001, M4-002 |
| 153 | [M4-005](issues/M4/M4-005-windows-secure-storage.md) | C/S/H | critical | 實作 Windows Secure Storage Adapter | M4-004, M3-014 |
| 154 | [M4-006](issues/M4/M4-006-windows-native-client.md) | B | critical | 實作 Windows Native Protocol Client Adapter | M4-003, M4-004, M3-035 |
| 155 | [M4-008](issues/M4/M4-008-windows-mouse-injector.md) | C/H | critical | 實作 Windows Mouse Injection Backend | M4-002, M4-004 |
| 156 | [M4-009](issues/M4/M4-009-windows-keyboard-injector.md) | C/H | critical | 實作 Windows Keyboard Injection Backend | M4-002, M4-004, M1-042 |
| 157 | [M4-010](issues/M4/M4-010-windows-mouse-capture.md) | C/H | critical | 實作 Windows Mouse Capture Backend | M4-002, M4-004 |
| 158 | [M4-011](issues/M4/M4-011-windows-keyboard-capture.md) | C/H | critical | 實作 Windows Keyboard Capture Backend | M4-002, M4-004, M1-042 |
| 159 | [M4-013](issues/M4/M4-013-windows-clipboard.md) | B/H | high | 實作 Windows Clipboard Adapter／Loop Guard | M4-002, M4-004, M1-052, M1-054 |
| 160 | [M4-014](issues/M4/M4-014-windows-screen-backend.md) | C/H | critical | 實作 Windows Screen Enumeration／DPI／Coordinate Mapping | M4-002, M4-004, M1-039, M2-019 |
| 161 | [M4-021](issues/M4/M4-021-linux-secure-storage.md) | C/S/H | critical | 實作 Linux Secure Storage Adapter | M4-020, M3-014 |
| 162 | [M4-022](issues/M4/M4-022-linux-native-client.md) | B | critical | 實作 Linux Native Protocol Client Adapter | M4-003, M4-020, M3-035 |
| 163 | [M4-024](issues/M4/M4-024-linux-x11-injector.md) | C/H | critical | 實作 Linux X11 Mouse／Keyboard Injection Backend | M4-002, M4-020 |
| 164 | [M4-025](issues/M4/M4-025-linux-x11-capture.md) | C/H | critical | 實作 Linux X11 Mouse／Keyboard Capture Backend | M4-002, M4-020 |
| 165 | [M4-026](issues/M4/M4-026-linux-x11-clipboard.md) | B/H | high | 實作 Linux X11 Clipboard Adapter | M4-020, M1-052, M1-054 |
| 166 | [M4-027](issues/M4/M4-027-linux-screen-backend.md) | C/H | critical | 實作 Linux Screen Enumeration／Scaling Backend | M4-020, M1-039, M2-019 |
| 167 | [M4-028](issues/M4/M4-028-wayland-capability-evidence.md) | H | critical | 蒐集 Wayland Environment／Capability Evidence Matrix | M4-020 |
| 168 | [M4-007](issues/M4/M4-007-windows-native-server.md) | B | critical | 實作 Windows Native Protocol Server Adapter | M4-006 |
| 169 | [M4-012](issues/M4/M4-012-windows-event-filter.md) | C/S/H | critical | 實作 Windows Synthetic-event Filtering／Suppression Safety | M4-008, M4-009, M4-010, M4-011 |
| 170 | [M4-023](issues/M4/M4-023-linux-native-server.md) | B | critical | 實作 Linux Native Protocol Server Adapter | M4-022 |
| 171 | [M4-038](issues/M4/M4-038-cross-platform-key-matrix.md) | B/H | critical | 建立 Cross-platform VirtualKey Conformance Matrix | M4-009, M4-011, M4-024, M4-025, M1-051 |
| 172 | [M4-029](issues/M4/M4-029-wayland-backend-adr.md) | C/S/H | critical | 凍結 Wayland Backend／Support Matrix ADR | M4-028, M4-001 |
| 173 | [M4-015](issues/M4/M4-015-windows-app-shell.md) | B/H | high | 實作 Windows Tray／Settings／Permission Status Shell | M4-005, M4-006, M4-007, M4-013, M4-014 |
| 175 | [M4-034](issues/M4/M4-034-linux-lifecycle.md) | B/H | high | 實作 Linux Autostart／Background Lifecycle | M4-021, M4-022, M4-023 |
| 176 | [M4-030](issues/M4/M4-030-uinput-helper-security.md) | C/S/H | critical | 完成 uinput Helper Privilege／Threat Model Review | M4-029, M3-002 |
| 177 | [M4-033](issues/M4/M4-033-wayland-clipboard.md) | C/H | high | 實作 Wayland Clipboard Adapter | M4-029, M4-020, M1-052 |
| 179 | [M4-016](issues/M4/M4-016-windows-lifecycle.md) | C/H | high | 實作 Windows Startup／Background Lifecycle | M4-015 |
| 180 | [M4-035](issues/M4/M4-035-linux-beta-packages.md) | C/S/H | high | 建立 Linux DEB／AppImage Beta Packaging | M4-034 |
| 181 | [M4-031](issues/M4/M4-031-uinput-helper.md) | C/S/H | critical | 實作受限權限的 uinput Helper／IPC | M4-030 |
| 182 | [M4-039](issues/M4/M4-039-cross-platform-clipboard-matrix.md) | B/H | high | 建立 Cross-platform Clipboard Conformance Matrix | M4-013, M4-026, M4-033 |
| 184 | [M4-017](issues/M4/M4-017-windows-installer-dev.md) | C/S/H | high | 建立 Windows Installer／Dev Signing Pipeline | M4-016 |
| 186 | [M4-032](issues/M4/M4-032-wayland-input-backend.md) | C/S/H | critical | 實作凍結 Wayland Input Backend | M4-029, M4-031 |
| 188 | [M4-018](issues/M4/M4-018-windows-client-e2-e.md) | H | critical | 執行 Windows First-party Client E2E | M4-005, M4-006, M4-008, M4-009, M4-013, M4-014, M4-017 |
| 189 | [M4-036](issues/M4/M4-036-linux-client-e2-e.md) | H | critical | 執行 Linux First-party Client E2E | M4-022, M4-024, M4-026, M4-027, M4-032, M4-033, M4-035 |
| 190 | [M4-019](issues/M4/M4-019-windows-server-e2-e.md) | H | critical | 執行 Windows First-party Server E2E | M4-007, M4-010, M4-011, M4-012, M4-018 |
| 191 | [M4-037](issues/M4/M4-037-linux-server-e2-e.md) | H | critical | 執行 Linux First-party Server E2E | M4-023, M4-025, M4-032, M4-036 |
| 192 | [M4-040](issues/M4/M4-040-three-oscompatibility-matrix.md) | H | critical | 執行 3-OS Server／Client Compatibility Matrix | M4-019, M4-037, M4-038, M4-039 |
| 193 | [M4-041](issues/M4/M4-041-cross-platform-soak.md) | H | critical | 執行 Cross-platform Latency／Reconnect／24-hour Soak | M4-040 |
| 194 | [M4-042](issues/M4/M4-042-m4-exit-review.md) | C/S/H | critical | 完成 M4 Beta Exit Review | M4-041 |

## M5 — 1.0 Production Release

| Order | Issue | Tier | Risk | Title | Depends on |
|---:|---|---|---|---|---|
| 174 | [M5-016](issues/M5/M5-016-crash-recovery.md) | C/H | critical | 實作 Crash Recovery／Last Safe State | M1-063, M2-033, M4-012 |
| 178 | [M5-012](issues/M5/M5-012-permission-onboarding.md) | B/H | high | 完成 Accessibility／Permission／Firewall Onboarding UX | M1-035, M2-002, M4-012, M4-029 |
| 183 | [M5-013](issues/M5/M5-013-production-diagnostics.md) | B/S/H | high | 完成 Production Diagnostic Bundle／Support Workflow | M1-012, M4-015, M5-012 |
| 185 | [M5-010](issues/M5/M5-010-autostart-policy.md) | B/H | high | 實作 Launch-at-login／Autostart／Background Policy | M1-067, M4-016, M4-034 |
| 187 | [M5-014](issues/M5/M5-014-privacy-audit.md) | C/S/H | critical | 執行 Privacy／Log Redaction Audit | M5-013, M1-011 |
| 195 | [M5-023](issues/M5/M5-023-performance-gate.md) | B/H | high | 建立 Performance／Latency／Resource Release Gate | M4-041, M5-016 |
| 196 | [M5-001](issues/M5/M5-001-discovery-spec.md) | C/S | critical | 凍結 LAN Discovery／Advertisement Specification | M4-042 |
| 197 | [M5-002](issues/M5/M5-002-mac-discovery.md) | B/H | high | 實作 macOS Discovery／Advertisement Backend | M5-001 |
| 198 | [M5-003](issues/M5/M5-003-cross-platform-discovery.md) | B/H | high | 實作 Windows／Linux Discovery Backends | M5-001, M4-004, M4-020 |
| 199 | [M5-004](issues/M5/M5-004-discovery-registry.md) | B | high | 實作 Discovery Dedupe／Name Conflict／Stale Entry Handling | M5-002, M5-003, M3-011 |
| 200 | [M5-005](issues/M5/M5-005-pairing-ux.md) | C/S/H | critical | 實作 Pairing UX／Short-code Verification | M3-012, M3-028, M5-004 |
| 201 | [M5-006](issues/M5/M5-006-trusted-device-manager.md) | C/S/H | critical | 實作 Trusted Device Management／Revoke／Re-pair | M3-014, M5-005 |
| 202 | [M5-007](issues/M5/M5-007-device-manager.md) | B | high | 實作 Device Manager Domain／Persistence | M5-004, M5-006 |
| 203 | [M5-015](issues/M5/M5-015-security-review.md) | C/S/H | critical | 執行 Security Review／Abuse Boundary／Remediation | M3-002, M4-030, M5-005, M5-006, M5-014 |
| 204 | [M5-008](issues/M5/M5-008-screen-layout-editor.md) | B/H | critical | 實作 Screen Layout Editor／Validation | M2-016, M5-007 |
| 205 | [M5-011](issues/M5/M5-011-auto-connect-policy.md) | B/S | high | 實作 Auto-connect／Preferred Server Policy | M5-006, M5-007, M5-010 |
| 206 | [M5-017](issues/M5/M5-017-mac-production-release.md) | C/S/H | critical | 建立 macOS Developer ID／Hardened Runtime／Notarization Pipeline | M5-015, M5-016 |
| 207 | [M5-018](issues/M5/M5-018-windows-production-release.md) | C/S/H | critical | 建立 Windows Production Signing／Installer Pipeline | M4-017, M5-015, M5-016 |
| 208 | [M5-019](issues/M5/M5-019-linux-production-release.md) | C/S/H | high | 建立 Linux Production Packages／Repository Metadata | M4-035, M5-015, M5-016 |
| 209 | [M5-009](issues/M5/M5-009-multi-monitor-reconciler.md) | C/H | critical | 實作 Multi-monitor Layout／Hot-plug Reconciliation | M2-015, M4-014, M4-027, M5-008 |
| 210 | [M5-020](issues/M5/M5-020-update-specification.md) | C/S/H | critical | 凍結 Signed Update Manifest／Channel／Rollback Specification | M5-015, M5-017, M5-018, M5-019 |
| 211 | [M5-026](issues/M5/M5-026-barrier-migration-guide.md) | A/H | medium | 撰寫 Barrier Migration／Rollback Guide | M5-006, M5-011, M5-017, M5-018, M5-019 |
| 212 | [M5-021](issues/M5/M5-021-cross-platform-updater.md) | C/S/H | critical | 實作三平台 Update Verification／Staged Rollout | M5-020 |
| 213 | [M5-022](issues/M5/M5-022-update-rollback.md) | C/S/H | critical | 實作 Update Rollback／Recovery Tests | M5-021 |
| 214 | [M5-024](issues/M5/M5-024-production-fault-matrix.md) | H | critical | 執行 Sleep／Wake／Network／Crash Fault Matrix | M5-016, M5-021, M5-023 |
| 215 | [M5-025](issues/M5/M5-025-production-soak.md) | H | critical | 執行 72-hour Multi-device／Multi-monitor Soak | M5-009, M5-024 |
| 216 | [M5-027](issues/M5/M5-027-release-candidate-checklist.md) | C/S/H | critical | 完成 Release Candidate Checklist／Evidence Index | M5-022, M5-025, M5-026 |
| 217 | [M5-028](issues/M5/M5-028-release10-gate.md) | C/S/H | critical | 完成 1.0 Release Gate：確認真正取代 Barrier | M5-027 |
