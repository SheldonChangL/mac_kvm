# M1-033 Independent Review

- Reviewer: a fresh-context review agent (Fable), not the implementer, 2026-10-29.
- Target: PR #338 at `6737177` (base `76f4045`), read-only, in the reviewer's own worktree.
- Design references (`a.4`, `a.5`, `a.6`, `b.2`, `d.1`) point to the lead's decoder design,
  which is not in the repository; each decision it settled is restated in the component doc.

## Report

The report is verbatim, except that the reviewer's absolute worktree path is replaced by
`<reviewer-worktree>` and the user name it searched for by `<user name>`.

> Review of PR #338 @ 6737177 (base origin/main 76f4045). Paths below are relative to my
> worktree `<reviewer-worktree>`. Verified in this session:
> `swift test --filter BarrierMouseButtonDecoder` → 20/20 passed (4.8 s); `make docs-check` OK;
> `make architecture-check` OK; `swift format lint --strict` on both Swift files → no
> diagnostics. PR body not read (sandbox refuses gh/curl); reviewed the commit.
>
> Critical / High / Medium: none found.
>
> Low
> 1. docs/components/M1-033-barrier-mouse-button-decoder.md:127-129 and :217-218 — the M2-035
>    claims (server sent left/right/middle, client produced X raw buttons 1, 3, 2, auxiliary not
>    sent) go beyond the contract: ADR "Compatibility impact" :294-296 credits M2-035 only with
>    vertical wheel, clipboard, text and Shift+B, and the doc cites no source. The facts do exist
>    in evidence/issues/M2-035/automated-smoke/README.md:36 and x-events.txt:13-18 (while
>    evidence/e2e/M2-035/README.md says the formal E2E is "not executed"). Fix: cite the
>    automated-smoke README in "Frozen inputs", labelled as smoke evidence rather than contract,
>    or drop the sentences.
> 2. Same doc :138-152 ("Button 5") and :168-172 (a release without a press is emitted) are
>    first-party decoder policies (design b.2 [DECISION], open question d.1), not contract rules,
>    and are not labelled as such; the ADR labels its equivalents "Decoder policy (first-party,
>    not a capture claim)" (:140). Fix: add that label to both.
> 3. evidence/issues/M1-033/commands.json:7-10 — the first entry exits 1 with no phase/note. Its
>    stdout is the RED run on a stub (`mouseButton(wireValue: 1) → nil`, `token.bytes → []`), but
>    a reader sees a failed Required Command. The same-schema precedent
>    evidence/issues/M1-PROTOCOL-003/commands.json carries a top-level `note`;
>    EVIDENCE_STANDARD.md:16 also asks for `toolchain`, which is absent (only `baseCommit`). Fix:
>    add `note` ("entry 1 = RED run on the stub, entry 3 = GREEN") and a `toolchain` block.
> 4. evidence/issues/M1-033/commands.json:15 — the mutation run (R1–X7, all killed) depends on
>    `<producer-scratch>/m1-033/run-mutations.py` and `mutations.json`, which are not in the
>    repo, so a reviewer cannot rerun it (EVIDENCE_STANDARD.md:17 "可由 reviewer 重跑或核對").
>    Fix: commit the script and mutations.json under evidence/issues/M1-033/ (alongside the
>    tests/ report the lead is adding) or mark the entry non-reproducible.
>
> Checked, no issue
> - Correctness (Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseButtonDecoder.swift):
>   table :102-110 is 1 left / 2 middle / 3 right / 4 auxiliary, the inverse of
>   BarrierServerInputEncoder.swift:41-47 and not MouseButton's raw values (KVMEvent.swift:30-35,
>   right=2, middle=3); `default: nil` plus `1...5` (:95, :129-130) classify all 256 values:
>   5 → unrepresentableButton, 0 and 6–255 → buttonOutOfContract. Check order token (:115) →
>   direction (:118) → body length (:122) → value matches M1-031 and design a.4. Slicing
>   `dropFirst(4)` then `body[body.startIndex]` (:121-125) is correct on an ArraySlice. Phase
>   comes from the token only (:28-33). Errors and the diagnostic hold enums and Int only
>   (:47-70). Symmetry: a DMUP is dropped iff the DMDN of the same value is, and 1–4 are emitted
>   in both phases, so no sequence leaves a button held that the contract would release; a
>   malformed or foreign frame throws, and the contract's terminal-path cleanup (ADR:245-246)
>   releases. Round trip: `encoder.button(b, p)` → decode = `.event(b, p)` for all 8
>   combinations, each encoder frame byte-equal to the fixture frame (test :274-291).
> - Tests (…/BarrierMouseButtonDecoderTests.swift): the fixture is read in file order, the 12
>   button frames pinned to sequences [43,44,47,48,51,52,55,56,59,60,63,70] byte-for-byte
>   (:252-257) and decoded in that order (:259-272); the held case, seq 63 DMDN 1 / 65 DMMV /
>   67 CALV / 70 DMUP 1, is routed in order (:407-426) and again inside the full 284-frame,
>   3,849-byte server stream through BarrierFrameReassembler, coalesced, byte-wise, every 2-way
>   split and every truncation (:548-603). Wrong implementations I tried on paper all fail:
>   rawValue lookup, 5 → auxiliary, phase swap, accepting 0 or 6, direction before token
>   (:459-479 feeds unknown tokens in both directions), length before direction (:447-457),
>   body ≥ 1 byte (:430-445), a diagnostic carrying the byte (reflection walker :499-544),
>   case-insensitive tokens, a whole frame as payload. The evidence's mutations R1–X7 agree.
> - Template: type names exactly as a.6; token init identical to BarrierControlMessages.swift:53-60;
>   error, diagnostic and outcome shapes equal a.5; the only addition, `contractWireValues`, is
>   private. Nothing public/package; `import KVMContracts` only (both pinned by tests).
> - Scope and evidence: the diff touches only the three Exact Files plus
>   evidence/issues/M1-033/commands.json; commands.json has 0 hits for `/Users/`, `/home/`,
>   `<user name>`, `~/` (paths masked as `<producer-scratch>`/`<repository>`). The doc's "20 tests" and
>   "284 frames, 3,849 bytes" match my own decode of the fixture; its X-button order
>   (1, 3, 2, 8, 9 → 1, 3, 2, 4, 5) matches register CLAIM-002 verbatim.

## Resolution

| Finding | Resolution |
| --- | --- |
| 1 (Low) | The doc cites `evidence/issues/M2-035/automated-smoke/README.md` and `x-events.txt` and labels the statements as smoke evidence, not a contract claim. |
| 2 (Low) | "Button 5" and the unpaired-release rule are labelled "Decoder policy (first-party, not a capture claim)". |
| 3 (Low) | `commands.json` has a `note` (entry 0 is the RED run, entry 2 the GREEN run), a `toolchain` and a `date`. |
| 4 (Low) | `mutations/run-mutations.py` and `mutations/mutations.json` are committed; the `commands.json` note says how to rerun them. |
