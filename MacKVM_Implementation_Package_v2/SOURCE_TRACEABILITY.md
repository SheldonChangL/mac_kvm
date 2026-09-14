# Source Traceability

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
