# Definition of Ready

Issue 只有在以下全部成立時才可開始：

- [ ] 所有 `depends_on` 已 merge 且 evidence 可讀。
- [ ] Exact Files 與 contract references 存在。
- [ ] Wire/platform/security 任務所需 ADR、fixture、toolchain.lock 已凍結。
- [ ] 可以寫出客觀 test；不是只靠「看起來正常」。
- [ ] 指定 reviewer／實機環境可用（C/S/H）。
- [ ] 沒有 unresolved licensing/security/privacy blocker。
- [ ] Scope 可在一個 XS/S/M PR 完成；否則先再拆分。
