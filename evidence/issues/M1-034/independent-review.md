# M1-034 Independent Review

- Reviewer: a fresh-context review agent (Fable), not the implementer, 2026-10-29.
- Target: PR #336 at `e5b5465`, read-only, in the reviewer's own worktree.
- Design references (`a.5`, `b.3` and so on) point to the lead's decoder design, which is not in
  the repository; each decision it settled is restated in the component doc.

## Report

The report is verbatim, except that the worktree basename is replaced by `<worktree>`.

> Review of PR #336 (head e5b5465), BarrierMouseWheelDecoder. Verified in my worktree:
> `swift test --package-path Packages/BarrierCompatibility --filter BarrierMouseWheelDecoder`
> 17/17 pass, exit 0, 0 warnings in the build log; `swift format lint --strict` on both Swift
> files exit 0.
>
> Critical: none.
> High: none.
>
> Medium
> 1. evidence/issues/M1-034/ has no `tests/` report (only commands.json). Trigger: the issue's
>    "Expected Evidence" lists `evidence/issues/M1-034/tests/` (machine-readable report) and
>    design b.3 names `tests/barrier-mouse-wheel-decoder-tests.json` +
>    `tests/swift-testing-xunit.xml`; M1-031, M1-022 and M1-029 ship it. Fix: rerun the filtered
>    test with `--xunit-output` and commit both files under `tests/`.
>
> Low
> 2. evidence/issues/M1-034/commands.json:65 (xcodebuild stdout) keeps the worktree basename 4
>    times: `--bundle-identifier <worktree>.*` and `-package-name <worktree>`, while the note
>    claims paths are masked. No `/Users/`, no user name, no `/tmp` anywhere in the file. Fix:
>    replace with `<worktree>`.
> 3. docs/components/M1-034-barrier-mouse-wheel-decoder.md:260-262 says "the remainder rule ...
>    validated only for the vertical axis by M2-035". M2-035 validated the encoder's vertical
>    multi-notch frame against a real barrierc (ADR:105-107); no run validated the client
>    remainder rule. Same doc :84 says a drop "is counted" where ADR:227 says a diagnostic is
>    emitted (counting is the session design, a.10). Fix: reword both sentences.
>
> Checked, no issue
> - Correctness: signs/axes match ADR:99-104 and the fixture (seq 72/74/76/78 =
>   up/down/left/right, decoded from the JSON); toward-zero via Int32 `/`; Int16.min widened
>   before negation (decoder:90; 32768/120 = 273, no trap); check order token -> direction ->
>   length (decoder:97-106) as design a.4; slicing `dropFirst(4)` with `startIndex + offset`,
>   exact body count 4 (payload of 4 bytes -> invalidBodyLength 0); a (0,0) result is dropped at
>   :110 and a single zero axis still emits. Exact inverse of ENC:54-58 up to 273;
>   Int32.max/min inputs saturate to +-273 as the extremes test expects.
> - Tests: mutation loop in my worktree (10 mutants, decoder restored after each, tree clean at
>   e5b5465) killed every mutant: no inversion, negate in Int16 (trap), floor division,
>   round-to-nearest, body `>= 4`, drop-if-either-axis-zero, payload count in the diagnostic,
>   swapped axes, length-before-direction, little-endian. Fixture order: `capturedFrames` keeps
>   JSON array order, the fixture file is sorted by `sequence` (verified), and the
>   named-direction test pins `[up, down, left, right]` with `==`, so a reorder fails loudly. It
>   does not assert the sequence numbers 72/74/76/78 the doc cites (nit only).
> - Template: all five a.6 names exact; shapes match a.5 (token init identical to CTRL:53-60; the
>   3 error cases; diagnostic token/direction/bodyByteCount/reason; outcome event/dropped);
>   `decode(payload:direction:) throws(...)`, `deltas(wireX:wireY:)`, `bodyByteCount`,
>   `unitsPerNotch` as in b.3. Diagnostics and errors hold only enums and `Int`; the reflection
>   walker has positive controls. Production file imports KVMContracts only.
> - Docs: per-axis rule, multi-notch magnitudes and the zero policy are labelled first-party; the
>   ADR's drop list not naming DMWM is stated; the sign-fix attribution (Codex review of
>   fd32fee, fix 226b011) matches the ADR review record; "284 frames", the 18-byte largest
>   payload and "17 tests" verified against the fixture and the test file.
> - Scope: 4 files = the 3 Exact Files + evidence/commands.json; all Required Commands plus
>   `make verify` are recorded with exit 0.

## Resolution

| Finding | Resolution |
| --- | --- |
| 1 (Medium) | `tests/swift-testing-xunit-swift-testing.xml` (full package, 264 tests, 0 failures) and `tests/barrier-mouse-wheel-decoder-tests.json` (the 17 M1-034 tests, RED, GREEN and mutation runs) added. |
| 2 (Low) | The four occurrences in `commands.json` are masked as `<worktree>`. |
| 3 (Low) | The doc now says M2-035 validated only the server's vertical multi-notch frame, and that a drop emits a diagnostic. |
| Nit | The sequence numbers are not asserted; the named-direction order is. Left as is. |
