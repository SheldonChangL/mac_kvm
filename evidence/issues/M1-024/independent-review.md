# M1-024 Independent Review

GitHub Issue: #17

Implementation commit under review: `710ce0be68e0df496c1600e2e8b643ae5209d774`

## Reviewer identity and independence

This review was produced by a fresh, isolated Claude reviewer session. That
session is neither the capture producer nor the implementation author. It did
not run the observation, did not author the sanitizer, and did not write any of
the eleven implementation-author Exact Files carried by the implementation
commit. It authored only this file, the twelfth Exact File, and it authored no
other repository file. The only repository file it caused to change besides this
one is the generated `evidence/e2e/M1-024/result.json`, which
`make e2e ISSUE=M1-024` rewrites on every run.

The reviewer did not stage, commit, push, or change any GitHub state. Live
Issue #17 was read once, read-only, for source verification. The two untracked
owner artifacts at the repository root are outside M1-024 and were not opened.

This review does not replace the registration of the fixture as consumable
evidence. That remains out of scope here and belongs to corrective Issue #249,
as the plan states.

## Finding counts

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 6 |

No Critical, High or Medium finding exists. The six Low findings are recorded
below with their axis; none blocks this Issue and none requires a change to the
implementation commit.

## Axis 1 — Source validity and traceability

Verified:

- The packaged Issue source
  `MacKVM_Implementation_Package_v2/issues/M1/M1-024-barrier-client-handshake-fixtures.md`
  and the body of live GitHub Issue #17 are byte-identical apart from one
  trailing newline. There is no drift between the canonical local source and the
  remote Issue.
- `MacKVM_Implementation_Package_v2/issues_manifest.json` lists the same twelve
  Exact Files as the Issue, in the same order, with `depends_on` naming M1-023
  only.
- The dependency register `evidence/registers/M1-023.json` is present, is
  readable, names M1-024 as `nextEvidenceIssue`, and is unchanged by this
  commit. It still records `initialized-no-approved-evidence`, so this fixture is
  correctly not yet registered as approved evidence.
- `MacKVM_Implementation_Package_v2/toolchain.lock.json` is present with
  `lock_id` `M1-CAPTURE-TOOLCHAIN-001`, `status` `LOCKED`, scope
  `M1_CONTROLLED_BARRIER_BLACK_BOX_CAPTURE_ONLY` and `scoped_issues` limited to
  M1-024. Its ADR `docs/adr/M1-CAPTURE-TOOLCHAIN-001-capture-readiness.md`,
  `docs/adr/M1-SCOPE-001-linux-only-validation.md`,
  `MacKVM_Implementation_Package_v2/PROTOCOL_EVIDENCE_POLICY.md`,
  `MacKVM_Implementation_Package_v2/ARCHITECTURE_GUARDRAILS.md`,
  `MacKVM_Implementation_Package_v2/DEFINITION_OF_READY.md` and
  `MacKVM_Implementation_Package_v2/DEFINITION_OF_DONE.md` were all read and are
  all readable.
- Every value in `evidence/issues/M1-024/environment.json` that the lock pins was
  compared against the lock and matches exactly: host OS name, version and build,
  host architecture, host Barrier client executable, version and protocol
  version, peer OS name and version, peer architecture, peer Barrier server
  executable, version and protocol version, recorder name and version, the
  version-checked alternative recorder, the Barrier role, and the Windows
  non-execution flag.
- No canonical or frozen source conflicts with this Issue. No required source was
  missing.
- No `AGENTS.md` exists anywhere in this repository, and it has never existed in
  any ref of its history. Nothing in the repository references one, and the
  canonical agent instruction document is
  `MacKVM_Implementation_Package_v2/AGENT_EXECUTION_PROMPT.md`. Prior evidence
  packages record the same absence, so this is a stable property and not a
  missing source.

