# Epics

## E00 — 產品方向與架構治理

固定產品終局、授權邊界、ADR、模型執行權限與 release gates。

Issue count: **10**

## E01 — Repository、Build、CI 與診斷

建立可重現 build/test/lint/architecture checks 與 privacy-safe diagnostics。

Issue count: **9**

## E02 — KVM Contracts 與 Core

建立 KVMEvent、Transport、Session、clock、errors、state ledger 與 concurrency boundary。

Issue count: **9**

## E03 — Barrier Compatibility Evidence 與 Codec

以獨立實作方式建立可被 fixtures 驗證的 Barrier client/server adapter。

Issue count: **21**

## E04 — macOS Client Mouse/Coordinate

完成 Accessibility、mouse/button/scroll injection 與 Retina/coordinate normalization。

Issue count: **5**

## E05 — Keyboard Mapping、Modifier 與 IME

完成 VirtualKey、layout strategy、modifier/repeat/caps lock 與 stuck-key handling。

Issue count: **13**

## E06 — Clipboard

完成純文字 clipboard codec、NSPasteboard adapter、loop prevention 與限制。

Issue count: **5**

## E07 — TLS、Trust 與 Secure Storage

完成 TLS transport、fingerprint、trust policy、Keychain 與 identity change rejection。

Issue count: **5**

## E08 — Reliability、Fail-safe 與 Client UX

完成 reconnect、sleep/wake、network recovery、cleanup、fault injection 與 Alpha UI。

Issue count: **10**

## E09 — macOS Server Input Capture

完成 CGEventTap capture、synthetic event filtering、suppression 與 emergency escape。

Issue count: **9**

## E10 — Screen Routing 與 Multi-session

完成 screen topology、edge detection、coordinate switching、SessionManager 與 ScreenRouter。

Issue count: **19**

## E11 — Native Protocol 與 Security

完成第一方 wire protocol、identity、pairing、codec、session、conformance 與 threat model。

Issue count: **31**

## E12 — 第一方 macOS ↔ macOS 整合

完成第一方 Mac Server/Client 的 barrier-free E2E 與 optional compatibility module。

Issue count: **8**

## E13 — Windows Platform

完成 Windows capture、injection、clipboard、DPI、tray/service、installer 與 E2E。

Issue count: **16**

## E14 — Linux Platform

完成 X11/Wayland/uinput、clipboard、screen、autostart、packages 與 E2E。

Issue count: **18**

## E15 — Discovery、Pairing 與 Product UI

完成 discovery、pairing、trusted devices、device manager、screen layout 與 onboarding。

Issue count: **12**

## E16 — Release、Security Review 與 Operations

完成 signing、updates、rollback、soak、migration 與 1.0 release gate。

Issue count: **17**
