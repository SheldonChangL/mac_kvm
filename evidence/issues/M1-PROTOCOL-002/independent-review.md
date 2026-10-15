# M1-PROTOCOL-002 Independent Review

Reviewer: Claude Code independent reviewer
Producer: Codex M1-PROTOCOL-002 capture orchestrator
Date: 2026-10-14
Scope: `BARRIER-EVID-0005`, the M1-PROTOCOL-002 ADR, sanitized fixture,
register entry, register documentation, issue evidence package and contract
test.

## Review status

Blocking review completed. `BARRIER-EVID-0005` remains `pending-review`, and
M1-031 remains blocked until a final independent approval review records no
unresolved Critical or High findings and the register disposition is changed to
`approved`.

## Critical findings

None after remediation.

## High findings

The second independent review found two High issues before this remediation
commit:

1. The test file reconstructed the redacted peer IP from string fragments. This
   was removed and replaced with generic IPv4 and SSH-principal pattern checks.
2. The recorded validation outputs were stale because the contract test count
   changed from 9 to 10. Final approval requires rerunning the full gate suite
   and updating `commands.json` and `tests/results.json` with exact fresh
   results.

## Medium findings addressed in this remediation

- `BARRIER-EVID-0004` now has an explicit relationship note: it remains
  append-only and did not establish enter/leave/keepalive semantics, while this
  later entry is intended to resolve that M1-031-specific blocker after
  approval.
- The ADR no longer calls DINF geometry synthetic. It records that the retained
  values are real display/cursor geometry from the controlled peer, retained as
  low-sensitivity M1-031 protocol evidence.
- Coordinate handling is deterministic: M1-031 may accept only raw coordinate
  values in `0x0000...0x7fff` that also fall inside the current DINF rectangle.
- `ambiguousFields` now covers DINF reserved value, DINF cursor signedness, DINF
  size signedness/zero bounds, CINN coordinate signedness, CINN sequence
  semantics, control ordering/state-machine behavior, excluded-frame body/length
  semantics and keepalive timing.
- The trigger/observation mismatch is recorded as a capture limitation: the
  accepted evidence contains one `CINN` and one `COUT`; no repeated-enter or
  sequence-increment behavior is claimed.
- Rollback wording now preserves the register's append-only policy after merge.
- The reviewer field now records the blocking review rather than a successful
  approval placeholder.

## Low findings addressed in this remediation

- Diagnostics for skipped excluded frames may include only token, direction,
  count/length and non-sensitive reason metadata. They must not include frame
  bodies, clipboard content or key data.
- `DCLP`, `DKDN` and `DKUP` are described as excluded side-effect tokens rather
  than as frozen clipboard or keyboard semantics.

## Verified acceptance criteria

The blocking review verified the following static facts:

- ADR, fixture and test golden bytes agree for `DINF`, `CINN`, `DSOP` and
  token-only control frames.
- Retained and omitted frame counts reconcile for both directions.
- `DCLP`, `DKDN` and `DKUP` body bytes are not retained.
- `DSOP` is limited to one 4-byte zero value.
- The committed command record uses `<linux-peer>` and no longer records the
  peer address or concrete SSH principal.
- M1-032, M1-033, M1-034 and M1-041 remain blocked; this evidence is scoped to
  M1-031 only after approval.

## Executed validation commands

The independent reviewer was limited to read/grep/glob checks and did not run
the project test suite. Codex must run and record the final commands before
approval.

## Remaining risks before approval

- Public PR history previously exposed one peer address in `commands.json`; the
  current committed tree is redacted, but history rewrite requires explicit
  separate approval.
- The evidence is a single controlled capture with one accepted `CINN`/`COUT`
  transition.
- Production TLS behavior remains outside this evidence.

## Final approval review

Reviewer: Claude Code independent reviewer
Reviewed at: 2026-10-14T09:24:25Z
Disposition: Approved for M1-031 only

### Critical findings

None.

### High findings

None.

### Medium findings

- Coordinate handling is intentionally fail-closed. Negative coordinate regions
  are not accepted by this evidence; M1-031 owns any later compatibility work.
- The approval commit must update the prior pending-review assertion to
  `approved`; this file and the contract test now record that change.
- Validation must be bound to the final commit and rerun after approval edits.

### Low findings

- Public PR history previously exposed one peer address. The current committed
  tree is redacted; history rewrite requires separate explicit approval.
- DINF geometry comes from a single controlled capture and remains scoped to
  M1-031.

### Verified acceptance criteria

- No unresolved Critical or High findings remain.
- The committed command record uses `<linux-peer>` and no concrete SSH
  principal or peer IP in command records.
- Known excluded `DCLP`, `DKDN` and `DKUP` frames may only be skipped by
  complete top-level frame length; bodies remain undecoded and never enter the
  KVM input pipeline.
- DINF cursor and CINN enter coordinate signedness remain unknown; M1-031 must
  accept only raw coordinate values in `0x0000...0x7fff` that also fall within
  the current DINF rectangle.
- DINF geometry is documented as real low-sensitivity display/cursor geometry
  retained only because M1-031 consumes screen-info fields.
- `BARRIER-EVID-0004` remains unchanged and append-only; `BARRIER-EVID-0005`
  resolves only the M1-031 enter/leave/keepalive/control-message blocker.
- M1-032, M1-033, M1-034 and M1-041 remain blocked.

### Executed validation commands

The reviewer performed read/grep/glob checks only. Codex recorded the executable
validation commands in `commands.json` and `tests/results.json`.

### Exact results

- Recommendation: approve `BARRIER-EVID-0005` for M1-031 only.
- Scope exclusions remain: mouse, button, wheel, keyboard, clipboard, Windows,
  production TLS and full linked-screen compatibility.

### Remaining risks

- Single capture, one accepted `CINN`/`COUT` transition.
- Historical public PR exposure of one peer address remains unless separately
  remediated by history rewrite.

## Recommendation

Approve `BARRIER-EVID-0005` for M1-031 only. Do not consume this evidence for
M1-032, M1-033, M1-034, M1-041 or production TLS behavior.
