# M1-WIRE-002 Discrimination Plan (capture preparation only)

GitHub Issue #279. Status: **pre-capture plan approved at 2026-10-02T08:41:12Z for one bounded capture
attempt**, as recorded by the independent reviewer (Codex, who is not the capture author) in
`evidence/issues/M1-WIRE-002/independent-review.md`. The approval authorizes no predicted
outcome and no width. Capture has not started. This plan predicts no result
and does not claim that `M1-025` is unblocked. `M1-025` stays blocked until a separately
reviewed outcome says otherwise.

## 1. Boundaries

- **Clean room.** Inputs are limited to the registered sanitized evidence (`BARRIER-EVID-0001`,
  `BARRIER-EVID-0002`), `docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`,
  `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`, documented product behavior, and
  black-box observation. No Barrier or Deskflow source, source-derived writeup, decompiled,
  disassembled, patched, hooked or instrumented output is consulted or produced.
- **Platforms.** Linux and/or macOS hosts that the owner controls. No Windows host is used.
- **No production code.** No Swift, parser, codec, framer or reassembler is added or changed.
  The partition walks below are evidence-only contract test helpers in Python stdlib.
- **TLS.** The MacKVM production TLS default stays enabled and fail-closed, and no MacKVM
  configuration, code or default changes. Any cleartext Barrier setting exists only inside the
  bounded, isolated, disposable evidence leg in section 6 and is torn down afterwards.
- **No predicted bytes.** This plan names observable conditions only. It does not predict any
  wire byte, length value, message, message type or payload layout.

## 2. Current ambiguity

The approved fixture holds 7 retained runs and 133 bytes. Two readings partition all of them:

- **Reading A:** consecutive frames each start with a 4-byte unsigned big-endian prefix whose
  value is the count of bytes that follow it in the same frame.
- **Reading B:** the recorded narrower reading, same rule with a 2-byte unsigned big-endian
  prefix (`alternativeReadings`, `runsPartitioned: 7` of 7).

All 11 candidate lengths under Reading A lie between 4 and 24, so every Reading A prefix
starts with two zero bytes. Reading B reads those as a zero-length frame followed by a 2-byte
prefix with the same value. That is why both readings consume the same bytes.

Arithmetic consequence (derived from the two rules, not from any predicted byte): every stream
that Reading A partitions with all prefix values below 65536 is also partitioned by Reading B.
Reading B frames that are not in the form `00 00 hi lo` can make Reading A fail, and Reading A
values of 65536 or more can make Reading B misalign. Neither outcome is guaranteed.
**Therefore a candidate length ≥ 256 alone is never proof, and a candidate length ≥ 65536 alone
is never proof.** Only a full-stream partition divergence under section 4 counts.

Reviewer check R0: confirm that the Reading B rule above is exactly the 2-byte big-endian
algorithm recorded by `M1-WIRE-001`, including that zero-length frames are admitted. If it is
not, STOP and revise this plan before any capture.

## 3. Normal-use candidate action

- **Action.** Ordinary Barrier clipboard sharing between a server-role and a client-role host,
  using the product's documented clipboard feature from the normal desktop session.
- **Data.** Deterministic, synthetic, non-personal text made on the capture host by a recorded
  generator (fixed ASCII pattern, fixed seed, recorded size and SHA-256). No real user data,
  no clipboard history, and no other application content is used.
- **Size ladder.** A short, recorded sequence of increasing synthetic sizes, from small to
  large (multi-megabyte at most), each copied once, so that the product has the chance to emit
  diverse frame lengths. The ladder is exploratory: no size is claimed to produce any specific
  frame length, frame count, chunking, or divergence, and no numeric threshold is claimed to
  prove a width.
- **Lifecycle.** Connect → idle settle → clipboard ladder → idle settle → normal client
  disconnect via the product UI or process quit. Every step gets a UTC timestamp in `manual.md`.
- If the product refuses the action, truncates it, or needs non-product behavior (scripts
  injecting into Barrier, forced oversize, modified binaries), STOP (stop condition 2).

## 4. Mechanical analysis rule

### 4.1 Stream construction

