# M1-011 Evidence Summary

GitHub Issue: #5

Implementation commit: `d3e2bd4308e245d1910ca09968b8bef385779324`

## Deliverables

- `docs/adr/M1-011-logging-policy.md`
- A C-010-compatible diagnostic envelope with fixed category, event-id, correlation-id, and metadata rules.
- A closed diagnostic error taxonomy with severity, retry, and cleanup dispositions.
- Explicit prohibited-content, pre-sink validation, failure, and rollback rules.
- Selected/rejected alternatives, consequences, security/privacy impact, compatibility impact, owners, and blocking Issues.

## Acceptance criteria mapping

- Privacy-safe focus: ADR prohibits typed text, passwords, clipboard payload/content hashes, secrets, key material, arbitrary strings, and reconstructable activity.
- Diagnostic structure: category, event id, correlation id, and metadata are explicitly defined as allowlisted typed fields.
- Diagnostic errors: closed domains/codes remain diagnosable without localized descriptions, raw errors, frames, or user content.
- Decision completeness: Selected, Rejected, Consequences, Security and privacy impact, Compatibility impact, Rollback, and acceptance evidence are present.
- Open decisions: each deferred decision has an owner and blocking Issue; no unresolved TODO/TBD exists.
- Signoff: Product Owner standing authorization is recorded; final privacy/security disposition remains required in the PR review before merge.
- Referenced paths: C-010 sources and M1-012/M1-015 issue documents exist.

## Validation

- `make docs-check`: passed.
- `python3 Tools/Backlog/validate_package.py`: `PACKAGE OK: 217 issues, 5 milestones, 17 epics`.
- `make architecture-check`: passed.
- Full `make verify`: 11/11 gates passed on native arm64.
- `git diff --check`: passed.

## Known limitations and follow-ups

- This decision Issue intentionally adds no Swift API, event catalog, sink, retention implementation, or diagnostic bundle.
- M1-015 owns the concrete Core error/diagnostic representation.
- M1-012 owns retention, OSLog integration, bundle schema, and export behavior.
- The first production emitter must add a reviewed source-controlled event and metadata catalog.

## Scope and rollback

The decision file plus this explicitly required evidence package are the entire scope. No production, protocol, wire, UI, input, networking, or TLS behavior changes.

Rollback is a normal PR revert. If a later implementation logs prohibited data, disable the event/sink, quarantine unsafe artifacts, restore the last reviewed schema, and complete Product Owner/Security incident review before re-enabling it.
