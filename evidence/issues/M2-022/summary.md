# M2-022 Evidence Summary

## What exists

| Item | Location |
| --- | --- |
| Server input and client clipboard/keepalive sessions (2026-10-28) | `evidence/e2e/M2-022/README.md` |
| Punctuation keys, clipboard transfer and chunk measurement (2026-10-29) | `evidence/e2e/M2-022/punctuation-clipboard.md`, `evidence/e2e/M2-022/chunks.json` |
| Machine record | `evidence/e2e/M2-022/result.json` (validates with `Tools/Evidence/validate_evidence.py`) |
| Fixtures | `Tests/Fixtures/Barrier/m2-022-linux-server-input/`, `m2-022-linux-client-clipboard-keepalive/`, `m2-022-linux-punctuation-clipboard/` |
| Capture, sanitization and decode tools | `evidence/e2e/M2-022/tools/` |
| Independent review (2026-10-29) | `independent-review.md` |
| Register entries | BARRIER-EVID-0006, 0007 and 0008 in `evidence/registers/M1-023.json` |
| Incident: labels without an observed source | `incident-001-unobserved-labels.md` (disposition decided by the Product Owner on 2026-10-29) |

## Review outcome

No artifact was rejected. The reviewer approved the server input capture, approved the
other fixtures with conditions, and allowed `sanitizationReviewed: true`. This change
meets the conditions:

- add the 2026-10-29 artifacts and cases to `result.json`;
- shorten the metadata `reference` fields to the schema's 512 characters (F4);
- record the addendum's UTC capture time, commit, full raw hash and tool versions (F3, F8);
- retain the chunk measurement (F3);
- withdraw the unobserved labels (F2);
- correct the inferences stated as observations (F5, F6);
- note which timing values are raw-only (F7).

## Still open

- Before any client decoder consumes these layouts, a contract entry must freeze them:
  the M2-023 amendment. `frozenContractRefs` and `consumingTests` in the register entries
  stay empty until then.
- Gaps the evidence does not cover: section 5 of the review.
