# M1-WIRE-002 Independent Review

## Reviewer identity

- Reviewer: Codex independent reviewer
- Independence: not the discrimination-plan author or capture producer; Claude Opus 5 authored the plan and will own any capture implementation.
- Issue: GitHub #279 (M1-WIRE-002)

## Checkpoint 1 — pre-capture plan review

- Reviewed at: `2026-10-02T08:41:12Z`
- Plan: `evidence/issues/M1-WIRE-002/discrimination-plan.md`
- Verdict: **APPROVED FOR ONE BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval fixes the analysis predicate and safety boundary; it does not predict or certify a discriminating outcome. No width is approved, no evidence entry is approved, and M1-025 remains blocked.

### Source validity and clean-room boundary

- The plan is grounded in the approved M1-024 fixture, BARRIER-EVID-0001, BARRIER-EVID-0002, the accepted M1-WIRE-001 ADR and GitHub Issue #279.
- No Barrier or Deskflow source, source-derived writeup, decompilation, disassembly, patching, injection or instrumentation is permitted.
- Only Linux/macOS black-box operation is in scope; Windows is not executed.
- Production TLS stays enabled and fail closed. Any cleartext leg is evidence-only, isolated, bounded, documented and torn down.

### R0 — reading definitions

APPROVED. The recorded M1-WIRE-001 partition helper reads an unsigned big-endian integer of parameterized width, advances by `width + length`, accepts a zero length, and succeeds only when the final offset equals the input length. The plan applies that same rule with widths 4 and 2 to identical bytes. The current ambiguity explanation is arithmetically correct: a 4-byte prefix with a value below 65536 begins with `00 00`, which the 2-byte walk accepts as a zero-length frame before reading the same low 16-bit length.

### Acceptance predicate and completeness

APPROVED.

- TCP application payload must first be reconstructed as complete ordered per-direction streams.
- Packet, read, capture-record and prior retained-run boundaries are not protocol frame boundaries.
- Both readings receive identical complete bytes.
- A discriminating result requires exactly one reading to consume every required complete stream and the other to fail at a recorded first offset and reason.
- Both succeed, both fail, any sequence gap/conflicting overlap/drop/truncation, missing explicit close, or any other predicate failure is non-discriminating and stops the issue with M1-025 blocked.
- The predicate, completeness rules and failure codes may not change after capture.

FIN in both directions is required for this attempt. An RST does **not** qualify as an equivalent complete end condition under this approval; if an RST occurs, the attempt stops as incomplete.

### Normal-use causal hypothesis

APPROVED as a bounded experiment, not as a predicted result. A deterministic synthetic, non-personal clipboard size ladder is normal product use and may produce length diversity. No clipboard size, candidate length threshold, message layout, chunking behavior or byte value is claimed in advance. A candidate length at or above 256 or 65536 is not proof by itself; only the full-stream predicate can discriminate.

### Capture, privacy and deletion controls

APPROVED subject to all of the following:

- one predeclared maximum-duration window, opened before connection and closed only after qualifying FINs;
- isolated owner-controlled roles with committed artifacts using sanitized role labels only;
- raw capture and generator material remain on `role-capture` until allowlist sanitization;
- sanitizer retains only bytes required by either walk plus already approved marker/version bytes, reproduces both raw walk results exactly, and otherwise replaces payload with a documented constant;
- privacy scan must have zero hits before any artifact leaves the capture host;
- reviewer independently re-derives stream construction, sanitization, hashes and both walks on the capture host before bounded raw deletion;
- deletion records exact files, pre-deletion hashes/lengths, exact command, UTC time and post-check, with no secure-erasure claim.

### Resolved review finding

- **High — resolved before approval:** the first #279 wording required proof before capture that the normal-use action itself must produce divergence, while also prohibiting predicted bytes. GitHub Issue #279 was corrected to approve a fixed acceptance predicate and causal hypothesis for a bounded experiment. Non-discriminating outcomes remain fail-closed and cannot be converted by changing the rule after capture.

### Pre-capture decision checklist

- APPROVE: clean-room, platform and no-production-code boundary.
- APPROVE: production TLS boundary and bounded evidence-only cleartext exception.
- APPROVE: R0 matches the recorded 2-byte and 4-byte partition algorithms, including zero-length frames.
- APPROVE: normal-use deterministic synthetic clipboard hypothesis without byte/result prediction.
- APPROVE: complete ordered per-direction stream analysis on identical bytes.
- APPROVE: exactly-one-success predicate; thresholds alone are not proof.
- APPROVE WITH CONDITION: explicit FIN in both directions is required; RST is rejected for this attempt.
- APPROVE: topology, validity checks, time window, cancellation and cleanup.
- APPROVE: raw locality, sanitizer round-trip, privacy scan, reviewer re-derivation and bounded deletion.
- APPROVE: all #279 and plan-specific stop conditions are present; none applies to planning sources now.
- APPROVE: bounded-experiment honest limit matches the corrected #279 discrimination requirement.
- FINAL: **capture MAY proceed once the producer completes and records all pre-window environment/source-validity checks.**

## Checkpoint 1 addendum — amended-topology re-review

- Re-reviewed at: `2026-10-05T00:00:44Z`
- Plan: `evidence/issues/M1-WIRE-002/discrimination-plan.md`
- Verdict: **RE-APPROVED FOR ONE BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**
- Medium findings: **0 open**
- Low findings: **0 open**

This addendum supersedes the original Checkpoint 1 topology, raw-generator-location and
cleartext-leg statements wherever they differ. It does not change the fixed partition
predicate, completeness rules, FIN requirement, failure codes or fail-closed outcome rule.
It approves no predicted result and no prefix width. `M1-025` remains blocked.

### Five-axis amended-plan review

1. **Source validity / traceability — APPROVED.** The plan remains grounded in GitHub #279,
   the registered sanitized evidence and the accepted M1-WIRE-001 ADR. Linux package
   provenance and the official-upstream-DMG-to-installed-binary macOS hash chain must be
   rechecked and recorded before the window opens. The recorded macOS CLI `--version` abort is
   disclosed; any hash, bundle-version or runtime-connection mismatch is a STOP.
2. **Product contract / architecture boundaries — APPROVED.** The change is evidence-only and
   adds no production Swift, parser, codec, framer or reassembler. Barrier traffic crosses
   hosts only inside SSH. The client generator remains normal-use synthetic clipboard input.
3. **Security, fail-safe and compatibility — APPROVED.** Production TLS remains enabled and
   fail closed. Barrier cleartext is accurately bounded to two host-local loopback legs: the
   uncaptured macOS client-to-SSH-listener leg and the captured Linux sshd-exit-to-server leg.
   Both endpoints are checked as loopback-only, no wildcard/LAN listener is allowed, SSH
   forwarding is fail-fast, Windows is not executed, and any failed pre-window check is a STOP.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** Both readings
   still receive identical complete Linux-loopback direction streams. Explicit FIN in both
   directions remains required; RST does not qualify. Both-succeed, both-fail, incomplete,
   sanitizer mismatch or non-reproducible results stop the issue and leave M1-025 blocked.
