# M1-055-FOLLOWUP-002 Security Review

- Reviewer: fresh-context Opus agent, not the implementer
- Date: 2026-11-18
- Target: PR #373 at `a769b94`
- Verdict: APPROVE; 0 Critical, 0 High, 2 Low, 3 Info; static review only

## Reviewer designation

This is a Tier S PR (TLS transport). On 2026-11-17 the Product Owner decided that a fresh-context
security review replaces the designated Codex Security Reviewer for Tier S PRs. The review below is
that review, separate from the Tier C review in `independent-review.md`.

## Review (reviewer findings, as recorded)

Text after `FIX` in the review record was added later and is moved to the Resolution table.

> Memory bounded (cap checked under lock before append, fail closed resourceExhausted); no data before pin (received ignores unless .connected; pin in NIOSSL verify callback, unchanged); error paths fail closed; pause/resume race-safe; no payload logging; test hooks are package-access integer counts; protocol/clipboard caps unchanged.
> 1. Low: overshoot larger than doc (same as Tier C 1).
> 2. Low: per-chunk overhead not counted in 1 MiB (tiny records -> few MiB bounded).
> 3. Info: silent peer stalls connection (pre-existing).
> 4. Info: NIOSSL's own read bypasses gate; bounded by cap.
> 5. Info: evidence privacy.

## Resolution (later FIX notes, implementer, at `656ef69`)

| Finding | Resolution |
| --- | --- |
| Low 1: overshoot | Fixed via the doc (same change as Tier C Low 1). |
| Low 2: per-chunk overhead outside the cap | Documented as a known limitation. |
| Info 3: silent peer | Confirmed `BarrierClientProtocolSession` checks each second and fails `timeout(.keepalive)` after 9 silent checks; documented. |
| Info 4: NIOSSL's own read bypasses the gate | Accepted; bounded by the 1 MiB cap. |
| Info 5: evidence privacy | Checked: grep for home-directory paths and the user name found 0 hits. |
