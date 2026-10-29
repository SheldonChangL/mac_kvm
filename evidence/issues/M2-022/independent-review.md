> Filed by the producer from the independent reviewer's report of 2026-10-29. Local absolute
> paths are replaced by `<repository>` and `<producer-scratch>`; nothing else is changed.

# M2-022 Barrier server-side evidence: independent review

- Reviewer: independent reviewer agent, not the producer (a separate session from the "Claude Opus" executing agent named in `evidence/e2e/M2-022/README.md`).
- Reviewed at: 2026-10-29T03:41:32Z.
- Repository: `<repository>` at HEAD `ef444bd9d7cf9976b4c95629ded387626f294298`, read-only. `git status` shows no tracked change after the review.
- Review tools (outside the repository): `<producer-scratch>/review-decode.py` (independent frame decoder, no reuse of the producer's tools), `review-checks.py` (pairing, CNOP accounting, in-memory validator simulation), `review-raw-timing.py` (raw-stream timing and marker correlation). All run with `python3 -I`.
- Disclosure: I also ran `Tools/verify/M1-007-test-targets.sh .` expecting a fixture-metadata schema check. It turned out to run the package's Swift test target as well (176 tests, exit 0). This was not intended; it changed no tracked file. Its result is used only for one fact: that script does not enforce the schema's `maxLength` on `provenance.reference` (finding F4).

Everything marked **verified** below cites a file and an observation index (`obs N` = `observations[N-1]`, i.e. `sequence: N`) or a byte value. Everything marked **inference** or **raw-only** is not supported by the committed fixtures.

## 1. Verdicts per artifact in `result.json`

| Artifact (`evidence/e2e/M2-022/result.json#/artifacts`) | Verdict | Reason |
|---|---|---|
| `Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json` (`506535a7…dcb9b`, 73,941 B) | **approve** | SHA-256 and length match; 579 observations, every length prefix equals the following byte count; no host, IP, user, path, certificate, probe text or clipboard content (only the codes, `Barrier`, and the synthetic screen name `capclient` are printable); re-derived byte for byte from the producer's raw stream `6db39890…781e` with the committed `make_fixtures.py`. |
| `Tests/Fixtures/Barrier/m2-022-linux-server-input/metadata.json` (`e10afd68…1a08`, 1,269 B) | **approve with conditions** | Hash and length match; keys match the schema. `provenance.reference` is 786 characters, above the schema's `maxLength: 512` (F4). Either shorten it in a new revision (new hash in `result.json`) or record a schema deviation decision. |
| `Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json` (`72417873…5bb7`, 4,878 B) | **approve with conditions** | Hash and length match; 36 observations; sanitized; re-derived byte for byte from raw stream `acb55a3b…c372`. Condition: the write-ups must state that the **entire** client-to-server `DCLP` body after the code (id, sequence, mark, length and data) is zero-filled (obs 34–36 are all-zero after `DCLP`; body lengths 12, 93, 10), so this fixture supports only the count and lengths of the client `DCLP` frames, not their layout (F5). The keepalive-timeout numbers are not in this fixture (F7). |
| `Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/metadata.json` (`501fad70…7fe3`, 1,363 B) | **approve with conditions** | Hash and length match. `reference` is 826 characters (> 512, F4) and says "Client-to-server DCLP data is zero-filled at its original length", which understates the zeroed span (F5). |

Artifacts **not listed** in `result.json` but committed and reviewed (F3):

| Artifact | Verdict | Reason |
|---|---|---|
| `Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json` (`3851b910…bc41f`, 23,530 B) | **approve with conditions** | Matches its own `metadata.json`; 181 observations; every clipboard format content is all-zero at its original length (obs 11: formats 0/1/2 sizes 36/54/0; obs 170: 37/54/0); no probe bytes; re-derived byte for byte from raw stream `07c968ef836652e7…2d65` (the addendum quotes only this 16-hex prefix). Conditions: add it to `result.json` with a case, a UTC capture time and commit; withdraw or source the labels "HTML", "bitmap", "primary selection" (F2). |
| `Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/metadata.json` (`10e4aa27…9d3a`, 1,188 B) | **approve with conditions** | Keys match the schema; `reference` is 660 characters (> 512, F4); not referenced anywhere in `result.json`. |

## 2. May `privacy.sanitizationReviewed` be set to true?

**Yes**, for the three capture fixtures and their metadata, on the basis of my own byte inspection (section 6), with two conditions in the same edit:

1. Set `reviewStatus: reviewed` on the four listed artifacts. With `sanitizationReviewed: true` alone the validator still fails with `artifact_not_reviewed` (simulated in memory with `Tools/Evidence/validate_evidence.py`'s `validate_document`; with both changes the document validates).
2. Add the two punctuation artifacts with their hashes above and `reviewStatus: reviewed`, plus a case for the 2026-10-29 session and an `endedAt` that covers it. The in-memory simulation with those two artifacts appended also validates.

Note for the record: `containsTypedText: false` is acceptable only because the retained key frames encode exactly the synthetic xdotool sweep listed in the committed driver (`tools/capture_server_input.py` lines 182–209), confirmed marker by marker from the raw stream; the register entry should say so explicitly.

## 3. Findings, by severity

### F1 — High (process). Pending-review evidence is already consumed and called "frozen" by first-party code and documents

`docs/evidence/M1-023-barrier-evidence-register.md` ("A capture … absent from this register with disposition `approved` is not implementation input") and `docs/adr/M1-003-independent-implementation-policy.md` (roles 3–5) require registration and independent review before a contract is frozen or a codec written. No `BARRIER-EVID` entry exists for M2-022, yet:

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClipboard.swift:1-2` "wire frozen from the M2-022 punctuation and clipboard capture".
- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierServerProtocolSession.swift:6-7, 272, 446, 453` keepalive cadence, timeout and 32 KiB chunk bound from the M2-022 README and chunk measurement.
- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClipboardControlEncoder.swift:3`.
- `docs/components/M2-028-barrier-clipboard-control-encoder.md:37-40` "The `DCLP` layout is now frozen from the M2-022 punctuation and clipboard addendum".
- `docs/adr/M1-042-virtual-key-catalog.md:160-163` Barrier identifiers and buttons taken from the addendum.
- `evidence/issues/M2-032/summary.md:30-35` and commit `482472c` consume the chunk measurement.
- `docs/adr/M2-023-barrier-server-wire-contract.md:6-7` still states "M2-022 … has not been executed", so the only server wire-contract ADR is stale relative to the code that cites M2-022.

Because the bytes now verify (section 6), the remediation is registration plus consumer links, not quarantine of bytes. The labels in F2 do need correction in the consumers. `docs/adr/M4-SCOPE-001-linux-client-first.md:104-107` correctly gates the Linux client decoders on this review; that gate has not been bypassed for the Linux side.

### F2 — High (provenance). Semantic labels that no observation can produce, with no recorded source

The committed fixtures zero-fill clipboard content, and no marker or peer log identifies clipboard formats. The following labels therefore rest on nothing in the evidence, and the write-up does not say where they came from:

- `evidence/e2e/M2-022/punctuation-clipboard.md:57` "0 = clipboard, 1 = primary selection"; `:75` "Format 0 is UTF-8 text, 1 is HTML and 2 is bitmap"; `:84-85`, `:91` "HTML (54)", "bitmap (0)", "empty primary selection".
- `evidence/e2e/M2-022/tools/decode_stream.py:60` names the fifth `DINF` field `warp` (`BARRIER-EVID-0005` records it as "reserved zero").
- Propagated into first-party sources: `BarrierClipboard.swift:11` ("Format 0 is UTF-8 text; HTML (1) and bitmap (2) …") and `BarrierServerProtocolSession.swift:402` ("Clipboard 1, the primary selection").

What the bytes do support: format 0's size equals the UTF-8 byte length of the driver's probe strings (36 for the server probe, 37 for the client probe; obs 11 and obs 170 of the punctuation fixture), which is consistent with, but does not name, a UTF-8 text format. What contradicts the label: format 1 is 54 bytes for **both** probes although the probes differ in length, so it is not a text-derived HTML rendering of the probe; its meaning is unknown. Format 2 was always size 0. Clipboard id 1 was always empty (format count 0; obs 13–16 in all three fixtures), so "primary selection" is not observed.

Required disposition: the producer records the source of these labels. If the source is Barrier or Deskflow source code, headers or constant tables, M1-003 "Review and incident workflow" applies to the labels and the comments that carry them. In any case the register entries below keep format-id semantics and clipboard-id-1 semantics at `status: unknown`.

### F3 — Medium (record completeness). The 2026-10-29 addendum is not in the machine record

- `result.json` lists neither punctuation artifact, has no case for the session, and its `endedAt` (2026-10-28T06:30:02Z) precedes it. The README "Artifacts" section (lines 79–85) lists only the two 10-28 fixtures.
- `punctuation-clipboard.md` records a date but no UTC time and no commit; the register entry contract requires `capture.capturedAt` as a UTC datetime, so the punctuation entry cannot be appended until the producer records it (section 7).
- The raw stream is identified only by a 16-hex prefix (`07c968ef836652e7`). Full value, verified by me on the producer's copy outside the repository: `07c968ef836652e711edda57f3d19929072877ea668cffa1b39b5123041f2d65` (13,186 bytes, 209 lines).
- The chunk-size measurement has no retained artifact at all. `tools/measure_clipboard_chunks.py` writes `chunks.json`, which exists only outside the repository (`<producer-scratch>/chunks.json`, SHA-256 `4144d20e3d59f10a81fde0cd7e8129946eedbd86dd0312cc4c40715da9e6406c`, 31,049 bytes). I confirmed it holds only `t`, `dir`, `code`, `length`, `id`, `mark`, `dataLength` per frame (no payload byte) and that its `results` match the addendum table exactly (client→server 100,000 B: 8 chunks, largest 32,768, total 250,028, largest frame payload 32,782; server→client 600,000 B: 46 chunks, 1,500,028; the 600,000/3,000,000 client copies and the 3,000,000 server copy did not transfer). It is committable as a `sanitized-log` artifact; until then the chunk claims are unsupported by anything in the repository.

### F4 — Medium (schema). All three `metadata.json` files violate the fixture schema's `maxLength`

`Tests/Fixtures/fixture-metadata.schema.json#/properties/provenance/properties/reference` sets `maxLength: 512`. Measured: 786 (server input), 826 (client clipboard), 660 (punctuation). Every earlier Barrier fixture stays under the cap (505, 509, 368, 371). No gate enforces it (`Tools/verify/M1-007-test-targets.sh` checks constants and keys only), and the `result.json` case `fixture-metadata` claims only "schema keys", which is true but incomplete. The schema is an authoritative reference of the register (`authoritativePolicyRefs`), so the deviation must be fixed or decided.

### F5 — Medium (claim scope). The README's `DCLP` "both" layout is not supported by the client-clipboard fixture

`README.md:47` claims the `DCLP` layout for both directions; `result.json` (`fixture-sanitization`) and the metadata say "client-to-server DCLP data zero-filled". In `client-clipboard-keepalive-capture.json` obs 34–36 the whole body after the code is zero (`make_fixtures.py:44-45` keeps `frame[:8]` only), so id, sequence, mark and length are not retained; only the frame count (3) and body lengths (12, 93, 10) are. The client-to-server `DCLP` layout is supported solely by the punctuation fixture (obs 169–171). The write-ups must cite that fixture for the client direction.

### F6 — Medium (inference presented as observation)

1. `README.md:42` "clamped to the client screen": no clamping event exists; all seven `DMMV` values (obs 28, 30, 32, 34, 39, 41, 65: x 0–116, y 450–506) are exact results of the relative moves.
2. `README.md:38` "(it also advances on leave)": sequence 2 is never on the wire; `COUT` has no body. Observed values are 1 then 3 in all three sessions (server input obs 8/564, punctuation obs 8/175, client clipboard obs 8).
3. `README.md:20` and the plan "Frame layouts are server-platform independent": only a Linux server was observed.
4. `punctuation-clipboard.md:92-93` "the server did not send the clipboard back to the client that owned it": the server-input session, where no client copy happened and the server clipboard was unchanged, also shows no `DCLP` after the second `CINN` (obs 564–569). The fixtures do not discriminate ownership from "no resend of an unchanged clipboard on re-enter".
5. The labels in F2.

### F7 — Low (timing claims rest on non-retained raw data; verified by me, not repeatable from the repository)

The fixtures carry no timestamps and no close event. From the producer's raw streams and `barrierc.log` (outside the repository) I measured: server `CALV` intervals after the enter burst 3.002–3.036 s (12 intervals; the first two `CALV` are inside the enter burst, 0.0 and 1.386 s apart); client `CALV` reply 0.34–1.00 ms in the server-input session (1.04 ms and 1.15 ms maxima in the other two sessions, so "within 1 ms" is slightly over elsewhere); `CNOP` 0.20–3.22 ms after the server frame it follows; in the client-clipboard session the relay saw EOF 9.018 s after the last server `CALV` and 8.625 s after the last server frame, and `barrierc.log` line 8 reads `NOTE: server is dead`; `CCLP` 15 ms after the `client-copy` marker. The README values (3.0 s, 1 ms, 3.2 ms, 9.02 s, 8.63 s, "at once") are therefore correct but, as in `BARRIER-EVID-0001`, must be recorded as reviewer-verified and non-repeatable once the raw streams are deleted. `DKRP` cadence (first repeat 661 ms after down, then every 40 ms) is the Xvfb autorepeat setting, not protocol.

### F8 — Low (missing versions). Xvfb, xdotool and xclip versions and the peer OS build are not recorded anywhere; the register's `capture.tools[]` requires a non-empty version string per tool. Python 3.10.16 on the peer is recorded in `result.json`.

### F9 — Low (observed behaviors the write-ups omit and a Linux client decoder must handle)

- A server `CALV` is interleaved inside each `DCLP` start/chunk/end sequence sent at enter: obs 10 and obs 14 in all three fixtures. A decoder must not treat `CALV` as a transfer error.
- Caps Lock toggle-off: both the down and the up carry mask `0x1000` (server input obs 523/525), so a lock key's release does not reveal the new lock state; the toggle-on pair is `0x0000`/`0x1000` (obs 515/517).
- A server-to-client `CCLP` exists (one in the uncommitted `chunks.json`) but is in no fixture; its layout is unobserved.
- `modifier Shift_R` via xdotool produced `Shift_L` down (0xEFE1) before `Shift_R` (0xEFE2) (obs 483–488; likewise Control_R, Alt_R, Super_R at obs 491–512): an environment artifact, but it means the right-modifier observations are only ever "with the left one already down".

### F10 — Low (process documents). `docs/adr/M2-023-barrier-server-wire-contract.md` is stale (F1). `evidence/issues/M2-022/` (summary, commands, environment, manual) required by `EVIDENCE_STANDARD.md` and by the Issue's "Expected Evidence" does not exist. The README correctly refuses to self-mark `sanitizationReviewed`.

## 4. Frame layouts: supported or not supported

"SI" = `m2-022-linux-server-input/server-input-capture.json`, "CC" = `m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json`, "PC" = `m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json`. All multi-byte integers were read big-endian; little-endian readings do not give the driver's values.

| Layout claimed | Status | Citations and notes |
|---|---|---|
| Frame envelope: 4-byte BE length = following bytes, then 4-byte ASCII code | supported (consistent with `BARRIER-EVID-0003`) | every observation of SI (579), CC (36), PC (181); no mismatch |
| `CINN` s→c: x u16, y u16, sequence u32, mask u16 (10-byte body) | supported for layout and observed values | SI obs 8 `x=0 y=450 seq=1 mask=0`, obs 564 `seq=3`; PC obs 8, 175; CC obs 8. Signedness, mask bits, increment rule: not established (F6.2). Note: `y=450` is the server cursor `y=540` scaled 1080→900; only one geometry observed |
| `COUT` s→c: no body | supported | SI 562, 569; PC 167, 177; CC 32 |
| `CALV` both: no body | supported | SI 14+14, PC 6+6, CC 3+3; timing raw-only (F7) |
| `CNOP` c→s: no body, one per server frame after the handshake | supported as count | SI: 279 server frames after `DSOP`, 279 `CNOP`; PC 82/82; CC 11/11 |
| `DMMV` s→c: x u16, y u16 (absolute client pixels) | supported for layout and values; "clamped" not supported | SI 28 `(10,450)`, 30 `(10,460)`, 32 `(0,460)`, 34 `(0,450)`, 39 `(100,500)`, 41 `(101,501)`, 65 `(116,506)`; each equals the previous position plus the driver's relative move; values < 0x8000 only |
| `DMDN`/`DMUP` s→c: button u8; 1,2,3,4,5 for X buttons 1,2,3,8,9 | supported | SI 43/44 `b1`, 47/48 `b3`, 51/52 `b2`, 55/56 `b4`, 59/60 `b5`, 63/70 `b1` (drag); the X-button mapping is correlated with the raw markers `click left/right/middle/back/forward` (raw-only) and with the committed driver order |
| `DMWM` s→c: xDelta s16, yDelta s16, ±120 per notch | supported | SI 72 `0000 0078`, 74 `0000 FF88`, 76 `FF88 0000`, 78 `0078 0000` for wheel up/down/left/right; one notch each (single observation per direction); signed reading is the one consistent with ±120 |
| `DKDN`/`DKUP` s→c: key u16, mask u16, button u16 | supported | SI 80–560 (109 pairs), PC 31–164 (33 pairs); all bodies 6 bytes; every down has a matching up with the same button and nothing left held |
| `DKRP` s→c: key u16, mask u16, count u16, button u16 | supported (count = 1 only) | SI 532–558 (14 frames, all `0061/0000/1/38`) between down 530 and up 560 |
| Key identifier table (letters, digits, named keys, F1–F12, punctuation, KP_Enter, volume) | supported | SI 80–402 in the committed driver order; each name↔value pair also confirmed against the raw `key <name>` markers (raw-only). Values: a–z 0x61–0x7A, 0–9 0x30–0x39, Return 0xEF0D, Escape 0xEF1B, Tab 0xEF09, space 0x20, BackSpace 0xEF08, Delete 0xEFFF, Left/Up/Right/Down 0xEF51/52/53/54, Home 0xEF50, End 0xEF57, Prior 0xEF55, Next 0xEF56, Insert 0xEF63, F1–F12 0xEFBE–0xEFC9, KP_Enter 0xEF8D, VolUp/Down/Mute 0xE0AF/AE/AD |
| Modifier ids and mask bits (Shift 0x0001, Control 0x0002, Alt 0x0004, Super 0x0010, Caps 0x1000; own down carries prior mask, up carries mask including it; up may carry a different key id, same button) | supported | SI 404–410 (shift+a: `EFE1/0`, `0041/1`, `EFE1/1`, `0061/0`, button 38 both), 412–418 (`0021`→`0031`), 423–429 (`005F`→`002D`), 431–437 (ctrl), 439–445 (alt), 447–453 (super), 455–465 (`0003`), 467–481, 483–512 (right modifiers), 515–525 (caps; see F9) |
| Punctuation table, plain/shifted ids and buttons | supported | PC 31/37 (`002D`/`005F` b20), 43/49 (`003D`/`002B` b21), 55/61 (`005B`/`007B` b34), 67/73 (`005D`/`007D` b35), 79/85 (`005C`/`007C` b51), 91/97 (`003B`/`003A` b47), 103/109 (`0027`/`0022` b48), 118/124 (`0060`/`007E` b49), 130/136 (`002C`/`003C` b59), 142/148 (`002E`/`003E` b60), 154/160 (`002F`/`003F` b61); Shift button 50; the four-frame shifted sequence holds for all eleven; SI 344–386 agree for the plain ids |
| Enter/leave sequence numbers (1 then 3) | supported as values, not as a rule | SI 8/564, PC 8/175 (F6.2) |
| `DCLP` s→c: id u8, sequence u32, mark u8, u32-length string | supported | SI 9–16 and CC 9–16 (empty clipboards: start `"4"`, chunk `00000000`, end empty; ids 0 and 1; seq 0); PC 9–16 (id 0 start `"118"`, chunk 118 bytes, end) |
| `DCLP` c→s: same layout | supported by PC only | PC 169 (`id0 seq1 mark1 "119"`), 170 (`mark2`, 119 bytes), 171 (`mark3`); CC 34–36 are zero-filled after the code (F5) |
| Marks 1 = start, 2 = chunk, 3 = end; start data = decimal ASCII of the chunk's byte length | supported | every transfer: `"4"`↔4 (SI/CC/PC id 0 and 1), `"118"`↔118 (PC 9/11), `"119"`↔119 (PC 169/170); order 1→2→3 always; length field always equals the remaining body (trailing 0) |
| Marshalled clipboard: u32 format count, then per format u32 id, u32 size, content | supported as structure | PC 11: count 3, ids 0/1/2, sizes 36/54/0; PC 170: 3, 0/1/2, 37/54/0; empty: count 0 (SI/CC/PC id 1, SI/CC id 0) |
| Format semantics (0 UTF-8 text, 1 HTML, 2 bitmap); id 1 = primary selection | **not supported** | F2; only "format 0 size = UTF-8 byte length of the probe" is observable |
| `CCLP` c→s: id u8, sequence u32 = current enter sequence | supported | CC 28 `id0 seq1` after CINN seq 1; PC 166 `id0 seq1` |
| "Server sent two empty clipboards on enter" | supported | SI 9–16, CC 9–16 |
| No `DCLP` on the second enter | supported as observation; ownership explanation not | SI 564–569, PC 175–177 (F6.4) |
| Keepalive timeout (client closes ~9 s after last server `CALV`) | **not supported by any fixture**; raw-only, reviewer-verified | F7 |
| Chunk-size measurement (32 KiB chunks, 32,782-byte max frame payload) | **not supported by any retained artifact**; consistent with the uncommitted `chunks.json` | F3 |

## 5. Gaps

Single observation (one session, one value):

- Second-enter sequence 3 (three sessions, but one pair of values each; no third enter); `CINN` mask only ever `0x0000` here versus `0x2000` in `BARRIER-EVID-0005`; `CINN` x/y only `(0,450)`.
- Wheel: one notch per direction; `DKRP` count only 1; `DSOP` only zero; `DINF` only `0,0,1600,900,0,800,450`.
- Keepalive interval and client timeout: one session each, raw-only.
- Non-empty clipboard transfers: exactly two (server→client once, client→server once), both three frames, one chunk.

Inference rather than observation: F6 items, the format and clipboard-id labels (F2), "server-platform independent".

Nothing in the fixtures: the chunk-size table, the keepalive timing, the "server is dead" close, server-to-client `CCLP`.

What a first-party Linux client would need that this evidence does not cover:

- Server-to-client `CCLP` layout (seen once outside the repository, never retained).
- Multi-chunk `DCLP` reassembly (several `mark 2` frames per transfer), the 32 KiB chunk bound, maximum accepted sizes, and other frames interleaved within a multi-chunk transfer; the fixtures show only one chunk per transfer and `CALV` interleaved at enter.
- `DCLP` from the server with a non-zero sequence; a populated clipboard id 1; format ids other than 0/1/2; the meaning of format 1 and 2.
- `DMMV`/`CINN` values at or above 0x8000 or negative, a client `DINF` with a non-zero origin, more than one client screen.
- Key ids outside the observed sets (non-US layouts, dead keys, keypad digits, media keys beyond the three), `DKRP` with count > 1, mask bits other than the five observed (0x0008, 0x2000 and above).
- `DSOP` non-zero options, `CROP` semantics, screensaver/lock/cursor-lock/close/error frames (none observed): unknown tokens must stay fail-closed.
- Behavior when the client stops answering `CALV`, server-side timeout, reconnection.
- Any observation under TLS, of a macOS Barrier server, or of Windows.

## 6. Verification record

- Hashes: computed with `shasum -a 256` and `stat -f %z`; all six fixture files match `result.json` (four) and the punctuation `metadata.json` (one); none is a symlink.
- Commit `2ca7878807a09f1c9496972b7a405236d6a5707b` in `result.json` exists (`fix(m2-013)…`, 2026-10-28 14:23:57 +0800 = 06:23:57Z, three minutes before `startedAt`), consistent with the capture running at that HEAD before the evidence commits `21e7832`, `6578b49`, `2b8f14e`.
- Validator: `python3 -I Tools/Evidence/validate_evidence.py evidence/e2e/M2-022/result.json --expected-issue M2-022` → `privacy_violation`, exit 65, as the README states. In-memory: `sanitizationReviewed=true` alone → `artifact_not_reviewed`; plus all artifacts `reviewed` → valid; plus the two punctuation artifacts → valid.
- Re-derivation (outside the repository): the producer's raw directories `m2cap/run1`, `m2cap/run2`, `cap2` still exist under the job tmp dir. Raw stream SHA-256 values equal the README's `6db39890…781e` (40,745 B, 682 lines) and `acb55a3b…c372` (2,566 B, 37 lines) and the addendum prefix `07c968ef836652e7`. The producer's local copies of the four capture/build tools are byte-identical to the committed tools. Running the committed `make_fixtures.py` and `make_punctuation_clipboard_fixture.py` on those streams into a reviewer directory reproduced all six committed files byte for byte (`cmp`). Both streams decode with zero leftover bytes per direction.
- Marker correlation: every `key <name>`, `click <name>`, `combo`, `modifier`, `caps`, `hold` marker in the raw server-input stream is followed by exactly the frames the README attributes to it; every punctuation marker in the raw addendum stream likewise; the addendum's self-checks appear as markers `client-clipboard-after-enter-1 matches-server-probe` and `server-clipboard-after-leave-1 matches-client-probe`.
- Sanitization scan over all frame bytes of the three fixtures: printable runs ≥ 4 are only the message codes, `Barrier` and `capclient`; zero hits for `mackvm`, `probe`, the probe strings' UTF-8 bytes, `m2-022`, `127.0.0.1`, `capserver`, user or path fragments; all clipboard format contents are zero at their original length.
- Repository state after the review: no tracked file changed (`git status --short` shows only the pre-existing untracked M4 files).

## 7. Draft register entries for `evidence/registers/M1-023.json`

Three entries are drafted. `BARRIER-EVID-0006` and `BARRIER-EVID-0007` may be appended as written (after the F1/F2/F5 corrections are made in the same PR, so consumers are not misled by the README). `BARRIER-EVID-0008` **may not be appended yet**: `capture.capturedAt` is not recorded anywhere (the addendum has only a date; `validate_entry` rejects anything but a UTC datetime), and the fixture is absent from `result.json`. The placeholder below must be replaced by the producer from its own record, not guessed. `frozenContractRefs` and `consumingTests` stay empty by the workflow (step 7 links them later); the existing consumers in F1 must be linked, not pre-filled.

```json
{
  "evidenceId": "BARRIER-EVID-0006",
  "relatedIssue": "M2-022",
  "source": {
    "category": "black-box-capture",
    "acquisitionMethod": "Controlled black-box observation of two lawfully installed external Barrier 2.4.0 programs, barriers (server, screen name capserver) and barrierc (client, screen name capclient), each on a throwaway Xvfb display on one owner-approved Ubuntu 22.04 x86_64 test host, connected through a byte-logging loopback relay operated by evidence/e2e/M2-022/tools/capture_server_input.py under Tests/SystemTests/Plans/M2-022-barrier-server-fixtures.md. All input was synthetic xdotool input on the server display in the order listed in the committed driver. Direction labels are the relay's socket roles (client side versus upstream server side), not analysis of payload content. No Barrier or Deskflow source, header, constant table, generated artifact, decompiled material, patched binary, injected packet or instrumentation was used for the bytes; the review found unobservable labels only in the write-ups (see limitations)."
  },
  "capture": {
    "capturedAt": "2026-10-28T06:26:52Z",
    "tools": [
      {"name": "Barrier barriers", "version": "2.4.0-release protocol 1.6"},
      {"name": "Barrier barrierc", "version": "2.4.0-release protocol 1.6"},
      {"name": "evidence/e2e/M2-022/tools/capture_server_input.py", "version": "commit 21e7832"},
      {"name": "evidence/e2e/M2-022/tools/make_fixtures.py", "version": "commit 21e7832"},
      {"name": "Xvfb", "version": "not-recorded"},
      {"name": "xdotool", "version": "not-recorded"},
      {"name": "python3 on the peer", "version": "3.10.16"}
    ]
  },
  "peer": {
    "product": "Barrier",
    "version": "2.4.0-release",
    "role": "client-and-server",
    "os": {"name": "Ubuntu", "version": "22.04", "build": "not-reported (kernel Linux 6.8 recorded in evidence/e2e/M2-022/result.json)"}
  },
  "transport": {
    "networkScope": "Loopback only on the test host: barrierc connected to a relay on a temporary loopback port, which connected to barriers on another temporary loopback port; the relay recorded every byte of both directions. No address, port, host name or user name is retained in the fixture. The operator's existing Barrier client on the host was not touched.",
    "tls": {"enabled": false, "protocolVersion": null, "certificateIdentitySanitized": true}
  },
  "provenance": {
    "lawfulUseStatement": "Both endpoints were lawfully installed external Barrier programs operated by their owner on a host under that owner's control, used only as external black-box test peers as M1-003 permits. Only externally observable application payload bytes were recorded. Barrier remains an external test peer and is not bundled, linked or copied.",
    "permittedUse": "Independent clean-room interoperability implementation inside the MacKVM Barrier compatibility adapter only: freezing the server-to-client pointer, button, wheel, key, repeat, enter, leave, keepalive and empty-clipboard frame layouts and the observed value sets for a client decoder, and checking a server encoder's bytes against them. This entry authorises no consumer until a contract entry and its tests are linked.",
    "producer": "M2-022 capture producer (the Claude Opus executing agent named in evidence/e2e/M2-022/README.md), who also decoded the frames and built the fixture",
    "reviewer": {
      "identity": "Independent reviewer agent, not the producer; review recorded in the M2-022 independent review report (to be filed as evidence/issues/M2-022/independent-review.md), including re-derivation of the fixture byte for byte from the producer's raw stream before its deletion",
      "independentFromProducer": true,
      "reviewedAt": "2026-10-29T03:41:32Z"
    },
    "disposition": "approved"
  },
  "sanitization": {
    "procedure": "evidence/e2e/M2-022/tools/make_fixtures.py reassembles complete 4-byte-length-prefixed frames per direction from the relay log and retains, per frame, only its sequence number, direction label and the base64 of the complete frame; timestamps, marker lines, addresses and ports never enter the fixture, and zero bytes were left over in either direction. No clipboard content was present (both server clipboards were empty). The retained key frames encode exactly the synthetic xdotool sweep listed in the committed driver, which the reviewer confirmed marker by marker against the raw stream; no user input or user content was involved. The reviewer's byte scan found no printable run other than message codes, the marker word Barrier and the synthetic screen name capclient, and no address, host, user, path, certificate or probe bytes.",
    "status": "sanitized",
    "containsSensitiveData": false,
    "removedCategories": ["ip-address", "other-private-data"]
  },
  "fixture": {
    "path": "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json",
    "sha256": "506535a774f257dc8f004105c8d6333e2da4727aef9c6f4073533cb5e81dcb9b",
    "byteLength": 73941
  },
  "coverage": {
    "direction": "bidirectional",
    "behaviors": [
      "579 complete frames in capture order, 284 server-to-client and 295 client-to-server; every frame is a 4-byte unsigned big-endian length equal to the number of following bytes, then a 4-byte ASCII code.",
      "Handshake frames 1-7 (hello, HelloBack for capclient, QINF, DINF 0,0,1600,900,0,800,450, CIAK, CROP, DSOP zero) match the layouts already approved in BARRIER-EVID-0004 and 0005.",
      "The server sent CINN with sequence 1 at the first enter (frame 8) and sequence 3 at the second enter (frame 564), both at x=0 y=450 with mask 0x0000, and COUT with no body at frames 562 and 569.",
      "Immediately after the first CINN the server sent two empty clipboard transfers, ids 0 and 1, sequence 0, each as start (ASCII 4), chunk (4 zero bytes: format count 0) and end, with one CALV interleaved inside each transfer (frames 9-16).",
      "The client sent one CNOP for every server frame after DSOP (279 of 279) and answered every server CALV with a CALV (14 of 14); CALV and CNOP have no body.",
      "Pointer, button, wheel, key, key-repeat frames were observed with the layouts and values stated in the wire claims; every DKDN had a matching DKUP with the same button and no key was left held.",
      "Timing is not retained: from the raw stream the reviewer measured server CALV every 3.002-3.036 s after the enter burst, client CALV replies within 1.0 ms, client CNOP within 3.22 ms, and 14 DKRP frames 40 ms apart starting 661 ms after the held key went down; these are non-repeatable reviewer observations, not claims."
    ],
    "wireClaims": [
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-001",
        "assertion": "Server-to-client DMMV carries a 4-byte body read as two unsigned 16-bit big-endian fields, x then y, holding the absolute pointer position on the client in client pixels: the seven observed values (10,450), (10,460), (0,460), (0,450), (100,500), (101,501), (116,506) each equal the previous client position plus the driver's relative move from the enter point (0,450). Only values below 0x8000 were observed; signedness and clamping are not established.",
        "establishedFieldIds": ["barrier-server-dmmv-layout", "barrier-server-dmmv-absolute-client-coordinates"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/27/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/29/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/31/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/33/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/38/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/40/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/64/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-002",
        "assertion": "Server-to-client DMDN and DMUP carry a 1-byte body holding a button number. For the driver's X button presses 1, 3, 2, 8, 9 the observed values were 1, 3, 2, 4, 5, each as a DMDN/DMUP pair with equal values, and a held button 1 produced DMDN, a DMMV, then DMUP. No other value was observed.",
        "establishedFieldIds": ["barrier-server-dmdn-dmup-layout", "barrier-server-button-values-1-to-5"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/42/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/43/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/46/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/50/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/54/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/58/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/62/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/69/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-003",
        "assertion": "Server-to-client DMWM carries a 4-byte body read as two signed 16-bit big-endian fields, x delta then y delta. One wheel notch up, down, left and right produced bodies 0000 0078, 0000 ff88, ff88 0000 and 0078 0000, that is (0,+120), (0,-120), (-120,0), (+120,0). One notch per direction was observed; other magnitudes are not established.",
        "establishedFieldIds": ["barrier-server-dmwm-layout", "barrier-server-dmwm-120-per-notch"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/71/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/73/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/75/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/77/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-004",
        "assertion": "Server-to-client DKDN and DKUP carry a 6-byte body of three unsigned 16-bit big-endian fields: key identifier, modifier mask, button. DKRP carries an 8-byte body of four such fields: key identifier, modifier mask, count, button; 14 DKRP frames with count 1 were observed between the DKDN and DKUP of a key held about 1.2 s. The button is the same in every down/up pair and in the repeats; the key identifier of an up may differ from its down (0x0041 down, 0x0061 up after Shift was released; likewise 0x0021/0x0031 and 0x005F/0x002D).",
        "establishedFieldIds": ["barrier-server-dkdn-dkup-layout", "barrier-server-dkrp-layout", "barrier-server-key-button-pairing"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/79/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/81/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/405/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/409/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/529/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/531/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/557/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/559/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-005",
        "assertion": "For this Linux server with the Xvfb default US keymap the key identifiers observed were: a-z 0x0061-0x007A, 0-9 0x0030-0x0039, space 0x0020, minus 0x002D, equal 0x003D, bracketleft 0x005B, bracketright 0x005D, backslash 0x005C, semicolon 0x003B, apostrophe 0x0027, grave 0x0060, comma 0x002C, period 0x002E, slash 0x002F, Return 0xEF0D, Escape 0xEF1B, Tab 0xEF09, BackSpace 0xEF08, Delete 0xEFFF, Insert 0xEF63, Left 0xEF51, Up 0xEF52, Right 0xEF53, Down 0xEF54, Home 0xEF50, End 0xEF57, Page Up 0xEF55, Page Down 0xEF56, keypad Enter 0xEF8D, F1-F12 0xEFBE-0xEFC9, volume up 0xE0AF, volume down 0xE0AE, mute 0xE0AD, Shift left/right 0xEFE1/0xEFE2, Control 0xEFE3/0xEFE4, Alt 0xEFE9/0xEFEA, Super 0xEFEB/0xEFEC, Caps Lock 0xEFE5; with Shift held, A 0x0041, exclam 0x0021, underscore 0x005F; with Caps Lock on, a 0x0041. The input-to-value pairing follows the committed driver order (frames 80-525) and was confirmed by the reviewer against the raw-stream markers. The button values are this server's X keycodes and are not a claim about any other server.",
        "establishedFieldIds": ["barrier-server-key-identifier-observed-values"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/79/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/229/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/292/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/343/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/387/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/391/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/403/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/518/applicationPayloadBase64",
          "evidence/e2e/M2-022/tools/capture_server_input.py"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-006",
        "assertion": "In the DKDN/DKUP/DKRP modifier mask, bit 0x0001 was set while Shift was held, 0x0002 while Control, 0x0004 while Alt, 0x0010 while Super and 0x1000 while Caps Lock was on, and 0x0003 while Control and Shift were held together. A modifier key's own DKDN carries the mask before it took effect and its DKUP carries the mask with its bit set (Shift down 0x0000, up 0x0001). For Caps Lock both the toggle-off DKDN and DKUP carried 0x1000, so a lock key's release does not reveal the resulting lock state. Bits other than these five were never set; their meaning is unknown.",
        "establishedFieldIds": ["barrier-server-modifier-mask-observed-bits"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/403/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/405/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/407/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/432/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/440/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/448/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/458/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/514/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/516/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/522/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/524/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-007",
        "assertion": "CINN carries x, y as unsigned 16-bit big-endian, a 4-byte big-endian sequence and a 16-bit mask, as in BARRIER-EVID-0005; here the first enter carried sequence 1 and the second enter sequence 3, both x=0 y=450 mask 0x0000, with COUT (no body) between them. Sequence 2 was never on the wire; the increment rule is not established.",
        "establishedFieldIds": ["barrier-server-cinn-second-enter-observed-sequence-3"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/7/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/561/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/563/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/568/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-008",
        "assertion": "Server-to-client DCLP carries id (1 byte), sequence (4 bytes big-endian), mark (1 byte) and a 4-byte big-endian length followed by that many data bytes. On the first enter the server sent, for id 0 and then id 1, each with sequence 0: mark 1 with data ASCII 4, mark 2 with 4 data bytes 00000000, mark 3 with empty data; one CALV frame was interleaved inside each transfer. The mark-1 data is the decimal ASCII byte length of the mark-2 data; the mark-2 data read as a 4-byte big-endian format count was 0.",
        "establishedFieldIds": ["barrier-server-dclp-header-layout", "barrier-server-dclp-empty-clipboard-on-enter", "barrier-server-calv-interleaved-in-dclp-transfer"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/8/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/9/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/10/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/11/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/12/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/13/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/14/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/15/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0006-CLAIM-009",
        "assertion": "After DSOP the client sent exactly one CNOP (no body) per server frame, 279 for 279, and one CALV (no body) per server CALV, 14 for 14; COUT has no body in both observed instances.",
        "establishedFieldIds": ["barrier-client-cnop-per-server-frame", "barrier-client-calv-reply"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/35/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/36/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json#/observations/37/applicationPayloadBase64"
        ]
      }
    ]
  },
  "limitations": [
    "One session of one external version pair on one host; the server was a Linux Barrier server on an Xvfb display with the default US keymap. No macOS Barrier server and no Windows peer were observed; the claim that frame layouts are server-platform independent is an inference and is not established here.",
    "Button values in DKDN/DKUP/DKRP are this server's X keycodes; a consumer may rely only on their equality within a down/up pair and across plain and shifted presses of the same key, not on their values.",
    "TLS was disabled for the observation only; nothing under TLS was observed and the product TLS default remains unvalidated by this entry.",
    "No clamping of DMMV to the client screen was observed; the README's statement that positions are clamped is not supported.",
    "Keepalive interval, reply latency and CNOP latency are reviewer measurements from the raw stream, which is not retained; they are not repeatable from the repository and are recorded here only as context.",
    "The raw stream (SHA-256 6db39890e3000c6b7b445ad23a7c756691f5d9e1a538017d94ac469591e2781e) and the peer logs were held by the producer outside the repository; the reviewer re-derived the fixture from it byte for byte with the committed make_fixtures.py before any deletion. Once deleted, re-derivation is no longer repeatable.",
    "Xvfb, xdotool and xclip versions and the peer OS build were not recorded by the producer.",
    "The fixture metadata reference string exceeds the fixture schema's maxLength of 512; no gate enforces that constraint. Recorded as a deviation to be fixed or decided; it does not affect the fixture bytes.",
    "The producer's write-ups carry labels that no observation supports (clipboard id 1 as primary selection, format ids as HTML and bitmap, a DINF field named warp); none of them is a claim of this entry."
  ],
  "ambiguousFields": [
    {"fieldId": "barrier-server-dmmv-signedness-and-clamping", "observation": "Only values 0-116 and 450-506 were observed; signedness, out-of-range handling and clamping are not observed.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-dmwm-magnitudes-beyond-one-notch", "observation": "Only plus or minus 120 was observed.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-dkrp-count-semantics", "observation": "Count was always 1; the meaning of other values is not observed.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-modifier-mask-unobserved-bits", "observation": "Bits other than 0x0001, 0x0002, 0x0004, 0x0010 and 0x1000 were never set; the 0x2000 seen in BARRIER-EVID-0005 was not observed here.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-key-identifiers-outside-observed-set", "observation": "Non-US layouts, dead keys, keypad digits and other media keys were not pressed.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-control-cinn-sequence-increment-rule", "observation": "Values 1 and 3 were observed; whether leave consumes a sequence number is inferred, not observed.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-control-cinn-modifier-mask-bits", "observation": "Only 0x0000 was observed here.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-dclp-format-id-semantics", "observation": "Only empty clipboards (format count 0) were sent in this session.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-clipboard-id-1-semantics", "observation": "Id 1 was always empty; what it carries is not observed.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-keepalive-timing-and-timeout", "observation": "Not retained in the fixture; reviewer-measured from the raw stream only.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-unobserved-tokens", "observation": "No option, screensaver, lock, close or error frame was observed; unknown tokens remain fail-closed.", "status": "unknown", "blockedClaimIds": []}
  ],
  "prohibitedInferences": [
    "Do not infer field meaning, width, order or signedness beyond the claims above; in particular do not infer DMMV clamping, a CINN increment rule, DKRP counts other than 1, or any modifier-mask bit beyond the five observed.",
    "Do not infer that button values hold for any other server, keymap or platform, or that any layout holds for a macOS or Windows Barrier server.",
    "Do not infer clipboard format or clipboard-id semantics from this entry; only empty clipboards were observed.",
    "Do not infer keepalive interval, latency or timeout as a compatibility claim from this entry.",
    "Do not infer TLS, certificate or trust behavior; TLS was disabled for the observation.",
    "Do not fill unknown bytes from model output, Barrier or Deskflow source, analogy or memory; the unobservable labels in the producer's write-ups are not evidence."
  ],
  "frozenContractRefs": [],
  "consumingTests": []
}
```

```json
{
  "evidenceId": "BARRIER-EVID-0007",
  "relatedIssue": "M2-022",
  "source": {
    "category": "black-box-capture",
    "acquisitionMethod": "Controlled black-box observation of the same two lawfully installed external Barrier 2.4.0 programs and topology as BARRIER-EVID-0006, operated by evidence/e2e/M2-022/tools/capture_client_clipboard_keepalive.py: handshake, enter, a synthetic clipboard change on the client display (xclip with the fixed non-personal probe string in the committed driver), leave, then SIGSTOP of the server process for 15 s to observe the client giving up on keepalive. Direction labels are the relay's socket roles. No Barrier or Deskflow source, header, constant table, generated artifact, decompiled material, patched binary, injected packet or instrumentation was used."
  },
  "capture": {
    "capturedAt": "2026-10-28T06:26:52Z",
    "tools": [
      {"name": "Barrier barriers", "version": "2.4.0-release protocol 1.6"},
      {"name": "Barrier barrierc", "version": "2.4.0-release protocol 1.6"},
      {"name": "evidence/e2e/M2-022/tools/capture_client_clipboard_keepalive.py", "version": "commit 21e7832"},
      {"name": "evidence/e2e/M2-022/tools/make_fixtures.py", "version": "commit 21e7832"},
      {"name": "Xvfb", "version": "not-recorded"},
      {"name": "xdotool", "version": "not-recorded"},
      {"name": "xclip", "version": "not-recorded"},
      {"name": "python3 on the peer", "version": "3.10.16"}
    ]
  },
  "peer": {
    "product": "Barrier",
    "version": "2.4.0-release",
    "role": "client-and-server",
    "os": {"name": "Ubuntu", "version": "22.04", "build": "not-reported (kernel Linux 6.8 recorded in evidence/e2e/M2-022/result.json)"}
  },
  "transport": {
    "networkScope": "Loopback only on the test host through the byte-logging relay, as in BARRIER-EVID-0006. No address, port, host name or user name is retained.",
    "tls": {"enabled": false, "protocolVersion": null, "certificateIdentitySanitized": true}
  },
  "provenance": {
    "lawfulUseStatement": "Both endpoints were lawfully installed external Barrier programs operated by their owner on a host under that owner's control, used only as external black-box test peers as M1-003 permits. Only externally observable application payload bytes were recorded.",
    "permittedUse": "Independent clean-room interoperability implementation inside the MacKVM Barrier compatibility adapter only: the client-to-server CCLP layout and the fact that a client sends its clipboard as three DCLP frames after COUT. This entry establishes no client-to-server DCLP field layout (the bodies are zero-filled here; see BARRIER-EVID-0008) and no timing claim.",
    "producer": "M2-022 capture producer (the Claude Opus executing agent named in evidence/e2e/M2-022/README.md), who also decoded the frames and built the fixture",
    "reviewer": {
      "identity": "Independent reviewer agent, not the producer; review recorded in the M2-022 independent review report (to be filed as evidence/issues/M2-022/independent-review.md), including re-derivation of the fixture byte for byte from the producer's raw stream and verification of the keepalive-timeout observation against the raw stream and the external client's log before their deletion",
      "independentFromProducer": true,
      "reviewedAt": "2026-10-29T03:41:32Z"
    },
    "disposition": "approved"
  },
  "sanitization": {
    "procedure": "evidence/e2e/M2-022/tools/make_fixtures.py reassembles complete frames per direction and retains sequence number, direction label and base64 of each frame; timestamps, markers, addresses and ports never enter the fixture. For every client-to-server DCLP frame the entire body after the 4-byte code, that is id, sequence, mark, length and data, is replaced by zero bytes of the same length (frames 34-36, body lengths 12, 93 and 10), so no clipboard content, not even the synthetic probe, is retained; the reviewer confirmed zero bytes for the probe string, for any host, user, path, address or certificate fragment, and that the only printable runs are message codes, the word Barrier and the synthetic screen name capclient.",
    "status": "sanitized",
    "containsSensitiveData": false,
    "removedCategories": ["clipboard-payload", "ip-address", "other-private-data"]
  },
  "fixture": {
    "path": "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json",
    "sha256": "72417873132f738a9e256ee73365d09a36c681a59175e010f7be46989d615bb7",
    "byteLength": 4878
  },
  "coverage": {
    "direction": "bidirectional",
    "behaviors": [
      "36 complete frames: the same handshake, CINN (sequence 1, x=0 y=450, mask 0), two empty server clipboard transfers with interleaved CALV, CNOP and CALV replies as in BARRIER-EVID-0006 (frames 1-27).",
      "After the synthetic copy on the client display the client sent CCLP (frame 28); after the server's COUT (frame 32) the client sent CNOP and then three DCLP frames (34-36) whose bodies are zero-filled in this fixture.",
      "No server frame follows COUT: the server process was stopped. The fixture retains no timestamp and no close event. From the raw stream and the external client's log the reviewer observed the relay EOF 9.018 s after the last server CALV (8.625 s after the last server frame) and the client log line NOTE: server is dead; this is a non-retained, non-repeatable reviewer observation, not a claim."
    ],
    "wireClaims": [
      {
        "claimId": "BARRIER-EVID-0007-CLAIM-001",
        "assertion": "Client-to-server CCLP carries a 5-byte body: id (1 byte) 0 and a 4-byte big-endian sequence 1, equal to the sequence of the CINN in force; it was sent after the synthetic copy on the client display and before the server's COUT.",
        "establishedFieldIds": ["barrier-client-cclp-layout", "barrier-client-cclp-sequence-equals-enter-sequence"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json#/observations/7/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json#/observations/27/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json#/observations/31/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0007-CLAIM-002",
        "assertion": "After the server's COUT the client sent one CNOP and then exactly three DCLP frames with body lengths 12, 93 and 10 bytes. Their bodies are zero-filled in this fixture, so this claim covers frame count, order and lengths only; the client-to-server DCLP field layout is established by BARRIER-EVID-0008, not here. The lengths are consistent with a start frame carrying two ASCII digits, one 83-byte chunk and an empty end.",
        "establishedFieldIds": ["barrier-client-dclp-three-frames-after-cout"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json#/observations/31/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json#/observations/33/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json#/observations/34/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json#/observations/35/applicationPayloadBase64"
        ]
      }
    ]
  },
  "limitations": [
    "One session; one copy; one leave. The client-to-server DCLP bodies are zero-filled in their entirety, including id, sequence, mark and length, so nothing inside them is observable here.",
    "The keepalive-timeout behavior is not in the fixture. The reviewer verified it from the producer's raw stream (SHA-256 acb55a3b4145b60b43c776e22556fd0b9e07887e2a1959c07a0386a7744dc372) and the external client's log before their deletion; it is a single observation and must not be consumed as a compatibility claim.",
    "The client's clipboard send was triggered by the server's COUT; whether a copy while not entered is sent at once was not observed in this session (the producer's uncommitted chunk measurement suggests it, but no artifact is retained).",
    "TLS disabled for observation only; no macOS or Windows peer; Xvfb, xdotool and xclip versions and the peer OS build not recorded; metadata reference exceeds the schema maxLength of 512 (deviation, no byte impact)."
  ],
  "ambiguousFields": [
    {"fieldId": "barrier-client-dclp-field-layout-in-this-fixture", "observation": "All client DCLP body bytes are zero-filled; no field is observable in this fixture.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-keepalive-timing-and-timeout", "observation": "Not retained; reviewer-verified from non-retained raw data only.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-client-close-behavior", "observation": "The fixture ends at the last client DCLP frame; no close frame was observed, the connection simply ended.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-cclp-to-client", "observation": "A server-to-client CCLP was never captured in any retained fixture.", "status": "unknown", "blockedClaimIds": []}
  ],
  "prohibitedInferences": [
    "Do not infer any client-to-server DCLP field, mark or size from this entry.",
    "Do not infer a keepalive interval, timeout or close protocol from this entry.",
    "Do not infer clipboard content handling, format semantics or the meaning of clipboard id 1.",
    "Do not infer TLS, certificate, macOS-server or Windows behavior.",
    "Do not fill unknown bytes from model output, Barrier or Deskflow source, analogy or memory."
  ],
  "frozenContractRefs": [],
  "consumingTests": []
}
```

```json
{
  "evidenceId": "BARRIER-EVID-0008",
  "relatedIssue": "M2-022",
  "source": {
    "category": "black-box-capture",
    "acquisitionMethod": "Controlled black-box observation of the same two lawfully installed external Barrier 2.4.0 programs and topology as BARRIER-EVID-0006, operated by evidence/e2e/M2-022/tools/capture_punctuation_clipboard.py on 2026-10-29: the server clipboard set with xclip to the fixed non-personal probe string in the committed driver (36 UTF-8 bytes), enter, the eleven US punctuation keys plain and shifted by xdotool, the client clipboard set with xclip to the second fixed probe (37 UTF-8 bytes), leave, a second enter and leave. The driver's own checks that each peer's clipboard matched the other's probe after enter and after leave passed (markers in the raw stream, verified by the reviewer). Direction labels are the relay's socket roles. No Barrier or Deskflow source, header, constant table, generated artifact, decompiled material, patched binary, injected packet or instrumentation was used for the bytes."
  },
  "capture": {
    "capturedAt": "<PRODUCER MUST RECORD THE UTC CAPTURE TIME; only the date 2026-10-29 is recorded. Entry may not be appended with this placeholder>",
    "tools": [
      {"name": "Barrier barriers", "version": "2.4.0-release protocol 1.6"},
      {"name": "Barrier barrierc", "version": "2.4.0-release protocol 1.6"},
      {"name": "evidence/e2e/M2-022/tools/capture_punctuation_clipboard.py", "version": "commit 6578b49"},
      {"name": "evidence/e2e/M2-022/tools/make_punctuation_clipboard_fixture.py", "version": "commit 6578b49"},
      {"name": "Xvfb", "version": "not-recorded"},
      {"name": "xdotool", "version": "not-recorded"},
      {"name": "xclip", "version": "not-recorded"},
      {"name": "python3 on the peer", "version": "3.10.16"}
    ]
  },
  "peer": {
    "product": "Barrier",
    "version": "2.4.0-release",
    "role": "client-and-server",
    "os": {"name": "Ubuntu", "version": "22.04", "build": "not-reported"}
  },
  "transport": {
    "networkScope": "Loopback only on the test host through the byte-logging relay, as in BARRIER-EVID-0006. No address, port, host name or user name is retained.",
    "tls": {"enabled": false, "protocolVersion": null, "certificateIdentitySanitized": true}
  },
  "provenance": {
    "lawfulUseStatement": "Both endpoints were lawfully installed external Barrier programs operated by their owner on a host under that owner's control, used only as external black-box test peers as M1-003 permits. Only externally observable application payload bytes were recorded, and clipboard content was zero-filled before commit.",
    "permittedUse": "Independent clean-room interoperability implementation inside the MacKVM Barrier compatibility adapter only: the plain and shifted punctuation key identifiers, the four-frame shifted-press sequence, and the DCLP header, mark, start-size and marshalled-structure layout in both directions for single-chunk transfers. It establishes no clipboard format semantics, no clipboard-id-1 semantics and no multi-chunk behavior.",
    "producer": "M2-022 capture producer (the executing agent of the 2026-10-29 addendum, evidence/e2e/M2-022/punctuation-clipboard.md), who also decoded the frames and built the fixture",
    "reviewer": {
      "identity": "Independent reviewer agent, not the producer; review recorded in the M2-022 independent review report (to be filed as evidence/issues/M2-022/independent-review.md), including re-derivation of the fixture byte for byte from the producer's raw stream before its deletion",
      "independentFromProducer": true,
      "reviewedAt": "2026-10-29T03:41:32Z"
    },
    "disposition": "approved"
  },
  "sanitization": {
    "procedure": "evidence/e2e/M2-022/tools/make_punctuation_clipboard_fixture.py reassembles complete frames per direction and retains sequence number, direction label and base64 of each frame; timestamps, markers, addresses and ports never enter the fixture. In every DCLP mark-2 frame the marshalled clipboard keeps its structure (format count, format ids, sizes) while each format's content bytes are replaced by zero bytes of the same length; the reviewer confirmed that every format content in frames 11 and 170 is all-zero (sizes 36/54/0 and 37/54/0) and that no probe, host, user, path, address or certificate bytes exist anywhere in the fixture. The retained key frames encode exactly the synthetic punctuation sweep listed in the committed driver, confirmed marker by marker against the raw stream.",
    "status": "sanitized",
    "containsSensitiveData": false,
    "removedCategories": ["clipboard-payload", "ip-address", "other-private-data"]
  },
  "fixture": {
    "path": "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json",
    "sha256": "3851b910daa68b30631418c4f26e3fc1f0569c28827c23f48304cf9ccbfcb41f",
    "byteLength": 23530
  },
  "coverage": {
    "direction": "bidirectional",
    "behaviors": [
      "181 complete frames: handshake (1-7); CINN sequence 1 (8); server clipboard id 0 sent as start 118, one 118-byte chunk and end, then id 1 as start 4, chunk 00000000 and end, all sequence 0, with one CALV interleaved inside each transfer (9-16); CNOP and CALV replies; 33 DKDN/DKUP pairs for the punctuation sweep (31-164); client CCLP id 0 sequence 1 after the client copy (166); server COUT (167); client DCLP start 119, one 119-byte chunk and end, all sequence 1 (169-171); second CINN sequence 3 (175) with no DCLP following; COUT (177).",
      "Format 0's size equals the UTF-8 byte length of the probe set on the sending display (36 server, 37 client); format 1 was 54 bytes in both transfers despite the different probes, so its content is not a text-derived rendering of the probe; format 2 was 0 bytes in both. Content bytes are zero-filled and no format meaning is observable."
    ],
    "wireClaims": [
      {
        "claimId": "BARRIER-EVID-0008-CLAIM-001",
        "assertion": "For the eleven US punctuation keys the server sent DKDN/DKUP with these key identifiers (plain, shifted) and buttons: minus 0x002D/0x005F 20; equal 0x003D/0x002B 21; bracketleft 0x005B/0x007B 34; bracketright 0x005D/0x007D 35; backslash 0x005C/0x007C 51; semicolon 0x003B/0x003A 47; apostrophe 0x0027/0x0022 48; grave 0x0060/0x007E 49; comma 0x002C/0x003C 59; period 0x002E/0x003E 60; slash 0x002F/0x003F 61. A shifted press is four frames: DKDN Shift 0xEFE1 mask 0 button 50; DKDN shifted id mask 0x0001; DKUP Shift mask 0x0001; DKUP plain id mask 0, same button as the down. Buttons are this server's X keycodes.",
        "establishedFieldIds": ["barrier-server-punctuation-key-identifiers", "barrier-server-shifted-press-four-frame-sequence"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/30/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/34/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/36/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/38/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/40/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/48/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/60/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/72/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/84/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/96/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/108/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/123/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/135/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/147/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/159/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0008-CLAIM-002",
        "assertion": "DCLP in both directions carries id (1 byte), a 4-byte big-endian sequence, mark (1 byte) and a 4-byte big-endian length followed by exactly that many data bytes. Marks were sent in the order 1, 2, 3 with no other frame of the transfer between them other than the server's interleaved CALV at enter; mark-1 data is the decimal ASCII byte length of the mark-2 data (118 for 118, 4 for 4, 119 for 119); mark-3 data is empty. The server's transfers carried sequence 0; the client's transfer carried sequence 1, the sequence of the CINN in force, as did its preceding CCLP.",
        "establishedFieldIds": ["barrier-dclp-header-layout-both-directions", "barrier-dclp-start-chunk-end-marks", "barrier-dclp-start-data-decimal-length", "barrier-client-dclp-sequence-equals-enter-sequence"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/8/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/10/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/11/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/12/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/14/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/15/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/165/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/168/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/169/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/170/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0008-CLAIM-003",
        "assertion": "The mark-2 data of a non-empty transfer is a 4-byte big-endian format count followed, per format, by a 4-byte big-endian format id, a 4-byte big-endian size and that many content bytes, with no trailing bytes: count 3 with ids 0, 1, 2 and sizes 36, 54, 0 (server to client) and 37, 54, 0 (client to server); an empty clipboard is count 0. Format 0's size equals the UTF-8 byte length of the probe on the sending display in both transfers. No format's meaning is established: content is zero-filled, and format 1's identical 54-byte size for two probes of different length shows it is not a rendering of the probe text.",
        "establishedFieldIds": ["barrier-dclp-marshalled-clipboard-structure", "barrier-dclp-format-0-size-equals-utf8-probe-length"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/10/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/14/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/169/applicationPayloadBase64",
          "evidence/e2e/M2-022/tools/capture_punctuation_clipboard.py"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0008-CLAIM-004",
        "assertion": "After the client had sent CCLP and its DCLP transfer, the second CINN (sequence 3) was followed directly by COUT with no DCLP from the server. The same absence occurs in BARRIER-EVID-0006 where no client copy happened, so this observation does not discriminate clipboard ownership from a no-resend-on-re-enter rule.",
        "establishedFieldIds": ["barrier-server-no-dclp-on-second-enter-observed"],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/174/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json#/observations/176/applicationPayloadBase64"
        ]
      }
    ]
  },
  "limitations": [
    "One session; exactly one non-empty transfer per direction, each a single chunk; no transfer larger than 119 bytes is retained. Chunking of large clipboards was measured by the producer (evidence/e2e/M2-022/punctuation-clipboard.md, 32 KiB chunks) but no artifact of that measurement is in the repository; it is not a claim of this entry.",
    "Format and clipboard-id semantics are unknown. The producer's labels (format 0 UTF-8 text, 1 HTML, 2 bitmap; id 1 primary selection) are not supported by any observation and their source is not recorded; the first-party sources that repeat them must be corrected to cite nothing beyond this entry.",
    "The UTC capture time was not recorded by the producer; only the date 2026-10-29 is known. This entry cannot be appended until the producer records it.",
    "The raw stream (SHA-256 07c968ef836652e711edda57f3d19929072877ea668cffa1b39b5123041f2d65) was held by the producer outside the repository; the reviewer re-derived the fixture from it byte for byte with the committed builder before any deletion.",
    "TLS disabled for observation only; no macOS or Windows peer; Xvfb, xdotool and xclip versions and the peer OS build not recorded; the fixture is not yet listed in evidence/e2e/M2-022/result.json; metadata reference exceeds the schema maxLength of 512 (deviation, no byte impact)."
  ],
  "ambiguousFields": [
    {"fieldId": "barrier-dclp-format-id-semantics", "observation": "Content is zero-filled; only sizes are observed. Format 1 is 54 bytes for two different probes; format 2 is 0 bytes.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-clipboard-id-1-semantics", "observation": "Id 1 was always empty.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-dclp-multi-chunk-transfers-and-size-limits", "observation": "Only single-chunk transfers are retained; the producer's chunk measurement is not an artifact in the repository.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-dclp-sequence-values-other-than-zero", "observation": "Server transfers carried sequence 0 only.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-server-cclp-to-client", "observation": "Never captured in a retained fixture.", "status": "unknown", "blockedClaimIds": []},
    {"fieldId": "barrier-clipboard-ownership-on-re-enter", "observation": "No DCLP after the second enter, but the same absence occurs without a client copy; ownership semantics are not discriminated.", "status": "unknown", "blockedClaimIds": []}
  ],
  "prohibitedInferences": [
    "Do not infer clipboard format meaning, encoding of formats 1 and 2, or the meaning of clipboard id 1 from this entry.",
    "Do not infer chunk sizes, maximum sizes or multi-chunk reassembly from this entry.",
    "Do not infer a clipboard-ownership rule from the absence of DCLP after the second enter.",
    "Do not infer that the punctuation identifiers or buttons hold for other keymaps, servers or platforms.",
    "Do not fill unknown bytes from model output, Barrier or Deskflow source, analogy or memory; the producer's unobservable labels are not evidence."
  ],
  "frozenContractRefs": [],
  "consumingTests": []
}
```

## 8. Conditions summary for the caller

Before any Linux client decoder starts (`docs/adr/M4-SCOPE-001-linux-client-first.md:104-107`):

1. Fix the write-ups: F2 labels withdrawn or sourced (and corrected in `BarrierClipboard.swift:11`, `BarrierServerProtocolSession.swift:402`, `decode_stream.py:60`); F5 wording; F6 inferences marked as such; README "Artifacts" lists the punctuation fixture.
2. Complete the record: `result.json` with `sanitizationReviewed: true`, all artifacts `reviewed`, the two punctuation artifacts, a case and `endedAt` for 2026-10-29, the UTC capture time and commit in the addendum, the full raw-stream hash, and `chunks.json` committed as a `sanitized-log` artifact if the chunk claims are to be kept.
3. Append `BARRIER-EVID-0006` and `0007`; append `0008` once `capturedAt` is recorded.
4. Then freeze the client-side contract entry and link the existing consumers (F1); update or supersede `docs/adr/M2-023`.
5. Decide the metadata `maxLength` deviation (F4) and record the missing tool versions (F8).
