# M2-022 Incident 001: Labels Without an Observed Source

Raised by the independent review of 2026-10-29 (`independent-review.md`, finding F2) and
handled under `docs/adr/M1-003-independent-implementation-policy.md` "Review and incident
workflow".

## Facts

- **What.** The 2026-10-29 punctuation and clipboard addendum called clipboard format 1
  "HTML", format 2 "bitmap" and clipboard id 1 "primary selection". The M2-022 decode tool
  called the fifth `DINF` field "warp".
- **Source.** The producing agent's background knowledge of how Barrier and Synergy name
  these values. No observation in the captures produces these names, and no Barrier or
  Deskflow source, header or constant table was opened for the capture or the code. The
  review found evidence against the "HTML" label: format 1 was 54 bytes for two probes of
  different length.
- **Where they were used (step 3).** All places, before this change:
  - `evidence/e2e/M2-022/punctuation-clipboard.md` (5 places) and
    `evidence/e2e/M2-022/tools/decode_stream.py` (output label only);
  - code comments: `BarrierClipboard.swift`, `BarrierServerProtocolSession.swift`,
    `BarrierClipboardTests.swift`;
  - documents: `docs/components/M2-028-barrier-clipboard-control-encoder.md`,
    `docs/components/M2-032-server-clipboard-router.md`.
- **Effect on behavior.** None. The code reads and writes only format 0 of clipboard id 0,
  as UTF-8 text, and ignores every other format and id. That behavior rests on
  observation: format 0's size equaled the probe's UTF-8 length in both directions, the
  capture's clipboard checks matched both probes, and the M2-035 smoke runs against a real
  `barrierc` passed clipboard transfers both ways, including 600 KB and 100 KB.

## Remediation in this change

The labels are withdrawn and replaced with neutral, observation-based wording in every
place listed. No code behavior changes. No history is rewritten.

## Decision needed (steps 4–6)

The Product Owner, with the licensing reviewer, decides the disposition (step 5). The
producer proposes:

- accept the neutral wording above as the remediation;
- keep the behavior, which is supported by black-box observation;
- rewrite no history.

The format and clipboard-id semantics stay "not observed" in the register entries
(BARRIER-EVID-0008).

| Decision | Owner | Status |
| --- | --- | --- |
| Disposition of the withdrawn labels | Product Owner with the licensing reviewer | decided 2026-10-29: the Product Owner accepted the proposal above, verbatim 「同意建議處置」; no separate licensing reviewer was designated |

## Resumption (step 6)

The disposition is recorded, and the remediation is the neutral wording in this change.
Work that consumes this evidence may resume under the normal gates; for the client
decoders that is `M1-PROTOCOL-003`.
