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

## Checkpoint 2 — pre-deletion re-derivation

Status: **NOT STARTED**. Raw data must not be deleted until this section records an independent reproduction on the capture host.

## Checkpoint 3 — pre-merge review

Status: **NOT STARTED**. No register entry, width ADR or M1-025 unblock is approved by Checkpoint 1.
