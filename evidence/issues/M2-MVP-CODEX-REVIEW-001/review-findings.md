# M2 Mac Server MVP — Independent Codex Review (in progress)

Review head: `c32f619046fe5c4529d39df572dbce70dc60d9fc`

Reviewer: Codex, independent of the Claude implementation author. This review
is intentionally not a merge approval. The branch is not mergeable while any
High finding below remains open, while dependency ordering is unresolved, or
while live server TLS and Mac-to-Linux evidence are absent.

## Five-axis result

1. **Source validity / traceability: fail.** The formal M2 dependency graph has
   not been updated for the Product Owner's M2 pivot, and several implemented
   slices precede their declared dependencies.
2. **Product contract / architecture boundaries: partial pass.** The Swift
   package boundaries and `KVMEvent` protocol boundary pass the automated
   architecture gate. Issue-level dependency and Exact Files ownership still
   have blockers.
3. **Security / fail-safe / compatibility: fail.** Production server TLS is not
   assembled, live Barrier compatibility is not demonstrated, and two
   cancellation paths can act on the wrong or stale input operation.
4. **Tests / validation / acceptance criteria: fail.** The 24 automated gates
   pass, but two reviewer-authored regression probes fail and Tier-H evidence
   required by M2-004/M2-005/M2-022/M2-035 is missing.
5. **Scope control / repository hygiene / rollback: partial pass.** The working
   tree was clean before and after the probes, no probe remains, and no push or
   merge was performed. The stacked branch cannot yet be treated as one
   issue-scoped PR.

## Critical findings

None identified in the reviewed subset. This is not a final Critical-clear
statement for the full 129-file branch.

## High findings

### H-1 — Formal dependency graph still blocks the M2 pivot

- `M2-001` formally depends on `M1-070` and says the dependency must be
  complete before implementation.
- `docs/adr/M2-001-mac-server-safety-model.md` describes the pivot only inside
  a **Proposed** ADR. That document cannot silently replace the backlog source.
- Owner: Product Owner + backlog author (Claude).
- Priority: P0.
- Blocking relation: blocks M2-001 and every downstream M2 implementation PR.
- Required disposition: add the approved sequencing exception to the formal
  backlog/traceability sources, or finish M1-070 first. Do not merely edit an
  acceptance criterion to match the branch.

### H-2 — `CaptureQueue` cancellation can cancel a different consumer

`CaptureQueue.next()` stores one shared continuation. Its cancellation handler
unconditionally removes and resumes that continuation, without proving it
belongs to the cancelling task. A pre-cancelled second consumer therefore
cancels the already-waiting first consumer.

- Production location: `Packages/KVMCore/Sources/KVMCore/CaptureQueue.swift`,
  cancellation handler around lines 158–164.
- Reviewer probe: start the first waiter, call `next()` from a pre-cancelled
  second task, then enqueue an event for the first waiter.
- Exact result: the first waiter threw
  `CoreError.cancellation.requested`; the test failed with one issue.
- Owner: M2-003 implementation author (Claude).
- Priority: P0; input-safety concurrency bug.
- Blocking relation: blocks M2-003, M2-004, M2-005 and M2-022.
- Required disposition: waiter ownership/tokenisation plus a deterministic
  always-running regression test. Cancellation may only remove its own waiter.

### H-3 — M2-005 has an undeclared cross-Issue compile dependency

`MacKeyboardCapture.map` returns `MacCapturedInput`, but that type is declared
inside the M2-004 Exact File `MacMouseCapture.swift`. M2-005 declares M2-002,
M2-003, M1-042 and M1-046 as dependencies, not M2-004. Therefore the M2-005
commit cannot compile as an isolated issue branch from its declared base.

M1-046 is also still recorded by the author evidence as unmerged, so the
M2-005 precondition is not met.

- Owner: backlog author + M2-005 implementation author (Claude).
- Priority: P0.
- Blocking relation: blocks M2-005 and therefore M2-022.
- Required disposition: give the shared capture envelope explicit ownership
  in a dependency/Exact File and update the graph, without expanding M2-005
  silently. Then rebase/rebuild the isolated slice and complete Tier-H review.

### H-4 — Cancelling a queued `ServerSession` writer still sends stale input

`ServerSession.acquireWriter()` queues an unowned continuation and has no task
cancellation handler. A cancelled `forward()` remains in the writer queue and
sends its event after the earlier write completes.

- Production location: `Packages/KVMCore/Sources/KVMCore/ServerSession.swift`,
  writer queue around lines 119–149.
- Reviewer probe: hold a key-down send, queue key-up, cancel the key-up task,
  then release key-down.
