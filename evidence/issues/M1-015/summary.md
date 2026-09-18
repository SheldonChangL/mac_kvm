# M1-015 Evidence Summary

GitHub Issue: #14

Implementation commit: `0287018890f09b65c60144eb1fb6328c1b4fdbec`

## Deliverables

- `Packages/KVMContracts/Sources/KVMContracts/CoreErrors.swift`
- `Packages/KVMContracts/Tests/KVMContractsTests/CoreErrorsTests.swift`
- `docs/components/M1-015-core-errors.md`
- This evidence package.

## Acceptance criteria mapping

- Focus taxonomy: all ten M1-011 domains and their minimum code allowlists are
  represented by closed, typed Swift enums; the Issue's protocol, transport,
  security, permission, input, cancellation, result, and retry focus is covered.
- Privacy boundary: `CoreError` has no arbitrary string, generic underlying
  Error, payload, raw byte, address, path, identity, or content field.
- Underlying diagnostic preservation: an optional `Int32` wrapper retains a
  bounded numeric status without retaining localized or source error content.
- Happy path: a typed security failure round-trips through Codable and a typed
  cancellation remains a `CoreResult` failure.
- Boundaries: `Int32.min` and `Int32.max` diagnostic codes round-trip unchanged.
- Invalid input: unknown domain and retry values fail decoding.
- Retry semantics: never, user-mediated, bounded-backoff, and verified-state-
  change retry are distinct; only the latter two allow automatic retry.
- Cancellation/cleanup: cancellation reasons and cleanup dispositions are
  closed values; the declarations record outcomes but own no runtime resource.
- Architecture: no Barrier/native code, transport implementation, platform
  error object, OS input code, UI, logging sink, trust decision, or wire schema
  is introduced.
- Formal gates: all Required Commands and all 17 cumulative repository gates
  passed at the implementation commit.

## Security and fail-safe properties

- Unknown taxonomy input fails closed instead of selecting a permissive default.
- Cancellation is never silently changed into success.
- Retry disposition cannot imply completed cleanup; both values are independent.
- Codable conformance is not logging authorization. M1-011 still requires an
  approved event id and field schema before diagnostic emission.
- An unmapped implementation error is represented as `internal.unclassified`
  without source text.

## Scope control and follow-ups

- Implementation/test/docs changes are limited to the three Exact Files.
- Evidence files are added only because the Issue explicitly requires
  `evidence/issues/M1-015/`.
- Event catalogs and event-specific stage fields remain with their emitting
  Issues; wire-visible Native Protocol error codes remain owned by M3-010.
- Timers, backoff duration/count, cleanup execution, transport, permissions,
  trust, and UI behavior remain out of scope.

## Rollback

Revert the M1-015 PR and keep dependent session, transport, codec, permission,
clipboard, and trust Issues blocked. No runtime resource, persisted state, or
migration requires cleanup.
