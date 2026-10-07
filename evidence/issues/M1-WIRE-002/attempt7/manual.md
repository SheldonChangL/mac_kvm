# M1-WIRE-002 Attempt 7 Manual Log

## Gate

- Plan section: `evidence/issues/M1-WIRE-002/discrimination-plan.md` section 16.
- Checkpoint 1 approval: `evidence/issues/M1-WIRE-002/independent-review.md`,
  `2026-10-07T05:40:47Z`.
- Approved scope: one bounded seventh attempt using a deterministic long synthetic client
  screen name.

## Execution

- Attempt started: `2026-10-07T05:44:59Z`.
- Attempt completed: `2026-10-07T05:45:33Z`.
- Topology: macOS server, Linux client and capture host, SSH remote-forward inter-host leg,
  Linux loopback as the only captured cleartext leg.
- Synthetic name: generated from the recorded recipe in `environment.json`; the generated name
  itself is not committed.
- Raw capture stayed on `role-capture`.
- Sanitized output copied into this repository only after the analyzer allowlist sanitizer
  completed.

## Runtime result

- The disposable macOS server started and accepted TCP client connections.
- The Linux client emitted complete FIN-bounded streams and then reported `server reported a
  protocol error`.
- The server reported `protocol error from client "<unknown>"`.
- The client process was bounded by timeout and exited with code `124`.
- Under the approved section-16 stop rule, this is not an accepted runtime connection success.

## Analyzer result

- Analyzer output: `DISCRIMINATING`.
- Width 4 succeeded on every stream.
- Width 2 failed on every client-to-server stream.
- This diagnostic result is preserved in `sanitized.json` and `diagnostic-summary.json`, but
  it is not promoted to a fixture, register entry, width ADR, or `M1-025` unblock because the
  runtime gate stopped first.

## Restoration

- The owner Barrier server listener was restored on macOS.
- The Linux owner Barrier client was restored to a single running client process after a
  duplicate retrying restore client was terminated.

## Non-claims

- No Barrier or Deskflow source, source-derived writeup, decompiled output, instrumentation,
  packet injection, patched binary behavior, or generated protocol byte sequence was used.
- No Windows host was used.
- No production Swift, parser, codec, framer, reassembler, TLS default, or MacKVM runtime
  behavior was changed.
- No register entry, width ADR, fixture acceptance, or `M1-025` unblock is approved by this
  stopped attempt.
