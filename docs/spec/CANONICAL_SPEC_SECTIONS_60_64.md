# Canonical Product Specification — Sections 60–64

> Status: Canonical source for M1-001 and all architecture decisions covered by Sections 60–64.
>
> Provenance: Verbatim extraction from the original `macOS Barrier-Compatible KVM App` specification supplied by the product owner.
>
> Editing rule: Do not paraphrase or replace this document with summaries. Changes require an explicit product decision and an ADR or updated canonical specification.

---

# 60. Long-Term Protocol Architecture

最終不要：

```text
App

↓

Barrier
```

建議：

```text
App

↓

KVMCore

↓

KVMProtocol
       │
       ├── BarrierProtocol
       │
       ├── DeskflowCompatibleProtocol
       │
       └── FutureProtocol
```

interface：

```swift
protocol KVMProtocolSession {

    func connect() async throws

    func disconnect()

    func send(
        event: KVMEvent
    ) async throws

    var events:
        AsyncStream<KVMEvent> { get }
}
```

核心事件統一成：

```swift
enum KVMEvent {

    case mouseMove

    case mouseButton

    case scroll

    case keyDown

    case keyUp

    case clipboard

    case enterScreen

    case leaveScreen
}
```

這會讓整套產品不被 Barrier 綁死。

---

# 61. Recommended Architecture Principle

最重要的一條：

```text
Barrier protocol

≠

Application Core
```

正確：

```text
Barrier packet

↓

Barrier adapter

↓

KVMEvent

↓

KVM Core

↓

macOS Input Engine
```

未來才能：

```text
Barrier

Deskflow-like protocol

Custom protocol
```

共存。

---

# 62. Final Architecture

```text
                  ┌──────────────────┐
                  │     SwiftUI      │
                  │     Menu Bar     │
                  └────────┬─────────┘
                           │
                           ▼
                ┌─────────────────────┐
                │      KVM Core       │
                │                     │
                │ Session             │
                │ Screen Router       │
                │ Input Router        │
                │ Clipboard Router    │
                └──────────┬──────────┘
                           │
             ┌─────────────┼─────────────┐
             │             │             │
             ▼             ▼             ▼
     ┌──────────────┐ ┌────────────┐ ┌────────────┐
     │ Protocol     │ │ Input      │ │ Clipboard  │
     │ Adapter      │ │ Engine     │ │ Engine     │
     └──────┬───────┘ └─────┬──────┘ └──────┬─────┘
            │               │               │
            ▼               ▼               ▼
     ┌──────────────┐  CoreGraphics     NSPasteboard
     │ Barrier      │
     │ Protocol     │
     └──────┬───────┘
            │
            ▼
     ┌──────────────┐
     │ TCP / TLS    │
     │ NWConnection │
     └──────────────┘
```

---

# 63. Key Design Decisions

## Decision 1

使用：

```text
Swift
```

而不是：

```text
C++
Electron
Qt
```

理由：

```text
macOS native

Apple Silicon

權限整合

未來 macOS API 相容性

較好的使用體驗
```

---

## Decision 2

Barrier protocol 自己實作。

不要直接把 Barrier executable 包進 App。

---

## Decision 3

Protocol 與 KVM Core 分離。

避免產品永遠只能支援 Barrier。

---

## Decision 4

先 Client 後 Server。

Client 技術風險比較低，也比較容易用現有 Barrier Server 驗證。

---

## Decision 5

Input Engine 獨立。

Keyboard mapping 是產品品質的核心，不要散落在 network code 裡。

---

## Decision 6

TLS default ON。

不要為了開發方便讓正式版使用 insecure TCP。

---

# 64. Recommended MVP

第一個真正可以給人使用的版本：

```text
MacKVM 0.1

Apple Silicon native

Barrier Client

↓

connect

Windows Barrier Server

↓

Mouse

Keyboard

Scroll

Clipboard

TLS

Auto reconnect

Menu bar
```

接著：

```text
MacKVM 0.2

Barrier Server

Screen switch

Multi-device
```

最後：

```text
MacKVM 1.0

Server + Client

TLS

Clipboard

Screen layout

Auto reconnect

Permissions UI

Launch at login

Notarized DMG
```