Finding L-1 (Low, documentation accuracy). The Status section of
`Tests/SystemTests/Plans/M1-024-barrier-client-handshake-fixtures.md`, the
Reviewer section of `evidence/issues/M1-024/manual.md`, and the corresponding
limitation in `evidence/issues/M1-024/summary.md` each state that the
independent review has not happened and that this file is absent. Those
statements were true of the implementation commit and become stale once the
separate review commit adds this file. The design routes the live signal
elsewhere: the generated `result.json` `evidence-inputs` case reports the
presence of this file on every run, and it flips from `not yet` to `yes` in the
same run that this file exists. The three author-phase documents are
implementation-author Exact Files that this reviewer must not edit, so the
staleness is left recorded here rather than silently patched.

## Axis 2 — Product contract and architecture boundaries

Verified:

- The implementation commit contains exactly eleven files and every one of them
  is an Exact File of Issue #17. Nothing outside the Exact Files was added,
  changed or deleted. The twelfth Exact File is this review file and was absent
  from that commit, as the plan requires.
- No Swift source, no package manifest, no ADR, no contract, no schema, no
  toolchain lock and no evidence register is touched by the commit. The KVM Core
  and Input Engine boundaries are therefore untouched by construction, and
  `make architecture-check` confirms it at the current head.
- Barrier remains an external adapter-side test peer only. The lock records the
  role `EXTERNAL_TEST_PEER_ONLY` and
  `implementation_in_repository: NONE_COPIED_LINKED_OR_BUNDLED`. The only Barrier
  module in the tree, `Packages/BarrierCompatibility`, still holds a single
  boundary comment and no behavior, and this commit does not change it.
- No Barrier, Deskflow or other third-party source, header or implementation is
  present in the commit or referenced as copied. The temporary sanitizer was
  written against public pcap, Ethernet, IPv4, IPv6 and TCP structure only, is
  not an Exact File, and is not in the repository or its history.
- No public contract is added and nothing frozen is altered, which matches the
  Issue's Frozen Contract References section.

No finding on this axis.

## Axis 3 — Security, privacy, fail-safe and non-claim behavior

Verified:

- Production TLS default is untouched and unvalidated.
  `environment.json` records `observationTlsEnabled` false,
  `productDefaultTlsEnabled` true and `productTlsValidatedByThisObservation`
  false, and the system script requires exactly those three values. Because the
  commit contains no product code, the default cannot have been weakened by it.
- Windows was not executed. The lock records `windows_executed` false,
  `environment.json` records `executed` false and `resultClaimed` false against
  `docs/adr/M1-SCOPE-001-linux-only-validation.md`, and the validator's
  non-claim scan rejects any document line that pairs Windows with an execution
  or pass assertion. No reviewed document claims a Windows result.
- No document asserts field meaning, message code, endianness, framing, message
  boundaries or interoperability between the products. Every such statement in
  the reviewed documents is negated. The fixture itself stores nothing but
  ordered direction labels and opaque base64 payload runs.
- The fixture carries no timestamp, address, port or transport metadata key.
  Its four top-level keys and three per-observation keys are exactly those the
  plan closes.
- An independent identifying-content scan, written by this reviewer and using
  the same pattern families as
  `Tests/Contracts/test_m1_024_capture_readiness.py`, was run over all eleven
  committed files and over the decoded payload bytes. It reported no IPv4 or
  IPv6 literal, no user-home path, no email address, no local host name, no
  certificate fingerprint, no PEM material and no credential token, and no
  hexadecimal run that is not a declared and independently verified digest.
- No tracked repository path is a raw packet capture. The current run checked
  539 tracked paths and the fixture directory holds only its two files.
- The validator fails closed. Any malformed, missing, stale, oversized,
  secret-bearing, claim-bearing or out-of-history input causes exit 1 and no
  result file. It never reports `not_executed` for a missing input.