- Exact result: the cancelled task threw no error and the fake protocol session
  recorded the stale key-up; the probe failed with two issues.
- Owner: M2-029 implementation author (Claude).
- Priority: P0; stale remote input can create incorrect key state.
- Blocking relation: blocks M2-029, session composition and M2-035.
- Required disposition: cancellation-aware FIFO ownership and a deterministic
  regression test proving a cancelled queued writer neither sends nor strands
  later writers.

### H-5 — Evidence-first protocol order is not satisfied

M2-022 depends on M2-004 and M2-005. M2-023 depends on M2-022. The branch
already contains the proposed M2-023 ADR and downstream listener/handshake/
encoder/session implementations while M2-022 has no capture result and all of
these GitHub Issues remain open.

- Owner: Product Owner + M2-022/M2-023 authors.
- Priority: P0.
- Blocking relation: blocks freezing M2-023 and merging M2-024 onward.
- Required disposition: merge valid prerequisites, execute the approved
  sanitized Mac-server/Linux-client capture, independently review it, and only
  then freeze or revise the wire contract. No unfrozen input bytes may be
  guessed in the meantime.

### H-6 — Production Mac server TLS path is absent

The proposed M2-023 ADR explicitly says no server identity provisioning
decision or production TLS listener exists. Automated protocol tests use
abstract/plain test transports. The canonical product contract requires TLS
default-on and fail-closed; therefore this branch cannot be called a runnable
production-behavior Mac server MVP.

- Owner: Product Owner for identity ADR; Claude for implementation.
- Priority: P0 security.
- Blocking relation: blocks app composition, M2-035 and any MVP/merge claim.
- Required disposition: formal TLS server identity ADR, concrete
  Network.framework listener integration, identity-change rejection, and live
  evidence. No plaintext production fallback.

## Medium findings

### M-1 — Listener stop does not close pending admissions

`BarrierListenerTransport.stop()` disconnects only admitted transports.
Transports currently inside `connect()` are represented only by `pendingCount`,
so stop cannot disconnect them; a non-cooperative pending connect remains until
its timeout path acts. Track pending transports/tasks and prove stop releases
them promptly and idempotently.

### M-2 — Tier-H capture acceptance is missing

M2-004 and M2-005 require independent real-hardware evidence. Their summaries
explicitly say it was not performed. Unit tests demonstrate mapping only; they
do not demonstrate the final signed application's event-tap identity,
permission, callback latency or cleanup behavior.

## Low findings

None recorded yet. Lower-severity review continues after the High findings are
returned to the author.

## Executed validation commands and exact results

1. `make verify REPORT=/private/tmp/mackvm-m2-codex-review-report.json`
   at the review head: **24/24 gates passed**, zero non-passing gates, all exit
   codes `0`.
2. `swift test --package-path Packages/KVMCore --filter
   cancelledSecondConsumerDoesNotCancelFirst`: could not run because SwiftPM's
   nested sandbox failed during manifest evaluation. This is not product-test
   evidence.
3. `swift test --disable-sandbox --package-path Packages/KVMCore --filter
   cancelledSecondConsumerDoesNotCancelFirst`: **exit 1**; build succeeded and
   the single reviewer probe failed because the first waiter received the
   second task's cancellation.
4. `swift test --disable-sandbox --package-path Packages/KVMCore --filter
   cancelledQueuedWriterDoesNotSend`: **exit 1**; build succeeded and the
   single reviewer probe failed with two issues: no cancellation error and a
   stale key-up was sent.
5. `git status --short --branch`: clean branch after removing both temporary
   probe changes.

The temporary probes were review instrumentation only, were never committed,
and were removed immediately after execution. Their required final form is an
always-running regression test authored with the corresponding fix.

## Verified acceptance criteria

- Automated manifest, docs, architecture, code-quality, tool/evidence test,
  Swift test/build and native arm64 build gates all pass at the review head.
- Package visibility is used for new Swift declarations; no new public API was
  observed in the reviewed subset.
- No production input payload logging was observed in the reviewed subset.
- The working tree is clean and no direct push to `main`, PR merge or capture
  was performed by this review.

These passes do not override the open High findings or missing Tier-H evidence.

## Remaining risks and next gate

The review is incomplete for the remaining session manager, routing,
suppression and fail-safe interactions. Claude OAuth currently returns
`401 OAuth access token has expired`, so the designated implementation author
cannot receive these fixes yet. Resume the same Claude session only after
successful re-authentication; then require RED→GREEN fixes for H-2/H-3/H-4,
formalize H-1/H-5/H-6 in the backlog, rerun `make verify`, and repeat this
independent review before any PR is made Ready.