5. **Scope control, repository hygiene and rollback — APPROVED.** Raw capture stays on
   `role-capture`; generator bytes are created on `role-client` and are not committed. Only
   sanitized allowlisted output may leave the capture host, after privacy checks and before the
   recorded bounded deletion. The plan does not touch existing evidence entries or the
   M1-WIRE-001 ADR.

### Resolved amended-plan finding

- **High — resolved before re-approval:** the first topology amendment incorrectly said
  Barrier cleartext existed only on Linux loopback. An SSH local forward also has an
  uncaptured cleartext macOS loopback leg from the Barrier client to the SSH listener. The plan
  now records both host-local cleartext legs, captures only the Linux leg, forbids wildcard/LAN
  listener binding, requires loopback-only endpoints and requires fail-fast forwarding.

### Resolved editorial finding

- **Low — resolved after re-approval:** the introductory topology sentence was wrapped and
  stop condition 5's singular/plural wording was corrected without changing meaning.

### Re-approval conditions

- The producer records every section 6 validity check before the capture timestamp.
- The macOS listener and Linux destination are both verified loopback-only; no wildcard or LAN
  bind is accepted.
- The SSH forward is configured fail-fast and the inter-host leg is verified encrypted.
- The exact official provenance hashes in the plan are rechecked; any mismatch stops.
- The Barrier runtime connection must succeed once inside the bounded attempt; failure stops
  without an unreviewed retry.
- The one predeclared capture window uses Linux loopback only and requires qualifying FINs.
- Checkpoints 2 and 3 remain mandatory and are not started by this approval.

FINAL: **capture MAY proceed for one bounded attempt after all pre-window checks pass.**

## Checkpoint 2 — pre-deletion re-derivation

Status: **NOT STARTED**. Raw data must not be deleted until this section records an independent reproduction on the capture host.

## Checkpoint 1 addendum — second-attempt plan review

- Reviewed at: `2026-10-06T09:00:59Z`
- Plan commit reviewed: `60cb8b71a4c2a561e4295982ee843e9047b92c2e`
- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 11
- Verdict: **APPROVED FOR ONE SECOND BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval is narrow. It approves section 11 as a pre-capture amendment only. It does not
approve any prefix width, register entry, ADR, fixture, source interpretation, production code
change, or `M1-025` unblock. `M1-025` remains blocked until accepted discriminating evidence is
registered and independently reviewed.

### Five-axis section-11 review

1. **Source validity / traceability — APPROVED.** Attempt 1 remains preserved as stopped
   evidence and is not reused as capture input. The consumed attempt-1 approval, the
   `client-not-connected` stop label, and the absence of accepted width evidence are all kept
   visible. Section 11 correctly requires this new approval before any attempt-2 pre-window
   check, capture, SSH session or evidence configuration starts.
2. **Product contract / architecture boundaries — APPROVED.** The amendment keeps #279's
   evidence-only scope: no production Swift, parser, codec, framer or reassembler; no edit to
   `BARRIER-EVID-0001`, `BARRIER-EVID-0002` or the accepted `M1-WIRE-001` ADR; no Windows; and
   no byte, message, layout, chunking or width prediction.
3. **Security, fail-safe and compatibility — APPROVED.** MacKVM production TLS and fail-closed
   defaults remain unchanged. The owner-confirmed normal-use session is allowed only as a
   baseline; it is not captured as-is. Any attempt-2 evidence configuration must still satisfy
   the section 6 topology, loopback-only endpoints, SSH-forward fail-fast, raw locality,
   sanitizer, privacy scan and bounded deletion rules.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** The fixed
   section 4 predicate, section 5 completeness preconditions and FIN-in-both-directions
   requirement still govern the outcome. A connection success, a long candidate length, or a
   completed non-discriminating run still does not unblock `M1-025`.
5. **Scope control, repository hygiene and rollback — APPROVED.** The amendment is limited to
   documentation that prepares a second attempt. It adds no fixture, ADR, register entry or raw
   artifact. A third attempt is explicitly disallowed without another plan amendment and
   another independent approval.

### Required attempt-2 pre-window checks

Attempt 2 may proceed only if every section 11.4 check passes and is recorded with UTC
timestamps before the capture window opens:

- this approval exists and predates the check;
- the baseline direction is verified as Linux Barrier server to macOS Barrier client; if the
  direction is the attempt-1 restoration direction, STOP before the window opens;
- all section 6 validity checks are re-run in full, including OS versions, Linux package
  provenance, macOS official-DMG-to-installed-binary hash chain, capture tool capability,
  sanitizer identity, generator identity, UTC clocks, loopback-only capture filter,
  SSH-forward-only inter-host leg, loopback-only bindings and SSH forward fail-fast;
- owner configuration backup and restore procedures are re-verified on both roles;
- the fixed maximum window duration and graceful-only stop/timeout wrappers are recorded
  unchanged, or any change is brought back for review before execution.

### Reviewer decision for section 11

- APPROVE: attempt 1 is preserved unchanged and is not reused as capture input.
- APPROVE: the owner-confirmed Linux-server to macOS-client session is an acceptable
  normal-use baseline, and the recorded direction discrepancy is handled by fresh check 11.4(2).
- APPROVE: sections 1–10 boundaries apply unchanged: no Windows, no source, no production
  Swift, no production TLS or default change, no byte prediction.
- APPROVE: the 11.4 fresh pre-window checks are complete and each failure stops before the
  window opens.
- APPROVE: exactly one second bounded attempt; any further retry needs a new review.
- FINAL: **attempt 2 MAY proceed after all 11.4 checks pass.**

### Attempt-2 pre-window result — 2026-10-06T09:02:48Z

- The reviewer performed the first fresh section 11.4 pre-window check against the Linux role
  over the owner-authorized SSH access.
- Result: **STOP before the capture window opened**.
- Fixed stop label: `baseline-direction-mismatch`.
- Evidence: the Linux role reported a running Barrier client process connected to a remote
  server. Section 11.4(2) required the baseline to be Linux Barrier server to macOS Barrier
  client. The observed direction therefore matched the attempt-1 restoration direction, not
  the approved section-11 baseline.
- No capture window was opened. No SSH evidence configuration, disposable cleartext leg,
  tcpdump/dumpcap capture, raw file, sanitized fixture, register entry or width ADR was
  produced for attempt 2.
- `M1-025` remains blocked. A further retry requires a new plan amendment and a new
  independent approval; it is not authorized by this section-11 approval.