- The unit of analysis is the **complete ordered application byte stream per direction** of
  each in-scope TCP connection (server-to-client and client-to-server).
- The stream is built by ordering TCP segment payloads by sequence number and concatenating
  them. Retransmitted duplicates must be byte-identical and are counted once. Any conflicting
  overlap or sequence gap fails the completeness checks in section 5.
- Packet, read, run and capture-tool record boundaries are **never** treated as frame
  boundaries. They are kept as metadata only. In this issue a "retained run" is a complete
  direction stream.

### 4.2 Partition walk (the same function for both readings, parameterized by width `w`)

```
walk(S, w):           # S = complete direction stream bytes, w in {4, 2}
  off = 0
  while off < len(S):
    if len(S) - off < w:  FAIL(off, "leftover-bytes", remaining = len(S) - off)
    L = unsigned big-endian integer of S[off : off + w]
    if off + w + L > len(S):  FAIL(off, "overrun", declared = L, available = len(S) - off - w)
    off = off + w + L
  SUCCESS(frames, final offset == len(S))
```

- How the issue's failure classes map here: *leftover bytes* → `leftover-bytes`; *overrun* →
  `overrun`. *Boundary mismatch* and *length disagreeing with the observed run length* both
  show up as one of those two codes at the last frame, because the only required boundaries
  are stream start (offset 0) and stream end (externally observed close, section 5). The code
  and offset are always recorded.
- Zero-length frames are admitted by both readings. No other plausibility filter is applied.
- Exactly the same bytes go to `walk(S, 4)` and `walk(S, 2)` for every required stream.

### 4.3 Outcome rule

- A reading **succeeds** only if it returns SUCCESS on every required complete direction stream.
- **Discriminating:** exactly one reading succeeds, and the other fails on at least one required
  stream. Record every failing stream, its first failing offset, the reason code, and the
  declared/available values.
- **Still ambiguous → STOP:** both readings succeed, or both fail on any required stream set.
  `M1-025` stays blocked (stop condition 7). The plan is not changed after capture to escape
  a stop.
- Consistency check: the surviving reading is also re-applied to the `BARRIER-EVID-0001` runs,
  which both readings already partition. This check is recorded but proves nothing.

## 5. Completeness preconditions

A direction stream is analyzable only if all of the following hold. Otherwise STOP and record
the stream as incomplete. Partial streams are never analyzed for width.

1. The connection lifecycle is bounded inside the capture window: the connection start
   (handshake) and an externally observed close (FIN in both directions) are both captured.
   An explicit RST counts only if the reviewer agrees before capture that it is an equally
   explicit end condition. A timeout or "capture stopped" is not an end condition.
2. There are no sequence gaps from the first payload byte to the close, and no conflicting
   overlaps.
3. The capture tool reports zero dropped packets, and the snap length captures full segments.
4. The in-scope connection is identified only by the configured Barrier port inside the
   window. Every in-scope connection in the window is analyzed. Cherry-picking is not allowed.
5. The sanitizer round-trip check in section 6 passes for every stream.

## 6. Capture topology and handling

**Roles (sanitized labels only):** `role-server` (Barrier server), `role-client` (Barrier
client), `role-capture` (the host that runs the capture tool and keeps raw data; it may be
`role-server` or `role-client`). Real host names, users, addresses and interfaces are never
written to committed files. Placeholders follow the `M1-024` convention.

**Isolation:** a dedicated, disposable evidence environment on an isolated link or segment with
no route to other networks. Any Barrier cleartext setting is applied only here and is recorded
as an evidence-only leg with its start/end UTC and teardown.

**Validity checks before the window opens (recorded in `environment.json`):** OS name/version
per role. Barrier package or build version and its origin and package SHA-256, as reported
by the product's own metadata. Capture tool name/version. Sanitizer version and SHA-256.
Clocks in UTC. Capture filter limited to the configured Barrier port. Isolated-segment check.
The reviewer approval timestamp is earlier than the capture start.

**Strict time window:** one capture window with a fixed maximum duration that is recorded before
start and enforced by a timeout wrapper. The window opens before connect and closes after the
observed close. If the time runs out first, the streams are incomplete (section 5).

