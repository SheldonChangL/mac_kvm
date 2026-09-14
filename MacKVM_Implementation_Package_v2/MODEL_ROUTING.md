# Model Routing

本包不是在宣稱 Haiku 可以獨立完成產品，而是把工作分成可被正確路由的 execution units。

## Tier A

可由 Haiku 等輕量模型實作，但仍需 CI；review 可抽查。

## Tier B

可由輕量模型實作，但必須由較強模型或工程師完整 review。

## Tier C

需要強模型或資深工程師主導；輕量模型只能協助。

## Tier S

Security-critical；必須安全 review，不得由低階模型自主 merge。

## Tier H

需要實機、憑證、OS 權限或人工操作才能驗收。

## Merge Policy

- A/B 可由輕量模型產生 PR。
- C/S 必須由強模型或工程師主導或完整 review。
- H 必須有實機證據。
- 執行 Agent 不得自行 merge、改 AC、改凍結 contract 或移除測試。