## Checkpoint 1 addendum — third-attempt plan review

- Reviewed at: `2026-10-06T09:13:06Z`
- Plan commit reviewed: `b91bc9b9f1f3992380197b087aac95b49279aab6`
- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 12
- Verdict: **APPROVED FOR ONE THIRD BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval is narrow. It approves section 12 as a pre-capture amendment only. It does not
approve any prefix width, register entry, ADR, fixture, source interpretation, production code
change, or `M1-025` unblock. `M1-025` remains blocked until accepted discriminating evidence is
registered and independently reviewed.

### Five-axis section-12 review

1. **Source validity / traceability — APPROVED.** Attempts 1 and 2 remain preserved as stopped
   evidence and are not reused as capture input. Section 12 is a new bounded experiment based
   only on the observed normal-use direction from the attempt-2 pre-window check: macOS Barrier
   server to Linux Barrier client. It uses no Barrier or Deskflow source, source-derived
   writeup, decompiled output, instrumentation, or byte prediction.
2. **Product contract / architecture boundaries — APPROVED.** The amendment keeps #279's
   evidence-only scope: no production Swift, parser, codec, framer or reassembler; no edit to
   `BARRIER-EVID-0001`, `BARRIER-EVID-0002` or the accepted `M1-WIRE-001` ADR; no Windows; and
   no message, layout, chunking or width claim.
3. **Security, fail-safe and compatibility — APPROVED.** MacKVM production TLS and fail-closed
   defaults remain unchanged. Barrier cleartext remains bounded to host-local loopback legs:
   the captured Linux Barrier-client-to-remote-forward-listener leg and the uncaptured macOS
   remote-forward-exit-to-Barrier-server leg. Inter-host traffic must be inside SSH. The plan
   correctly forbids changing Linux `sshd_config`; unavailable or non-loopback remote
   forwarding is a STOP.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** The fixed
   section 4 predicate, section 5 completeness preconditions and FIN-in-both-directions
   requirement still govern the outcome. A connection success, a long candidate length, or a
   completed non-discriminating run still does not unblock `M1-025`.
5. **Scope control, repository hygiene and rollback — APPROVED.** The amendment is limited to
   documentation that prepares a third attempt. It adds no fixture, ADR, register entry or raw
   artifact. A fourth attempt is explicitly disallowed without another plan amendment and
   another independent approval.

### Required attempt-3 pre-window checks

Attempt 3 may proceed only if every section 12.5 check passes and is recorded with UTC
timestamps before the capture window opens:

- this approval exists and predates the check;
- the baseline direction is verified as macOS Barrier server to Linux Barrier client;
- all role-remapped section 6 validity checks are re-run in full, including OS versions,
  Linux package provenance, macOS official-DMG-to-installed-binary hash chain, capture tool
  capability, sanitizer identity, generator identity, UTC clocks, Linux-loopback capture
  filter, SSH-only inter-host leg, loopback-only bindings on both hosts and SSH forward
  fail-fast;
- Linux SSH daemon policy is checked without changing it; if remote forwarding is unavailable
  or cannot be made loopback-only without configuration changes, STOP;
- owner configuration backup and restore procedures are re-verified on both roles;
- any private tooling change caused by remote forwarding, role remapping, capture-filter
  changes or port-placeholder meaning changes is listed for review before execution.

### Reviewer decision for section 12

- APPROVE: attempts 1 and 2 are preserved unchanged and are not reused as capture input.
- APPROVE: the observed macOS-server to Linux-client direction is an acceptable normal-use
  baseline for a new bounded experiment.
- APPROVE: the remote-forward topology keeps the only captured cleartext leg on Linux
  loopback, keeps inter-host traffic inside SSH, and requires loopback-only bindings on both
  hosts.
- APPROVE: sections 1–10 boundaries apply unchanged except for the explicit role and leg
  remapping in 12.4.
- APPROVE: the 12.5 fresh pre-window checks are complete and each failure stops before the
  window opens.
- APPROVE: exactly one third bounded attempt; any further retry needs a new review.
- FINAL: **attempt 3 MAY proceed after all 12.5 checks pass.**

### Attempt-3 preparation progress — 2026-10-06T09:15:07Z

- Fresh baseline direction check passed: macOS role reported a Barrier server listener and
  Linux role reported a Barrier client process connected to a remote server. No committed
  address, host name, user name or port value is recorded.
- Linux package/capture-tool provenance check passed for the installed Ubuntu packages:
  Barrier 2.4.0+dfsg-2, tcpdump 4.99.1-3ubuntu0.2, wireshark-common/dumpcap 3.6.2-2,
  xclip 0.13-2 and xdotool 1:3.20160805.1-4. tcpdump and dumpcap reported packet-capture
  capabilities.
- macOS Barrier binary hash-chain spot check passed for the installed Barrier 2.4.0-release
  app binaries: `barriers` SHA-256
  `2ad6d3b9b9d6dd8cb4bb403cea91f026d896842c5ba0134891daf90f8ef846b5`, `barrierc` SHA-256
  `53369a4579223e0f8742b897d96b6a9a6c3abc9f6ef9c4fec2779b0ef7bd5715`.
- SSH remote-forward loopback check passed without changing Linux `sshd_config`: a temporary
  macOS-initiated SSH session with fail-fast forwarding created a Linux loopback-only remote
  listener, verified by the Linux socket table, and was then torn down.
- Remaining before any capture window: re-verify owner configuration backup/restore on both
  roles, review any private tooling changes for remote-forward role mapping and graceful-only
  cleanup, record the fixed window duration, and produce `environment.json`/`manual.md`.
- No capture window has opened. No raw capture, sanitized fixture, register entry, width ADR or
  `M1-025` unblock is approved.

### Attempt-3 runtime result — 2026-10-06T09:15Z

- One bounded attempt-3 capture window was opened after the section 12 approval and the
  pre-window checks above.
- Raw capture stayed on `role-capture`. The raw pcap byte length was `4199`, with SHA-256
  `778143c8feadf9c119d599222fa0a864069ae61ca0a4ff1efafca91a77681f26`. Raw capture was not
  copied into the repository.
- The approved stream analyzer was copied to `role-capture` and run there. Only the sanitized
  JSON output was copied back into the repository.
- Sanitized output: `evidence/issues/M1-WIRE-002/attempt3/sanitized.json`, byte length
  `20077`, SHA-256 `cf781d4fdee3e97d633d3c74c28f4737300e8cf1553af9e2d1d627ba9755cbd3`.
- Analyzer result: `STOP-BOTH-SUCCEED`. The capture reconstructed one complete connection with
  `client-to-server` and `server-to-client` streams. Both `walk(S, 4)` and `walk(S, 2)`
  succeeded on every stream.
