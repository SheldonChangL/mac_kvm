# Contract Catalog

這些是 v2 backlog 的 canonical API contracts。實際 repository 可增加 internal helpers，但不可在單一 Issue 中偷偷改 public semantics。

## C-001 — KVMEvent

`KVMEvent` 只包含 platform-neutral mouse/button/scroll/key/clipboard/screen control；詳見 reference package。

## C-002 — Transport

Ordered byte stream：`connect()`、`send(Data)`、`incomingBytes`、`disconnect()`；protocol 不得知道 socket implementation。

## C-003 — KVMProtocolSession

`connect()`、`send(KVMEvent)`、`events`、`disconnect(reason)`；Barrier/Native 都實作此 contract。

## C-004 — KVMClock

可替換 production/test clock；timeout/backoff tests 不使用任意 sleep。

## C-005 — VirtualKey

Platform-neutral physical/function/navigation/media/modifier key catalog，包含 `.unknown(rawCode)`。

## C-006 — ModifierState

Shift/Control/Option/Command/CapsLock 的明確狀態；不能完全依賴單一 event flags。

## C-007 — ClipboardPayload

V1 僅 UTF-8 plain text，帶 transaction/origin/hash/size limits；payload 不可進 log。

## C-008 — Screen／Coordinate

Logical/backing/wire coordinates 分離；跨螢幕以 normalized 0...1 轉換並 clamp。

## C-009 — TrustPolicy

Unknown→prompt；trusted+same fingerprint→allow；changed/revoked→reject；無 auto-accept。

## C-010 — DiagnosticEvent

Allowlisted event id/category/correlation/metadata；禁止任意 string payload。

## C-011 — InputSafetyController

`releaseAllKeys`、`releaseAllMouseButtons`、`restoreLocalInput`、`clearTransientState`，全部可重入/best-effort。

## C-012 — InputStateReducer

Pure reducer：state + action → next state + effects；狀態固定為 Local/EnteringRemote/Remote/LeavingRemote。

## C-013 — ScreenRouter

依 topology/input state 選 target session；invalid target 產生 rollback effect，不直接送 network。

## C-014 — NativeFrameHeader

Canonical fixed/explicit header，包含 version/type/flags/length/session/sequence；所有欄位先 bounds check。

## C-015 — PlatformBackend

Capture、Injection、Clipboard、Screen、SecureStorage、Lifecycle 各自獨立；輸入/輸出只用 KVM contracts。

可編譯參考：`reference/KVMContracts/`。
