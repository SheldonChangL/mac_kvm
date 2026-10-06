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