- This is source-validity stop condition 7 (non-discriminating outcome). No accepted fixture,
  register entry, width ADR or `M1-025` unblock is approved.
- Raw deletion was not performed in this change because independent Checkpoint 2 re-derivation
  and deletion review are not complete.

### Preparation progress — 2026-10-05T06:18:22Z

- The owner authorized installation of the Linux normal-use tools and temporary pause,
  backup and subsequent restoration of the existing owner Barrier session.
- The producer verified official Ubuntu packages `xdotool 1:3.20160805.1-4`,
  `libxdo3 1:3.20160805.1-4` and `xclip 0.13-2`; package verification reported no differences.
- Private backups and restoration scripts exist on both roles. The reviewer inspected the
  macOS restore script; it checks prior file hashes and restores prior configuration before
  restarting previously active components. Runtime restoration remains unexecuted.
- The prior Linux session was stopped with TERM. The reviewer stopped the prior macOS
  session with TERM after an AppleEvent quit returned without stopping the processes, then
  independently confirmed all three Barrier process names and Barrier listeners absent.
- Repository sanitizer checkpoint `270671d` passed all 23 `make verify` gates before capture.
  Its SHA-256 is `6b3179b32741e523ffba49b81abb37195a1dd12f06e32a4d1acec6a024614e6b`.
- A private pure-function tooling library passed 62 tests independently, including the
  Linux-loopback packet-counter regression (19 captured, 38 received, zero dropped).
- **Open High, runtime draft:** an unfinished capture-agent draft contains SIGKILL cleanup
  paths. It is not approved for execution. Its replacement and timeout wrappers require
  review against the graceful-stop condition before capture may start.
- No capture outcome, fixture, register entry, prefix width or M1-025 unblock is approved.
  Capture has not started. Checkpoints 2 and 3 remain NOT STARTED.

## Checkpoint 3 — pre-merge review

Status: **NOT STARTED**. No register entry, width ADR or M1-025 unblock is approved by Checkpoint 1.

## Checkpoint 1 addendum — fourth-attempt plan review

- Reviewed at: `2026-10-07T00:41:22Z`
- Plan commit reviewed: `e3de34caed4e`
- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 13
- Verdict: **APPROVED FOR ONE FOURTH BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval is narrow. It approves section 13 as a pre-capture amendment only. It does not
approve any prefix width, register entry, ADR, fixture, source interpretation, production code
change, or `M1-025` unblock. `M1-025` remains blocked until accepted discriminating evidence is
registered and independently reviewed.

### Five-axis section-13 review

1. **Source validity / traceability — APPROVED.** Attempts 1, 2 and 3 remain preserved as
   stopped evidence and are not reused as capture input. Attempt 3's missing raw cleanup source
   is disclosed as an evidence-handling limitation, not treated as a completed Checkpoint 2
   result. Section 13 uses no Barrier or Deskflow source, source-derived writeup, decompiled
   output, instrumentation, or byte prediction.
2. **Product contract / architecture boundaries — APPROVED.** The amendment keeps #279's
   evidence-only scope: no production Swift, parser, codec, framer or reassembler; no edit to
   `BARRIER-EVID-0001`, `BARRIER-EVID-0002` or the accepted `M1-WIRE-001` ADR; no Windows; and
   no message, layout, chunking or width claim. The added clipboard trigger is a normal-use
   causal check only.
3. **Security, fail-safe and compatibility — APPROVED.** MacKVM production TLS and fail-closed
   defaults remain unchanged. Barrier cleartext remains bounded to host-local loopback legs:
   the captured Linux Barrier-client-to-remote-forward-listener leg and the uncaptured macOS
   remote-forward-exit-to-Barrier-server leg. Inter-host traffic must be inside SSH. Synthetic
   clipboard material is non-personal, temporary, cleared during cleanup and never committed;
   only metadata may be committed.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** Both
   readings still receive identical complete Linux-loopback direction streams. Explicit FIN in
   both directions remains required; RST does not qualify. Both-succeed, both-fail,
   incomplete, sanitizer mismatch, clipboard-trigger mismatch or non-reproducible results stop
   the issue and leave M1-025 blocked.
5. **Scope control, repository hygiene and rollback — APPROVED.** The amendment is limited to
   documentation that prepares a fourth attempt. It adds no fixture, ADR, register entry or raw
   artifact. A fifth attempt is explicitly disallowed without another plan amendment and
   another independent approval.

### Required attempt-4 pre-window checks

Attempt 4 may proceed only if every section 13.6 check passes and is recorded with UTC
timestamps before the capture window opens:

- this approval exists and predates the check;
- the baseline direction is verified as macOS Barrier server to Linux Barrier client;
- all role-remapped section 6 validity checks are re-run in full, including OS versions,
  Linux package provenance, macOS official-DMG-to-installed-binary hash chain, capture tool
  capability, sanitizer identity, generator identity, Linux clipboard request tool identity,
  UTC clocks, loopback-only capture filter, SSH-forward-only inter-host leg, loopback-only
  bindings and SSH forward fail-fast;
- Linux SSH daemon policy is checked without changing it;
- owner configuration backup and restore procedures are re-verified on both roles;
- the fixed maximum window duration, synthetic clipboard size ladder, graceful-only
  stop/timeout wrappers and clipboard cleanup steps are recorded;
- any private tooling change caused by the clipboard trigger or role mapping is reviewed
  before execution.

### Reviewer decision for section 13

- APPROVE: attempts 1 through 3 are preserved unchanged and are not reused as capture input.
- APPROVE: the attempt-3 raw cleanup limitation is disclosed and does not masquerade as a
  completed Checkpoint 2 result.
- APPROVE: the observed macOS-server to Linux-client direction is an acceptable normal-use
  baseline for a new bounded experiment.
- APPROVE: the clipboard trigger is normal product use, records only metadata, and predicts no
  byte, frame, message, chunking or width result.
- APPROVE: the remote-forward topology keeps the only captured cleartext leg on Linux
  loopback, keeps inter-host traffic inside SSH, and requires loopback-only bindings on both
  hosts.
- APPROVE: sections 1–10 boundaries apply unchanged except for the explicit role, leg and
  trigger remapping in 13.5.
- APPROVE: the 13.6 fresh pre-window checks are complete and each failure stops before the
  window opens.
- APPROVE: exactly one fourth bounded attempt; any further retry needs a new review.
- FINAL: **attempt 4 MAY proceed after all 13.6 checks pass.**

### Attempt-4 runtime result — 2026-10-07T00:48Z

- One bounded attempt-4 capture window was opened after the section 13 approval and fresh
  pre-window checks.
- Raw capture stayed on `role-capture`. The raw pcap byte length was `225585`, with SHA-256
  `295385b65737145edc034a51d76b125a59dbcf6a7bc75599c12a0c17c72c2c5f`. Raw capture was not
  copied into the repository.
