# M1-WIRE-002 Discrimination Plan (capture preparation only)

GitHub Issue #279. Current status: **attempt 1 STOPPED (`client-not-connected`,
2026-10-05T07:09:55Z); attempt 2 STOPPED during pre-window check
(`baseline-direction-mismatch`, 2026-10-06T09:02:48Z); attempt 3 STOPPED after sanitizer
analysis (`STOP-BOTH-SUCCEED`, 2026-10-06T09:15Z); attempt 4 STOPPED after sanitizer analysis
(`STOP-BOTH-SUCCEED`, 2026-10-07T00:48Z); attempt 5 STOPPED before analyzable stream
construction (`file-transfer-runtime-unsupported`, 2026-10-07T04:36Z); attempt 6 STOPPED after
sanitizer analysis (`STOP-BOTH-SUCCEED`, 2026-10-07T04:47Z); all six approvals are consumed; a
seventh attempt STOPPED after runtime protocol error before accepted runtime connection success
(`protocol-error-before-runtime-connection-success`, 2026-10-07T05:45Z); all seven approvals
are consumed; no eighth attempt is proposed.**
Sections 1–10 below and the blank checklist after section 10 are kept unchanged as the
historical attempt-1 plan.

Attempt-1 status (historical): **amended after Checkpoint 1; re-approved for one bounded capture
attempt at 2026-10-05T00:00:44Z.** The independent reviewer (Codex, who is not the capture
author) recorded a pre-capture approval at 2026-10-02T08:41:12Z and an amended-topology
re-approval at 2026-10-05T00:00:44Z in `evidence/issues/M1-WIRE-002/independent-review.md`.
This amendment changes the capture topology (section 6): `role-server == role-capture` on
Linux, `role-client` on macOS, an SSH local forward as the encrypted inter-host leg, Barrier
cleartext only on two host-local loopback legs (macOS client to the SSH listener, and Linux
sshd forward exit to the Barrier server), and the Linux loopback leg as the only captured leg.
The amendment also places the synthetic generator on `role-client` and updates the
source-validity checks for macOS client provenance. Capture has not started. All pre-window
checks in section 6 remain mandatory, and any failure is a STOP before the window opens. No
approval authorizes a predicted outcome or a width. This plan predicts no result and does not
claim that `M1-025` is unblocked. `M1-025` stays blocked until a separately reviewed outcome
says otherwise.

## 1. Boundaries

- **Clean room.** Inputs are limited to the registered sanitized evidence (`BARRIER-EVID-0001`,
  `BARRIER-EVID-0002`), `docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md`,
  `evidence/issues/M1-WIRE-001/barrier-frame-conformance.json`, documented product behavior, and
  black-box observation. No Barrier or Deskflow source, source-derived writeup, decompiled,
  disassembled, patched, hooked or instrumented output is consulted or produced.
- **Platforms.** One Linux host (`role-server == role-capture`) and one macOS host
  (`role-client`), both controlled by the owner. No Windows host is used.
- **No production code.** No Swift, parser, codec, framer or reassembler is added or changed.
  The partition walks below are evidence-only contract test helpers in Python stdlib.
- **TLS.** The MacKVM production TLS default stays enabled and fail-closed, and no MacKVM
  configuration, code or default changes. Any cleartext Barrier setting exists only inside the
  bounded, isolated, disposable evidence legs in section 6 and is torn down afterwards. Between
  hosts, that Barrier traffic travels only inside the encrypted SSH local forward. It is
  cleartext only on two host-local loopback legs: the macOS Barrier client to the SSH
  local-forward listener on `role-client`, and the Linux sshd forward exit to the Barrier server
  on `role-server`. Both forward endpoints use loopback addresses only. Only the Linux loopback
  leg is captured.
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

- **Action.** Ordinary Barrier clipboard sharing between `role-server` (Linux) and
  `role-client` (macOS), using the product's documented clipboard feature from the normal
  desktop session.
- **Data.** Deterministic, synthetic, non-personal text made on `role-client` by a recorded
  generator (fixed ASCII pattern, fixed seed). The generator may run on `role-client` because
  its content is deliberately non-personal test data. `manual.md` and `environment.json` record
  the generator recipe and version, the size ladder, and the SHA-256 of each generated value.
  Only that metadata is committed. No generated value, and never a real clipboard value, is
  committed. No real user data, no clipboard history, and no other application content is used.
- **Data path.** The generator bytes intentionally travel the encrypted application path
  (macOS clipboard → Barrier client → macOS loopback → SSH local forward → Linux loopback →
  Barrier server).
  This is the observation itself. It is not raw capture data leaving a host. No raw capture
  leaves `role-capture` (section 6).
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
  each in-scope TCP connection (server-to-client and client-to-server). In-scope connections
  are on the Linux loopback leg between the sshd forward exit and the Barrier server. The
  forward relays an ordered byte stream. The plan does not assume that its segment boundaries
  match anything on the encrypted leg, and segment boundaries carry no meaning either way.
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
   (handshake) and an externally observed close (FIN in both directions) of the loopback-leg
   connection are both captured.
   An explicit RST counts only if the reviewer agrees before capture that it is an equally
   explicit end condition. A timeout or "capture stopped" is not an end condition.
2. There are no sequence gaps from the first payload byte to the close, and no conflicting
   overlaps.
3. The capture tool reports zero dropped packets, and the snap length captures full segments.
4. The in-scope connection is identified only by the loopback interface and the configured
   Barrier server port (recorded as a placeholder) inside the window. Every in-scope connection
   in the window is analyzed. Cherry-picking is not allowed.
5. The sanitizer round-trip check in section 6 passes for every stream.

## 6. Capture topology and handling

**Roles (sanitized labels only), fixed topology:**
- `role-server == role-capture`: one Linux host. It runs the Barrier server and the capture
  tool, and it keeps all raw data. On this host the capture tool runs without root, using
  packet-capture capabilities only.
- `role-client`: one macOS host. It runs the Barrier client, the SSH local-forward listener and
  the synthetic generator. No capture runs on macOS, because macOS cannot capture BPF traffic
  non-interactively.
- Real users, host names, IP addresses, interfaces and ports are never written to committed
  files. Placeholders follow the `M1-024` convention.

**Legs:**
- **Uncaptured cleartext leg (macOS loopback):** on `role-client`, the Barrier client connects
  to the SSH local-forward listener. The listener binds a loopback address only, never a
  wildcard or LAN address. Barrier traffic is cleartext on this host-local leg. It is not
  captured and not analyzed.
- **Encrypted inter-host leg:** the SSH channel from `role-client` to `role-server`. Barrier
  traffic between hosts exists only inside this SSH channel. This leg is not captured and not
  analyzed.
- **Captured cleartext leg (Linux loopback):** on `role-server`, the sshd forward exit connects
  to the Barrier server at a loopback destination address only. Barrier traffic is cleartext on
  this host-local leg. This is the only leg that is captured and analyzed.

**Isolation:** a dedicated, disposable evidence configuration. The Barrier cleartext setting is
applied only to this evidence configuration. Barrier cleartext exists only on the two
host-local loopback legs above, which have no route off their hosts, and its only inter-host
path is the encrypted SSH forward. Both legs are recorded as evidence-only legs with their
start/end UTC and teardown.

**Validity checks before the window opens (recorded in `environment.json`):**
- OS name/version per role.
- `role-server` Barrier provenance: the official Ubuntu Barrier package name, version, origin
  and package SHA-256, as reported by the package manager's own metadata.
