# Architecture Guardrails

## Required Flow

```text
Barrier packet / Native frame / Platform event
                 ↓
              Adapter
                 ↓
              KVMEvent
                 ↓
      KVM Core / Screen Router
                 ↓
           Platform Backend
```

## Hard Rules

- `KVMCore` 不可 import `BarrierCompatibility`、`NativeProtocol` 或 OS input frameworks。
- Barrier message codes（例如 DKDN/DMMV/CINN/COUT）只存在 `BarrierCompatibility`。
- CGKeyCode、Windows VK、Linux evdev/X11 code 不進 KVMEvent 或 Native wire schema。
- Codec 與 Transport 分離；protocol module 不直接依賴 socket implementation。
- UI 只 render state / send intents，不直接判斷 socket 或 input hook 狀態。
- Callback/event tap/hook 不等待 network async operation；透過 bounded queue。
- Unknown/oversize/malformed frames 必須在 allocation 前受限並回 typed error。
- Cleanup 可重入、best effort，且不依賴 UI 或 network 回應。
- Trust/keys 使用 secure storage；identity change fail closed。
- Logs/diagnostics 只使用 allowlist metadata。