- The capture tool reported `276 packets captured`, `552 packets received by filter` and
  `0 packets dropped by kernel`.
- The synthetic clipboard trigger did not hash-match inside the disposable evidence session:
  the generated value was `200000` bytes with SHA-256
  `3357eb5f288d9be2085180e3c97663995063b90b1599359367089d02b367c1eb`, while the Linux
  read-back returned `0` bytes with SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
- The approved stream analyzer was copied to `role-capture` and run there. Only the sanitized
  JSON output was copied back into the repository.
- Sanitized output: `evidence/issues/M1-WIRE-002/attempt4/sanitized.json`, byte length
  `419596`, SHA-256 `6b9b7291c06180189b05b95ff7600a696d9d33a5198a5c58a8e956df6e0b762d`.
- Analyzer result: `STOP-BOTH-SUCCEED`. The capture reconstructed one complete connection with
  FIN observed in both directions and no RST. The `client-to-server` stream length was `1256`
  bytes and the `server-to-client` stream length was `201657` bytes. Both `walk(S, 4)` and
  `walk(S, 2)` succeeded on every stream.
- This is source-validity stop condition 7 (non-discriminating outcome). No accepted fixture,
  register entry, width ADR or `M1-025` unblock is approved.
- Raw deletion was not performed in this change because independent Checkpoint 2 re-derivation
  and deletion review are not complete.

## Checkpoint 1 addendum — fifth-attempt plan review

- Reviewed at: `2026-10-07T04:32:25Z`
- Plan commit reviewed: `8e84c3174ef8`
- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 14
- Verdict: **APPROVED FOR ONE FIFTH BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval is narrow. It approves section 14 as a pre-capture amendment only. It does not
approve any prefix width, register entry, ADR, fixture, source interpretation, production code
change, or `M1-025` unblock. `M1-025` remains blocked until accepted discriminating evidence is
registered and independently reviewed.

### Five-axis section-14 review

1. **Source validity / traceability — APPROVED.** Attempts 1 through 4 remain preserved as
   stopped evidence and are not reused as capture input. The file-transfer path is based on
   the observed command-line capability advertised by both macOS and Linux Barrier binaries,
   not on Barrier or Deskflow source, source-derived writeup, decompiled output,
   instrumentation, or byte prediction.
2. **Product contract / architecture boundaries — APPROVED.** The amendment keeps #279's
   evidence-only scope: no production Swift, parser, codec, framer or reassembler; no edit to
   `BARRIER-EVID-0001`, `BARRIER-EVID-0002` or the accepted `M1-WIRE-001` ADR; no Windows; and
   no message, layout, chunking or width claim. File transfer is a normal-use candidate action
   only if it can be initiated without non-product behavior.
3. **Security, fail-safe and compatibility — APPROVED.** MacKVM production TLS and fail-closed
   defaults remain unchanged. Barrier cleartext remains bounded to host-local loopback legs:
   the captured Linux Barrier-client-to-remote-forward-listener leg and the uncaptured macOS
   remote-forward-exit-to-Barrier-server leg. Inter-host traffic must be inside SSH. Synthetic
   file content is non-personal, temporary, cleared during cleanup and never committed; only
   metadata may be committed.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** Both
   readings still receive identical complete Linux-loopback direction streams. Explicit FIN in
   both directions remains required; RST does not qualify. Both-succeed, both-fail,
   incomplete, sanitizer mismatch, file-transfer trigger failure or non-reproducible results
   stop the issue and leave M1-025 blocked.
5. **Scope control, repository hygiene and rollback — APPROVED.** The amendment is limited to
   documentation that prepares a fifth attempt. It adds no fixture, ADR, register entry or raw
   artifact. A sixth attempt is explicitly disallowed without another plan amendment and
   another independent approval.

### Required attempt-5 pre-window checks

Attempt 5 may proceed only if every section 14.6 check passes and is recorded with UTC
timestamps before the capture window opens:

- this approval exists and predates the check;
- the baseline direction is verified as macOS Barrier server to Linux Barrier client;
- both role binaries advertise `--enable-drag-drop` and `--drop-dir`;
- all role-remapped section 6 validity checks are re-run in full, including OS versions,
  Linux package provenance, macOS official-DMG-to-installed-binary hash chain, capture tool
  capability, sanitizer identity, generator identity, Linux file-hash tool identity, UTC
  clocks, loopback-only capture filter, SSH-forward-only inter-host leg, loopback-only
  bindings and SSH forward fail-fast;
- Linux SSH daemon policy is checked without changing it;
- owner configuration backup and restore procedures are re-verified on both roles;
- the fixed maximum window duration, synthetic file size ladder, graceful-only stop/timeout
  wrappers, disposable drop directory, file cleanup steps and UI drag automation method are
  recorded;
- any private tooling change caused by the file-transfer trigger or role mapping is reviewed
  before execution.

### Reviewer decision for section 14

- APPROVE: attempts 1 through 4 are preserved unchanged and are not reused as capture input.
- APPROVE: Barrier file drag-and-drop is an acceptable normal-use candidate action only if both
  binaries advertise the required options and the action can be initiated without source
  inspection, instrumentation, packet injection or patched binaries.
- APPROVE: the file-transfer trigger records only metadata and predicts no byte, frame,
  message, chunking or width result.
- APPROVE: the remote-forward topology keeps the only captured cleartext leg on Linux
  loopback, keeps inter-host traffic inside SSH, and requires loopback-only bindings on both
  hosts.
- APPROVE: sections 1–10 boundaries apply unchanged except for the explicit role, leg and
  trigger remapping in 14.5.
- APPROVE: the 14.6 fresh pre-window checks are complete and each failure stops before the
  window opens.
- APPROVE: exactly one fifth bounded attempt; any further retry needs a new review.
- FINAL: **attempt 5 MAY proceed after all 14.6 checks pass.**

### Attempt-5 runtime result — 2026-10-07T04:36Z

- One bounded attempt-5 capture window was started after the section 14 approval and fresh
  pre-window checks.
- Fixed stop label: `file-transfer-runtime-unsupported`.
- The macOS Barrier server binary advertised `--enable-drag-drop` and `--drop-dir`, but the
  disposable evidence server stopped at runtime with `setDropTarget not implemented`.
- The Linux Barrier client binary advertised `--enable-drag-drop` and `--drop-dir`, but the
  disposable evidence client reported that drag-and-drop is not supported on Linux and stopped
  at runtime with `setDropTarget not implemented`.
- Raw capture stayed on `role-capture`. The raw pcap byte length was `24`, with SHA-256
  `704e5e5b3234433c01fcfd1b20a306e77e985038120492dc53965c3edd38a4ea`. Raw capture was not
  copied into the repository.
- The capture tool reported `0 packets captured`, `0 packets received by filter` and
  `0 packets dropped by kernel`.
