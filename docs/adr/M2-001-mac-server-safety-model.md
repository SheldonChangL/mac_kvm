# M2-001 macOS Server Capture Safety and Threat Model

## Status

Proposed on 2026-10-27 under the Product Owner execution-order pivot that
prioritizes the M2 Mac Server MVP before the remaining M1 Issues. The pivot
supersedes only the M1-before-M2 sequencing dependency (`M1-070`). It does not
change any canonical, frozen, security, privacy, licensing, TLS, fail-safe or
evidence contract. Acceptance requires the designated Security Reviewer and a
non-implementing reviewer. Until then, downstream M2 code consumes this ADR as
a conservative proposal and must not weaken it.

## Decision owners

- Capture/suppression policy: Product Owner with Security Reviewer
- Emergency escape gesture: Product Owner
- Verification on real hardware: designated QA/Human Reviewer

## Binding sources

- `docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md` §61–§63 (Input Engine
  independent; Protocol and Core separate; TLS default on)
- `MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md` items 3, 4, 5, 6, 7, 8
- `MacKVM_Implementation_Package_v2/ARCHITECTURE_GUARDRAILS.md`
- `MacKVM_Implementation_Package_v2/CONTRACT_CATALOG.md` C-001, C-011, C-012,
  C-013, C-015
- `docs/adr/M1-011-logging-policy.md`

## Threat model

| Threat | Consequence | Control |
|---|---|---|
| Suppression stays on after the remote target is gone | The user loses the local keyboard and mouse | Suppression is enabled only in the committed `remote` state (M2-008) and every terminal path disables it synchronously before any network cleanup |
| Event tap callback blocks on network I/O | macOS disables the tap; input lag or loss | Callback only classifies and enqueues into the bounded M2-003 queue; it never awaits |
| macOS disables the tap (timeout or user input) | Captured events stop; a suppressing tap would freeze input | A tap-disabled notification is a `captureFailure`: fail open to `local` and stop suppression |
| First-party injected events are captured again | Feedback loop, runaway input | M2-006 synthetic event tagging plus own-process fallback filter |
| Keys/buttons held at switch time | Stuck modifiers or buttons on either side | No switch while any local key or button is held (M2-008 activation precondition); leave and fail-safe paths emit release effects; local held state is restored by M1-063/M2-033 |
| Typed text or clipboard reaches logs | Privacy breach | Capture adapters emit only `KVMEvent`; diagnostics use the M1-011 allowlist and never include key identity, text or clipboard bytes |
| Unknown or changed client identity | Input routed to an attacker | TLS default on; trust policy C-009 fail closed; no session, no remote state |
| Permission revoked mid-session | Capture fails | `captureFailure` → fail open to `local` |
| Sleep, termination, crash of the session task | Stuck suppression | Lifecycle actions force `local`; suppression is owned by the process and the tap is released on termination |

## Decision

### Events that may be captured

The server listens to physical pointer movement and drag, mouse button down/up
for left, right, middle and one auxiliary button, scroll wheel, key down/up,
key autorepeat and modifier flag changes. Tablet, gesture, media/system-defined
and accessibility events are not captured in the MVP.

### Events that may be suppressed

Only while the input state is the committed `remote` state defined by M2-008.
In `local`, `enteringRemote` and `leavingRemote` every event passes through to
macOS unchanged. The emergency escape chord is never suppressed. Synthetic
first-party events are never forwarded and never suppressed.

### Synthetic event identification

First-party injected events carry a process-unique source user-data marker.
Events with that marker are classified synthetic. If the marker is missing or
cannot be read, events whose source process identifier equals the current
process are also classified synthetic. Real user events never match either
rule; the filter does not inspect key identity or text.

### Emergency escape and fail-open principle

- The fixed, documented escape gesture is the chord
  Control + Option + Command + Delete (Backspace) pressed while any input state
  is active. It is detected in the capture callback before suppression is
  applied.
- Escape restores `local` without waiting for any remote acknowledgement,
  network operation, UI response or other thread.
- Fail open: when the system disables the tap, permission is revoked, the
  capture queue reports overflow of a non-coalescible event, the session fails
  or the process begins sleep/termination, the server immediately stops
  suppression and returns to `local`. Restoring local input always wins over
  delivering remote input.
- Cleanup is reentrant and best effort. A failing cleanup step does not skip
  later steps.

## Rejected alternatives

### Suppress during `enteringRemote`

Rejected. Before commit the remote side may never receive the enter; local
input must stay usable until the switch is committed.

### Implicit `isRemote` boolean

Rejected by M2-008: an untyped boolean cannot express the commit, rollback and
leave windows and has historically caused stuck suppression.

### Escape that requires the remote peer

Rejected. A lost network would make the escape unusable exactly when needed.

## Security and privacy

No typed text, key identity, clipboard payload, screen name, address, port or
key material is logged. TLS remains default on and fail closed for the server
listener; no insecure listener is enabled by this ADR.

## Compatibility

No wire format is frozen here. Barrier server encodings are owned by M2-023.
No Windows behavior is claimed.

## Consequences

M2-002 through M2-014 and M2-033 implement these rules. Any implementation that
suppresses outside `remote` or makes escape depend on the network is a
rollback condition.

## Rollback

Revert this ADR. Downstream M2 capture and suppression code must then return
to blocked state.

## Traceability

Issue: `MacKVM_Implementation_Package_v2/issues/M2/M2-001-mac-server-safety-model.md`.
