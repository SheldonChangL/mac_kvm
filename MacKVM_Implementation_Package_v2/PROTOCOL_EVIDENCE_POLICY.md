# Protocol Evidence Policy

## Barrier Compatibility

1. 先建立 evidence register。
2. 以合法的黑箱互通測試取得 sanitized fixtures。
3. 凍結 field layout/endian/limits/version behavior。
4. parser/encoder Issue 只依 frozen contract + fixtures。
5. 未知欄位不得猜；新增 evidence/ADR 後才能實作。
6. 不複製 GPL source/header/implementation 到第一方核心。

## Native Protocol

- 規格、threat model、encoding、limits、identity/trust 先凍結。
- Canonical test vectors 是跨語言真相來源。
- Swift/Windows/Linux codecs 必須跑相同 vectors。
- 任何 wire change 需版本/相容性/security review。