- The approved stream analyzer was run on `role-capture` and rejected the raw pcap with
  `no-in-scope-connection`; no sanitized output was produced.
- This is a source-validity stop before analyzable stream construction. No accepted fixture,
  register entry, width ADR or `M1-025` unblock is approved.

## Checkpoint 1 addendum — sixth-attempt plan review

- Reviewed at: `2026-10-07T04:45:04Z`
- Plan commit reviewed: `18defbdb72d1`
- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 15
- Verdict: **APPROVED FOR ONE SIXTH BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval is narrow. It approves section 15 as a pre-capture amendment only. It does not
approve any prefix width, register entry, ADR, fixture, source interpretation, production code
change, or `M1-025` unblock.

### Five-axis section-15 review

1. **Source validity / traceability — APPROVED.** Attempts 1 through 5 remain preserved as
   stopped evidence and are not reused as capture input. The large-config path uses a
   disposable normal Barrier configuration only; no Barrier or Deskflow source, source-derived
   writeup, decompiled output, instrumentation, or byte prediction is used.
2. **Product contract / architecture boundaries — APPROVED.** The amendment keeps #279's
   evidence-only scope: no production Swift, parser, codec, framer or reassembler; no edit to
   `BARRIER-EVID-0001`, `BARRIER-EVID-0002` or the accepted `M1-WIRE-001` ADR; no Windows; and
   no message, layout, chunking or width claim.
3. **Security, fail-safe and compatibility — APPROVED.** Production TLS and fail-closed defaults
   remain unchanged. Barrier cleartext remains bounded to host-local loopback legs and SSH
   carries inter-host traffic. Synthetic config labels are non-personal and temporary.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** Both
   readings still receive identical complete Linux-loopback direction streams. Explicit FIN in
   both directions remains required; both-succeed, both-fail, incomplete, sanitizer mismatch,
   config rejection or non-reproducible results stop the issue and leave M1-025 blocked.
5. **Scope control, repository hygiene and rollback — APPROVED.** The amendment is limited to
   documentation preparing a sixth attempt. It adds no fixture, ADR, register entry or raw
   artifact. Any seventh attempt requires a new amendment and review.

FINAL: **attempt 6 MAY proceed after all 15.5 checks pass.**

### Attempt-6 runtime result — 2026-10-07T04:47Z

- One bounded attempt-6 capture window was opened after the section 15 approval and fresh
  pre-window checks.
- Raw capture stayed on `role-capture`. The raw pcap byte length was `2561`, with SHA-256
  `57a6299efa5b0de97ea10daf86ae3be1709a546bcf88108d31bff9a2405ffbe2`. Raw capture was not
  copied into the repository.
- The capture tool reported `27 packets captured`, `54 packets received by filter` and
  `0 packets dropped by kernel`.
- The synthetic config contained `3000` synthetic screens, byte length `849708`, and SHA-256
  `a6fd0eb521adc7d188e6a76218edc3ff649868fef9d371e77abc31051ebd1746`.
- Runtime connection succeeded, but the large config did not produce a large captured
  application stream.
- Sanitized output: `evidence/issues/M1-WIRE-002/attempt6/sanitized.json`, byte length
  `15085`, SHA-256 `2907fbda2b8e7d25e2cd005ce821214c1506831bae3a38b9d1fe66be25af195c`.
- Analyzer result: `STOP-BOTH-SUCCEED`. The capture reconstructed one complete connection with
  FIN observed in both directions and no RST. The `client-to-server` stream length was `120`
  bytes and the `server-to-client` stream length was `187` bytes. Both `walk(S, 4)` and
  `walk(S, 2)` succeeded on every stream.
- This is source-validity stop condition 7 (non-discriminating outcome). No accepted fixture,
  register entry, width ADR or `M1-025` unblock is approved.

## Checkpoint 1 addendum — seventh-attempt plan review

- Reviewed at: `2026-10-07T05:40:47Z`
- Plan commit reviewed: `977f778919cd`
- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 16
- Verdict: **APPROVED FOR ONE SEVENTH BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval is narrow. It approves section 16 as a pre-capture amendment only. It does not
approve any prefix width, register entry, ADR, fixture, source interpretation, production code
change, or `M1-025` unblock. The reviewer is the same Codex executor operating under the
Product Owner's temporary M1 bootstrap waiver; this is not recorded as permanent independent
Critical/High review for M1 completion.

### Five-axis section-16 review

1. **Source validity / traceability — APPROVED.** Attempts 1 through 6 remain preserved as
   stopped evidence and are not reused as capture input. The long-name path uses a
   deterministic synthetic client identity through normal Barrier configuration or command-line
   inputs only. No Barrier or Deskflow source, source-derived writeup, decompiled output,
   instrumentation, packet injection, patched binary behavior, or byte prediction is used.
2. **Product contract / architecture boundaries — APPROVED.** The amendment keeps #279's
   evidence-only scope: no production Swift, parser, codec, framer or reassembler; no edit to
   `BARRIER-EVID-0001`, `BARRIER-EVID-0002` or the accepted `M1-WIRE-001` ADR; no Windows; and
   no message, layout, chunking, accepted-name-limit or width claim.
3. **Security, fail-safe and compatibility — APPROVED.** Production TLS and fail-closed
   defaults remain unchanged. Barrier cleartext remains bounded to host-local loopback legs and
   SSH carries inter-host traffic. The generated screen name is synthetic, non-personal,
   temporary, and not committed.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** Both
   readings still receive identical complete Linux-loopback direction streams. Explicit FIN in
   both directions remains required; both-succeed, both-fail, incomplete, sanitizer mismatch,
   name rejection, topology failure or non-reproducible results stop the issue and leave
   M1-025 blocked.
5. **Scope control, repository hygiene and rollback — APPROVED.** The amendment is limited to
   documentation preparing a seventh attempt. It adds no fixture, ADR, register entry or raw
   artifact. Any eighth attempt requires a new amendment and review.

Reviewer decision for section 16:

- APPROVE: attempts 1 through 6 are preserved unchanged and are not reused as capture input.
- APPROVE: a deterministic long synthetic client screen name is an acceptable normal-use
  candidate action only if both external Barrier programs accept it through normal
  configuration or command-line inputs.
- APPROVE: the long-name trigger records only metadata and predicts no byte, frame, message,
  chunking, accepted name limit or width result.
- APPROVE: the remote-forward topology keeps the only captured cleartext leg on Linux
  loopback, keeps inter-host traffic inside SSH, and requires loopback-only bindings on both
  hosts.
- APPROVE: sections 1-10 boundaries apply unchanged except for the explicit role, leg and
  trigger remapping in section 16.
- APPROVE: the 16.5 fresh pre-window checks are complete and each failure stops before the
  window opens.
