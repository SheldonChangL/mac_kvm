# M1-018 Evidence Summary

GitHub Issue: #21

Implementation commit: `cce5e48f3627addeb362d909091f1383ba0b8536`

## Deliverables

- `Packages/KVMContracts/Sources/KVMContracts/KVMClock.swift`
- `Packages/KVMContracts/Tests/KVMContractsTests/KVMClockTests.swift`
- `docs/components/M1-018-kvmclock.md`
- This evidence package.

## Acceptance criteria mapping

- Replaceable clock: `KVMClock` retains C-004's single `sleep(for:)` public
  operation and narrows failures to the closed M1-015 `CoreError` taxonomy.
- Production clock: `ContinuousKVMClock` uses monotonic `ContinuousClock`, maps
  task cancellation to `cancellation.requested`, and retains no arbitrary
  implementation error text.
- Test clock: `TestKVMClock` advances explicitly, releases due continuations in
  deadline/registration order, and never waits for wall time.
- Deadline coverage: concurrent two- and five-second deadlines release only at
  their corresponding explicit advances.
- Backoff coverage: a 1/2/4 sequence completes through explicit advances and
  reaches seven seconds of monotonic elapsed test time.
- Boundary and invalid input: zero duration is a no-op; negative sleep and
  advance durations fail closed with `internal.preconditionFailed`.
- Cancellation/cleanup: cancelling a pending sleep removes its continuation
  and throws typed cancellation with completed cleanup; the production clock
  maps task cancellation identically.
- Architecture/privacy: no network, protocol, Barrier, UI, input, logging,
  payload, address, path, key, credential, or arbitrary error string enters the
  contract.
- Formal gates: all Required Commands and all 17 cumulative repository gates
  passed at the implementation commit.

## Scope control

- Implementation/test/docs changes are limited to the three Exact Files.
- Evidence files are added only because the Issue explicitly requires
  `evidence/issues/M1-018/`.
- Timeout error selection, numeric limits, reconnect sequence/cap, jitter,
  protocol deadlines, timeout racing, and the general async harness remain
  with their owning Issues.
- No wall-clock API, scheduler framework, transport, socket, TLS/trust policy,
  wire value, or platform behavior was introduced.

## Known limitations and follow-ups

- C-004 intentionally exposes relative monotonic sleep rather than calendar or
  absolute-instant APIs. Each consuming component owns and tests its deadline
  and timeout policy.
- M1-020 owns the repository-wide deterministic async harness built on this
  clock and M1-019 MockTransport.
- M1-060 owns the concrete reconnect sequence, cap, cancellation generation,
  and manual-disconnect semantics.
- Real protocol/network timeout races and resource cleanup remain with their
  concrete owners; this contract owns no such resource.

## Rollback

Revert the M1-018 PR and keep M1-020, M1-060, and other dependent timeout users
blocked. No runtime resource, persisted state, migration, trust state, wire
behavior, or platform input state requires cleanup.
