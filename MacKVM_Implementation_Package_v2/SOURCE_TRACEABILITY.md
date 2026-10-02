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
3. `PRODUCT_ROADMAP.md`：控制 milestone 與實作順序，不取代架構合約；可由 accepted ADR 狹義 supersede。
4. 本文件：只提供 traceability index。

## M1 Validation Scope Supersession

本節只記錄 supersession chain，不是產品合約；合約內容以下列 ADR 為準。

- `docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md` 與 `docs/adr/M1-001-product-contract.md` 保持不變，後者作為 Accepted historical context。
- [`docs/adr/M1-SCOPE-001-linux-only-validation.md`](../docs/adr/M1-SCOPE-001-linux-only-validation.md)（Accepted 2026-09-29，Product Owner decision，Issue #270）僅 supersede M1 驗證條款：M1 goal/exit 的 Windows+Linux Barrier Server 要求、M1-024 Windows+Linux fixture、M1-040 Windows keyboard fixture、M1-068 Windows E2E execution、M1-069 Windows 比較、M1-070 舊 Windows+Linux exit criteria。
- 受影響來源：`PRODUCT_ROADMAP.md` M1、`issues_manifest.json` 與 M1-024、M1-040、M1-068、M1-069、M1-070 Issue 檔。
- M2、M4、M5 Windows 產品範圍不變。
- Verification：`Tests/Contracts/test_m1_linux_only_validation_scope.py`。

## M1-024 → M1-EVIDENCE-001 → M1-025 Barrier Evidence Chain

本節只記錄 Barrier wire evidence 的來源、登錄與 consumption gate 之間的 traceability，不是產品合約，也不凍結任何 wire contract。登錄內容與 entry contract 以 `evidence/registers/M1-023.json` 為準；M1-025 的合約內容仍由該 Issue 自行決定，本節不代替其執行。

| Stage | Issue | Recorded artifact | Verification |
|---|---|---|---|
| Register contract | M1-023 | `evidence/registers/M1-023.json`、[`docs/evidence/M1-023-barrier-evidence-register.md`](../docs/evidence/M1-023-barrier-evidence-register.md) | `evidence/issues/M1-023/tests/test_register.py` |
| Capture producer | M1-024 | `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json`、[`evidence/issues/M1-024/summary.md`](../evidence/issues/M1-024/summary.md) | `Tests/Contracts/test_m1_024_capture_readiness.py` |
| Independent review | M1-024 | [`evidence/issues/M1-024/independent-review.md`](../evidence/issues/M1-024/independent-review.md) | `evidence/issues/M1-EVIDENCE-001/tests/test_registration.py` |
| Registration | M1-EVIDENCE-001（GitHub Issue #249） | `evidence/registers/M1-023.json` 內的 `BARRIER-EVID-0001` entry、[`evidence/issues/M1-EVIDENCE-001/summary.md`](../evidence/issues/M1-EVIDENCE-001/summary.md) | `evidence/issues/M1-EVIDENCE-001/tests/test_registration.py` |
| Consumption gate | M1-025 | [`MacKVM_Implementation_Package_v2/issues/M1/M1-025-barrier-client-wire-contract.md`](issues/M1/M1-025-barrier-client-wire-contract.md)；`BARRIER-EVID-0001` 的 `frozenContractRefs` 與 `consumingTests` 在 M1-025 凍結 wire contract 並連結測試前維持空清單 | `evidence/issues/M1-EVIDENCE-001/tests/test_registration.py` |

鏈路方向與邊界：