- APPROVE: exactly one seventh bounded attempt; any further retry needs a new review.
- FINAL: **attempt 7 MAY proceed after all 16.5 checks pass.**

### Attempt-7 runtime result — 2026-10-07T05:45Z

- One bounded attempt-7 capture window was opened after the section 16 approval and fresh
  pre-window checks.
- Raw capture stayed on `role-capture`. The raw pcap byte length was `854578`, with SHA-256
  `490714785d07380d04c71a2beb503258783f418f0721834cbffde1ca9e2859dc`. Raw capture was not
  copied into the repository.
- The capture tool reported `169 packets captured`, `338 packets received by filter` and
  `0 packets dropped by kernel`.
- The synthetic client screen name was `70000` bytes, with SHA-256
  `77bd9c6f87d1ad04ed3ca8de8ac34d46bac2824b4539b001f0e5a2fe0c24e9bc`.
- The disposable server config was `210491` bytes, with SHA-256
  `251efacfabe6bc6f21b00e140a011b379f5be69f8f3e5a7e6d02ffef84934d42`.
- Runtime connection did **not** satisfy the approved gate: the server accepted TCP
  connections but logged `protocol error from client "<unknown>"`; the client logged `server
  reported a protocol error` and exited by timeout with code `124`.
- Sanitized output: `evidence/issues/M1-WIRE-002/attempt7/sanitized.json`, byte length
  `1187597`, SHA-256 `70c0a5930dd75cce1ae9d3536aaaa6f360fdb53e68aa15c8e0d4bd3f2f49c705`.
- Analyzer result: `DISCRIMINATING`. Width 4 succeeded on every stream; width 2 failed on
  every client-to-server stream. The first recorded width-2 failure was `connection-1`,
  `client-to-server`, offset `57514`, reason `overrun`, declared `24929`, available `12503`.
- This diagnostic analyzer result is **not accepted width evidence** because the runtime gate
  stopped first. No accepted fixture, register entry, width ADR or `M1-025` unblock is
  approved.

## Checkpoint 1 addendum — eighth-attempt plan review

- Reviewed at: `2026-10-07T05:53:56Z`
- Plan commit reviewed: `4268aa3ef61a`
- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 17
- Verdict: **APPROVED FOR ONE EIGHTH BOUNDED CAPTURE ATTEMPT**
- Critical findings: **0 open**
- High findings: **0 open**

This approval is narrow. It approves section 17 as a pre-capture amendment only. It does not
approve any prefix width, register entry, ADR, fixture, source interpretation, production code
change, or `M1-025` unblock. Attempt 7 remains stopped and is not retroactively upgraded.
The reviewer is the same Codex executor operating under the Product Owner's temporary M1
bootstrap waiver; this is not recorded as permanent independent Critical/High review for M1
completion.

### Five-axis section-17 review

1. **Source validity / traceability — APPROVED.** Attempts 1 through 7 remain preserved as
   stopped evidence and are not reused as capture input. Attempt 8 must rerun. The explicit
   protocol-error close gate treats the error as externally observable fail-closed product
   behavior only when both peer logs and complete FIN-bounded TCP streams corroborate it.
2. **Product contract / architecture boundaries — APPROVED.** The amendment keeps #279's
   evidence-only scope: no production Swift, parser, codec, framer or reassembler; no edit to
   `BARRIER-EVID-0001`, `BARRIER-EVID-0002` or the accepted `M1-WIRE-001` ADR; no Windows; and
   no message, layout, chunking, accepted-name-limit or width claim.
3. **Security, fail-safe and compatibility — APPROVED.** Production TLS and fail-closed
   defaults remain unchanged. Barrier cleartext remains bounded to host-local loopback legs and
   SSH carries inter-host traffic. Raw capture remains on `role-capture`, and the generated
   screen name is synthetic, non-personal, temporary, and not committed.
4. **Tests, validation and acceptance criteria — APPROVED FOR CAPTURE GATE ONLY.** Both
   readings still receive identical complete Linux-loopback direction streams. Explicit FIN in
   both directions remains required; both-succeed, both-fail, incomplete, sanitizer mismatch,
   missing peer protocol-error logs, topology failure or non-reproducible results stop the
   issue and leave M1-025 blocked.
5. **Scope control, repository hygiene and rollback — APPROVED.** The amendment is limited to
   documentation preparing an eighth attempt. It adds no fixture, ADR, register entry or raw
   artifact. Any ninth attempt requires a new amendment and review.

Reviewer decision for section 17:

- APPROVE: attempts 1 through 7 are preserved unchanged and are not reused as capture input.
- APPROVE: attempt 7 is not retroactively upgraded; attempt 8 must rerun.
- APPROVE: explicit protocol-error close is an acceptable bounded black-box observation only
  under all section-17.3 conditions.
- APPROVE: the long-name trigger records only metadata and predicts no byte, frame, message,
  chunking, accepted name limit or width result.
- APPROVE: the remote-forward topology keeps the only captured cleartext leg on Linux
  loopback, keeps inter-host traffic inside SSH, and requires loopback-only bindings on both
  hosts.
- APPROVE: sections 1-10 boundaries apply unchanged except for the explicit section-17 runtime
  gate.
- APPROVE: the 17.5 fresh pre-window checks are complete and each failure stops before the
  window opens.
- APPROVE: exactly one eighth bounded attempt; any further retry needs a new review.
- FINAL: **attempt 8 MAY proceed after all 17.5 checks pass.**

### Runtime attempt result — 2026-10-05T07:11:18Z

- The approved one bounded capture attempt was started after pre-window gates passed.
- During pre-window/runtime preparation, the producer fixed private tooling issues found by
  reviewer checks before execution: graceful-only timeout wrapping, `prewindow` port control
  arguments, macOS bracketed `ssh -G` loopback-forward parsing, empty failed-prewindow cleanup
  reset safety, and Linux `barriers --version` nonzero-but-parseable compatibility. These fixes
  were validated in private tooling tests only and do not approve any production code or width.
- The runtime attempt stopped at the required connection gate with fixed label
  `client-not-connected`. This is a source-validity stop under the approved plan because the
  required Barrier runtime connection did not succeed inside the bounded attempt.
- The Linux capture host reported no running evidence processes after emergency cleanup and
  explicit cleanup. The retained raw file was only a pcap header (`24` bytes), so no stream
  reconstruction, sanitizer output, privacy-scanned artifact, register entry or width ADR was
  produced.
- Raw data did not leave `role-capture`; no raw deletion was performed because Checkpoint 2 was
  not reached.
- The prior owner Barrier session was restored after the failed attempt. The macOS role reported
  `barriers running` and `server listener up`; the Linux role reported `barrierc running` and
  `connection established`.
- M1-WIRE-002 remains stopped without accepted width evidence. `M1-025` remains blocked.

