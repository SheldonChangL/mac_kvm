# Canonical Product Specification — Section 55

> Status: Canonical source for M1-003 and all license-strategy decisions covered by Section 55.
>
> Provenance: Verbatim specification text supplied and authorized by the Product Owner on 2026-09-14.
>
> Editing rule: Preserve the requirements and their meaning. Changes require an explicit Product Owner decision and an updated canonical specification or superseding ADR.

---

# 55. License Strategy

如果未來希望：

```text
Closed-source

Company internal

Commercial product
```

建議：

```text
不要直接 fork Barrier

不要直接 fork Deskflow
```

而是：

```text
參考 protocol specification

↓

自己實作 encoder / decoder

↓

自己實作 macOS input engine
```

不要複製：

```text
Barrier source

Deskflow source
```

到自己的 implementation。

如果要直接修改或引用 GPL implementation，則需要重新評估 GPL 授權義務。
