# M1-024 Evidence Summary

GitHub Issue: #17

Repository head at author run: `8b4170159b5d1ffda7d9ccbe550abbe80cf0dc40`

The author phase ran with the eleven implementation-author Exact Files
uncommitted over that head, so that head, and not an implementation commit, is
what the author-phase records can truthfully name. M1-024 lands in two commits:
the implementation commit comes into existence when root commits those eleven
files, and it contains exactly them. `independent-review.md` is the twelfth
Exact File; it does not exist yet, so it is not in that commit and lands later
in a separate review commit. The independent reviewer runs against the
implementation commit and records that exact SHA.
`evidence/issues/M1-024/manual.md` documents the full sequence.

## Deliverables

- `Tests/SystemTests/Plans/M1-024-barrier-client-handshake-fixtures.md` — capture
  plan, roles, sanitizer algorithm, closed fixture format and privacy gates.
- `Tests/SystemTests/Scripts/M1-024-barrier-client-handshake-fixtures.sh` —
  local-only fixture, evidence and lock validator plus E2E result generator.
- `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json` —
  the sanitized observation document, placed in the working tree byte for byte
  as the capture producer released it, for root to commit.
- `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/metadata.json` — fixture
  metadata conforming to `Tests/Fixtures/fixture-metadata.schema.json`.
- `evidence/e2e/M1-024/README.md` and the generated `evidence/e2e/M1-024/result.json`.
- This evidence package: `summary.md`, `commands.json`, `tests/e2e-validation.json`,
  `environment.json`, `manual.md`.

`evidence/issues/M1-024/independent-review.md` is deliberately absent. It is
written only by a reviewer who is neither the capture producer nor the
implementation author.

## What was observed

One controlled black-box observation of two lawfully installed external Barrier
programs: an external Barrier macOS client `barrierc` 2.4.0-release, protocol
1.6, connected through an encrypted local forward to an external Ubuntu 22.04
x86_64 Barrier server `barriers` 2.4.0-release, protocol 1.6. The recorder was
`tcpdump` 4.99.1 on the peer loopback, link type EN10MB, snapshot length 262144.

This is accepted attempt 8. Measured conservatively from the launcher to the
peer disconnect the bounded window ran 9 seconds, and 8 seconds from the client
log entry, both under the 15-second cap; 19 packets were captured, 38 received
by the filter and 0 dropped by the kernel.

The sanitizer kept 7 contiguous ordered observations covering both directions
and 133 aggregate application payload bytes, with 0 denylist hits. Raw packet
data never entered the repository.

## Capture-time environment metadata

Issue #17 requires the build, OS, hardware, network, keyboard layout, display
and peer metadata to be recorded before the test matrix runs. For attempt 8 the
producer recorded all of it first: capture host model and chip, core and memory
counts, active input source identifier, combined desktop bounds, and for the
peer the CPU model, logical CPU and memory counts, X display dimensions and
resolution, and X keyboard rules, model and layouts. The full table is in
`manual.md` and the machine-readable copy is in `environment.json`.

Two values are deliberately recorded as unproven: the macOS physical keyboard
layout is recorded as not captured, because an active input source identifier
is a logical selection, and individual display models and resolutions are
recorded as not reported, because only the combined desktop rectangle was.

## Non-claims

- No field meaning, message code, message boundary, endianness, framing or
  version negotiation is asserted, and no compatibility between Barrier and
  MacKVM, between Barrier versions or between platforms is asserted.
- Observation boundaries are direction runs of the captured byte stream; they
  are not messages and carry no semantics.
- The attempt 7 and attempt 8 sanitized documents differ in exactly one
  observation of identical length and direction. That difference is recorded,
  not interpreted, and nothing is asserted about its cause or its content.
- No first-party MacKVM code took part in the observation. Barrier remains an
  external test peer only; no Barrier or Deskflow source is copied, linked,
  bundled or referenced as copied.
- Both external peers ran with encryption disabled for this one observation so
  that application payload bytes were observable. The MacKVM production default
  stays TLS on and fail-closed; this observation does not exercise, change,
  weaken or validate it.
- Windows was not executed in M1 by explicit Product Owner decision
  (`docs/adr/M1-SCOPE-001-linux-only-validation.md`); no Windows result is
  claimed or implied.
- Registering this fixture as consumable Barrier evidence is not part of M1-024;
  it belongs to corrective Issue #249, and the M1-023 register is unchanged here.

## Acceptance criteria mapping

- Focus items have locatable implementation or evidence: the plan carries the
  capture procedure and non-claims, the script carries the machine-checked
  rules, the fixture pair carries the observation, and this package carries the
  command, environment and manual records.
- Test environment metadata is complete: `environment.json` records host and
  peer OS, hardware, keyboard layout, display, Barrier versions, protocol
  versions, recorder, packet counters, bounded window, network scope, TLS state
  and the Windows non-execution disposition, records that all of it was
  captured before the observation started, and the script fails closed when any
  lock-bound value drifts from the toolchain lock or when the window arithmetic
  disagrees with its own timestamps.
