# M2-035 E2E Evidence

Status: **not executed**. No live Mac server → Linux Barrier client run has
been performed, and no interoperability, input delivery, clipboard or
Windows result is claimed.

`make e2e ISSUE=M2-035` runs the local, read-only precondition gate in
`Tests/SystemTests/Scripts/M2-035-mac-to-linux-barrier-e2-e.sh`. It currently
exits 69 and lists the unmet preconditions from
`Tests/SystemTests/Plans/M2-035-mac-to-linux-barrier-e2-e.md`.

`result.json` is intentionally absent. The evidence schema permits
`not_executed` only with an approved decision reference, and no decision
approves skipping this Issue, so the gate fails closed instead of inventing
one. The operator writes `result.json` only from an executed live run.

A reachability probe of the test peer outside the repository showed
`barrierc 2.4.0-release` installed; no address, port or host data is kept
here. That probe is not E2E evidence.