- `role-client` Barrier provenance: the exact hash chain from the official upstream Barrier
  v2.4.0 DMG asset (size and SHA-256) to the installed `barrierc` and `barriers` binaries
  (each byte-identical to the DMG copy, with recorded SHA-256), plus the app bundle version
  `2.4.0-release`. This chain is the accepted macOS client provenance. The values the reviewer
  verified are: DMG size 29056360, DMG SHA-256
  `af938d17dcea5701da7a990705acbd0686dfedfdbcd64721666ae0bef7644ba9`; `barrierc` SHA-256
  `53369a4579223e0f8742b897d96b6a9a6c3abc9f6ef9c4fec2779b0ef7bd5715`; `barriers` SHA-256
  `2ad6d3b9b9d6dd8cb4bb403cea91f026d896842c5ba0134891daf90f8ef846b5`. They are re-checked
  inside the bounded attempt, and any mismatch is a STOP (stop condition 1).
- **Recorded limitation:** on macOS, `barrierc --version` from the CLI aborts and reports no
  version. This is recorded as a limitation in `environment.json` and `manual.md`, not hidden
  and not worked around. The hash chain and bundle version above stand in for it. The GUI
  launch runs.
- **Runtime connection success** is still required: inside the bounded attempt, the macOS
  client must connect through the forward to the Linux server and the product must report the
  connection. If the connection fails, STOP (stop condition 1). Retries outside the recorded
  window are not allowed.
- Capture tool name/version and its non-root capability configuration on `role-capture`.
  Sanitizer version and SHA-256. Generator recipe/version. Clocks in UTC.
- The capture filter is limited to the loopback interface and the configured Barrier server port.
- An SSH-forward check: the inter-host leg is the SSH channel only.
- A loopback-only binding check on both forward endpoints: on `role-client`, the SSH
  local-forward listener is bound to a loopback address only and not to a wildcard or LAN
  address; on `role-server`, the forward destination is a loopback address only.
- An SSH forward fail-fast check: the SSH session is configured to exit if the local forward
  cannot be established (for example `ExitOnForwardFailure yes`), so it never runs without the
  forward.
- If any of these checks fails, STOP before the window opens.
- The reviewer re-approval timestamp for this amended plan is earlier than the capture start.

**Strict time window:** one capture window with a fixed maximum duration that is recorded before
start and enforced by a timeout wrapper. The window opens before connect and closes after the
observed close. If the time runs out first, the streams are incomplete (section 5).

**Cancellation and cleanup:** on any abort, stop the capture, record the reason and UTC time,
keep the partial raw data on `role-capture` under the same deletion process, and do not analyze
it for width. Afterwards, in all cases, clear the synthetic clipboard on both roles, delete
the local generator output on `role-client`, restore or destroy the disposable Barrier
configuration on both roles, tear down the SSH local forward, and record each step.

**Raw data location:** raw captures never leave `role-capture`. Only sanitizer output leaves
it. The synthetic generator output is made on `role-client`. It reaches `role-server` only as
Barrier application traffic through the encrypted SSH forward, as section 3 describes, and is
never copied anywhere as a file. Only generator metadata (recipe, version, size ladder,
SHA-256) is committed.

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

1. **Before capture:** approve this plan (checklist below). No capture or SSH before it. The
   2026-10-02T08:41:12Z approval came before the topology amendment. The topology amendment
   was re-approved at 2026-10-05T00:00:44Z, as recorded in `independent-review.md`. Capture
   may proceed only after all section 6 pre-window checks pass. That approval was consumed by
   attempt 1. Attempt 2 needs a new Checkpoint 1 decision on section 11.
2. **Before raw deletion:** independent re-derivation on `role-capture` (section 6).
3. **Before merge:** register entry, sanitized fixture, hashes, privacy scan, ADR (only if
   exactly one width survives), and test results agree.

## 8. Source-validity stop conditions (from #279)

On any of these: STOP. Record it in `evidence/issues/M1-WIRE-002/summary.md`, append nothing to
the register as accepted width evidence, write no width ADR, and keep `M1-025` blocked.

1. Provenance (Barrier build origin, version, host environment, capture chain) is unavailable
   or invalid. For `role-client` this includes any break in the official-DMG-to-binary hash
   chain or a bundle version other than `2.4.0-release`. The recorded CLI `--version` abort
   alone is not a stop. A runtime connection failure inside the bounded attempt is a stop.
2. The observation cannot be produced safely through normal use without unsafe, unbounded or
   non-product behavior.
3. Source contamination: Barrier/Deskflow source, a source-derived writeup, or decompiled or
   instrumented output was consulted or could have influenced the plan, capture or derivation.
4. Telling the readings apart would require a Windows host.
5. The only path weakens production TLS or a fail-closed default, or goes beyond bounded,
   isolated, documented evidence-only cleartext legs.
6. Raw data leaves `role-capture` before allowlist sanitization, or the sanitized output fails
   the privacy scan.
7. After capture, both readings partition all required streams, or neither does.

Plan-specific stops that use the same handling: R0 fails; a completeness precondition
(section 5) fails; a loopback-only binding or SSH forward fail-fast check (section 6) fails;
the sanitizer round trip differs; the reviewer re-derivation disagrees; the
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
- [ ] APPROVE / [ ] REJECT: MacKVM production TLS stays on and fail-closed. Both host-local
      cleartext Barrier loopback legs are bounded, isolated, evidence-only and torn down.
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
- [ ] APPROVE / [ ] REJECT: the amended topology (`role-server == role-capture` on Linux,
      `role-client` on macOS, SSH local forward as the encrypted inter-host leg, cleartext only
      on the macOS and Linux host-local loopback legs, the Linux loopback leg as the only
      captured leg), validity checks (including macOS hash-chain provenance, the recorded CLI
      `--version` limitation, the required runtime connection success, loopback-only bindings
      on both forward endpoints with no wildcard/LAN listener, and SSH forward fail-fast), time
      window, cancellation and cleanup.
- [ ] APPROVE / [ ] REJECT: the synthetic generator on `role-client` is acceptable, only
      generator metadata is committed, and no raw capture leaves `role-capture`.
- [ ] APPROVE / [ ] REJECT: raw data stays on `role-capture`, the allowlist sanitizer round
      trip is sound, the privacy scan is adequate, re-derivation happens before deletion, and
      the deletion record makes no secure-erasure claim.
- [ ] APPROVE / [ ] REJECT: all seven #279 stop conditions and the plan-specific stops are
      complete, and none applies now.
- [ ] APPROVE / [ ] REJECT: the honest limit (section 10) is acceptable as meeting #279's
      discrimination requirement.
- [ ] FINAL: capture MAY proceed / capture MUST NOT proceed (`M1-025` stays blocked).

## 11. Amended second-attempt plan (proposed, pending independent review)

Status: **STOPPED.** This section was approved for one bounded attempt, which ran at
`2026-10-07T05:44:59Z` and stopped at `2026-10-07T05:45:33Z` with
`protocol-error-before-runtime-connection-success`. It records no accepted fixture, register
entry, ADR or width.

### 11.1 Attempt 1 is preserved as historical evidence

- Attempt 1 ran under the 2026-10-05T00:00:44Z re-approval and stopped at the required runtime
  connection gate with fixed label `client-not-connected` (2026-10-05T07:09:55Z). That stop was
  source-validity stop condition 1 (section 8) and is a valid, final result for attempt 1.
- The attempt-1 records stay as written: `summary.md` (stop reason, evidence handling,
  restoration) and the `Runtime attempt result — 2026-10-05T07:11:18Z` entry in
  `independent-review.md`. They are not rewritten, reinterpreted or reused as capture input.
  The 24-byte header-only raw file from attempt 1 is not analyzed and is not an input to
  attempt 2.
