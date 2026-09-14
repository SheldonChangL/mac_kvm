# Decision Gates

下列 Issue 完成前，後續工作不得由 Agent自行假設：

- M1-001：產品終局／Barrier 退場。
- M1-002：KVMEvent/Adapter/Core boundary。
- M1-003：獨立實作／授權政策。
- M1-025：Barrier Client wire contract。
- M2-008：InputState transition table。
- M2-023：Barrier Server wire contract。
- M3-003/M3-004：Native transport/encoding。
- M3-012～M3-014：pairing/identity/trust lifecycle。
- M4-001：Windows/Linux toolchain.lock。
- M4-029/M4-030：Wayland/uinput support/security。
- M5-020：signed update/rollback。

Gate 未完成時，next-issue 工具仍可能顯示文件任務，但 implementation task 應依 Stop Conditions 停止。
