# M1-032 Independent Review

- Reviewer: a fresh-context review agent (Fable), not the implementer, 2026-10-29.
- Target: PR #337 at `039299e` (base `76f4045`), read-only, in the reviewer's own worktree.
- Design references (`a.4`, `b.1`, "pitfall 15" and so on) point to the lead's decoder design,
  which is not in the repository; each decision it settled is restated in the component doc.

## Report

The report is verbatim, except that the reviewer's absolute worktree path is replaced by
`<reviewer-worktree>`.

> Review of PR #337 (head 039299e, base 76f4045). Verified in my worktree: `swift test --filter
> BarrierMouseMoveDecoder` 16/16 passed (3.3 s); `make architecture-check` OK;
> `validate_package.py` OK; `swift format lint --strict` on both files exit 0.
> Paths (W = `<reviewer-worktree>`):
> SRC = W/Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseMoveDecoder.swift
> TEST = W/Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierMouseMoveDecoderTests.swift
> DOC = W/docs/components/M1-032-barrier-mouse-move-decoder.md; CMD = W/evidence/issues/M1-032/commands.json
>
> Critical: none. High: none.
>
> Medium
> 1. Evidence incomplete: `W/evidence/issues/M1-032/tests/` does not exist. Issue line 114
>    requires a machine-readable test report; design b.1 names
>    `tests/barrier-mouse-move-decoder-tests.json` + `tests/swift-testing-xunit.xml`; precedent
>    `evidence/issues/M1-031/tests/` has both. Fix: rerun the filtered `swift test` with
>    `--xunit-output evidence/issues/M1-032/tests/swift-testing-xunit.xml` and add the JSON
>    summary (may be bundled with the known summary.md gap; your call).
>
> Low
> 2. CMD: no per-command `startedAt`/`endedAt` (issue line 113 asks for start/end times; M1-031
>    and M1-060 commands.json both carry them). Fix: add the two fields per record, or state the
>    omission in `note`.
> 3. DOC:87-106 ("Validation") never reconciles the issue's "invalid coordinate typed error"
>    wording with the drop outcome. Fix: one sentence citing ADR "Rejection semantics"
>    (ADR:227-236) and design pitfall 15; repeat it in summary.md's AC table.
> 4. TEST:573-617: the truncation loop builds a fresh reassembler and re-feeds `bytes[..<cut]`
>    for every cut (quadratic), 3.3-4.2 s, 5x the next slowest test in the package. Design a.7
>    asks for every cut, so acceptable; flag only.
>
> Judgment on the "invalid coordinate typed error" reading: right. ADR:227-236 lists `DMMV` out
> of range / out of rectangle under "Drop and continue" with a diagnostic of token, direction,
> body length, reason; fail-closed is only body length, server-to-client CCLP, unknown token
> (ADR:238-243). The issue predates the ADR (`contract_refs: []`) and itself forbids diverging
> from the frozen ADR (issue lines 69, 86). Design a.4 and pitfall 15 settle the same: "the
> session must not reuse M1-031's error path for DMMV". A closed `Reason` enum is still typed.
> Throwing here would end the session on a stray pointer frame, a contract violation.
>
> Checked, no issue
> - Correctness (SRC:89-123): order token -> direction -> length -> raw bound -> rectangle
>   matches design a.4; `dropFirst(4)` + `body.startIndex + offset` slices the ArraySlice
>   correctly; a whole frame (length prefix first) fails as unknownToken; big-endian read
>   correct; `<= 0x7FFF` accepts 0x7FFF and drops 0x8000 on either axis before containment,
>   even when the rectangle contains 0x8000 or starts at -32768; `contains` is M1-031's
>   `[origin, origin+size)` in Int; `Int(pixel) - Int(origin)` cannot overflow; extent 1 returns
>   0 (no 0/0); extent 0 drops everything via containment before `normalized`.
> - Round trips by arithmetic: decode->encode exact for every reachable pixel
>   (|((k/(n-1))*(n-1)) - k| <= ~2^-37 < 0.5); encode->decode exact at 0.0 and 1.0 for origin
>   >= 0 and rectangle inside 0...0x7FFF (0/(n-1) = 0 and (n-1)/(n-1) = 1 exactly); center exact
>   only for even n-1 (m/(2m) = 0.5 exactly); 1600x900 gives 800/1599 asserted by the identical
>   Double expression plus a toleranced bound. Negative origin and rectangles past 0x7FFF are
>   excluded from the edge claim in DOC:151-154 and DOC:161-163, which is correct (encoder
>   clamps lowest to 0 / highest to 0x7FFF).
> - Tests: fixture frames read in array order, sequences pinned to [28,30,32,34,39,41,65] with
>   count check (TEST:237-249); bytes match my independent decode of the fixture. Wrong
>   implementations I tried on paper all fail: /extent instead of /(extent-1), axis swap (7x5
>   screens), little-endian, cursor instead of origin, range-after-containment (reason differs),
>   `<` 0x7FFF, length `>=`, direction after length, case-insensitive token, diagnostic carrying
>   payload count instead of body count, signed read of 0x8000, Float arithmetic. Privacy walker
>   is non-vacuous (TEST:527-536) and admits only `Int`.
> - Template a.5/a.6: all five fixed names, conformances, `bodyByteCount`,
>   `normalized(pixel:origin:extent:)`, `decode(payload:direction:) throws(BarrierMouseMoveDecoderError)`,
>   `Reason` with the two design cases; error cases have the same names/shapes as
>   `BarrierControlMessageError`. Diagnostics and errors carry only enums and `Int` (M1-011).
> - Docs: first-party items are labelled (DOC:11-13 header, 100-106 direction rule, 117-118
>   reason split, 124 formula, 209-213 non-zero origin); register quote DOC:31 exists at
>   evidence/registers/M1-023.json:1180; frame table DOC:45-51 matches the fixture; "16 tests"
>   matches.
> - Scope/evidence: only the three Exact Files plus CMD changed; CMD has no `/Users/`, no user
>   name, no /var/folders, /tmp, DerivedData or hostname; masked `<producer-scratch>` and the
>   `reduced` xcodebuild record are declared in `note`.

## Resolution

| Finding | Resolution |
| --- | --- |
| 1 (Medium) | `tests/swift-testing-xunit-swift-testing.xml` (full package, 263 tests, 0 failures) and `tests/barrier-mouse-move-decoder-tests.json` (the 16 M1-032 tests, RED, GREEN and the 13 mutants) added. |
| 2 (Low) | The `commands.json` note now states that per-command times were not recorded; they are not reconstructed after the fact. |
| 3 (Low) | The doc's Validation section now says the issue's "invalid coordinate typed error" is the typed drop the contract requires; `summary.md`'s acceptance table already says so. |
| 4 (Low) | Accepted as is: the design asks for every truncation cut. |
