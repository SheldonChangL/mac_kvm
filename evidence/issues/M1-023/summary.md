# M1-023 Evidence Summary

GitHub Issue: #12

Implementation commit: `706fa8a6295140ad745cb6d03ca176eddf065bd3`

## Deliverables

- `docs/evidence/M1-023-barrier-evidence-register.md`
- `evidence/registers/M1-023.json`
- Re-runnable register contract tests and this evidence package.

## Acceptance criteria mapping

- Wire-claim traceability: every future claim must reside in a stable evidence
  entry with source, fixture path/hash/length, claim id, evidence locations,
  limitations, unknown fields, frozen contracts, and consuming tests.
- Server environment: peer product/version/role, OS name/version/build, capture
  date/tools, network scope, and explicit TLS state/version are mandatory paths.
- Unknown fields: ambiguity remains `unknown`; the validator rejects using the
  same field id in an established wire claim.
- Provenance/licensing: only lawful public specifications, controlled black-box
  captures, and sanitized vectors are permitted; implementation-derived GPL
  material is explicitly prohibited.
- Privacy: sensitive fixtures, unsanitized certificate identity, unreviewed
  entries, path traversal, symlinks, length/hash mismatch, and unknown metadata
  fail closed.
- Happy path: a complete in-memory approved-entry example passes the contract
  validator but is never persisted or represented as real evidence.
- Boundary/invalid behavior: missing or empty server version, invalid TLS
  metadata, sensitive data, producer self-review, traversal, duplicate ids,
  unknown metadata, and unknown-to-known promotion are rejected.
- Cancel/cleanup/idempotency: no async work, transport, process, input state, or
  mutable runtime resource exists in this registry-only change; not applicable.
- Architecture/public behavior: no Swift API, parser, encoder, message code,
  networking, TLS policy, KVM Core behavior, input behavior, or UI is added.
- Formal gates: all Required Commands, the 11-test register suite, and all 14
  cumulative repository gates pass at the implementation commit.

## Fail-closed initial state

The canonical register intentionally contains zero entries and status
`initialized-no-approved-evidence`. No Barrier wire byte, field meaning, server
version, TLS observation, or compatibility claim is inferred. M1-024 owns the
real Windows/Linux captures; only independently reviewed entries can later use
the `approved` disposition.

## Review and follow-up

- The Product Owner standing authorization permits same-executor five-axis
  review as a temporary merge gate, but it does not satisfy the final
  independent C/H review obligation.
- Medium workflow finding: M1-024's Exact Files did not provide an explicit
  register-update owner. Corrective Issue #249 is assigned to @SheldonChangL,
  priority P0, milestone M1, depends on M1-024, and blocks M1-025.
- M1-024, #249, and M1-025 must preserve real-peer, sanitization, provenance,
  licensing, independent-review, and unknown-field gates.

## Rollback

Revert the M1-023 PR and keep M1-024, #249, M1-025, and every Barrier codec
Issue blocked until an equivalent fail-closed register is restored. No runtime
or persisted user state requires cleanup.