- Required cases have pass or fail plus evidence: seven automated cases are
  listed in `result.json`; the two red phases, the 18 mutation checks and the
  green commands are recorded in `tests/e2e-validation.json` with their exact
  exit codes.
- Failure cases are reproducible and were root-caused rather than retried: see
  `commands.json` `remediatedAttempts`, which records the attempt 7
  supersession as a procedural evidence gap and the commit self-reference as a
  validator defect, and the mutation matrix, which is regenerable from private
  mutated copies of the fixture directory.
- No stuck key or button, no suppressed local input and no leaked trust state:
  the capture producer verified cleanup on both hosts, recorded in `manual.md`;
  no first-party input, permission or trust code ran at all.
- Manual and on-device evidence verified by a non-executing reviewer: this gate
  is open. The independent review file is absent until the isolated reviewer
  writes it.

## Automated tests

- The E2E result document is schema-valid and is accepted by
  `Tools/Evidence/validate_evidence.py`.
- The system script is re-runnable with correct exit codes: it exits 0 when
  every check passes, and exits 1 without writing a result when any fixture,
  metadata, lock, evidence, provenance, privacy or claim rule fails.
- The validator checks fixture metadata, artifact digests and redaction: digests
  and byte lengths are recomputed from the files as they stand in the tree, an
  identifying pattern scan covers every Exact File present in the tree and the
  decoded payload bytes, and every hexadecimal digest in those files must be a
  declared, verified value. The eleven implementation-author files are required;
  `independent-review.md` is scanned by the same rules once the reviewer has
  created it, and cannot be required before then.
- The validator checks author-phase provenance read-only: each recorded
  `repositoryHeadAtAuthorRun` must be a full commit id that `git merge-base
  --is-ancestor` accepts as an ancestor of, or equal to, the current head, and
  a malformed, unresolvable or out-of-history value is rejected with no result
  written.

## Known limitations

- One observation of one external version pair on one locked host pair. It
  represents nothing beyond that observation.
- The observation ran with encryption disabled, so payload under TLS was not
  observed.
- The window is bounded to the connection handshake; no input, clipboard or
  screen-switch traffic exists in the fixture.
- Checksums were not validated during sanitization; fragmented, extension
  header, pcapng or retransmitted input is rejected rather than supported.
- The macOS physical keyboard layout and the individual display models and
  resolutions were not reported before capture and are therefore absent rather
  than inferred.
- The independent review has not happened yet, so no reviewed disposition may be
  inferred from this package.
- `make code-quality-check` could not complete in the implementation session:
  SwiftPM's own manifest cache and sandbox are denied by that session
  environment, so the gate stops before it evaluates any repository file. Its
  exact non-zero exit and the observed reason are recorded in `commands.json`,
  and the same test set was run with the SwiftPM sandbox disabled: `swift build`
  succeeded and `swift test -Xswiftc -warnings-as-errors` passed 47 tests with
  no compiler warning. The root reviewer separately reran the exact gate outside
  the managed outer sandbox at exit 0; that run is recorded under
  `rootReviewerVerification`, covered the author tree as it stood at
  2026-09-30T06:57:45Z, and does not replace the independent reviewer's rerun at
  the committed implementation head.
- `swift build` emits one SwiftPM packaging diagnostic that this Issue causes:
  the two new paths under `Tests/SystemTests` are unhandled files of the system
  test target. Silencing it needs an `exclude:` entry in `Package.swift`, which
  is outside the M1-024 Exact Files, so it is left as the follow-up below rather
  than as an undeclared PR expansion. It is a packaging notice, not a compiler
  warning, and it does not fail `swift build` or `swift test`.

## Rollback

- Revert the M1-024 branch. That removes the plan, script, fixture pair, result
  and evidence package. No product code, lock, ADR, schema or register is
  changed by M1-024, so nothing else has to be undone.
- Delete any remaining private capture directory and confirm the deletion, then
  re-run cleanup verification on both hosts.
- Keep Issue #249, M1-025 and every Barrier codec Issue blocked until a
  replacement fixture passes the plan.

## Follow-up

- A separate change adds an `exclude:` entry to `Package.swift` for
  `Tests/SystemTests/Plans` and `Tests/SystemTests/Scripts`, so the system test
  target stops reporting them as unhandled files. `Package.swift` is outside the
  M1-024 Exact Files, so that change belongs to its own Issue.
- The isolated reviewer writes `evidence/issues/M1-024/independent-review.md`
  against the implementation commit, records that exact SHA there, and that
  twelfth file lands in a separate review commit.
- Issue #249 performs the independent registration of this fixture before any
  consumer uses it.
- M1-025 may freeze a client wire contract only from registered approved
  evidence.
