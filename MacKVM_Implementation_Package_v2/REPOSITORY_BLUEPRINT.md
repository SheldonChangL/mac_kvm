# Repository Blueprint

```text
MacKVM/
├── Apps/macOS/MacKVM/
├── Packages/
│   ├── KVMContracts/
│   ├── KVMCore/
│   ├── BarrierCompatibility/
│   ├── NativeProtocol/
│   ├── MacPlatform/
│   └── Discovery/
├── Platforms/
│   ├── Windows/        # paths resolved by toolchain.lock.json
│   └── Linux/          # paths resolved by toolchain.lock.json
├── Tests/
│   ├── Fixtures/Barrier/
│   ├── Fixtures/Native/
│   ├── Conformance/
│   └── SystemTests/
├── Tools/
├── Release/
├── docs/
├── evidence/
├── toolchain.lock.json
└── Makefile
```

Dependency direction:

```text
Apps/Platform shells → Adapters → KVMContracts/KVMCore
BarrierCompatibility ─┘
NativeProtocol       ─┘

KVMCore must not depend on BarrierCompatibility, NativeProtocol or platform input APIs.
```
