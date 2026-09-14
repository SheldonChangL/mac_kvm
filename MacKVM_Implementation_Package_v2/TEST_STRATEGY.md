# Test Strategy

## Layers

1. Unit：pure models、reducers、mapping、codec、limits。
2. Golden/Conformance：exact bytes、cross-language vectors。
3. Integration：MockTransport、fake clock、secure storage wrappers。
4. System/E2E：真實 OS input、Barrier compatibility、first-party Native path。
5. Fault：EOF/error/cancel/timeout/network/sleep/crash/update interruption。
6. Soak/Performance：長時間、多裝置、多螢幕、resource trend。

## Safety Invariants

每個 terminal/fault test 都要驗證：

- no pressed keys/buttons remain
- local input not permanently suppressed
- no stale active remote session
- no silent trust update
- no leaked task/queue growth
- no sensitive log content