- M1-024 產出 sanitized fixture 與獨立 review → M1-EVIDENCE-001（Issue #249）以 append-only 方式將其登錄為 `BARRIER-EVID-0001`，disposition `approved` → M1-025 只能從登錄且 `approved` 的 evidence 凍結 client wire contract。缺少登錄的 capture 不是實作輸入。
- `BARRIER-EVID-0001` 的 `ambiguousFields` 一律維持 `status: unknown`，不得出現在任何 claim 的 `establishedFieldIds`；direction label 屬 capture provenance，不是對 payload 內容的分析結果。
- 登錄採 append-only：更正以新的 reviewed entry 取代並將舊 entry 標為 `superseded`，不得改寫既有 entry 的 provenance、fixture digest 或 review 歷史。
- M1 未執行、未測試 Windows（`docs/adr/M1-SCOPE-001-linux-only-validation.md`），本鏈路不記錄任何 Windows 結果，也不主張 Windows 相容。
- 該觀測關閉 TLS 以便觀察 application payload；MacKVM production TLS 預設維持 enabled、fail-closed，且未被此 entry 驗證。
- M1-025 另需 GitHub Issue #278（M1-WIRE-001）append 的 `BARRIER-EVID-0002` 成為 `approved`；`BARRIER-EVID-0001` 不被改寫、升級或標為 `superseded`。順序與證據見下一節。

## M1-WIRE-001 → M1-025 → M1-021 → M1-022 Barrier Wire Contract Sequence

本節只記錄 GitHub Issue #278（M1-WIRE-001）修正後的 Barrier wire 順序與證據鏈，不是產品合約，也不凍結任何 wire contract。決策內容以 [`docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`](../docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md) 為準；wire contract 仍由 M1-025 凍結。

| Stage | Issue | Recorded artifact | Verification |
|---|---|---|---|
| Derived conformance evidence | M1-WIRE-001（GitHub Issue #278） | `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`；`evidence/registers/M1-023.json` 內 append 的 `BARRIER-EVID-0002`（`BARRIER-EVID-0001` 逐位元組不變） | `Tests/Contracts/test_m1_wire_001_contract_sequence.py` |
| Independent review | M1-WIRE-001 | `evidence/issues/M1-WIRE-001/independent-review.md`，由非實作者 reviewer 新增；新增前 `BARRIER-EVID-0002` 維持 `pending-review`，不可消費 | `Tests/Contracts/test_m1_wire_001_contract_sequence.py` |
| Wire contract freeze | M1-025 | `docs/adr/M1-025-barrier-client-wire-contract.md`（M1-025 的 Exact File，尚未建立） | M1-025 Required Commands |
| Bounded codec | M1-021 | M1-021 Exact Files | M1-021 Required Commands |
| Frame reassembler | M1-022 | M1-022 Exact Files | M1-022 Required Commands |

- `issues_manifest.json`：M1-025 的 `depends_on` 只剩 M1-024；M1-021 的 `depends_on` 為 M1-015、M1-025；M1-022 維持 M1-019、M1-020、M1-021。M1-WIRE-001 不在 70 筆 canonical manifest 中，validator 只接受 manifest ID，因此其前置關係記錄於 M1-025 Preconditions 與本節，而非 `depends_on`。
- `topological_order` 只在三個位置間輪換：M1-025 為 22、M1-021 為 36、M1-022 為 38，其餘不變。Issue 檔、`issues_manifest.json`、`issues_index.csv` 與 `EXECUTION_ORDER.md` 同步。
- Exact length-prefix width：`BARRIER-EVID-0002` 只記錄 candidate interpretation，width 維持 unknown。Owner-tracked follow-up blocker 為 GitHub Issue #279（M1-WIRE-002，Acquire discriminating Barrier length-prefix evidence），依賴 #278，並阻擋 M1-025 完成 exact width 凍結；#279 尚未完成，且與 M1-WIRE-001 相同不在 70 筆 canonical manifest 中，不列入任何 `depends_on`。
- 版本：只記錄觀測到的 version bytes，以及交由 M1-025 採納或拒絕的 `exact-supported-version-fail-closed` 提案；不主張一般版本協商或跨版本相容。
- M1 未執行 Windows（`docs/adr/M1-SCOPE-001-linux-only-validation.md`），本鏈路不記錄 Windows 結果。production TLS 預設維持 enabled、fail-closed，未被改變。

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