- The cause of `client-not-connected` is not established in this repository. This amendment
  does not claim one and does not depend on one.

### 11.2 Why a new reviewer approval is required

- Both prior approvals (2026-10-02T08:41:12Z and 2026-10-05T00:00:44Z) authorized exactly one
  bounded attempt. That attempt has been used. Its re-approval conditions state that a runtime
  connection failure "stops without an unreviewed retry".
- Section 6 forbids retries outside the recorded window, and section 8 says a stop is not
  bypassed by changing the plan after the fact. A second attempt is therefore a new bounded
  experiment, not a continuation of attempt 1, and needs its own independent approval.
- The baseline in 11.3 is new to the plan, so the reviewer must check it against the
  clean-room, TLS and privacy boundaries before it is used.
- Required ordering: the reviewer (not the capture author) records a Checkpoint 1 decision for
  this section in `independent-review.md`, with a UTC timestamp that is later than this
  amendment's commit and earlier than any attempt-2 pre-window check. Without that record,
  attempt 2 MUST NOT start.

### 11.3 Second-attempt baseline: the owner-confirmed normal-use session

- The owner has confirmed a working Barrier normal-use session with the Linux host as Barrier
  server and the macOS host as Barrier client. Attempt 2 may use that session's installed
  products and normal-use pairing as its baseline, only after the fresh pre-window checks in
  11.4 pass.
- **Recorded discrepancy for the reviewer:** the attempt-1 restoration record lists the
  restored owner session as `barriers` (server) on the macOS role and `barrierc` (client) on
  the Linux role, which is the opposite direction. This amendment does not resolve that
  difference. Fresh check 11.4(2) decides it at runtime. If the observed direction is not
  Linux server to macOS client, STOP before the window opens.
- Using the owner session as a baseline does not relax anything else. Sections 1–10 stay in
  force for attempt 2, including: Linux/macOS only, no Windows; no Barrier or Deskflow source,
  source-derived writeup, decompiled or instrumented material; no production Swift; MacKVM
  production TLS stays enabled and fail-closed, and no MacKVM configuration, code or default
  changes; no predicted wire byte, length, message, layout or proving threshold; the section 6
  topology, loopback-only legs, SSH-forward fail-fast, raw locality, sanitizer, privacy scan
  and bounded deletion; and the fixed section 4 predicate, section 5 completeness rules and
  the FIN-in-both-directions requirement (RST does not qualify).
- The owner session is never captured as-is. Barrier cleartext is permitted only inside the
  disposable evidence configuration on the two host-local loopback legs of section 6. The
  owner's own configuration is backed up before attempt 2 and restored afterwards, and each
  step is recorded, as in attempt 1.

### 11.4 Fresh pre-window checks for attempt 2

All of the following are performed fresh for attempt 2 and recorded with UTC timestamps in
`environment.json` and `manual.md` before the capture window opens. Results from attempt 1 do
not satisfy any of them. Any failure is a STOP before the window opens, and no capture
starts.

1. The new reviewer approval for section 11 exists and its timestamp precedes this check.
2. Baseline session check: on the unmodified owner session, the Linux role runs the Barrier
   server, the macOS role runs the Barrier client, and the product reports the client as
   connected. Only process names and product connection status are recorded; no address,
   host name, user name or port value is written to committed files.
3. All section 6 validity checks, re-run in full: OS versions, Linux package provenance, the
   exact macOS official-DMG-to-binary hash chain and bundle version `2.4.0-release`, capture
   tool and non-root capability, sanitizer version and SHA-256, generator recipe and version,
   UTC clocks, the loopback-only capture filter, SSH-forward-only inter-host leg, loopback-only
   bindings on both forward endpoints, and SSH forward fail-fast.
4. The owner configuration backup and restore procedure on both roles is re-verified before
   the baseline session is paused.
5. The fixed maximum window duration and the graceful-only stop and timeout wrappers that were
   reviewed for attempt 1 are recorded unchanged, or any change is listed for the reviewer.

### 11.5 Attempt-2 limits and outcome handling

- Exactly one bounded attempt. The runtime connection through the evidence configuration must
  succeed once inside the window; if it does not, STOP with a fixed label, restore the owner
  session, and record the result. A third attempt requires another plan amendment and another
  independent approval.
- Attempt 2 produces no fixture, register entry or ADR unless it reaches the section 9 flow
  after a discriminating result, and then only through Checkpoints 2 and 3.
  `BARRIER-EVID-0001`, `BARRIER-EVID-0002` and the `M1-WIRE-001` ADR stay unchanged.
- `M1-025` stays blocked until a register entry with accepted, independently reviewed
  discriminating width evidence exists. A connection success, a long candidate length, or a
  completed attempt without exactly one surviving reading does not unblock it.

### 11.6 Reviewer decision for section 11

Reviewer (not the capture author) records the decision in `independent-review.md`:

- [ ] APPROVE / [ ] REJECT: attempt 1 is preserved unchanged and is not reused as capture input.
- [ ] APPROVE / [ ] REJECT: the owner-confirmed Linux-server to macOS-client session is an
      acceptable normal-use baseline, and the recorded direction discrepancy is handled by
      fresh check 11.4(2).
- [ ] APPROVE / [ ] REJECT: sections 1–10 boundaries apply unchanged: no Windows, no source,
      no production Swift, no production TLS or default change, no byte prediction.
- [ ] APPROVE / [ ] REJECT: the 11.4 fresh pre-window checks are complete and each failure
      stops before the window opens.
- [ ] APPROVE / [ ] REJECT: exactly one bounded attempt; any further retry needs a new review.
- [ ] FINAL: attempt 2 MAY proceed after all 11.4 checks pass / attempt 2 MUST NOT proceed
      (`M1-025` stays blocked).

## 12. Amended third-attempt plan (proposed, pending independent review)

Status: **PROPOSED. NOT APPROVED. NOT STARTED.** This section is a plan amendment only. It
records no capture, fixture, register entry, ADR or width.

### 12.1 Attempts 1 and 2 are preserved as stopped

- Attempt 1 ran under the 2026-10-05T00:00:44Z re-approval and stopped at the required runtime
  connection gate with fixed label `client-not-connected` (2026-10-05T07:09:55Z). Its 24-byte
  header-only raw file is not analyzed and is not an input to attempt 3.
- Attempt 2 ran only to the section 11.4 pre-window baseline check and stopped before the
  capture window opened with fixed label `baseline-direction-mismatch`
  (2026-10-06T09:02:48Z). No SSH evidence configuration, disposable cleartext leg, raw
  capture, fixture, register entry or width ADR was produced.
- Both stops remain valid final results for their attempts. This amendment does not rewrite,
  reinterpret or reuse them as capture input.
- Section 11's Linux-server to macOS-client baseline is not rescued or retried. Section 12 is
  a new bounded experiment based only on the observed normal-use direction from the attempt-2
  pre-window check: macOS Barrier server to Linux Barrier client. No Barrier or Deskflow source
  or source-derived material is used.

### 12.2 Why a new reviewer approval is required

- Section 11 approved exactly one second bounded attempt and explicitly said any further retry
  requires another plan amendment and another independent approval. That approval was consumed
  by the `baseline-direction-mismatch` stop.
- Section 8 says a stop is not bypassed by changing the plan after the fact. Attempt 3 is
  therefore a new bounded experiment, not a continuation of attempts 1 or 2.
- Required ordering: the reviewer (not the capture author) records a Checkpoint 1 decision for
  this section in `independent-review.md`, with a UTC timestamp later than this amendment's
  commit and earlier than any attempt-3 pre-window check. Without that record, attempt 3 MUST
  NOT start.

