# Source Traceability

本文件只負責來源、Issue、程式碼與測試的追蹤，不是產品合約。若內容與 canonical specification 不一致，以 canonical specification 為準。

## Formal Backfill Status

M1-001、M1-002、M1-003 的正式 gate 與獨立 Critical／High review 補驗記錄位於 [`docs/audits/M1-001-003-formal-backfill.md`](../docs/audits/M1-001-003-formal-backfill.md)。個別 evidence packages 位於：

- [`evidence/issues/M1-001/`](../evidence/issues/M1-001/summary.md)
- [`evidence/issues/M1-002/`](../evidence/issues/M1-002/summary.md)
- [`evidence/issues/M1-003/`](../evidence/issues/M1-003/summary.md)

M1-002 獨立 review 發現的 High 已由 Issue #234／PR #235 修正並獨立 re-review 歸零。M1-001 與 M1-003 的兩個 Medium test-depth finding 由 Issue #233 實作 explicit source-integrity、frozen/policy drift 與 fail-closed negative regression tests；合併前仍阻擋 M1 completion declaration。其 evidence 位於 [`evidence/issues/M1-CONTRACT-001/`](../evidence/issues/M1-CONTRACT-001/summary.md)。

## Source Precedence for M1-001

1. [`docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md`](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md)：M1-001 的 canonical architecture／MVP contract。
2. `FROZEN_DECISIONS.md`：僅明確標記 frozen 的決策有約束力；可細化 canonical specification，但不可靜默牴觸。
3. `PRODUCT_ROADMAP.md`：控制 milestone 與實作順序，不取代架構合約。
4. 本文件：只提供 traceability index。

## M1-001 Direct Traceability

| Requirement | Canonical source | Frozen refinement | Decision record | Verification |
|---|---|---|---|---|
| Protocol 是 Adapter，不是 Application Core | [§60](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#60-long-term-protocol-architecture)、[§61](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#61-recommended-architecture-principle) | Frozen Decisions 3–4 | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |
| Swift native macOS implementation | [§63 Decision 1](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#decision-1) | Frozen Decision 5 | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |
| Barrier 自行實作且只存在於 Protocol Adapter | [§62](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#62-final-architecture)、[§63 Decision 2](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#decision-2) | Frozen Decisions 4、9 | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |
| KVMEvent 是 Core／Protocol 統一邊界 | [§60](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#60-long-term-protocol-architecture)、[§61](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#61-recommended-architecture-principle) | Frozen Decision 3 | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |
| Input Engine 與 protocol／networking 分離 | [§62](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#62-final-architecture)、[§63 Decision 5](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#decision-5) | Architecture Guardrails | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |
| Client-first delivery | [§63 Decision 4](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#decision-4)、[§64](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#64-recommended-mvp) | Frozen Decision 2 | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |
| Production TLS default ON | [§63 Decision 6](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#decision-6)、[§64](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#64-recommended-mvp) | Frozen Decision 6 | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |
| 1.0 以第一方 Server／Client＋Native Protocol 為主路徑 | [§60](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#60-long-term-protocol-architecture)、[§64](../docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md#64-recommended-mvp) | Frozen Decision 1 | `docs/adr/M1-001-product-contract.md` | `Tests/Contracts/test_m1_001_product_contract.py` |

## M1-003 Direct Traceability

M1-003 的 canonical source 是 [`docs/spec/CANONICAL_SPEC_SECTION_55.md` §55](../docs/spec/CANONICAL_SPEC_SECTION_55.md#55-license-strategy)。Frozen Decision 9 與 `PROTOCOL_EVIDENCE_POLICY.md` 細化執行方式，但不取代 §55。

| Requirement | Canonical source | Frozen refinement | Decision record | Verification |
|---|---|---|---|---|
| 不直接 fork Barrier／Deskflow | [§55](../docs/spec/CANONICAL_SPEC_SECTION_55.md#55-license-strategy) | Frozen Decision 9 | `docs/adr/M1-003-independent-implementation-policy.md` | `Tests/Contracts/test_m1_003_independent_implementation_policy.py` |
| 不複製 Barrier／Deskflow source 到第一方 implementation | [§55](../docs/spec/CANONICAL_SPEC_SECTION_55.md#55-license-strategy) | Frozen Decision 9 | `docs/adr/M1-003-independent-implementation-policy.md` | `Tests/Contracts/test_m1_003_independent_implementation_policy.py` |
| 只依公開 protocol specification、黑箱行為與 sanitized fixtures 自行實作 codec | [§55](../docs/spec/CANONICAL_SPEC_SECTION_55.md#55-license-strategy) | Protocol Evidence Policy | `docs/adr/M1-003-independent-implementation-policy.md` | `Tests/Contracts/test_m1_003_independent_implementation_policy.py` |
| macOS input engine 必須自行實作 | [§55](../docs/spec/CANONICAL_SPEC_SECTION_55.md#55-license-strategy) | Frozen Decisions 5、9 | `docs/adr/M1-003-independent-implementation-policy.md` | `Tests/Contracts/test_m1_003_independent_implementation_policy.py` |
| 直接修改、引用或連結 GPL implementation 前必須停止並重新評估 | [§55](../docs/spec/CANONICAL_SPEC_SECTION_55.md#55-license-strategy) | Protocol Evidence Policy | `docs/adr/M1-003-independent-implementation-policy.md` | `Tests/Contracts/test_m1_003_independent_implementation_policy.py` |

本包以使用者提供的 `macOS Barrier-Compatible KVM App` 規格為基礎，保留下列核心：

- Apple Silicon 原生、Client/Server、mouse/keyboard/clipboard/TLS。
- Protocol、Transport、Core、Platform Input 分離。
- KVMEvent 統一事件模型。
- Keyboard mapping、coordinate normalization、state machine、stuck-key/fail-safe。
- Client-first 開發策略。
- Barrier 只作為相容層，不綁死 Application Core。

v2 新增／擴充：

- 使用者後續明確修正：最終 Server/Client 都使用第一方 App 與 Native Protocol。
- Model routing、evidence gates、exact files、commands、stop conditions。
- 第一方 Native Protocol 的 threat model/conformance/fuzz 工作。
- Windows/Linux 第一方 App、Wayland/uinput security gate。
- Production signing/update/rollback/release evidence。

原始資料未提供 Barrier 精確 wire bytes、Native encoding 選型、跨平台 toolchain、Wayland 最終後端；v2 沒有猜測，而是建立阻擋式決策/證據 Issue。
