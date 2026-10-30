# M1-041 Independent Review

- Reviewer: a fresh-context review agent (Fable), not the implementer, 2026-10-29.
- Target: PR #339 at `3578e01`, read-only, in the reviewer's own worktree.
- Design references (`a.6`, `b.4`, `c.13`) point to the lead's decoder design, which is not in the
  repository; each decision it settled is restated in the component doc. The lead overrode `c.13`
  before this review: the first press identity is kept while a button is held.

## Report (verbatim)

> PR #339 review, head 3578e01. Verified in my worktree: `swift test --filter
> BarrierKeyboardDecoder` 20/20 pass (exit 0, 4.95 s); `swift format lint --strict` clean on both
> Swift files; an independent Python pairing walk over both captures (232 and 66 key frames) finds
> no re-press, no unpaired up/repeat, no identifier on two buttons, nothing held at the end, and
> every fixture sequence the tests and doc cite decodes to the stated token/identifier/mask/button.
>
> Critical: none. High: none.
>
> Medium
> 1. docs/components/M1-041-barrier-keyboard-decoder.md:231-235 — an unpaired `DKRP` is the one
>    emitted event that is neither a held press nor a release: it is absent from `heldKeys`, and
>    the KVMCore ledger precedent (Packages/KVMCore/Sources/KVMCore/ServerCoordinator.swift:498-499)
>    does not add a repeat to the pressed set. If the client session or the X11 injector (M4-024,
>    not written yet) turns a repeat into a KeyPress, that key sticks with no release and no
>    cleanup entry. The doc only defers the decision. Fix: state the fail-safe default as a MUST
>    for the session ("an unpaired repeat is not injected; a paired repeat is injected only as a
>    repeat of the held key"), or have the lead record it in the session design. No decoder code
>    change needed.
>
> Low
> 2. Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierKeyboardDecoderTests.swift:620-651
>    — "pairs by button only" is not separated from "button first, identifier fallback": a decoder
>    that, on an unpaired `DKUP`, searches `held` for the frame's identifier and frees that button
>    passes every test (the 65,536-button sweep catches identifier-first pairing, not the
>    fallback). Add: `DKDN(0x61,38)`, `DKUP(0x61,56)` → `.unpaired`, held still `[(38,0x61)]`; and
>    `DKDN(0x61,38)`, `DKDN(0x61,56)`, `DKUP(0x61,56)` → `.paired`, held `[(38,0x61)]`.
> 3. Same test file :826-845 (`goldenKeyFramesReEncodeByteForByte`) — the re-encode uses the
>    hard-coded `VirtualKey` and only the decoded phase/modifiers, so the decoded identifier and
>    button take no part in the byte comparison; a misread identifier still passes here (caught
>    elsewhere by `roundTrip…` :764-766). Either compare `pressed.identifier`/`button` against
>    `u16(frame, 8)`/`u16(frame, 12)` in this test or soften "decodes them" at md:62-64.
> 4. md:149-150 — the `DKRP` count rule is labelled "Contract (ADR decoder policy)" while the ADR
>    files it under "Decoder policy (first-party, not a capture claim)" and lists other counts as
>    a non-claim. Label it first-party like the neighbouring bullets.
>
> Checked, no issue (D = Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierKeyboardDecoder.swift):
> - Stuck-key sequences traced on D:183-202: re-press → down id1 press, down id1 paired, up id1
>   paired (lead's override implemented: `press = held[button]; if press == nil { held[button] =
>   identifier }`); up for an unheld button → emitted, held unchanged; repeat before press →
>   emitted, held unchanged (see 1); same identifier on two buttons → two entries, each freed by
>   its own button; failure mid-hold → all three throws (D:168-177) precede any `held` mutation,
>   the latch at D:148 blocks every later frame, `heldKeys` intact
>   (`failureIsStickyAndHeldKeysSurviveIt`); foreign or malformed frames latch
>   `unknownToken`/`invalidBodyLength` with held intact.
> - Mask: five bits, Caps Lock 0x1000, other 11 bits ignored (D:125-129, 159-163; test sweeps all
>   32 states × each unknown bit). `DKRP` layout count@4, button@6 via `bodyByteCount - 2` (D:181),
>   count never read. Check order latch → token → direction → length (D:148, 168-177) equals
>   M1-031; token init and latch are byte-identical to the M1-031 template. Slicing:
>   `body.startIndex + offset` on the `dropFirst(4)` slice (D:206-208) is correct.
> - Fixture order: 404/406/408/410, 412-418, 423-429, 515/517/523/525 and the
>   0x0041-down/0x0061-up pair on button 38 all verified against the capture bytes.
> - Round trip: 81 keys × 32 states, down/repeat/up plus the opposite-Shift release; modifier-key
>   XOR and Caps Lock two-frame rules match `BarrierServerInputEncoder.swift:80-100`; one button per
>   key, no shared buttons.
> - Template and privacy: all eight a.6 type names and the three error cases present; errors carry
>   only enums and `Int` (reflection test rejects fixed-width integers); doc states
>   `BarrierKeyEvent`/`heldKeys` are outputs never logged (md:245-252); production file imports
>   `KVMContracts` only.
> - Docs: first-party policies labelled at md:146-169 except item 4; the claims "every release and
>   repeat in both captures pairs" and "all 14 repeats carry the press identifier" hold under my
>   walk.
> - Scope: only the three Exact Files plus `evidence/issues/M1-041/{summary.md,commands.json}`
>   change.

## Resolution (`e189692`)

| Finding | Resolution |
| --- | --- |
| 1 (Medium) | The doc's new section "Fail-safe requirement for consumers" says the session MUST NOT inject an unpaired repeat (`pairing == .unpaired`), and may inject a paired repeat only as a repeat of the held key, never as a new press. It cites the contract's decoder policy and Frozen Decision 7. |
| 2 (Low) | `releasePairsByButtonOnlyNeverByIdentifier` adds both sequences and an unpaired `DKRP`; the identifier-fallback mutant F1 fails only this test. |
| 3 (Low) | `goldenKeyFramesReEncodeByteForByte` checks each decoded identifier (offset 8) and button (offset 12, or 14 in `DKRP`); mutants G1 and G2 fail it. |
| 4 (Low) | The `DKRP` count rule is labelled first-party. |