### 12.3 Third-attempt baseline and topology

Attempt 3 may use the observed owner normal-use direction, macOS Barrier server to Linux
Barrier client, only after the fresh pre-window checks in 12.5 pass.

Roles for attempt 3:

- `role-server`: macOS host. It runs the Barrier server in the disposable evidence
  configuration. No capture runs on macOS.
- `role-client == role-capture`: Linux host. It runs the Barrier client, the capture tool and
  the raw/sanitization workflow. Raw capture data stays on this host.

Legs for attempt 3:

- **Captured cleartext leg (Linux loopback):** the Linux Barrier client connects to a Linux
  loopback remote-forward listener served by the Linux SSH daemon. This is the only leg that is
  captured and analyzed.
- **Encrypted inter-host leg:** a macOS-initiated SSH session to the Linux host carries the
  remote forward. Barrier traffic between hosts exists only inside this SSH channel.
- **Uncaptured cleartext leg (macOS loopback):** the macOS SSH client remote-forward exit
  connects to the macOS Barrier server at a loopback destination only. This leg is not captured
  or analyzed.

The evidence configuration must not modify Linux `sshd_config`. If remote forwarding is not
allowed, the listener is not loopback-only, the macOS destination is not loopback-only, or the
SSH session cannot be configured fail-fast, STOP before the capture window opens.

The owner session is never captured as-is. Barrier cleartext is permitted only inside the
disposable evidence configuration on the two host-local loopback legs above. The owner's own
configuration is backed up before attempt 3 and restored afterwards, with each step recorded.

### 12.4 Mapping of sections 1–10 under attempt 3

Sections 1–10 remain in force unless this section explicitly remaps a role or leg:

- Sections 1 and 8: Linux/macOS only; no Windows; no Barrier or Deskflow source,
  source-derived writeup, decompiled or instrumented material; no production Swift; MacKVM
  production TLS stays enabled and fail-closed, and no MacKVM configuration, code or default
  changes.
- Section 3: the deterministic synthetic generator remains on the macOS host. The normal-use
  data path becomes macOS clipboard -> Barrier server -> macOS loopback -> SSH remote forward
  -> Linux loopback -> Barrier client. Only generator metadata is committed.
- Section 4.1: the in-scope connection is the complete ordered application byte stream per
  direction on the Linux loopback leg between the Barrier client and the remote-forward
  listener. Packet, read, run and capture-tool record boundaries still carry no frame meaning.
- Sections 4.2 and 4.3: the `walk(S, 4)` and `walk(S, 2)` predicate is unchanged. Both
  readings receive identical complete bytes. Exactly one success is required; both-success,
  both-fail or incomplete results STOP.
- Section 5: FIN in both directions remains required; RST does not qualify. The in-scope
  connection is identified by Linux loopback interface plus a documented remote-forward
  listener port placeholder. Cherry-picking is not allowed.
- Section 6 validity checks are remapped to the roles above. Linux provenance applies to the
  official Ubuntu Barrier client binary. macOS provenance applies to the official upstream DMG
  hash chain, with `barriers` as the server binary of interest and the recorded CLI
  `--version` limitation still disclosed.
- The sanitizer and privacy scan keep the same allowlist policy. Any change from a "server
  port" placeholder to a "remote-forward listener port" placeholder is a sanitizer identity
  change that must be listed for reviewer approval before execution.

### 12.5 Fresh pre-window checks for attempt 3

All of the following are performed fresh for attempt 3 and recorded with UTC timestamps in
`environment.json` and `manual.md` before the capture window opens. Results from attempts 1 or
2 do not satisfy any of them. Any failure is a STOP before the window opens, and no capture
starts.

1. The new reviewer approval for section 12 exists and its timestamp precedes this check.
2. Baseline session check: on the unmodified owner session, the macOS role runs the Barrier
   server, the Linux role runs the Barrier client, and the product reports the client as
   connected. Only process names and product connection status are recorded; no address,
   host name, user name or port value is written to committed files.
3. All role-remapped section 6 validity checks are re-run in full: OS versions, Linux package
   provenance, macOS official-DMG-to-binary hash chain and bundle version `2.4.0-release`,
   capture tool and non-root capability, sanitizer version and SHA-256, generator recipe and
   version, UTC clocks, the Linux-loopback capture filter, SSH-only inter-host leg,
   loopback-only bindings on the Linux remote-forward listener and macOS forward destination,
   and SSH forward fail-fast.
4. Linux SSH daemon policy is checked without changing it. If remote forwarding is unavailable
   or cannot be made loopback-only without configuration changes, STOP.
5. The owner configuration backup and restore procedure on both roles is re-verified before
   the baseline session is paused.
6. The fixed maximum window duration and the graceful-only stop and timeout wrappers are
   recorded. Any private tooling change caused by switching from local forward to remote
   forward, changing roles, changing port-placeholder meaning, or changing capture filters
   must be listed for reviewer approval before execution. Unreviewed tooling MUST NOT run.

### 12.6 Attempt-3 limits and outcome handling

- Exactly one bounded attempt. The runtime connection through the evidence configuration must
  succeed once inside the window; if it does not, STOP with a fixed label, restore the owner
  session, and record the result. A fourth attempt requires another plan amendment and another
  independent approval.
- Attempt 3 produces no fixture, register entry or ADR unless it reaches the section 9 flow
  after a discriminating result, and then only through Checkpoints 2 and 3.
  `BARRIER-EVID-0001`, `BARRIER-EVID-0002` and the `M1-WIRE-001` ADR stay unchanged.
- `M1-025` stays blocked until a register entry with accepted, independently reviewed
  discriminating width evidence exists. A connection success, a long candidate length, or a
  completed attempt without exactly one surviving reading does not unblock it.

### 12.7 Reviewer decision for section 12

Reviewer (not the capture author) records the decision in `independent-review.md`:

- [ ] APPROVE / [ ] REJECT: attempts 1 and 2 are preserved unchanged and are not reused as
      capture input.
- [ ] APPROVE / [ ] REJECT: the observed macOS-server to Linux-client direction is an
      acceptable normal-use baseline for a new bounded experiment.
- [ ] APPROVE / [ ] REJECT: the remote-forward topology keeps the only captured cleartext leg
      on Linux loopback, keeps inter-host traffic inside SSH, and requires loopback-only
      bindings on both hosts.
- [ ] APPROVE / [ ] REJECT: sections 1–10 boundaries apply unchanged except for the explicit
      role and leg remapping in 12.4.
- [ ] APPROVE / [ ] REJECT: the 12.5 fresh pre-window checks are complete and each failure
      stops before the window opens.
- [ ] APPROVE / [ ] REJECT: exactly one bounded attempt; any further retry needs a new review.
- [ ] FINAL: attempt 3 MAY proceed after all 12.5 checks pass / attempt 3 MUST NOT proceed
      (`M1-025` stays blocked).

## 13. Amended fourth-attempt plan (proposed, pending independent review)

Status: **PROPOSED. NOT APPROVED. NOT STARTED.** This section is a plan amendment only. It
records no capture, fixture, register entry, ADR or width.

### 13.1 Attempts 1 through 3 are preserved as stopped

- Attempt 1 stopped at the required runtime connection gate with fixed label
  `client-not-connected` (2026-10-05T07:09:55Z). It produced no analyzable stream and is not an
  input to attempt 4.
- Attempt 2 stopped before the capture window opened with fixed label
  `baseline-direction-mismatch` (2026-10-06T09:02:48Z). It produced no raw capture, fixture,
  register entry or width ADR and is not an input to attempt 4.
