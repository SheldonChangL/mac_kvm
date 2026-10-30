# M1-043 Independent Review

- Reviewer: a fresh-context review agent (Fable), not the implementer, 2026-10-30.
- Target: PR #341 at `472b96a`, read-only, in the reviewer's own worktree.
- The lead's decoder design (section b.5) is not in the repository; its decisions are restated
  in the component doc and `summary.md`.

## Report (verbatim)

> Review of PR #341 (472b96a, codex/m1-043-barrier-virtual-key-mapper). Ran in my worktree:
> `swift test --package-path Packages/BarrierCompatibility --filter BarrierVirtualKeyMapper` → 14
> tests, exit 0; `swift format lint --strict` on both Swift files → exit 0;
> `git diff --check origin/main...HEAD` → clean.
>
> **Critical: none. High: none.**
>
> **Medium**
> - docs/components/M1-043-barrier-virtual-key-mapper.md:182-189, 326-329, 367-368 — the consumer
>   rule "must derive [modifier/lock state] from the modifier keys' own press and release events
>   ... must never rebuild it from `modifiers`". Right for a modifier key's own events (taking the
>   state after a Shift tap from its DKUP mask would leave Shift held). Not sufficient, and
>   over-constraining: (a) a modifier already held when the pointer enters, and the Caps Lock
>   state at enter, produce no modifier key event on the client (CINN mask bits are unfrozen), so
>   a regular key's own `modifiers` is the only per-event signal for those cases, which the
>   "never" forbids M4-024 from using; (b) for Caps Lock the rule does not say toggle-per-press vs
>   held. It is labelled first-party guidance, but it binds M1-046/M1-063-FOLLOWUP-001/M4-024 from
>   a mapper doc. Fix: narrow it to "do not take the state after a modifier key's own event from
>   that event's `modifiers`", list the two gaps as open questions owned by M1-046/M4-024, and drop
>   the "must".
>
> **Low**
> - docs/...M1-043...md:233-238 — "A Barrier server with another layout sends the characters of
>   its own layout ... a German server sends 0x007A, z, from the key in the US Y position" is an
>   unobserved claim about Barrier behaviour (ADR Non-claims: non-US layouts; incident 001).
>   Label as an expectation, or cut to "non-US identifiers are not frozen; behaviour is unknown".
> - evidence/issues/M1-043/commands.json:42 — the RED run lists
>   `noKeyComesFromRawValueArithmetic()`, which is not in the committed test file (now
>   `identifiersAtRawValueShortcutEdgesMapToTheirOwnKeys`), so the RED evidence is of an earlier
>   suite. Re-run RED with the committed suite against the stub, or state the rename in
>   `baseNote`.
> - BarrierVirtualKeyMapperTests.swift:748, 787 — the "no stray literal" check only matches `0x`
>   and strips `//` comments, not `/* */`; a decimal-literal or block-commented shortcut passes.
>   Match `\b\d+\b` outside the lists too. Minor.
> - evidence/issues/M1-043/tests/ holds only the xunit XML; M1-033 and M1-041 also ship a
>   per-suite JSON report. Not required by the issue; mention only.
>
> **Checked, no issue**
> - Table: derived all 134 rows independently — the 232+66 key frames of both fixtures walked in
>   order against the drivers' xdotool key names (capture_server_input.py:182-204,
>   capture_punctuation_clipboard.py:193-195), paired by button for releases/repeats; plus
>   CLAIM-005/0008-CLAIM-001 text and the encoder's table. 100 captured + 34 convention, zero
>   differences, no identifier with two derived keys, nothing extra or missing. Specifically
>   confirmed: 22 punctuation rows plain/shifted; shifted digits `)!@#$%^&*(` → digit 0–9; F1–F12
>   = 0xEFBE–0xEFC9; Left EF51/Right EF53/Up EF52/Down EF54 (seq 254–269), Home EF50/End
>   EF57/Prior EF55/Next EF56; BackSpace EF08/Delete EFFF; RaiseVolume E0AF/LowerVolume
>   E0AE/Mute E0AD; right-hand EFE2/EFE4/EFEA/EFEC (seq 484–508) → same side-agnostic member as
>   the left.
> - Round trip: encoder identifier choice (letters shift XOR caps, digits/punctuation shift only,
>   `mask ^ modifierBit` on a modifier's down/up, Caps Lock as DKDN+DKUP with toggle masks and no
>   repeat) is inverted exactly; the documented exceptions (own bit inverted on down/up, repeat
>   exact; Caps Lock two frames) are real and complete; the test sweeps 81 keys × 32 states × 3
>   phases plus the release-under-other-Shift pair through one decoder and pins `inexactKeys` to
>   exactly those five keys.
> - Unknown policy: dictionary lookup, `?? .unknown(UInt32(raw))`, no arithmetic or rawValue init;
>   Insert/KP_Enter in contract but unknown; all 65,402 outside values asserted.
> - Composition: phase and modifiers pass through; button/pairing ignored; asserted over 32
>   states × 3 phases × 3 pairings × 4 buttons.
> - Tests vs wrong tables: arrow/volume/Home-End swaps, F-key off-by-one, a right-hand modifier to
>   a wrong member, shifted-digit shifts, and convention removal all fail the driver-order fixture
>   test and/or the encoder inverse; 11 mutants recorded killed; mutations.json `sourceSha256`
>   equals the HEAD source; `testedFiles` blobs equal HEAD.
> - Docs: conventions labelled; 90+10 frozen count correct; left/right residual cited correctly
>   (independent-review.md:437-440); d.2 and d.3 recorded; M4-SCOPE-001 §8 placement correct.
> - Scope/evidence: only the 3 Exact Files + evidence/issues/M1-043/ changed; commands.json,
>   mutations.json, run_mutations.py and the xunit contain no `/Users/`, user name or worktree name
>   (only `<home>`, `<repository>`, `<producer-scratch>` placeholders; the literal "<worktree>"
>   appears once, in the masking legend).

## Resolution (`ddbf459`, and the lead's finishing commit)

| Finding | Resolution |
| --- | --- |
| Medium | The doc narrows the guidance to "do not take the state after a modifier key's own event from that event's `modifiers`". It drops "must", labels the guidance first-party, and lists two open questions for M1-046 and M4-024: modifiers held at enter, and the Caps Lock state at enter. |
| Low 1 | The German-layout example is removed; non-US identifiers are stated as not frozen, with unknown behavior. |
| Low 2 | `commands.json` has a `testRenames` field and a note mapping the RED output's old name to the current one; the RED entry is unchanged. |
| Low 3 | `productionSourceKeepsEveryNumericLiteralInsideTheNamedLists` flags hexadecimal and decimal literals outside the named lists, after removing `//` comments, nested `/* */` comments and strings. Mutant 8 survived the previous suite and is killed by this test. |
| Low 4 | `tests/barrier-virtual-key-mapper-tests.json` is added by the lead's finishing commit. |
