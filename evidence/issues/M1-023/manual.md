# M1-023 Manual Verification

## Scope

This H evidence verifies the register's fail-closed governance behavior. M1-023
does not operate a protocol peer or capture packets. Real Windows/Linux Barrier
server execution is owned by M1-024, and no mock is used as a substitute.

## Steps and results

1. Compared the register fields and documentation against canonical §55, the
   M1-003 ADR evidence-register requirements, Protocol Evidence Policy, and the
   M1-007 fixture schema.
   - Expected: provenance, capture tools/date, peer version/OS/TLS,
     sanitization, fixture integrity, claims, unknowns, consumers, and review
     disposition are mandatory.
   - Actual: present in `entryContract.requiredFields` and documented.
2. Inspected the canonical register contents.
   - Expected: no wire behavior is asserted without a real approved fixture.
   - Actual: `entries` is empty and status is
     `initialized-no-approved-evidence`.
3. Ran the issue validator.
   - Expected: one in-memory complete-entry happy path passes; missing/empty
     peer version, invalid TLS, sensitive/unreviewed data, traversal, unknown
     metadata, duplicate ids, and unknown-field promotion fail.
   - Actual: 11/11 tests passed.
4. Ran all Required Commands and the cumulative repository pipeline.
   - Actual: docs/package/architecture passed; 14/14 repository gates passed.
5. Inspected repository changes for prohibited material and private content.
   - Actual: no capture, peer address/name, typed text, clipboard payload,
     credential, key, token, GPL source/header/table, or build artifact exists.

## Cleanup and fail-safe

No connection, TLS session, input event, key/button state, process, temporary
fixture, or mutable product resource is created. Cancellation, input cleanup,
and stuck-input verification are not applicable to this registry-only change.

## Reviewer disposition

The current merge review is performed by the same executor under the Product
Owner standing temporary waiver. It is not an independent C/H review. A true
independent review remains mandatory before M1 completion and before any
evidence entry receives consumable `approved` disposition.

## Remaining manual work

- M1-024: real Windows and Linux server capture/sanitization.
- #249: independent review and append-only registration of those fixtures.
- M1-025: wire contract only from registered approved evidence.