- Attempt 3 opened one bounded capture window and produced sanitized stop evidence with result
  `STOP-BOTH-SUCCEED`. It is accepted only as non-discriminating stop evidence. It produced no
  fixture, register entry, width ADR or `M1-025` unblock.
- Attempt 3 raw cleanup source is currently unavailable on `role-capture`: the previously
  recorded raw and sanitizer working files under the attempt-3 temporary directory were not
  present when rechecked. This plan does not treat Checkpoint 2 re-derivation or deletion as
  complete. If those files are later restored, they must be reviewed under the Checkpoint 2
  rules for attempt 3; otherwise the loss remains a recorded evidence-handling limitation.
- This amendment does not rewrite, reinterpret or reuse attempts 1 through 3 as capture input.
  A fourth attempt is a new bounded experiment based only on the current observed normal-use
  direction and the unchanged section 4 predicate.

### 13.2 Why a new reviewer approval is required

- Section 12 approved exactly one third bounded attempt and explicitly said any fourth attempt
  requires another plan amendment and another independent approval. That approval was consumed
  by the `STOP-BOTH-SUCCEED` result.
- Section 8 says a stop is not bypassed by changing the plan after the fact. Attempt 4 is
  therefore a new bounded experiment, not a continuation of attempt 3.
- Required ordering: the reviewer (not the capture author) records a Checkpoint 1 decision for
  this section in `independent-review.md`, with a UTC timestamp later than this amendment's
  commit and earlier than any attempt-4 pre-window check. Without that record, attempt 4 MUST
  NOT start.

### 13.3 Fourth-attempt baseline and discriminating trigger

Attempt 4 may use the currently observed owner normal-use direction, macOS Barrier server to
Linux Barrier client, only after the fresh pre-window checks in 13.6 pass.

The attempt-3 sanitized streams were complete but too small to discriminate: both `walk(S, 4)`
and `walk(S, 2)` succeeded on every stream. Attempt 4 therefore adds a predeclared
normal-use trigger whose purpose is to verify that synthetic clipboard payload actually crosses
the Barrier connection during the bounded capture window. This is a causal trigger, not a byte
or width prediction.

The trigger is:

1. create deterministic, synthetic, non-personal UTF-8 clipboard text on the macOS server;
2. place that value on the macOS system clipboard by normal OS clipboard APIs;
3. move Barrier focus to the Linux client using normal product interaction;
4. request the Linux clipboard through normal Linux desktop clipboard APIs;
5. record only metadata: size, SHA-256, UTC step times and whether the Linux-side hash matched
   the generated value.

The generated value and Linux-side clipboard material are temporary evidence data. They are
not committed, not copied into the repository, and are deleted or cleared during cleanup. A
hash match is required only to prove that the normal-use trigger occurred; it is not evidence
of any prefix width. If the Linux-side clipboard request cannot retrieve the synthetic value
without product modification, source-code inspection, packet injection, instrumentation or
non-normal Barrier behavior, STOP before analyzing for width.

### 13.4 Topology for attempt 4

Roles for attempt 4:

- `role-server`: macOS host. It runs the Barrier server in the disposable evidence
  configuration and creates the synthetic clipboard value. No capture runs on macOS.
- `role-client == role-capture`: Linux host. It runs the Barrier client, the capture tool, the
  Linux clipboard request and the raw/sanitization workflow. Raw capture data stays on this
  host.

Legs for attempt 4 are the same role-remapped legs as section 12:

- **Captured cleartext leg (Linux loopback):** the Linux Barrier client connects to a Linux
  loopback remote-forward listener served by the Linux SSH daemon. This is the only leg that is
  captured and analyzed.
- **Encrypted inter-host leg:** a macOS-initiated SSH session to the Linux host carries the
  remote forward. Barrier traffic between hosts exists only inside this SSH channel.
- **Uncaptured cleartext leg (macOS loopback):** the macOS SSH client remote-forward exit
  connects to the macOS Barrier server at a loopback destination only. This leg is not captured
  or analyzed.

The evidence configuration must not modify Linux `sshd_config`. If remote forwarding is not
allowed, the listener is not loopback-only, the macOS destination is not loopback-only, or the
SSH session cannot be configured fail-fast, STOP before the capture window opens.

### 13.5 Mapping of sections 1–10 under attempt 4

Sections 1–10 remain in force unless this section explicitly remaps a role, leg or trigger:

- Sections 1 and 8: Linux/macOS only; no Windows; no Barrier or Deskflow source,
  source-derived writeup, decompiled or instrumented material; no production Swift; MacKVM
  production TLS stays enabled and fail-closed, and no MacKVM configuration, code or default
  changes.
- Section 3: the deterministic synthetic generator remains on the macOS host. The normal-use
  data path is macOS clipboard -> Barrier server -> macOS loopback -> SSH remote forward ->
  Linux loopback -> Barrier client -> Linux clipboard request. Only generator and hash
  metadata is committed.
- Section 4.1: the in-scope connection is the complete ordered application byte stream per
  direction on the Linux loopback leg between the Barrier client and the remote-forward
  listener. Packet, read, run and capture-tool record boundaries still carry no frame meaning.
- Sections 4.2 and 4.3: the `walk(S, 4)` and `walk(S, 2)` predicate is unchanged. Both
  readings receive identical complete bytes. Exactly one success is required; both-success,
  both-fail or incomplete results STOP.
- Section 5: FIN in both directions remains required; RST does not qualify. The in-scope
  connection is identified by Linux loopback interface plus a documented remote-forward
  listener port placeholder. Cherry-picking is not allowed.
- Section 6 validity checks are remapped to the roles above. Linux provenance applies to the
  official Ubuntu Barrier client binary plus the Linux clipboard request tool. macOS provenance
  applies to the official upstream DMG hash chain, with `barriers` as the server binary of
  interest and the recorded CLI `--version` limitation still disclosed.
- The sanitizer and privacy scan keep the same allowlist policy. The Linux clipboard hash and
  generated value metadata are evidence metadata only and are not parsed as protocol bytes.

### 13.6 Fresh pre-window checks for attempt 4

All of the following are performed fresh for attempt 4 and recorded with UTC timestamps in
`environment.json` and `manual.md` before the capture window opens. Results from attempts 1,
2 or 3 do not satisfy any of them. Any failure is a STOP before the window opens, and no
capture starts.

1. The new reviewer approval for section 13 exists and its timestamp precedes this check.
2. Baseline session check: on the unmodified owner session, the macOS role runs the Barrier
   server, the Linux role runs the Barrier client, and the product reports the client as
   connected. Only process names and product connection status are recorded; no address,
   host name, user name or port value is written to committed files.
3. All role-remapped section 6 validity checks are re-run in full: OS versions, Linux package
   provenance, macOS official-DMG-to-binary hash chain and bundle version `2.4.0-release`,
   capture tool and non-root capability, sanitizer version and SHA-256, generator recipe and
   version, Linux clipboard request tool identity, UTC clocks, the Linux-loopback capture
   filter, SSH-only inter-host leg, loopback-only bindings on the Linux remote-forward listener
   and macOS forward destination, and SSH forward fail-fast.
4. Linux SSH daemon policy is checked without changing it. If remote forwarding is unavailable
   or cannot be made loopback-only without configuration changes, STOP.
5. The owner configuration backup and restore procedure on both roles is re-verified before
   the baseline session is paused.
6. The fixed maximum window duration, synthetic clipboard size ladder, graceful-only stop and
   timeout wrappers, and clipboard cleanup steps are recorded. Any private tooling change
   caused by the clipboard trigger, remote-forward role mapping, port-placeholder meaning, or
   capture filters must be listed for reviewer approval before execution. Unreviewed tooling
   MUST NOT run.