## Checkpoint 2 — attempt-8 pre-registration re-derivation

- Reviewed at: `2026-10-08T02:19:12Z`
- Evidence under review:
  `Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/sanitized.json`,
  `Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/metadata.json`,
  `evidence/issues/M1-WIRE-002/attempt8/`
- Verdict: **APPROVED WITH RECORDED LOG-RETRIEVAL LIMITATION**
- Critical findings: **0 open**
- High findings: **0 open**

The retained fixture is accepted as deterministic, sanitized, machine-checkable stream evidence.
It establishes the width-4-vs-width-2 discrimination result under the fixed section-17 predicate.
It does not rely on any Barrier or Deskflow source, and it adds no production Swift code.

### Product Owner waiver for peer raw-log re-fetch

- Decision recorded at: `2026-10-08T02:19:12Z`
- Decision source: Product Owner selected option `1` in the active Codex thread after being
  told the attempt-8 remote temporary directory was unavailable and that continuing would use
  existing metadata, manual notes and prior runtime output as summarized log evidence.
- Waived requirement, limited to attempt 8 only: byte-for-byte re-fetch and hashing of peer
  runtime log excerpts for section 17.3 conditions 2 and 3.
- Not waived: complete FIN-bounded stream evidence, deterministic width-walk reproduction,
  privacy checks, clean-room boundary, no production code, no Windows claim, and no Barrier or
  Deskflow source consultation.
- Risk accepted: the protocol-error peer-log corroboration is weaker than a hashable log
  fixture, so it is recorded as summary-only evidence and as a remaining review risk.

### Re-derivation checks

- Fixture byte length is `100283`; SHA-256 is
  `6b5049bb34694130186dd147353c14c072820825c98a2ede942a49f6bab674f1`.
- The fixture records one complete connection with SYN and FIN observed in both directions and
  no RST.
- The `client-to-server` stream is `70019` bytes. Width 4 succeeds with one frame of payload
  length `70015`; width 2 fails at offset `57514`, reason `overrun`, declared `24929`,
  available `12503`.
- The `server-to-client` stream is `23` bytes. Both width 4 and width 2 partition that stream;
  discrimination comes only from the `client-to-server` stream.
- The analyzer outcome is `DISCRIMINATING` and the only surviving candidate width in the
  approved `{2, 4}` candidate set is `4`.
- Raw pcap bytes and generated long-name content are not committed. The raw pcap is recorded as
  role-capture-only with byte length `71230` and SHA-256
  `5ed5322b6edc0e3c8fd0a63776a25335de4a15d824769d1162361dfd05c6fabc`.
- Raw-pcap current availability is not independently verified after the attempt-8 temporary
  directory became unavailable. Checkpoint 2 therefore does not claim raw-pcap-to-sanitized
  fixture re-derivation; it accepts deterministic re-walking of the committed sanitized streams
  and records this as a limitation.

### Recorded limitation

The remote attempt-8 temporary directory was unavailable when rechecked, so peer runtime log
excerpts cannot be re-fetched and hashed in this repository state. Under the Product Owner's
explicit direction, the runtime peer logs are retained only as summarized evidence in
`runtime-log-excerpts.json` and `environment.json`. This limitation does not change the
machine-checkable fixture result, but it remains a review risk and is recorded rather than
silently treated as full log re-verification.

## Checkpoint 3 — attempt-8 pre-merge review

- Reviewed at: `2026-10-08T02:19:12Z`
- Verdict: **LOCAL REMEDIATION COMPLETE; SUPERSEDED BY CHECKPOINT 4 FINAL APPROVAL**
- Critical findings: **0 open in local remediation**
- High findings: **0 open in local remediation**
- Medium findings: peer raw-log re-fetch is unavailable; recorded as a limitation and review
  risk rather than a hidden pass.
- Low findings: none open after documentation and fixture-permission cleanup.

### Five-axis review

1. **Source validity / traceability — locally satisfied with limitation.** The canonical inputs
   remain the approved M1-WIRE-001 evidence, GitHub #279, section 17 of the plan, and the
   attempt-8 sanitized fixture. The peer raw-log source is unavailable for re-fetch and is
   therefore not treated as a hashable source.
2. **Product contract / architecture boundaries — satisfied.** The change is evidence,
   documentation and tests only. It adds no parser, codec, framer, reassembler, networking
   implementation or production TLS behavior. M1-025 remains the consumer that freezes the
   client wire contract from registered evidence.
3. **Security, fail-safe and compatibility — satisfied with limitation.** Raw capture and
   generated long-name content are not committed. The fixture retains only prefix-position bytes
   and no real address, hostname, user name, port, payload text, credential, key or certificate.
   Windows was not executed and no Windows behavior is claimed.
4. **Tests, validation and acceptance criteria — locally satisfied before second-pass review.**
   The local remediation gate required the M1-WIRE-002 fixture contract test, M1-WIRE-001 guard
   test, M1-023 register validator, package validator, privacy scan, `git diff --check`, and
   the repository verification target available in this bootstrap phase. Checkpoint 4 records
   the independent second-pass approval after these remediations.
5. **Scope control, repository hygiene and rollback — satisfied.** The entry appends
   `BARRIER-EVID-0003` without rewriting prior evidence. Rollback is a PR revert or a
   superseding reviewed register entry; raw captures and generated content remain out of repo.

FINAL: attempt 8 proceeded to the second-pass independent review recorded in Checkpoint 4.
`M1-025` is not started until `BARRIER-EVID-0003` is validated, reviewed and merged.

## Checkpoint 4 — attempt-8 second-pass independent review

- Reviewed at: `2026-10-08T02:35:55Z`
- Reviewer: Claude Opus 5.5 independent reviewer (Claude Code session), not the attempt-8
  producer
- Verdict: **APPROVED** — `BARRIER-EVID-0003` `provenance.reviewer.independentFromProducer`
  set to `true`
- Critical findings: **0 open**
- High findings: **0 open**
- Medium findings: peer raw-log re-fetch and raw-pcap current availability remain unverified;
  accepted as recorded limitations under the Product Owner waiver, not as passes.

Prior High findings re-checked: the only failing assertions before this checkpoint were the
`independentFromProducer` checks; the attempt-1 historical runtime block is preserved; the
Product Owner waiver is recorded with timestamp and scope; the raw-pcap availability limitation
is recorded in README, environment, metadata, register limitations, register doc and
Checkpoint 2.

Independent re-derivation in this review: fixture SHA-256 and byte length match; the retained
`client-to-server` bytes give a width-4 prefix of `70015`, exactly the remaining stream length,
while the width-2 walk reaches offset `57514` and overruns (declared `24929`, available
`12503`) on a FIN-bounded stream. No raw-pcap-to-sanitized re-derivation is claimed.
