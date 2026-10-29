# M1-PROTOCOL-003 Independent Protocol Review

> Filed by the implementing agent from the independent reviewer's two reports of 2026-10-29,
> followed by a Codex finding the Product Owner relayed the same day.
> Each report's title line is replaced by its section heading and its other headings are
> nested one level down; local absolute paths are replaced by `<repository>` and
> `<producer-scratch>`. Nothing else is changed.

## First review (draft at 4ee8f62)

- Reviewer: independent protocol reviewer (not the implementing agent), 2026-10-29.
- Target: `codex/m2-023-client-frame-contract` at `4ee8f62` (PR #334), read-only, in
  `<repository>`.
- Method: read the ADR, the register entries, the independent evidence review, the fixtures
  (independently decoded with a throwaway `python3 -I` script), the contract test, the
  precedent ADRs, the first-party server encoders and the M2-035 smoke records. Ran the
  contract test and the register test suites. No file in the repository was changed; no
  Swift build; no network.
- Notation: `SI obs N` = `server-input-capture.json` observation with `sequence: N`
  (index N-1), `PC` = punctuation fixture, `CC` = client-clipboard fixture. "Verified" cites a
  byte, index or `file:line`; "inference" is my reading and is marked.

### Verdict

**Accept with conditions.** The frozen layouts, widths, value sets and orderings are all
supported by the registered claims and I reproduced every one of them from the fixture
bytes. The ADR is honest about the three first-party conventions and about what the
captures do not show. It cannot be consumed by the Linux client decoders as written,
because (1) the frozen key-identifier set does not cover what the first-party Mac server
actually sends for shifted letters and digits, so a conforming first-party client would
drop Shift+B..Z and Shift+0/2..9; (2) "reject" and "fails closed" are not defined at the
session level, so two implementers would build different decoders; (3) two wording
choices freeze or blur things the register leaves unknown (DMMV signedness; start-size
semantics for multi-chunk transfers); and (4) the contract test does not pin the
modifier-bit assignment or the identifier-to-key correspondence, so a plausible wrong
contract would still pass. H1 and M1-M4 must be fixed before the decoders start; the
Low items can be fixed in the same edit or a follow-up.

### Findings, by severity

#### H1 (High, completeness / contradiction) - The first-party server emits key identifiers outside the frozen set; the decoder rule would drop them

- Location: ADR lines 111-118 ("Key identifiers: the frozen set is exactly the values in
  `BARRIER-EVID-0006-CLAIM-005` ... and `BARRIER-EVID-0008-CLAIM-001`. Any other
  identifier is outside this contract: the decoder does not inject it") versus
  `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierServerInputEncoder.swift:137-147`
  (`shifted: 0x41 + offset` for every letter; `shiftedDigits` = 0x29, 0x21, 0x40, 0x23,
  0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28) and `:189-200` (shift or Caps Lock selects the
  shifted identifier).
- Verified: the captured identifier set (my decode of SI and PC, identical to the test's
  `FROZEN_KEY_IDENTIFIERS`) contains, among shifted printables, only 0x0041 `A`
  (SI obs 406, 519), 0x0021 `!` (SI obs 414), 0x005F `_` (SI obs 425) and the eleven shifted
  punctuation values (PC). The first-party server sends 0x0042-0x005A for Shift/Caps+B..Z and
  nine shifted-digit values that were never on the wire. The M2-035 smoke sent Shift+b and the
  real `barrierc` produced X keycodes 50+56 (`evidence/issues/M2-035/automated-smoke/x-events.txt`
  lines 3-6), so 0x0042 was interoperability-validated once; no shifted digit was ever sent.
- Consequence: a first-party Linux client built to this ADR records the button and injects
  nothing for Shift+B..Z and Shift+0,2..9. That contradicts the Status claim that the Mac
  server's encoders "become formally backed by these contracts" (ADR lines 14-15) and would
  make M4-036-FOLLOWUP-001 fail on ordinary typing. Safety is not affected (the release still
  pairs by button).
- Fix (either, stated explicitly in the ADR): (a) add a fourth "First-party convention, not a
  capture claim" block: the first-party peers use the produced-character identifier for all
  shifted letters (0x0041-0x005A) and the US shifted digits, exactly the table the server
  encoder holds; validated by M2-035 for Shift+b only; and have the contract test assert that
  every identifier the server's table can emit is in `FROZEN_KEY_IDENTIFIERS` or in a
  declared convention list; or (b) capture Shift+b..z and Shift+0..9 in an M2-022 addendum,
  register it, and move them into the frozen set. (a) unblocks now and follows the precedent
  the ADR already uses for wheel multiples; (b) is the only way to make it a Barrier claim.

#### M1 (Medium, decoder safety / ambiguity) - "reject" and "fails closed" are undefined at the session level

- Location: ADR lines 52-53 (DMMV at or above 0x8000: "a decoder rejects such a frame without
  moving the pointer"), 68-70 (`DMDN` outside 1-5: "rejects"), 168 (server-to-client `CCLP`:
  "fails closed"), 202 (unknown tokens "stay fail closed").
- What is wrong: the ADR never says whether a rejected frame is dropped with the session
  continuing, or ends the session. The precedent (`M1-PROTOCOL-002` lines 142-154) defines
  the skip-one-frame-with-diagnostic rule and the fail-closed rule separately, and the
  diagnostic content (token, direction, length, reason; never body bytes). Here one
  implementer will drop a bad `DMMV` and continue (the "without moving the pointer" wording
  suggests this), another will end the session; for `CCLP` one will drop the frame, another
  will disconnect. Neither contradicts Frozen Decision 7 by itself, but if "fails closed"
  means disconnect, the ADR must say that the terminal path releases every pressed key and
  button (M1-063-FOLLOWUP-001 owns that cleanup) so the release guarantee at ADR lines
  129-130 holds across the session boundary.
- Fix: add one paragraph "Rejection semantics": for `DMMV`, `DMDN`, `DKRP` and unknown
  identifiers/mask bits, the frame is dropped, a diagnostic with token/direction/length/reason
  only is emitted and the session continues; for server-to-client `CCLP` and any unknown
  token, the session fails closed with a typed protocol-violation error and the client's
  terminal-path cleanup releases all pressed input. State the same for a malformed body
  length (for example a 5-byte `DMMV`).

#### M2 (Medium, evidence) - DMMV is frozen as "unsigned" although the register keeps signedness unknown; in-rectangle handling is unspecified

- Location: ADR lines 45-48 ("x | 2 bytes | unsigned ...", "y | 2 bytes | unsigned") versus
  `evidence/registers/M1-023.json:1180` (CLAIM-001: "signedness and clamping are not
  established"), `:1344-1349` (`barrier-server-dmmv-signedness-and-clamping`, status
  `unknown`) and `:1412` (prohibited: "do not infer ... signedness beyond the claims").
- Verified: all seven observed values are below 0x8000 (SI obs 28, 30, 32, 34, 39, 41, 65), so
  the ADR's restriction to values below 0x8000 makes the word operationally harmless, but the
  table still freezes a field the register lists as unknown. The precedent wording for the
  same situation is `M1-PROTOCOL-002` lines 73-74 and 102-103: "big-endian coordinate value,
  signedness not frozen", accepted only in `0x0000...0x7fff`.
- Also unspecified: a value below 0x8000 but outside the client's `DINF` rectangle.
  `M1-PROTOCOL-002` lines 87-91 and 114-117 require `DINF`/`CINN` coordinates to fall inside
  the rectangle and fail closed otherwise; the first-party server clamps into the rectangle
  (`BarrierServerInputEncoder.swift:216-221`); the register says clamping was not observed
  (`M1-023.json:1336`). Two implementers will clamp, reject or pass through differently.
- Fix: change the two table cells to "big-endian, signedness not frozen; accepted only in
  0x0000...0x7FFF" and add the rectangle rule explicitly (recommended: same as
  M1-PROTOCOL-002, drop the frame and continue when outside the rectangle; do not clamp,
  since clamping is unobserved). Note that the observed `DINF` origin was (0,0) in all three
  fixtures, so the relation of `DMMV` to a non-zero `DINF` origin is not observed (ADR line 47
  says "in the client's `DINF` coordinate space", which is one step beyond CLAIM-001's "client
  pixels"); the open question at line 250 should name this.

#### M3 (Medium, ambiguity) - The start frame's size is defined as "the chunk data" length, which breaks the multi-chunk convention

- Location: ADR line 150 ("start: decimal ASCII byte length of the chunk data") and lines
  176-178 (transfers "may span several chunks of at most 32 KiB").
- Verified: in every retained transfer there is one chunk, so chunk length equals total
  (SI obs 9/11, 13/15; PC obs 9/11, 169/170; test lines 150 and 161). In the committed chunk
  log the client's 100,000-byte copy had a start data length of 6 digits and a chunk total of
  250,028 bytes over 8 chunks, and the server's a 7-digit start over 46 chunks totalling
  1,500,028 (`evidence/e2e/M2-022/chunks.json#/results`; no payload bytes retained), so the
  start carries the total of all chunk data. The first-party assembler implements the total
  (`BarrierClipboard.swift:8-9, 160-176`).
- Consequence: an implementer reading line 150 literally validates each chunk against the
  start value and rejects every multi-chunk transfer from the first-party server
  (`BarrierClipboard.defaultChunkSize` = 32 KiB, `BarrierClipboard.swift:35`).
- Fix: in the table write "start: decimal ASCII total byte length of the mark-2 data of the
  transfer (one chunk observed, so equal to the chunk length)"; in the first-party
  convention say explicitly that the sum of the chunks must equal the start value, a chunk
  must not exceed the remaining size, and the end must complete it exactly (that is what the
  server-side assembler enforces, `BarrierClipboard.swift:164-176`). Also say what happens
  to a frame other than `CALV` arriving inside a transfer (the first-party assembler ignores
  interleaving entirely, keyed by id); the ADR only admits `CALV`.

#### M4 (Medium, test) - The contract test would accept a plausible wrong contract for the modifier bits and the identifier-to-key correspondence

- Location: `Tests/Contracts/test_m1_protocol_003_input_clipboard_message_contracts.py`
  lines 110-130 and 132-138.
- Verified gaps:
  1. Mask bits: line 119 only asserts that no bit outside the union 0x1017 is set. A contract
     saying "0x0002 = Alt, 0x0004 = Control, 0x0010 = Caps Lock, 0x1000 = Super" passes. The
     bytes pin the assignment: Control `DKDN` 0xEFE3 at SI obs 431 (mask 0) is followed by
     0x0063 with mask 0x0002 (obs 433); Alt 0xEFE9 (obs 439) by 0x0061/0x0004 (obs 441);
     Super 0xEFEB (obs 447) by 0x0061/0x0010 (obs 449); Caps Lock 0xEFE5 (obs 515) by
     0x0041/0x1000 (obs 519); Control+Shift gives 0x0003 (obs 457-459).
  2. Identifier names: line 130 pins the *set* of identifiers, not which is which. A contract
     that swapped Left/Right (0xEF51/0xEF53) or Home/End (0xEF50/0xEF57) passes. The driver
     order (`evidence/e2e/M2-022/tools/capture_server_input.py:182-193`) and the `DKDN` order
     in SI (obs 80 a ... 183 z, 190-226 digits, 230 Return, 234 Escape, 238 Tab, 242 space,
     246 BackSpace, 250 Delete, 254 Left, 258 Right, 265 Up, 269 Down, 273 Home, 277 End,
     281 Prior, 285 Next, 289 Insert, 293-340 F1-F12, 344-384 punctuation, 388 KP_Enter,
     392-400 volume) establish the correspondence; I re-derived it and it matches CLAIM-005.
  3. Only Shift's own-down/own-up mask rule is pinned (lines 136-137); the Caps Lock
     toggle-off rule at ADR line 125 (both frames 0x1000, SI obs 523/525) is not.
  4. `CINN` sequences 1 and 3 and mask 0 (ADR line 136) are not asserted; only the token at
     index 7 is.
  5. The "held button spans pointer moves" rule (ADR line 67; SI obs 63 `DMDN` 1, 65 `DMMV`,
     70 `DMUP` 1) is not pinned.
- Fix: add assertions that walk the `DKDN` frames of SI in driver order against a named
  table (identifier, name), assert the four modifier-bit transitions and the Caps Lock pairs
  by observation index, assert `CINN` at SI obs 8/564 decodes to (0, 450, 1, 0) and
  (0, 450, 3, 0), and assert the obs 63-70 ordering. These are the facts M1-041/M1-043 will
  consume.

#### L1 (Low, wording / evidence) - "A server-to-client `CCLP` was never captured"

- Location: ADR line 168; also line 201.
- Verified: one server-to-client `CCLP` (length 9, so a 5-byte body like the client's) is in
  the committed chunk log at t=67.42 s, before `CINN` at 68.81 s and the server's transfer
  (`evidence/e2e/M2-022/chunks.json#/frames`); the register says "never captured in a
  retained fixture" (`M1-023.json:1580-1583`), which is the accurate statement.
- Fix: "never captured in a retained fixture; the chunk log recorded one (code and length
  only, 9-byte payload) before an enter, so its body is unobserved".

#### L2 (Low, labelling) - Decoder policies sit among frozen rules without a label

- Location: ADR lines 109-110 (`DKRP` count other than 1 "is treated as one repeat"),
  117-118 (unknown identifier: record the button), 125-126 (unknown mask bits ignored).
- These are first-party fail-safe policies about fields the register marks unknown
  (`barrier-server-dkrp-count-semantics`, `-key-identifiers-outside-observed-set`,
  `-modifier-mask-unobserved-bits`, `M1-023.json:1356-1373`). They do not infer meaning, so
  they are allowed under M1-003 and the register, but they are not capture claims and the
  question "is this frozen from evidence or decided?" should be answerable from the heading.
- Fix: move them under a "Decoder policy (first-party, not a capture claim)" sub-heading, as
  the wheel and clipboard conventions already are.

#### L3 (Low, over-generalisation) - "A shifted press is four frames"

- Location: ADR lines 119-121.
- The four-frame order is the xdotool driver's order (Shift released before the key). It is
  observed for all eleven punctuation keys and for Shift+a/1/minus (SI obs 404-429), but a
  user who releases the key before Shift will produce `DKUP` with the shifted identifier and
  mask 0x0001. The first-party server sends whatever order the user types
  (`BarrierServerInputEncoder.swift:89-94`).
- Fix: "Observed shifted-press sequence (driver order): ... A decoder must not depend on this
  order; it pairs by button only (CLAIM-004)."

#### L4 (Low, timing wording) - "sent at once on a client copy"

- Location: ADR line 167. CLAIM-001 of 0007 says only "after the synthetic copy ... and
  before the server's `COUT`"; the 15 ms figure is a raw-only reviewer observation
  (`independent-review.md` F7) and the register prohibits timing claims. Say "after the copy
  and before the next `COUT`".

#### L5 (Low, consistency with precedent) - The register narrative does not describe entries 0006-0008 or their consumer links

- Location: `docs/evidence/M1-023-barrier-evidence-register.md` has a section per entry
  through `BARRIER-EVID-0005` (lines 308-405) and records each consumer link there
  (lines 117-125, 160-170, 322-330, 353-356, 385-390). It has no mention of 0006, 0007,
  0008, M2-022 or M1-PROTOCOL-003 (grep returned nothing). PR #333 did not add it when the
  entries were appended, and this PR links consumers without recording that.
- Fix: add a "BARRIER-EVID-0006 to 0008 - M2-022 server-side captures" section listing the
  fixtures, the permitted use, the consumer links and the non-claims, following the 0005
  section.

#### L6 (Low, informational) - The first-party server's Caps Lock toggle-off differs from the observed pattern

- `BarrierServerInputEncoder.swift:80-87` sends `DKDN` with the bit cleared and `DKUP` with it
  set for every toggle; the capture shows 0x1000 on both frames of a toggle-off
  (SI obs 523/525, ADR line 125). Not a contract violation if decoders treat the mask as
  informational (CLAIM-006: "a lock key's release does not reveal the resulting lock state"),
  but the ADR should say that a decoder must not derive lock state or synthesise modifier
  presses from the mask; the modifier's own `DKDN`/`DKUP` frames carry that.

### Answers to the six questions

1. **Evidence.** Every frozen layout, width, value set and ordering is supported by a claim and
   I reproduced it from the bytes: frame envelope (579+36+181 frames, all lengths exact);
   `DMMV` values (SI obs 28-65) = CLAIM-001; buttons 1,3,2,4,5,1 in pairs (SI obs 43-70) =
   CLAIM-002; wheel (0,120), (0,-120), (-120,0), (120,0) (SI obs 72-78) = CLAIM-003; `DKDN`/
   `DKUP` 6 bytes, `DKRP` 8 bytes, 14 repeats all count 1, pairing by button with nothing left
   held, up-id differing at SI obs 410/418/429 = CLAIM-004; the identifier set = CLAIM-005 and
   0008-CLAIM-001 (my decode of the set equals the test's set exactly); mask bits only
   0x0001/0x0002/0x0003/0x0004/0x0010/0x1000 = CLAIM-006; `CINN` seq 1/3, mask 0 (SI obs 8,
   564) = CLAIM-007; `DCLP` id/seq/mark/length layout, start "4"/"118"/"119", `CALV` at obs
   10 and 14 inside the transfers in all three fixtures = CLAIM-008 and 0008-CLAIM-002;
   marshalled (0,36),(1,54),(2,0) and (0,37),(1,54),(2,0), empty = count 0 = 0008-CLAIM-003;
   `CCLP` `00 00000001` at CC obs 28 and PC obs 166 = 0007-CLAIM-001; no server-to-client
   `CCLP` in any fixture. Two places go one step beyond the register: "unsigned" for `DMMV`
   (M2) and "in the client's `DINF` coordinate space" (M2, origin only ever (0,0)). Nothing
   else freezes an ambiguous field; format and id-1 meaning, the `CINN` increment rule,
   `DKRP` counts, unobserved mask bits, multi-chunk, timing and TLS all stay in Non-claims.
   The driver-order derivation of key names (my cross-check of
   `capture_server_input.py:182-209` against the `DKDN` order) agrees with CLAIM-005.
2. **First-party conventions.** The three conventions are labelled and separated. Their
   description is honest: the multi-notch wheel rests on one smoke command `scroll 0 -2`
   (`Tests/SystemTests/Scripts/M2-035-linux-smoke.sh:89`) delivered as one `KVMEvent`
   (`ServerCoordinator.swift:214-217`, `SmokeDriver.swift:95`) and encoded as one `DMWM`
   (0, -240) (`BarrierServerInputEncoder.swift:54-59`), with `barrierc` producing two X
   button-5 events (`x-events.txt` lines 21-24) - inference along that chain, since no wire
   bytes of the smoke are retained, but consistent; the chunk convention matches
   `chunks.json` (both peers 32,768-byte chunks, largest payload 32,782) and the smoke's
   600 KB out / 100 KB in (`automated-smoke/README.md` run 5); the text-as-format-0 rule
   rests on the two size equalities (PC obs 11, 170) and the smoke's clipboard cases. All
   three are allowed: M1-003 admits "expected input/output behavior ... derived from
   black-box tests", and the register's prohibitions are on inferring Barrier semantics,
   which the ADR does not do. The missing fourth convention is H1.
3. **Decoder safety.** No rule drops a release or leaves input stuck: `DMUP` with an
   out-of-contract value still releases (line 69), unknown identifiers still record the
   button (line 117), unknown mask bits still decode (line 126), `DKRP` with another count
   is one repeat (line 110), and `DMMV` rejection does not touch buttons. Nothing contradicts
   Frozen Decision 7. The gap is M1: the session-level meaning of "reject"/"fails closed" and
   the dependence on terminal-path cleanup are not stated.
4. **Completeness.** Against what the first-party server sends (`BarrierServerInputEncoder`,
   `BarrierClipboardControlEncoder`, `BarrierServerProtocolSession`): pointer clamped to the
   rectangle and 0x7FFF (in contract); buttons 1-4 (in contract); wheel multiples of 120
   (convention); `CINN` with mask 0 and a sequence that advances on enter and leave
   (ADR line 136 correctly tells the client not to validate it); `COUT`, `CALV` every 3 s and
   a three-interval silence timeout (the client answering `CALV` suffices); `DCLP` id 0,
   sequence 0, count-1 marshalled clipboard, 32 KiB chunks, up to 1 MiB of text
   (`BarrierServerProtocolSession.swift:49`); never `CCLP` to the client; never clipboard id
   1 to the client; never `DKRP` with count other than 1; mask bits only the five. Outside
   the frozen subset: the 34 shifted identifiers of H1, and the Caps Lock toggle-off pattern
   of L6. The ADR does not state a minimum transfer size a first-party client must accept
   (the server can send 1 MiB of text); a sentence pointing at that bound would avoid a
   client limit below it.
5. **Test.** The test pins the envelope, `DMMV` values and the 0x8000 bound, button values and
   pairs, wheel sign and magnitude, key frame widths, the exact identifier set, the mask-bit
   union, `DKRP` count, pairing by button, the four-frame punctuation sequence, the on-enter
   clipboard sequence with interleaved `CALV`, the `DCLP` layout in both directions, the
   marshalled structure, `CCLP` bytes, the absence of server-to-client `CCLP`, and the
   register links; the index-based lookups match the register's `evidenceLocations`. It
   would still pass a wrong modifier-bit assignment, a swapped identifier-name table, a
   wrong `CINN` sequence/mask and a wrong Caps Lock pattern (M4). It runs green
   (11 tests, `python3 -I Tests/Contracts/test_m1_protocol_003_input_clipboard_message_contracts.py`).
6. **Consistency.** The register links follow the 0004/0005 precedent exactly
   (`frozenContractRefs` = the contract ADR plus M1-025; `consumingTests` = the Python
   contract test plus the Swift tests that load the fixture bytes - I checked that
   `BarrierServerInputEncoderTests.swift:3-25`, `BarrierClipboardTests.swift:16-20` and
   `BarrierServerProtocolSessionTests.swift:160-165` read the M2-022 fixtures;
   `BarrierClipboardControlEncoderTests.swift:7-9` uses hand-copied golden bytes from the
   same capture). Only the consumer-link fields changed in the three entries (the diff shows
   nothing else). The register suites still pass: `evidence/issues/M1-023/tests/test_register.py`
   15 tests OK, `evidence/issues/M1-EVIDENCE-001/tests/test_registration.py` 18 OK, and the
   0025/0001/0002/wire-002 contract tests 7/5/10/7 OK. M2-023's in-place dated note and
   "superseded ... when accepted" rows mirror how M1-PROTOCOL-002 handled 0004; the stale
   "has not been executed" sentence is kept for the record as the note says. The one
   precedent not followed is the register narrative document (L5).

### Checked and found sound

- Frame envelope on all 796 frames of the three fixtures; direction counts 284/295, 16/20,
  87/94; CNOP count equals the server frame count after `DSOP` in every fixture
  (279, 11, 82).
- The ADR's Non-claims list covers every `ambiguousFields` id of the three entries.
- The withdrawn labels (HTML, bitmap, primary selection, warp) do not appear in the ADR; the
  incident-001 disposition is cited in Rejected alternatives.
- The Status scopes consumption to M1-032/033/034/041, M1-043 and M1-029-FOLLOWUP-001,
  as M4-SCOPE-001 lines 104-108 require; the ADR names the reviewer gate.
- Security section: fixtures hold zero-filled clipboard content (verified: every format
  content in PC obs 11 and 170 is all zero; CC obs 34-36 bodies all zero), no addresses;
  TLS stays default-on; no TLS claim.
- Rollback is the reverse of the consumer-link update, consistent with M1-025's rule that
  the register is never rewritten.
- `evidence/issues/M2-022/summary.md`, `incident-001-unobserved-labels.md` and
  `docs/components/M2-028-barrier-clipboard-control-encoder.md` now point at M1-PROTOCOL-003
  instead of "the M2-023 amendment".

## Second review (revision at a621ca3)

- Reviewer: the same independent protocol reviewer (not the implementing agent), 2026-10-29.
- Target: `codex/m2-023-client-frame-contract` at `a621ca3` (PR #334), one commit after the
  reviewed `4ee8f62`; it changes only the ADR, the Python contract test,
  `BarrierServerInputEncoderTests.swift` and the register narrative (`git diff --stat`:
  4 files, +258/-32). Read-only; no Swift build; no network. I re-read the whole ADR, the
  diff, the two tests and the narrative, re-decoded every observation the new assertions
  cite with a throwaway `python3 -I` script, and re-ran the suites.
- Runs (this session): `python3 -I Tests/Contracts/test_m1_protocol_003_input_clipboard_message_contracts.py`
  15 tests OK; `evidence/issues/M1-023/tests/test_register.py` 15 OK;
  `evidence/issues/M1-EVIDENCE-001/tests/test_registration.py` 18 OK;
  `test_m1_protocol_002...` 10 OK; `test_m1_025...` 7 OK. The Swift test was not run (no
  build allowed); see H1 below for what I checked instead.

### Verdict

**Accept.** Every finding of the first review is resolved, and nothing the revision added
is unsupported by the register or ambiguous enough to produce two different decoders.
The remaining items are wording nits that do not block the decoders; they can go into the
merge edit or a follow-up.

### Finding-by-finding

#### H1 (34 shifted identifiers) - resolved

- ADR lines 146-158 declare the convention under a "First-party convention, not a
  capture claim" heading, list exactly the encoder's values (0x0042-0x005A; 0x0029, 0x0040,
  0x0023, 0x0024, 0x0025, 0x005E, 0x0026, 0x002A, 0x0028 for digits 0 and 2-9), state that
  0x0041 and 0x0021 are captured, and limit the interoperability claim to Shift+B (M2-035).
  I checked the digit table against `BarrierServerInputEncoder.swift:122-124`: identical.
- `identifiersStayInContract` (`BarrierServerInputEncoderTests.swift:202-242`): the frozen
  set it builds is 100 values and equals the Python `FROZEN_KEY_IDENTIFIERS` and my own
  decode of the fixtures (90 from SI plus 10 shifted punctuation from PC); the convention
  set is 34 and disjoint; it enumerates every `VirtualKey` the encoder accepts under none /
  Shift / Caps / Shift+Caps for down, up and repeat, reads the identifier at payload bytes
  8-9, and requires emitted ⊆ frozen ∪ convention and convention ⊆ emitted. Reasoning
  through the encoder (`:137-147`, `:189-200`) the two expectations hold and removing any
  one convention value breaks the second. Helper names (`none`, `shift`, `caps`,
  `encoder()` at `:42-46`) and the types (`KeyPhase.repeatKey`, `ModifierState`,
  `PunctuationKey: CaseIterable` in `KVMContracts/KVMEvent.swift:42-73`) exist. Not built
  here; the coordinator reports it runs and fails when 0x40 is removed.
- The Python test (`:235-241`) additionally pins that the ADR text names all 34 and that
  they are outside the frozen set.
- Nothing unsupported was added: the convention block makes no Barrier claim, the Decoder
  policy bullet (`:135-136`) now says "outside the frozen set and the convention below",
  and the register narrative repeats "The first-party conventions in M1-PROTOCOL-003 are
  not capture claims".

#### M1 (rejection semantics) - resolved

- ADR lines 216-236 separate drop-and-continue (`DMMV` out of `0x0000...0x7FFF` or outside
  the `DINF` rectangle; `DMDN`/`DMUP` outside 1-5; a broken `DCLP` transfer) from fail
  closed (a known token with a body length that does not match its layout; server-to-client
  `CCLP`; any unlisted token), define the diagnostic as token/direction/body length/reason
  with no body bytes (M1-011 is the logging-policy ADR, `docs/adr/M1-011-logging-policy.md`),
  and state that the terminal path's cleanup (M1-063-FOLLOWUP-001, as listed in
  M4-SCOPE-001) releases every pressed key and button. Frozen Decision 7 is satisfied.
- The `DMUP` rule changed from "still releases any matching pressed button" to "dropped
  too: its `DMDN` was dropped, so nothing is held" (ADR lines 72-73). That is logically
  sound and loses no release.
- Residual nit (non-blocking): a `DCLP` whose inner 4-byte length disagrees with the
  remaining body is a "body length does not match its layout" case by the fail-closed
  bullet, but a reader may file it under "a transfer that breaks the rules" (drop). The
  first-party server drops such frames (`BarrierServerProtocolSession.swift:31-33`,
  `BarrierClipboard.swift:100-101`). One clause naming which bucket it belongs to would
  remove the last fork; either choice is safe.

#### M2 (DMMV signedness and rectangle) - resolved

- Table cells now read "big-endian; signedness not frozen; accepted only in
  `0x0000...0x7FFF`" (ADR lines 48-49), the M1-PROTOCOL-002 wording. The prose keeps
  CLAIM-001's "client pixels", drops rather than clamps outside the rectangle ("clamping
  was never observed"), and records that the `DINF` origin was (0, 0) in every capture
  (verified: all three fixtures' `DINF` bodies decode to 0,0,1600,900), with the non-zero
  origin added to the open questions (line 308) and to the narrative's non-claims.
- Cosmetic: the test method is still named `test_dmmv_is_two_unsigned_big_endian_client_coordinates`;
  its assertions (`u16` unsigned read, `< 0x8000`) match the new rule, so only the name is
  stale.

#### M3 (start value and multi-chunk) - resolved

- Table (line 178): "decimal ASCII total byte length of the transfer's mark-2 data (one
  chunk was observed, so it equaled that chunk's length)"; chunk: "the marshalled clipboard,
  or the next part of it". The convention block (lines 208-214) adds the sum rule, the
  chunk-never-exceeds-remaining rule, the exact-end rule and the 1 MiB minimum, which
  matches the first-party assembler (`BarrierClipboard.swift:160-176`) and the server's
  `clipboardByteLimit = 1 << 20` (`BarrierServerProtocolSession.swift:49`). Interleaving
  (lines 191-193) now says state is kept per clipboard id and other tokens are processed
  normally in between. The multi-chunk sum is consistent with `chunks.json` (6-digit start
  over 250,028 bytes in 8 chunks; 7-digit start over 1,500,028 in 46) and is correctly left
  outside the capture claims.

#### M4 (test pins) - resolved

I re-decoded every observation the new assertions cite:

- `test_key_identifiers_follow_the_capture_driver_order`: 78 names in the driver's order
  (26 letters, 10 digits, 15 named keys, F1-F12, 11 punctuation, KP_Enter and three volume
  keys) against the first 78 `DKDN` identifiers of SI; my earlier decode of SI obs 80-400
  gives exactly that sequence (Left 0xEF51 at obs 254, Right 0xEF53 at 258, Up 0xEF52 at
  265, Down 0xEF54 at 269, Home 0xEF50, End 0xEF57, Prior 0xEF55, Next 0xEF56, Insert
  0xEF63, KP_Enter 0xEF8D, volume 0xE0AF/0xE0AE/0xE0AD). A swapped table now fails.
- `test_modifier_bits_and_caps_lock_by_observation`: SI obs 404/406 (Shift 0xEFE1 mask 0,
  then 0x41 mask 0x0001), 431/433 (Control 0xEFE3, then 0x63 mask 0x0002), 439/441 (Alt
  0xEFE9, then 0x61 mask 0x0004), 447/449 (Super 0xEFEB, then 0x61 mask 0x0010), 455/457/459
  (Control, Shift mask 0x0002, Escape mask 0x0003), 515/517/519/523/525 (Caps toggle-on
  0x0000/0x1000, `A` with 0x1000, toggle-off 0x1000/0x1000). All match my decode byte for
  byte. A wrong bit assignment now fails.
- `test_cinn_sequences_and_held_button`: SI obs 8 and 564 decode to (0, 450, 1, 0) and
  (0, 450, 3, 0); obs 63/65/70 are `DMDN` 01, `DMMV` 0074 01FA = (116, 506), `DMUP` 01.
- `test_convention_identifiers_are_declared_and_outside_the_capture` and the extended
  phrase check ("Decoder policy (first-party, not a capture claim)", "Rejection semantics",
  "signedness not frozen", "total byte length") pin the revision's structure.
- Residual, non-blocking: the right-hand modifier identifiers (0xEFE2, 0xEFE4, 0xEFEA,
  0xEFEC) are in the frozen set but their left/right identity is not pinned by order. The
  first-party server never sends them (`BarrierServerInputEncoder.swift:168-171`), so no
  first-party decoder depends on it.

#### L1-L6 - resolved

- L1: lines 197-200 say "never captured in a retained fixture", describe the chunk-log
  record (before an enter, code and length only, 5-byte body) and add "the first-party
  server never sends it" (true: no `CCLP` in `BarrierClipboardControlEncoder.swift` or the
  session).
- L2: the three policies and the new mask-is-informational rule sit under "Decoder policy
  (first-party, not a capture claim)" (lines 131-141).
- L3: "Observed shifted-press sequence (driver order) ... A decoder must not depend on it;
  it pairs by button only" (lines 126-129).
- L4: "sent after the copy and before the next `COUT`" (line 196).
- L5: `docs/evidence/M1-023-barrier-evidence-register.md:407-453` adds the 0006-0008
  section with fixtures, contract effect, consumer links, sanitization, the incident and
  the non-claims, in the shape of the 0005 section. Nit: it says the Swift tests "read
  these fixtures"; `BarrierClipboardControlEncoderTests.swift:7-9` uses golden bytes copied
  by hand from the capture rather than reading the file. Harmless; "derive their golden
  bytes from" would be exact.
- L6: lines 138-141 state that a decoder derives no lock state and synthesizes no modifier
  press from the mask, and record the first-party server's Caps Lock toggle pattern
  (`BarrierServerInputEncoder.swift:80-87`) as harmless under that rule.

### Did the revision add anything unsupported or ambiguous?

Checked every new sentence against the register and the code:

- "Control with Shift gave 0x0003" (SI obs 459), "toggle-on 0x0000 then 0x1000; toggle-off
  0x1000 on both" (obs 515/517, 523/525), "`DMDN` 1, a `DMMV`, then `DMUP` 1" (obs 63/65/70),
  "sent after the copy and before the next `COUT`" (CC obs 28/32, PC obs 166/167): all
  supported by CLAIM-006, -002, 0007-CLAIM-001.
- "the first-party server never sends [`CCLP`]", "1 MiB ... the first-party server's limit",
  the Caps Lock encoder pattern, the 34-identifier table: all first-party facts verified in
  the sources cited above and labelled as such.
- No new Barrier semantic claim appears; the Non-claims list is unchanged and still covers
  every `ambiguousFields` id; the withdrawn labels are still absent (test).
- Minor overstatements worth one edit each (non-blocking):
  1. Compatibility impact (line 284-285) still says M2-035 validated "the first-party
     conventions"; the ADR itself now says only Shift+B of the shifted identifiers was
     validated and no shifted digit was ever sent. Qualify it.
  2. Rejected alternatives (lines 297-300) names the wheel and multi-chunk conventions but
     not the shifted identifiers; add them for symmetry.
  3. Non-claims bullet "key identifiers outside the listed set, or non-US layouts" could
     read "as capture claims", as the wheel bullet does, since 34 of them are now a
     convention.

### Answers

1. Each finding is resolved as described; the fixes add no unsupported claim and leave only
   the nits above (DCLP inner-length bucket, a stale test name, three wording tweaks, the
   narrative's "read these fixtures", right-hand modifier order), none of which would lead
   two implementers to different decoders for the first-party pair.
2. Verdict: **accept**. The ADR may be consumed by M1-032, M1-033, M1-034, M1-041, M1-043
   and M1-029-FOLLOWUP-001 once the Product Owner merges it.

## Codex finding relayed by the Product Owner (fd32fee)

Received 2026-10-29, verbatim:

> - [P2] 上次的水平捲動方向問題尚未修正：契約第 96 行 仍要求兩軸直接除以 120。現有編碼器將向左的 deltaX = +1 編成 −120，照契約解碼會得到 −1，方向相反。應明定水平軸取反：deltaX = −wireX / 120，垂直軸維持 deltaY = wireY / 120，並補往返測試。
> 本次更新已釐清 DCLP 長度錯誤的處理及相容性描述，未發現新增問題。

Verification by the implementing agent: the finding holds.

- `BARRIER-EVID-0006-CLAIM-003`: the left notch is `(−120, 0)` on the wire.
- `BarrierServerInputEncoder.scroll` sends `−deltaX × 120`, documented as "positive
  `deltaX` scrolls left", and its existing test matches the captured left frame.
- The ADR's rule, both axes divided by 120, therefore decoded the left notch as
  `deltaX = −1`, a right scroll.
- The M2-035 smoke's X events contain buttons 1–5 only, so no horizontal scroll was ever
  exercised end to end.

Resolution: the ADR states the per-axis rule (`deltaX = −wireX / 120`,
`deltaY = wireY / 120`). `test_wheel_rule_inverts_the_horizontal_axis` failed before the
ADR change and passes after it. The Swift test `scrollRoundTrip` round-trips 80 delta
pairs through the encoder and the rule; an encoder without the inversion, and the old rule,
each fail it with 72 issues.
