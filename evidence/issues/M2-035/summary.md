# M2-035 Evidence Summary

## Scope

Plan and fail-closed gate only:
`Tests/SystemTests/Plans/M2-035-mac-to-linux-barrier-e2-e.md`,
`Tests/SystemTests/Scripts/M2-035-mac-to-linux-barrier-e2-e.sh`,
`evidence/e2e/M2-035/README.md`. The Exact File
`evidence/e2e/M2-035/result.json` is intentionally not created.

## Result

`make e2e ISSUE=M2-035` → script exit 69, runner disposition
`script_failed`, listing six unmet preconditions (M2-023 not accepted,
pointer and key encodings not frozen, no server TLS listener, no app
composition root, human operator required). No live step was attempted.

A first draft wrote `status: not_executed`; the evidence validator rejects
that without an approved decision reference (`approvedDecisionRef`), and none
exists, so the gate was changed to fail closed instead of inventing one.

## Live-E2E status

Not executed. No interoperability, input, clipboard or Windows claim.

## Review

Pending independent review and a Product Owner decision on the blockers.
