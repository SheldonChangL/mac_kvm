# M1-042 Evidence Summary

## Status

Decision document authored; signoff pending. M1-042 is not complete until the
Product Owner, Security Reviewer and an independent tier-B reviewer record
approval in the ADR signoff table.

Base commit: `a25e591b1e86359909e3837b0cf7eb0b4efb6965`; final implementation
commit is recorded in the PR and review comment.

## Dependencies

- M1-013: merged (PR #248, commit `1b31f00`); `VirtualKey` enum present in
  `Packages/KVMContracts/Sources/KVMContracts/KVMEvent.swift`.
- M1-040: merged (PR #284); independent review approved with no Critical or
  High findings. Used only as dependency status. No key-code, message-code or
  field semantics were derived from its fixture bytes.

## Deliverables

- `docs/adr/M1-042-virtual-key-catalog.md`
- `evidence/issues/M1-042/summary.md`
- `evidence/issues/M1-042/commands.json`
- `evidence/issues/M1-042/tests/results.json`

No Swift source, test, package or contract file was changed.

## Acceptance criteria mapping

| Criterion | Evidence |
|---|---|
| Focus items located | ADR "Catalog v1 members" covers letters, digits, navigation, function, media and modifiers; "Unknown-key policy" keeps the original code and bars it from platform APIs; "Catalog versioning" defines version `1` and change rules. All 26 merged `VirtualKey` cases are mapped (machine check in `tests/results.json`). |
| Selected, Rejected, Consequences, Security/Compatibility impact, Rollback | Present as ADR sections (section check in `tests/results.json`). |
| Open questions with owner and blocking condition | ADR "Open questions" table: four entries, each with owner and blocking condition; no other open question. |
| Owner/Security/Human signoff recorded | ADR "Signoff record" lists all three roles as Pending. Not satisfied until reviewers approve. |

## Automated checks

- Markdown/JSON lint: `make docs-check` passed with the M1-042 files staged.
- Referenced contract, issue and evidence paths exist.
- No TODO/TBD/FIXME/XXX placeholders in the ADR.
- `python3 Tools/Backlog/validate_package.py` and `make architecture-check`
  passed.

Details: `commands.json`, `tests/results.json`.

## Known limitations

- Catalog v1 cannot forward punctuation/OEM, keypad, Insert, Fn/Globe, media
  transport, IME or side-specific modifier keys; they become `unknown` and are
  rejected by platform mappers.
- Payload domains are enforced by mappers, not yet by `KVMContracts` decoding.
- The ADR flags that M1-043's Exact Files place a Barrier mapper in
  `KVMCore`, which conflicts with M1-002 and Frozen Decision 4; Product Owner
  decision is required before M1-043 starts.
- Manual hardware verification: not required by this Issue.

## Rollback

Revert the M1-042 PR; keep M1-043, M1-044 and M1-046 blocked until a
replacement C-005 decision is signed off. No runtime state or data is affected.