**Cancellation and cleanup:** on any abort, stop the capture, record the reason and UTC time,
keep the partial raw data on `role-capture` under the same deletion process, and do not analyze
it for width. Afterwards, in all cases, clear the synthetic clipboard, restore or destroy the
disposable Barrier configuration, tear down the isolated segment, and record each step.

**Raw data location:** raw captures and the synthetic generator output never leave
`role-capture`. Only sanitizer output leaves it.

**Allowlist sanitizer (runs on `role-capture`):**
- It keeps per-direction stream byte lengths, connection lifecycle facts, and frame
  offsets/lengths under both readings.
- It keeps the actual bytes only at positions that either walk reads as a prefix in the raw
  stream, plus the already-registered marker and the 4 bytes after it.
- It fills every other byte with a documented constant. Because each walk's path depends only
  on the bytes it reads as prefixes, both walks over the sanitized stream must reproduce the
  raw results exactly. The sanitizer checks this round trip and fails closed on any difference.
- It drops all addresses, MACs, ports other than the documented placeholder, hostnames,
  usernames, screen names, timestamps finer than the recorded window, certificates and keys.
- **Privacy scan:** runs over the sanitized fixture and all committed evidence for addresses,
  hostnames, usernames, emails, keys, certificates, tokens, and any run of the synthetic pattern
  longer than the retained prefix windows. Any hit is a STOP (stop condition 6) until resolved
  without re-capture tuning.

**Reviewer re-derivation, then bounded deletion:**
- On `role-capture`, the reviewer independently re-runs stream construction, sanitization and
  both walks from raw. They confirm the same SHA-256 and byte length for every file, the same
  surviving reading (or the same stop), and the same failing stream, offset and reason.
- Only then are the listed raw files deleted with an exact, file-scoped command.
- `manual.md` records the raw file list, the SHA-256 and byte length of each file, the exact
  command, the UTC timestamp, and a post-deletion directory listing.
- No claim of secure erasure or forensic unrecoverability is made.

## 7. Reviewer checkpoints

1. **Before capture:** approve this plan (checklist below). No capture or SSH before it.
2. **Before raw deletion:** independent re-derivation on `role-capture` (section 6).
3. **Before merge:** register entry, sanitized fixture, hashes, privacy scan, ADR (only if
   exactly one width survives), and test results agree.

## 8. Source-validity stop conditions (from #279)

On any of these: STOP. Record it in `evidence/issues/M1-WIRE-002/summary.md`, append nothing to
the register as accepted width evidence, write no width ADR, and keep `M1-025` blocked.

1. Provenance (Barrier build origin, version, host environment, capture chain) is unavailable
   or invalid.
2. The observation cannot be produced safely through normal use without unsafe, unbounded or
   non-product behavior.
3. Source contamination: Barrier/Deskflow source, a source-derived writeup, or decompiled or
   instrumented output was consulted or could have influenced the plan, capture or derivation.
4. Telling the readings apart would require a Windows host.
5. The only path weakens production TLS or a fail-closed default, or goes beyond a bounded,
   isolated, documented evidence-only cleartext leg.
6. Raw data leaves `role-capture` before allowlist sanitization, or the sanitized output fails
   the privacy scan.
7. After capture, both readings partition all required streams, or neither does.

Plan-specific stops that use the same handling: R0 fails; a completeness precondition
(section 5) fails; the sanitizer round trip differs; the reviewer re-derivation disagrees; the
capture window or cleanup cannot be bounded. A stop is a valid result and is not bypassed by
changing this plan after capture.

## 9. Planned artifacts, tests and commands (created only after approval)

- `evidence/issues/M1-WIRE-002/`: `discrimination-plan.md` (this file), `independent-review.md`,
  `summary.md`, `manual.md`, `commands.json`, `environment.json`, `tests/e2e-validation.json`.
- `evidence/e2e/M1-WIRE-002/result.json`.
- `Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/` with the sanitized streams
  and `metadata.json` (provenance, versions, per-file SHA-256, stream offsets/lengths, both
  derived results). Created only if no stop occurs before sanitization.