- The non-claim scan demonstrably covers this review file too. An earlier draft
  of this document was rejected by `make e2e ISSUE=M1-024` with
  `independent-review.md asserts a Windows result`, because one paragraph named
  that platform alongside an unnegated outcome word. The run exited 1, wrote no
  result and left the tracked result deleted, exactly as the fail-closed rule
  specifies. The wording was corrected and the rerun passed. The twelfth Exact
  File is therefore not exempt from the gate that guards the other eleven.
- Fail-safe on the device side is recorded and is credible: no first-party input,
  permission or trust code ran at all, the peer server, recorder and listener
  were confirmed gone, the local tunnel and local listener were confirmed gone,
  no key or pointer button was left stuck, local input was not suppressed, and
  no new trust entry or permission grant was created.

Finding L-2 (Low, privacy tooling scope). Two entries of the producer's private
denylist are ordinary technical vocabulary rather than distinctive identifiers:
one is a standard loopback label and one is a common English noun. Both
therefore also occur as ordinary vocabulary inside the committed plan, system
script and manual, in eleven places in total. Each of those occurrences is
generic prose or a pattern label, and none of them discloses a host, account,
address, path or port value. The plan scopes the denylist to the decoded payload
bytes, and there it is clean: the producer reported zero hits and this reviewer's
own independent sanitizer run over the same raw capture with the same denylist
also produced zero hits. The consequence of the overlap is over-rejection inside
the payload scan, never under-detection, so the failure direction is safe. It is
recorded because a future capture whose payload happens to contain that common
noun would be rejected and would need investigating rather than editing.

Finding L-3 (Low, developer ergonomics of a deliberate fail-closed rule). The
system script deletes any existing regular file at
`evidence/e2e/M1-024/result.json` before it validates anything. That is what
makes "any failure writes no result" true and it is what the mutation matrix
depends on, so the behavior is correct. The side effect is that a failing
`make e2e ISSUE=M1-024` leaves the tracked `result.json` deleted in the working
tree, and the developer has to restore it from git after fixing the cause. This
is worth knowing before a first failed run; it is not a defect.

## Axis 4 — Tests, validation, manual evidence and Acceptance Criteria

### Automated validation logic, inspected rather than trusted

The system script was read in full. It is local only: the single external
program it runs is `git`, read-only, for the head and the tracked file list. It
never invokes ssh, scp, tcpdump, dumpcap, the external Barrier client or the
external Barrier server, and it never reads a private directory. Its checks are
real rather than nominal: it recomputes the payload digest and byte length from
the bytes in the tree, it re-encodes every base64 payload and requires an exact
round trip, it requires a contiguous 1-based sequence and both directions, it
bounds per-observation and aggregate payload size, it pins every lock-bound
value, it re-derives the observation window arithmetic from the window's own
timestamps, it requires every red-phase and mutation record to carry a non-zero
exit code and every mutation record to carry `resultWritten` false, and it
requires every green-phase record to carry exit code 0.

The commit-lineage rule was inspected directly. `commands.json`,
`environment.json` and `tests/e2e-validation.json` each carry
`repositoryHeadAtAuthorRun`. The validator requires that value to be a full
lowercase forty-character commit id and then calls
`git merge-base --is-ancestor <value> <current head>` read-only. Exit status 1
is rejected as "not an ancestor of, or equal to, HEAD", any other non-zero status
is rejected as "cannot be resolved in this repository", and a failed or
unavailable git invocation is rejected as well. Equality with the current head is
deliberately not required, which is correct: the eleven files cannot name the
commit that contains them, so an equality rule would make the resulting tree
permanently unable to pass its own gate. The recorded value
`8b4170159b5d1ffda7d9ccbe550abbe80cf0dc40` is the parent of the implementation
commit, so the ancestor relation holds.

The regression this rule was written for was re-tested at the current head. HEAD
is now the implementation commit and `make e2e ISSUE=M1-024` exits 0 with
`e2e disposition: passed`. The three fail-closed cases are recorded in
`tests/e2e-validation.json` as `provenance-malformed-head`,
`provenance-unresolvable-head` and `provenance-non-ancestor-head`, each exiting
non-zero with a specific reason and each leaving no result file, and the code
paths that produce those three rejections were read and match the recorded
reasons.