### 13.7 Attempt-4 limits and outcome handling

- Exactly one bounded attempt. The runtime connection through the evidence configuration must
  succeed once inside the window, and the Linux clipboard request must retrieve the generated
  value by hash. If either condition does not hold, STOP with a fixed label, restore the owner
  session, and record the result.
- Attempt 4 produces no fixture, register entry or ADR unless it reaches the section 9 flow
  after a discriminating result, and then only through Checkpoints 2 and 3.
  `BARRIER-EVID-0001`, `BARRIER-EVID-0002` and the `M1-WIRE-001` ADR stay unchanged.
- `M1-025` stays blocked until a register entry with accepted, independently reviewed
  discriminating width evidence exists. A connection success, a clipboard hash match, a long
  candidate length, or a completed attempt without exactly one surviving reading does not
  unblock it.

### 13.8 Reviewer decision for section 13

Reviewer (not the capture author) records the decision in `independent-review.md`:

- [ ] APPROVE / [ ] REJECT: attempts 1 through 3 are preserved unchanged and are not reused as
      capture input.
- [ ] APPROVE / [ ] REJECT: the attempt-3 raw cleanup limitation is disclosed and does not
      masquerade as a completed Checkpoint 2 result.
- [ ] APPROVE / [ ] REJECT: the observed macOS-server to Linux-client direction is an
      acceptable normal-use baseline for a new bounded experiment.
- [ ] APPROVE / [ ] REJECT: the clipboard trigger is normal product use, records only metadata,
      and predicts no byte, frame, message, chunking or width result.
- [ ] APPROVE / [ ] REJECT: the remote-forward topology keeps the only captured cleartext leg
      on Linux loopback, keeps inter-host traffic inside SSH, and requires loopback-only
      bindings on both hosts.
- [ ] APPROVE / [ ] REJECT: sections 1–10 boundaries apply unchanged except for the explicit
      role, leg and trigger remapping in 13.5.
- [ ] APPROVE / [ ] REJECT: the 13.6 fresh pre-window checks are complete and each failure
      stops before the window opens.
- [ ] APPROVE / [ ] REJECT: exactly one bounded attempt; any further retry needs a new review.
- [ ] FINAL: attempt 4 MAY proceed after all 13.6 checks pass / attempt 4 MUST NOT proceed
      (`M1-025` stays blocked).

## 14. Amended fifth-attempt plan (proposed, pending independent review)

Status: **PROPOSED. NOT APPROVED. NOT STARTED.** This section is a plan amendment only. It
records no capture, fixture, register entry, ADR or width.

### 14.1 Attempts 1 through 4 are preserved as stopped

- Attempt 1 stopped at the required runtime connection gate with fixed label
  `client-not-connected`.
- Attempt 2 stopped before the capture window opened with fixed label
  `baseline-direction-mismatch`.
- Attempt 3 opened a bounded capture window and stopped with `STOP-BOTH-SUCCEED`.
- Attempt 4 opened a bounded capture window and stopped with `STOP-BOTH-SUCCEED`; its
  sanitized stream evidence included a `201657` byte server-to-client stream, but the largest
  accepted frame length in either walk was still below the ambiguous range boundary, so both
  readings still succeeded. The attempt-4 synthetic clipboard trigger also failed to
  hash-match inside the disposable evidence session, and that mismatch remains only a recorded
  stop fact.
- Attempts 1 through 4 remain valid final results for their attempts. This amendment does not
  rewrite, reinterpret or reuse them as capture input.

### 14.2 Why a new reviewer approval is required

- Section 13 approved exactly one fourth bounded attempt and explicitly said any further retry
  requires another plan amendment and another independent approval. That approval was consumed
  by the attempt-4 `STOP-BOTH-SUCCEED` result.
- Section 8 says a stop is not bypassed by changing the plan after the fact. Attempt 5 is
  therefore a new bounded experiment, not a continuation of attempt 4.
- Required ordering: the reviewer (not the capture author) records a Checkpoint 1 decision for
  this section in `independent-review.md`, with a UTC timestamp later than this amendment's
  commit and earlier than any attempt-5 pre-window check. Without that record, attempt 5 MUST
  NOT start.

### 14.3 Fifth-attempt evidence strategy

Attempt 5 may use Barrier's documented file drag-and-drop path as a normal-use candidate
action only after a fresh pre-window capability check proves that both role binaries advertise
the normal `--enable-drag-drop` and `--drop-dir` options.

The evidence hypothesis is narrow: a normal file-transfer path may produce larger or differently
structured Barrier application streams than clipboard sharing. This is only a causal hypothesis.
It predicts no byte, message, marker, frame count, chunking behavior or prefix width.

The trigger is:

1. create a deterministic, synthetic, non-personal file on the macOS role;
2. enable Barrier drag-and-drop only in the disposable evidence configuration on both roles;
3. set a disposable Linux drop directory on `role-capture`;
4. move Barrier focus to the Linux client using normal product interaction;
5. initiate one normal GUI file drag from macOS toward the Linux Barrier screen;
6. record only metadata: generated file size, SHA-256, UTC step times, Linux drop-directory
   result, and whether any received file hash matches the generated file.

No generated file content, received file content, raw capture, real user file, real clipboard
value, host name, address, user name, path or private artifact may be committed. The synthetic
file and any received file remain temporary evidence data and are deleted during cleanup after
their hashes and byte lengths are recorded.

If the drag-and-drop trigger cannot be initiated with normal product behavior, if Barrier
refuses or disables the option, if Accessibility/TCC blocks synthetic GUI drag input, if no
file arrives in the drop directory, or if making it work would require source-code inspection,
packet injection, process instrumentation, patched binaries, private APIs or product behavior
outside normal Barrier operation, STOP before analyzing for width.

### 14.4 Topology for attempt 5

Roles for attempt 5:

- `role-server`: macOS host. It runs the Barrier server in the disposable evidence
  configuration, creates the synthetic source file and initiates the normal file drag. No
  capture runs on macOS.
- `role-client == role-capture`: Linux host. It runs the Barrier client, capture tool,
  disposable drop directory and raw/sanitization workflow. Raw capture data stays on this host.

Legs for attempt 5 are the same role-remapped legs as sections 12 and 13:

- **Captured cleartext leg (Linux loopback):** the Linux Barrier client connects to a Linux
  loopback remote-forward listener served by the Linux SSH daemon. This is the only leg that is
  captured and analyzed.
- **Encrypted inter-host leg:** a macOS-initiated SSH session to the Linux host carries the
  remote forward. Barrier traffic between hosts exists only inside this SSH channel.
- **Uncaptured cleartext leg (macOS loopback):** the macOS SSH client remote-forward exit
  connects to the macOS Barrier server at a loopback destination only. This leg is not captured
  or analyzed.

The evidence configuration must not modify Linux `sshd_config`. If remote forwarding is not
allowed, the listener is not loopback-only, the macOS destination is not loopback-only, or the
SSH session cannot be configured fail-fast, STOP before the capture window opens.

### 14.5 Mapping of sections 1–10 under attempt 5

Sections 1–10 remain in force unless this section explicitly remaps a role, leg or trigger:

- Sections 1 and 8: Linux/macOS only; no Windows; no Barrier or Deskflow source,
  source-derived writeup, decompiled or instrumented material; no production Swift; MacKVM
  production TLS stays enabled and fail-closed, and no MacKVM configuration, code or default
  changes.