- An appended register entry (expected `BARRIER-EVID-0003`) in `evidence/registers/M1-023.json`
  and `docs/evidence/M1-023-barrier-evidence-register.md`. `BARRIER-EVID-0001` and
  `BARRIER-EVID-0002` stay byte-for-byte unchanged.
- `docs/adr/M1-WIRE-002-barrier-length-prefix-width.md` only if exactly one width survives.
  The `M1-WIRE-001` ADR is not edited.
- `Tests/Contracts/test_m1_wire_002_length_prefix_evidence.py` (stdlib `unittest`), covering:
  artifact integrity; both walks over the fixture bytes with exactly one success and the
  recorded failing offset and reason (fails if both succeed or both fail); review-gate
  ordering; append-only register; separate ADR; privacy scan; raw deletion record; and an
  in-memory mutation proving that a both-succeed stream is rejected.
- The sanitizer and stream builder, if they need repository code, go under `Tools/Evidence/`
  with names fixed in the reviewed change. They contain no host, user, address or secret.
- Validation commands, run only after capture and sanitization:
  - `make verify`
  - `make e2e ISSUE=M1-WIRE-002`
  - `python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-WIRE-002/result.json --expected-issue M1-WIRE-002 --require-passed`
  - `python3 -m unittest Tests.Contracts.test_m1_wire_002_length_prefix_evidence -v`
  - `python3 -m unittest Tests.Contracts.test_m1_wire_001_contract_sequence Tests.Contracts.test_m1_024_capture_readiness -v`
  - `make backlog-check`
  - `make docs-check`

## 10. Honest limit of this plan

Because no wire bytes are predicted, this plan cannot show before capture that the planned
observation **will** diverge. It does show the following: the decision rule is mechanical and
the same for both readings; a length threshold alone cannot satisfy it; and every
non-divergent outcome ends in a STOP. The reviewer decides whether that meets #279's
discrimination requirement. If the reviewer finds that it does not, no capture occurs and
`M1-025` stays blocked.

## Reviewer pre-capture decision

Reviewer (not the capture author): ____________ UTC: ____________

- [ ] APPROVE / [ ] REJECT: clean-room boundary holds. No source, decompiled or instrumented
      input was used. Linux/macOS only. No Windows. No production Swift.
- [ ] APPROVE / [ ] REJECT: MacKVM production TLS stays on and fail-closed. Any cleartext
      Barrier leg is bounded, isolated, evidence-only and torn down.
- [ ] APPROVE / [ ] REJECT: R0, the Reading B rule, matches the recorded `M1-WIRE-001` 2-byte
      big-endian algorithm.
- [ ] APPROVE / [ ] REJECT: the clipboard action is normal use with deterministic synthetic
      non-personal data, and it predicts no bytes and asserts no proving threshold.
- [ ] APPROVE / [ ] REJECT: the analysis uses complete per-direction streams in sequence
      order, never read or run boundaries, and runs the identical walk for widths 4 and 2.
- [ ] APPROVE / [ ] REJECT: the outcome rule is exactly one success with the other failing at
      an exact offset and reason. Both succeed or both fail means STOP, and lengths ≥ 256 or
      ≥ 65536 alone are not proof.
- [ ] APPROVE / [ ] REJECT: completeness preconditions, including the bounded lifecycle and
      the externally observed close (and whether RST qualifies), are sufficient.
- [ ] APPROVE / [ ] REJECT: topology, validity checks, time window, cancellation and cleanup.
- [ ] APPROVE / [ ] REJECT: raw data stays on `role-capture`, the allowlist sanitizer round
      trip is sound, the privacy scan is adequate, re-derivation happens before deletion, and
      the deletion record makes no secure-erasure claim.
- [ ] APPROVE / [ ] REJECT: all seven #279 stop conditions and the plan-specific stops are
      complete, and none applies now.
- [ ] APPROVE / [ ] REJECT: the honest limit (section 10) is acceptable as meeting #279's
      discrimination requirement.
- [ ] FINAL: capture MAY proceed / capture MUST NOT proceed (`M1-025` stays blocked).