### Exact commands, exit codes and results

All commands were run by this reviewer at the implementation commit.

| # | Command | Exit | Result |
|---|---|---|---|
| 1 | `git status --porcelain` | 0 | only the generated result and the two untracked owner artifacts outside this Issue |
| 2 | `git show --stat 710ce0be68e0df496c1600e2e8b643ae5209d774` | 0 | 11 files changed, 3556 insertions, 0 deletions |
| 3 | `bash -n Tests/SystemTests/Scripts/M1-024-barrier-client-handshake-fixtures.sh` | 0 | parses, no output |
| 4 | `make e2e ISSUE=M1-024` | 0 | `e2e script exit: 0`, `e2e disposition: passed`, `e2e exit: 0` |
| 5 | `python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-024/result.json --expected-issue M1-024 --require-passed` | 0 | `evidence valid: issue=M1-024 status=passed` |
| 6 | `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| 7 | `make architecture-check` | 0 | `architecture check OK` |
| 8 | `make docs-check` | 0 | `docs check OK` |
| 9 | `make code-quality-check` | 2 | environmental failure, resolved independently; see below |
| 10 | `python3 -m unittest discover -s Tests/Contracts -p 'test_m1_024_capture_readiness.py'` | 0 | 15 tests, OK |
| 11 | `python3 -m unittest discover -s Tools/Evidence/tests -p 'test_*.py'` | 0 | 144 tests, OK |
| 12 | `git diff --check` | 0 | no whitespace error, no output |
| 13 | reviewer identifying-content and denylist scan over the commit and the decoded payload | 0 | no finding; see Axis 3 |

### The one environmental failure and its independent resolution

`make code-quality-check` exited 2 in this reviewer session. Its first two steps,
`swift-format-version` and `swift-format-lint`, both exited 0. The third step,
`swift-test-warnings-as-errors`, exited 1. The cause was isolated directly: a
bare `swift build` in the same session fails while resolving the package
manifest with `sandbox-exec: sandbox_apply: Operation not permitted`, together
with three warnings that the SwiftPM user-level configuration, security and
cache directories are not writable. SwiftPM cannot start its own nested sandbox
inside the managed outer sandbox this session runs in, so the gate stops before
it evaluates any repository file. This is an environment limitation of the
reviewer session, not a product failure, and the implementation commit contains
no Swift source, no package manifest and no build setting that could cause it.

The root-supplied committed-head verification report was then validated as data
rather than accepted as prose. It parses as JSON. Its `commit` field equals
`710ce0be68e0df496c1600e2e8b643ae5209d774`, the implementation commit under
review. Its `status` is `passed`. It carries 21 named gates and every one of them
carries `status` `passed` with `exitCode` 0, with no exception: manifest
validation, docs check, architecture check, code quality, tool test discovery,
evidence test discovery, eight individual tool test suites, two evidence test
suites, two Swift package test suites, the repository contract test suite, the
Swift test target check and the native arm64 build. Every gate's start and end
timestamp is ordered and lies inside the report's own overall window, which runs
after the implementation commit was created. The `code-quality` gate in that
report ran the same tool with three stdout lines and exit 0, which is consistent
with all three of its steps passing once SwiftPM is not blocked. The report
records the same locked toolchain: arm64, macOS 26.6.2, system Python 3.9.6 and
Apple Swift 6.2.3.

This independently resolves command 9. The gate is not claimed as passing inside
this reviewer session; it is claimed as passing at the implementation commit on
the basis of a machine-readable report whose every field was checked here.

### Acceptance Criteria, item by item

AC1 — every Focus item has locatable implementation, test or sign-off evidence.
Verified. At least one real Linux Barrier server observation exists and is not a
mock: the raw capture is a real 1731-byte pcap held privately, and this reviewer
re-derived the committed fixture from it. Host name, address, clipboard and
input content are absent, checked by two independent scans. Metadata and
reproduction steps exist as `metadata.json` and the capture plan. Windows server
capture is excluded by ADR. The raw capture is outside the repository. The
fixture holds ordered direction and uninterpreted payload bytes only, with the
encoding documented in the plan. Nothing claims field meaning, message code,
endianness or interoperability. The fixture, the mandatory evidence package and
this non-implementer review are all present.

AC2 — test environment metadata complete, every required case has pass or fail
plus evidence. Verified. `environment.json` records host and peer OS, build,
architecture, hardware, keyboard, display, Barrier and protocol versions,
recorder and packet counters, the bounded window, network scope, TLS state,
the M1-SCOPE-001 platform disposition and the privacy flags, and records that all of it was queried
before the observation started, by whom, and for which attempt. Seven automated
cases in `result.json` are all `passed` with exit code 0. Two red phases, 18
mutation checks and 16 green commands are recorded with exact exit codes.

AC3 — failure cases reproducible, no retry-until-green. Verified. Six remediated
attempts are recorded with a root cause and a resolution each, including one
where the mutation harness itself was wrong, one where the validator's own
head rule was wrong, and the supersession of attempt 7. None was resolved by
rerunning until the outcome looked better. The supersession of attempt 7 is
recorded as a procedural evidence-ordering gap, its sanitized bytes never
entered git history, and no retroactive conformance is claimed for it. The two
sanitized documents differ in exactly one observation of identical length and
direction; this review records that difference and, like the package, asserts
nothing whatsoever about its cause or its content.

AC4 — no stuck key or button, no permanently suppressed local input, no leaked
trust state. Verified against the producer's cleanup table and the fact that no
first-party input, permission or trust code ran at all. The observation ran with
encryption disabled, so no certificate identity was stored and no trust entry
could be created.

AC5 — manual and on-device evidence verified by a reviewer who is not the
executing agent. This document is that verification.

Automated-test criteria: the E2E result JSON conforms to its schema and is
accepted by the evidence validator; the test script is rerunnable with correct
exit codes, which this reviewer confirmed by rerunning it twice at the current
head; and the evidence validator checks metadata, artifacts and redaction, with
digests and byte lengths recomputed from the files as they stand in the tree.

Finding L-4 (Low, an inherent property of the sanitizer, for the attention of
Issue #249). Direction labelling depends entirely on the server test port the
operator passes in, as the plan's step 4 states. The rule is symmetric, so the
other endpoint's port also yields a structurally valid document. This reviewer
confirmed that concretely: over the documented port range exactly two port
values are accepted by the rule, and the second produces a document of the same
observation count and the same aggregate payload length but with every direction
label inverted and a different digest. Only the producer-selected server port
reproduces the committed bytes. The sanitizer cannot independently know which
endpoint is the server; it applies whichever server-port role the capture
producer selected, exactly as the plan's step 4 specifies. Two things contain the
risk, and both rest on capture provenance rather than on anything inside an
observation: the capture producer supplies the server test port of the role it
selected when it ran the observation, and re-running the sanitizer with that
selected role is what reproduces the committed document and its recorded digest,
which this reviewer confirmed independently. This review asserts nothing about
the content of any observation and relies on no such assertion. The registration
Issue should record the direction convention explicitly before any consumer
relies on it.

## Axis 5 — Scope control, repository hygiene and rollback

Verified:

- The implementation commit is exactly eleven files, all Exact Files. The set
  difference against the manifest's Exact Files is empty in one direction and is
  exactly this review file in the other.
- Working tree hygiene: `git diff --check` exits 0. Before this review the only
  tracked modification was the regenerated `result.json`. The two untracked owner
  artifacts at the repository root predate this Issue, are not part of it, and
  were not opened.
- No secret material: no credential, key, token, certificate identity or
  certificate fingerprint appears anywhere in the commit or in this file. Every
  hexadecimal run of 32 or more characters in the reviewed files is a declared
  digest, and each declared digest was independently recomputed or resolved by
  this reviewer.
- No raw capture is committed or present in git history, and no tracked path ends
  with a raw capture suffix.
- The commit message follows the repository convention and carries no attribution
  lines that the repository forbids.
- Rollback is stated and is achievable, because M1-024 changes no product code,
  lock, ADR, schema or register.

Finding L-5 (Low, plan text narrower than the implementation). The plan's
repository-validator section, item 3, says the identifying-content scan allows
"only the metadata `payload.sha256` value". The implemented scan is broader: it
allows any hexadecimal run that is declared under a key whose name ends in a
digest or commit suffix, across the fixture metadata, the commands record, the
environment record, the validation record and the generated result. The broader
rule is necessary, because the evidence legitimately carries the raw capture
digest, two sanitizer script digests and two commit ids. It is also safe here,
because this reviewer independently verified every one of those six declared
values. The plan text should be widened to match the code it describes.

Finding L-6 (Low, comment accuracy). The system script comments that its
identifying-content patterns are "kept behavior-identical to
`Tests/Contracts/test_m1_024_capture_readiness.py`". They are not exactly
identical: the contract test's certificate-fingerprint pattern also matches a
bare run of 32 or more hexadecimal characters, while the script splits that case
out into a separate rule with a declared-digest allowlist. The split is the
correct design for a file set that must carry digests, but the comment overstates
the equivalence.

## Private manual-evidence verification

All of the following was carried out on private material outside the repository.
No private path, SSH target, account, host name, address or port value, and no
raw packet byte, is reproduced here or anywhere in the repository.

- The temporary sanitizer and its self-test were located and hashed. Both digests
  match the values recorded in `commands.json`: the sanitizer is
  `d273a45575b75d433e07fb29fe6361aa9d76bf62a9585645affc19698be004a4` and the
  self-test is `d8c5c6db42f0e2eac39946ded502e83795b70f7b0a2a8771da57db782b5f8794`.
- The self-test was run independently against the sanitizer. It exited 0 and
  reported 21 checks passed, which is exactly the count recorded in
  `commands.json` and in `manual.md`.
- The accepted raw capture was hashed without being decoded, printed or
  inspected. It is 1731 bytes with digest
  `836f3d55037f7936b9cc42f729dc490bb844b4b755b900e28eddfea118532c61`, matching
  both `commands.json` and `manual.md` exactly.
- The sanitizer was then run independently by this reviewer, as a subprocess,
  over that raw capture, with the producer's private denylist and the
  producer-selected server test port, writing to a new private reviewer output
  file that did not previously exist. It exited 0 and reported 7 observations,
  133 aggregate payload bytes, 1079 output bytes and digest
  `57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2`, and it
  created the output with owner-only permissions.
- That reviewer output was compared byte for byte against the committed
  `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json`.
  They are identical. The counts and the digest also match `metadata.json`,
  `commands.json`, `manual.md`, `summary.md` and the generated `result.json`. The
  committed fixture is therefore reproducible from the raw capture by a party
  that did not produce it.
- The denylist scan inside that run reported zero hits, independently confirming
  the producer's reported figure.
- The attempt-8 client, server and timing logs were inspected. They record, in
  order, the client starting, the client connecting to the server, the server
  accepting a client connection, the synthetic screen name `m1-client`
  connecting, that same name disconnecting, and the server stopping. Nothing in
  them shows typing, pointer movement, clipboard use or a screen switch.
- The bounded window was re-derived from those logs rather than taken from the
  package. The launcher start, the termination request, the client log start, the
  peer accept and the peer disconnect in `environment.json` each match the
  corresponding private log entry once the peer entries are read at their
  equivalent capture-host local log time. The recorded 9-second conservative
  window and 8-second client-log window follow from those timestamps and are both
  under the recorded 15-second cap. The peer server process stopped later, during
  teardown, which is outside the observation window by design and not part of it.
- Raw transfer evidence was verified only as far as it is locally verifiable. The
  producer's report that the two private copies hashed identically before
  sanitization is recorded in the package; this reviewer can confirm the digest of
  the local copy it can reach, and makes no claim to have observed the remote
  copy or any remote state it cannot independently access.

## Current-head and lineage regression result

At HEAD `710ce0be68e0df496c1600e2e8b643ae5209d774`, which is the implementation
commit itself, `make e2e ISSUE=M1-024` exits 0 and prints
`e2e disposition: passed`. The generated `result.json` carries that same commit
as its `commit` field, while the three author-phase records continue to carry the
parent commit `8b4170159b5d1ffda7d9ccbe550abbe80cf0dc40` as
`repositoryHeadAtAuthorRun`, which `git merge-base --is-ancestor` accepts. The
regression that an equality rule would have caused, where committing the eleven
files makes the tree unable to pass its own gate, does not occur. The malformed,
unresolvable and non-ancestor cases fail closed in the code that was read here
and are recorded with their exit codes and rejection reasons in
`tests/e2e-validation.json`.

## Remaining risks and known limitations

- One observation, one external version pair, one locked host pair. It represents
  nothing beyond that observation.
- The observation ran with encryption disabled, so payload under TLS was not
  observed and nothing about TLS behavior is demonstrated.
- The window is bounded to the connection handshake. No input, clipboard or
  screen-switch traffic exists in the fixture.
- The fixture is uninterpreted. It supports no assertion about field meaning,
  message code, endianness, framing or interoperability, and no consumer may
  derive one from it.
- Windows was not executed in M1 and no Windows result is claimed or implied.
- The fixture is not registered as approved evidence. Issue #249 must register it
  before any consumer uses it, and M1-025 must not freeze a client wire contract
  from unregistered evidence.
- The raw packet capture, the peer configuration and the private logs remain
  retained privately outside the repository at the time this review is written.
  Their deletion is not claimed here. It is performed by the capture producer
  after this review is committed, and no file in the repository asserts otherwise.
- `make code-quality-check` cannot run inside a managed sandbox that blocks
  SwiftPM. Anyone reproducing this review must run that gate outside such a
  sandbox, as documented in Axis 4.
- The six Low findings above remain open as documentation and tooling
  improvements. None affects the committed bytes, the evidence, or the
  disposition.

## Rollback

- Revert the review commit alone to remove this file. That leaves the
  implementation commit intact and returns the generated `result.json` to
  reporting the review file as not yet present on the next run.
- Revert the whole M1-024 branch to remove the plan, the system script, the
  fixture pair, the generated result and the evidence package. No product code,
  package manifest, lock, ADR, schema or evidence register is changed by M1-024,
  so nothing else has to be undone.
- Delete any remaining private capture directory and confirm the deletion, then
  re-run cleanup verification on both hosts.
- Keep Issue #249, M1-025 and every Barrier codec Issue blocked until a
  replacement fixture passes the capture plan.

## Final disposition

**Approved.** Critical 0, High 0, Medium 0, Low 6.

The eleven implementation-author Exact Files carried by implementation commit
`710ce0be68e0df496c1600e2e8b643ae5209d774` satisfy Issue #17's Scope, Acceptance
Criteria, Automated Tests, Required Commands, Expected Evidence, Manual
Verification and Prohibited Shortcuts, within the limitations recorded above.
No prohibited shortcut was taken: no Acceptance Criterion was rewritten to match
the implementation, no sleep or retry masks a race, no error is swallowed, no
frozen dependency output is modified, and nothing is guessed in the absence of
evidence.

This review file is the twelfth Exact File. It was authored after the
implementation commit existed and it lands in a separate review commit. That
later review commit is not part of the implementation commit and carries no
implementation change. Reverting it does not affect the implementation commit,
and reverting the implementation commit does not depend on it.