- Section 3: the deterministic synthetic generator remains on the macOS host. The normal-use
  data path is synthetic file -> macOS drag source -> Barrier server -> macOS loopback -> SSH
  remote forward -> Linux loopback -> Barrier client -> disposable Linux drop directory. Only
  file metadata and hash-match status are committed.
- Section 4.1: the in-scope connection is the complete ordered application byte stream per
  direction on the Linux loopback leg between the Barrier client and the remote-forward
  listener. Packet, read, run and capture-tool record boundaries still carry no frame meaning.
- Sections 4.2 and 4.3: the `walk(S, 4)` and `walk(S, 2)` predicate is unchanged. Both
  readings receive identical complete bytes. Exactly one success is required; both-success,
  both-fail or incomplete results STOP.
- Section 5: FIN in both directions remains required; RST does not qualify. The in-scope
  connection is identified by Linux loopback interface plus a documented remote-forward
  listener port placeholder. Cherry-picking is not allowed.
- Section 6 validity checks are remapped to the roles above. Linux provenance applies to the
  official Ubuntu Barrier client binary plus the Linux drop directory and file-hash tools.
  macOS provenance applies to the official upstream DMG hash chain, with `barriers` as the
  server binary of interest and the recorded CLI `--version` limitation still disclosed.
- The sanitizer and privacy scan keep the same allowlist policy. File hashes and file sizes
  are evidence metadata only and are not parsed as protocol bytes.

### 14.6 Fresh pre-window checks for attempt 5

All of the following are performed fresh for attempt 5 and recorded with UTC timestamps in
`environment.json` and `manual.md` before the capture window opens. Results from attempts 1
through 4 do not satisfy any of them. Any failure is a STOP before the window opens, and no
capture starts.

1. The new reviewer approval for section 14 exists and its timestamp precedes this check.
2. Baseline session check: on the unmodified owner session, the macOS role runs the Barrier
   server, the Linux role runs the Barrier client, and the product reports the client as
   connected. Only process names and product connection status are recorded; no address,
   host name, user name or port value is written to committed files.
3. Capability check: the macOS and Linux Barrier binaries both advertise `--enable-drag-drop`
   and `--drop-dir`; if not, STOP before the window opens.
4. All role-remapped section 6 validity checks are re-run in full: OS versions, Linux package
   provenance, macOS official-DMG-to-binary hash chain and bundle version `2.4.0-release`,
   capture tool and non-root capability, sanitizer version and SHA-256, generator recipe and
   version, Linux file-hash tool identity, UTC clocks, the Linux-loopback capture filter,
   SSH-only inter-host leg, loopback-only bindings on the Linux remote-forward listener and
   macOS forward destination, and SSH forward fail-fast.
5. Linux SSH daemon policy is checked without changing it. If remote forwarding is unavailable
   or cannot be made loopback-only without configuration changes, STOP.
6. The owner configuration backup and restore procedure on both roles is re-verified before
   the baseline session is paused.
7. The fixed maximum window duration, synthetic file size ladder, graceful-only stop and
   timeout wrappers, disposable drop directory, file cleanup steps and UI drag automation
   method are recorded. Any private tooling change caused by the file-transfer trigger,
   remote-forward role mapping, port-placeholder meaning, or capture filters must be listed for
   reviewer approval before execution. Unreviewed tooling MUST NOT run.

### 14.7 Attempt-5 limits and outcome handling

- Exactly one bounded attempt. The runtime connection through the evidence configuration must
  succeed once inside the window, and the file-transfer trigger must either produce a matching
  synthetic file in the Linux drop directory or stop with a fixed label. If either condition
  does not hold, STOP, restore the owner session, and record the result.
- Attempt 5 produces no fixture, register entry or ADR unless it reaches the section 9 flow
  after a discriminating result, and then only through Checkpoints 2 and 3.
  `BARRIER-EVID-0001`, `BARRIER-EVID-0002` and the `M1-WIRE-001` ADR stay unchanged.
- `M1-025` stays blocked until a register entry with accepted, independently reviewed
  discriminating width evidence exists. A connection success, a file-transfer success, a long
  candidate length, or a completed attempt without exactly one surviving reading does not
  unblock it.

### 14.8 Reviewer decision for section 14

Reviewer (not the capture author) records the decision in `independent-review.md`:

- [ ] APPROVE / [ ] REJECT: attempts 1 through 4 are preserved unchanged and are not reused as
      capture input.
- [ ] APPROVE / [ ] REJECT: Barrier file drag-and-drop is an acceptable normal-use candidate
      action only if both binaries advertise the required options and the action can be
      initiated without source inspection, instrumentation, packet injection or patched
      binaries.
- [ ] APPROVE / [ ] REJECT: the file-transfer trigger records only metadata and predicts no
      byte, frame, message, chunking or width result.
- [ ] APPROVE / [ ] REJECT: the remote-forward topology keeps the only captured cleartext leg
      on Linux loopback, keeps inter-host traffic inside SSH, and requires loopback-only
      bindings on both hosts.
- [ ] APPROVE / [ ] REJECT: sections 1–10 boundaries apply unchanged except for the explicit
      role, leg and trigger remapping in 14.5.
- [ ] APPROVE / [ ] REJECT: the 14.6 fresh pre-window checks are complete and each failure
      stops before the window opens.
- [ ] APPROVE / [ ] REJECT: exactly one bounded attempt; any further retry needs a new review.
- [ ] FINAL: attempt 5 MAY proceed after all 14.6 checks pass / attempt 5 MUST NOT proceed
      (`M1-025` stays blocked).

## 15. Amended sixth-attempt plan (proposed, pending independent review)

Status: **PROPOSED. NOT APPROVED. NOT STARTED.** This section is a plan amendment only. It
records no capture, fixture, register entry, ADR or width.

### 15.1 Attempts 1 through 5 are preserved as stopped

- Attempts 1 through 5 remain valid final results for their attempts and are not reused as
  capture input.
- Attempt 5 proved that the advertised file-transfer options are not usable in this Barrier
  2.4.0 runtime path: both roles stopped with `setDropTarget not implemented`, no in-scope
  packet was captured, and no sanitized artifact was produced.

### 15.2 Why a new reviewer approval is required

- Section 14 approved exactly one fifth bounded attempt and said any further retry requires
  another plan amendment and another independent approval. That approval was consumed by the
  attempt-5 stop.
- Required ordering: the reviewer records a Checkpoint 1 decision for this section in
  `independent-review.md`, with a UTC timestamp later than this amendment's commit and earlier
  than any attempt-6 pre-window check. Without that record, attempt 6 MUST NOT start.

### 15.3 Sixth-attempt evidence strategy

Attempt 6 may use a disposable, synthetic Barrier server configuration containing many
synthetic screen entries, aliases and links. This is a normal Barrier configuration input, not
source inspection, packet injection, instrumentation or patched binary behavior.

The evidence hypothesis is narrow: a larger normal server configuration may produce larger or
differently structured handshake/configuration streams than clipboard sharing. This is only a
causal hypothesis. It predicts no byte, message, frame count, chunking behavior or prefix
width.

The trigger is:

1. generate a deterministic disposable config on the macOS server role;
2. include the real client screen label plus many synthetic non-personal screen labels,
   aliases and links;
3. start the disposable macOS Barrier server with this config;
4. connect the Linux Barrier client through the existing Linux-loopback remote-forward capture
   topology;
5. record only metadata: config size, SHA-256, synthetic screen count and whether the client
   connected.

If Barrier rejects the config, truncates names, refuses connection, crashes, requires source
inspection, requires patched binaries, or needs product behavior outside normal config parsing,
STOP before analyzing for width.

