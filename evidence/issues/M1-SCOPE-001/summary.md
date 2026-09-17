# M1-SCOPE-001 Evidence Summary

GitHub Issue: #253

Implementation commit: `c2ba1b2ea631c86d31ac74e7139bcf985021314d`

## Trigger and correction

M1-013 introduced `DeviceID` and `ScreenID` in `KVMEvent.swift` because the
canonical event model consumes them. Its documentation explicitly assigns the
complete identifier catalog and semantics-preserving declaration extraction to
M1-014. M1-014's Exact Files omitted `KVMEvent.swift`, making correct extraction
an undeclared scope violation and leaving duplication as the only in-list
alternative.

The canonical M1-014 Issue and manifest now include the existing source file.
No production code, identifier semantics, public behavior, dependency,
acceptance criterion, wire format, or frozen architecture decision changes.

## Acceptance criteria mapping

- Repository consistency: the Issue and manifest contain the same ordered four
  Exact Files, without duplicates.
- Narrow authority: the correction authorizes declaration extraction only;
  M1-014 may not change KVMEvent cases or payload semantics.
- Traceability: M1-013 documentation already records M1-014 ownership and
  semantics-preserving extraction; GitHub Issues #13 and #253 record the DoR
  blocker and corrective relation.
- Machine enforcement: a committed evidence test compares both canonical
  sources and preserves the M1-013 traceability statement.
- Formal gates: the 2-test corrective suite and all 17 cumulative repository
  gates pass at the implementation commit.
- Scope/privacy: no runtime, logging, protocol, input, network, TLS/trust,
  secret, credential, private data, or generated artifact is changed.

## TDD

The initial test failed because both canonical sources lacked
`KVMEvent.swift`. The M1-013 traceability assertion already passed. After the
two-line metadata correction, both tests pass.

## Rollback

Revert the corrective PR and keep M1-014 blocked. Do not duplicate identifiers
or silently modify a source omitted from Exact Files.