### 15.4 Topology and unchanged rules

Roles and legs match sections 12 through 14: macOS is `role-server`, Linux is
`role-client == role-capture`, the only captured cleartext leg is Linux loopback, inter-host
traffic is inside SSH, and the macOS forward exit uses loopback. Sections 1 through 10 remain
in force: no Windows, no Barrier/Deskflow source, no production Swift, no MacKVM TLS/default
change, fixed `walk(S, 4)`/`walk(S, 2)` predicate, complete FIN-bounded streams only, raw
stays on `role-capture`, sanitizer allowlist only.

### 15.5 Fresh pre-window checks for attempt 6

All checks are performed fresh and recorded before the capture window opens:

1. The new reviewer approval for section 15 exists and predates the check.
2. Baseline session check confirms macOS server to Linux client owner session.
3. OS versions, Linux package provenance, macOS official-DMG-to-binary hash chain, capture
   capabilities, analyzer identity, UTC clocks, SSH remote-forward loopback binding and
   fail-fast behavior are rechecked.
4. The disposable config generator records its recipe, config byte length, SHA-256 and
   synthetic screen count.
5. Owner session backup/restore and graceful stop/timeout wrappers are reverified.

### 15.6 Attempt-6 limits and outcome handling

- Exactly one bounded attempt. If runtime connection fails or the config is rejected, STOP with
  a fixed label and restore the owner session.
- Attempt 6 produces no fixture, register entry or ADR unless it reaches the section 9 flow
  after a discriminating result, and then only through Checkpoints 2 and 3.
- `M1-025` stays blocked until a register entry with accepted, independently reviewed
  discriminating width evidence exists. A connection success, a large config, a long candidate
  length, or a completed attempt without exactly one surviving reading does not unblock it.

## 16. Amended seventh-attempt plan (proposed, pending independent review)

Status: **PROPOSED. NOT APPROVED. NOT STARTED.** This section is a plan amendment only. It
records no capture, fixture, register entry, ADR or width.

### 16.1 Attempts 1 through 6 are preserved as stopped

- Attempts 1 through 6 remain valid final results for their attempts and are not reused as
  capture input.
- Attempt 6 proved that a large synthetic macOS server configuration can connect but still
  produce only small captured application streams in the tested topology. Both candidate
  readings succeeded and no width evidence was accepted.

### 16.2 Why a new reviewer approval is required

- Section 15 approved exactly one sixth bounded attempt and said any further retry requires
  another plan amendment and another independent approval. That approval was consumed by the
  attempt-6 stop.
- Required ordering: the reviewer records a Checkpoint 1 decision for this section in
  `independent-review.md`, with a UTC timestamp later than this amendment's commit and earlier
  than any attempt-7 pre-window check. Without that record, attempt 7 MUST NOT start.

### 16.3 Seventh-attempt evidence strategy

Attempt 7 may use a deterministic, synthetic, non-personal Barrier client screen name that is
substantially longer than ordinary human host names. This is a normal Barrier client identity
input supplied through documented runtime configuration or command-line options. It is not
Barrier or Deskflow source inspection, source-derived material, decompilation,
instrumentation, packet injection, patched binary behavior, or generated protocol bytes.

The evidence hypothesis is narrow: a very long normal client identity may cause the external
Barrier runtime to emit a larger or differently structured handshake/client-info stream than
the previous clipboard, file-transfer and large-config attempts. This is only a causal
hypothesis. It predicts no byte, message, frame count, chunking behavior, accepted name limit or
prefix width.

The trigger is:

1. generate a deterministic long screen-name string using only safe ASCII characters from a
   recorded recipe;
2. configure the disposable macOS Barrier server to accept exactly that synthetic client name
   and a minimal screen layout that lets the product connect;
3. start the disposable macOS Barrier server with that config;
4. start the Linux Barrier client with that same synthetic screen name through the existing
   Linux-loopback remote-forward capture topology;
5. record only metadata: name byte length, SHA-256, generator recipe, whether both external
   programs accepted the name, whether runtime connection succeeded, and the normal analyzer
   result.

If either Barrier program rejects the name, truncates it before connection in a way that cannot
be observed only as metadata, crashes, requires source inspection, requires patched binaries,
requires binary instrumentation, or needs product behavior outside normal configuration parsing,
STOP before analyzing for width.

### 16.4 Topology and unchanged rules

Roles and legs match sections 12 through 15: macOS is `role-server`, Linux is
`role-client == role-capture`, the only captured cleartext leg is Linux loopback, inter-host
traffic is inside SSH, and the macOS forward exit uses loopback. Sections 1 through 10 remain
in force: no Windows, no Barrier/Deskflow source, no production Swift, no MacKVM TLS/default
change, fixed `walk(S, 4)`/`walk(S, 2)` predicate, complete FIN-bounded streams only, raw
stays on `role-capture`, sanitizer allowlist only.

### 16.5 Fresh pre-window checks for attempt 7

All checks are performed fresh and recorded before the capture window opens:

1. The new reviewer approval for section 16 exists and predates the check.
2. Baseline session check confirms macOS server to Linux client owner session.
3. OS versions, Linux package provenance, macOS official-DMG-to-binary hash chain, capture
   capabilities, analyzer identity, UTC clocks, SSH remote-forward loopback binding and
   fail-fast behavior are rechecked.
4. The long-name generator records its recipe, generated name byte length and SHA-256. The
   generated name itself is not committed.
5. The disposable server config and client command use only the generated synthetic name and
   placeholders in committed evidence.
6. Owner session backup/restore and graceful stop/timeout wrappers are reverified.

### 16.6 Attempt-7 limits and outcome handling

- Exactly one bounded attempt. If runtime connection fails, either external program rejects the
  name, or the evidence topology cannot be restored safely, STOP with a fixed label and restore
  the owner session.
- Attempt 7 produces no fixture, register entry or ADR unless it reaches the section 9 flow
  after a discriminating result, and then only through Checkpoints 2 and 3.
- `M1-025` stays blocked until a register entry with accepted, independently reviewed
  discriminating width evidence exists. A connection success, a long synthetic name, a long
  candidate length, or a completed attempt without exactly one surviving reading does not
  unblock it.

### 16.7 Reviewer decision for section 16

Reviewer (not the capture author, except under the Product Owner's temporary M1 bootstrap
waiver) records the decision in `independent-review.md`:

- [ ] APPROVE / [ ] REJECT: attempts 1 through 6 are preserved unchanged and are not reused as
      capture input.
- [ ] APPROVE / [ ] REJECT: a deterministic long synthetic client screen name is an acceptable
      normal-use candidate action only if both external Barrier programs accept it through
      normal configuration or command-line inputs.
- [ ] APPROVE / [ ] REJECT: the long-name trigger records only metadata and predicts no byte,
      frame, message, chunking, accepted name limit or width result.
- [ ] APPROVE / [ ] REJECT: the remote-forward topology keeps the only captured cleartext leg
      on Linux loopback, keeps inter-host traffic inside SSH, and requires loopback-only
      bindings on both hosts.
- [ ] APPROVE / [ ] REJECT: sections 1–10 boundaries apply unchanged except for the explicit
      role, leg and trigger remapping in section 16.
- [ ] APPROVE / [ ] REJECT: the 16.5 fresh pre-window checks are complete and each failure
      stops before the window opens.
- [ ] APPROVE / [ ] REJECT: exactly one bounded attempt; any further retry needs a new review.
- [ ] FINAL: attempt 7 MAY proceed after all 16.5 checks pass / attempt 7 MUST NOT proceed
      (`M1-025` stays blocked).
