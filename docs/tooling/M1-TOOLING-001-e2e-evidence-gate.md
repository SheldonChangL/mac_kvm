# M1-TOOLING-001 E2E Evidence Gate

## Outcome

This change (GitHub Issue #272) implements the stable `make e2e ISSUE=Mx-xxx`
command from
[`COMMAND_CONTRACT.md`](../../MacKVM_Implementation_Package_v2/COMMAND_CONTRACT.md)
and a committed, machine-checkable result contract:

| File | Role |
|---|---|
| `Makefile` target `e2e` | Delegates to the runner with `ISSUE` as one argv value |
| `Tools/Evidence/run_e2e.py` | Read-only runner: resolves, executes and gates one script |
| `Tools/Evidence/validate_evidence.py` | Standalone read-only validator for a `result.json` |
| `MacKVM_Implementation_Package_v2/schemas/e2e-result.schema.json` | JSON Schema draft 2020-12 of the contract |
| `Tools/Evidence/tests/test_*.py` | Unit tests; discovered automatically by existing CI |

Both tools use the Python standard library only. The validator enforces the
contract directly; it does not depend on a JSON Schema library.

## Scope boundary

This tooling does not create, capture, sanitize or approve fixtures. It does
not interpret Barrier or native protocol bytes and makes no wire,
compatibility or platform claim. It checks the structure, consistency, paths
and hashes of evidence that someone else produced and reviewed.

This change does **not** complete M1-024 or any other E2E Issue. An Issue's
script, real Linux capture, sanitization, provenance record and
non-implementing reviewer disposition remain required by
[`M1-003`](../adr/M1-003-independent-implementation-policy.md) and
[`M1-SCOPE-001`](../adr/M1-SCOPE-001-linux-only-validation.md).

## Runner contract

```text
make e2e ISSUE=M1-069
python3 Tools/Evidence/run_e2e.py --issue M1-069 [--timeout-seconds N]
```

The Makefile passes `$(value ISSUE)` unexpanded, single-quoted with embedded
quotes escaped, and does not export `ISSUE` into the recipe environment, so the
value is never interpreted by the shell or by make. The runner then:

1. Validates the Issue with `^M[1-5]-[0-9]{3}$` before any path is built.
2. Prints closed metadata: runner version, Issue, git commit (or
   `unavailable`), Python version.
3. Requires `Tests/SystemTests/Scripts` and every ancestor below the
   repository root to be real directories (no symlinks).
4. Resolves exactly one `<ISSUE>-*.sh` entry. Zero matches, multiple matches,
   a symlink, a non-regular file, a name outside
   `M[1-5]-[0-9]{3}-[A-Za-z0-9._-]+.sh`, or a real path outside the script
   root is rejected.
5. Runs `bash <relative script path>` as an argv list (never `shell=True`)
   with cwd at the repository root, stdin from `/dev/null`, a new session and
   a bounded timeout (default 1800 s, 1..86400). The script receives
   `MACKVM_E2E_ISSUE` and `MACKVM_E2E_RESULT`
   (`evidence/e2e/<ISSUE>/result.json`).
6. On timeout, cancellation (SIGINT, SIGTERM, SIGHUP), output overflow or any
   other exception, sends SIGTERM to the whole process group, escalating to
   SIGKILL after two seconds. If signalling the group fails (permission error,
   group already gone, any other `OSError`), the runner also signals the script
   process directly with `terminate()` / `kill()`. Cleanup succeeds only when
   the script process is reaped and every stdout/stderr reader drains. A
   leader that is already reaped while a child still holds a pipe open and
   ignores SIGTERM still escalates to group SIGKILL. If the leader is not
   reaped within five seconds of SIGKILL, waiting fails, or a reader cannot
   drain after SIGKILL, the run ends with `cleanup_failed` (exit 70).
7. Streams stdout and stderr through reader threads that hash as they read.
   Each stream is capped independently at `MAX_OUTPUT_BYTES_PER_STREAM`
   (8 MiB). Output is never stored, so memory stays at one 64 KiB chunk per
   stream and no temporary disk is used. Stdout and stderr are reported only
   as line counts and SHA-256 of the retained bytes (at most the cap). Raw
   output is never replayed.
8. Reading more than the cap from either stream sends SIGKILL to the process
   group at once, then runs the cleanup in step 6. The truncated stream's
   metadata line ends with the closed marker `capture=truncated`, the script
   exit is `none`, and the run ends with `output_limit_exceeded` (exit 65),
   even if the script wrote a `passed` result. A stream read failure ends with
   `output_capture_failed` (exit 70).
9. A nonzero script exit ends with disposition `script_failed`, even if the
   script wrote a `passed` result.
10. Otherwise requires a new or rewritten `evidence/e2e/<ISSUE>/result.json`
   (an unchanged pre-existing result is rejected as `result_not_updated`),
   validates it with the validator and requires `issueId` to equal the Issue.

The runner never writes, repairs, moves or deletes results or evidence.
Interactive manual steps are recorded as `manual-record` artifacts by the
script's operator, not through runner stdin.

Output is fixed-format:

```text
e2e runner version: 1
e2e issue: M1-069
e2e commit: <40 lower-case hex | unavailable>
e2e python: 3.12.4
e2e script: Tests/SystemTests/Scripts/M1-069-linux-e2e.sh
e2e stdout: lines=12 sha256=<hex>
e2e stderr: lines=0 sha256=<hex>
e2e script exit: 0
e2e disposition: passed
e2e exit: 0
```

A truncated stream reads, for example,
`e2e stdout: lines=<n> sha256=<hex> capture=truncated`; the marker is absent
when the stream stayed within the cap.

Errors add one line `e2e error: <code>` on stderr, where `<code>` is a fixed
identifier and never an untrusted value, followed by
`e2e disposition: error`. Any unexpected exception is caught by `main`, which
prints only `e2e error: internal_failure` (no traceback, path or exception
text), returns 70 and restores the previous SIGTERM and SIGHUP handlers.

## Exit codes

| Exit | Runner meaning | Validator meaning |
|---|---|---|
| 0 | Result `passed`, or `not_executed` with an approved decision | Result valid |
| 1 | Result `failed`; or script exited outside 1..125 | `--require-passed` and status is not `passed` |
| 1..125 | Script exit code preserved (`script_failed`) | — |
| 64 | Usage: bad arguments, Issue or timeout | Bad arguments or `--expected-issue` |
| 65 | Invalid data: result contract, ambiguous script, stale result, wrong Issue, `output_limit_exceeded` | Result contract violation, hash/length mismatch, wrong Issue |
| 66 | Missing input: script, script root, result, artifact, `bash` | Result or artifact missing |
| 70 | Internal: `cleanup_failed`, `output_capture_failed`, `internal_failure` | — |
| 77 | Unsafe path: symlink, non-regular file, path outside root | Same |
| 124 | Runner timeout, or result status `timed_out` | — |
| 130 | Runner cancelled, or result status `cancelled` | Validator cancelled |

## Schema-valid retention versus gate success

`failed`, `timed_out` and `cancelled` results are valid evidence. They pass the
validator (exit 0 without `--require-passed`) so failure evidence can be kept
per [`EVIDENCE_STANDARD.md`](../../MacKVM_Implementation_Package_v2/EVIDENCE_STANDARD.md),
which forbids deleting failed evidence. They never pass the gate: the runner
returns nonzero and `--require-passed` returns 1. Only `passed` is a
successful execution.

## `not_executed` semantics

`not_executed` exists for Product Owner-approved non-execution disposition
gates such as M1-068 (Windows not executed in M1). It requires `cases == []`,
`artifacts == []` and a non-empty `approvedDecisionRef` matching
`^[A-Za-z0-9][A-Za-z0-9._#/-]{0,159}$` (for example
`docs/adr/M1-SCOPE-001-linux-only-validation.md`). The runner returns 0 and
prints `e2e disposition: not_executed`; it never prints `passed`, and the
result is not execution, compatibility or pass evidence. Every execution
status requires `approvedDecisionRef: null`.

## Validator contract

```text
python3 Tools/Evidence/validate_evidence.py <result.json> [--expected-issue Mx-xxx] [--require-passed]
```

The repository root is derived from the tool's location, so the validator works
from any cwd. A relative result path is resolved against the cwd and must still
lie inside the repository. On success it prints
`evidence valid: issue=<ID> status=<STATUS>`; on failure it prints one line
`evidence validation failed: <code>` on stderr.

Result file checks: inside the repository root, no symlink component, a
regular file opened with `O_NOFOLLOW`, at most 1 MiB, strict UTF-8 JSON with no
duplicate keys, `NaN`, `Infinity` or overflowing numbers.

Document rules (all objects have exactly the listed keys):

- `schemaVersion` is the integer `1`; `issueId` matches the Issue pattern.
- `status` is `passed`, `failed`, `timed_out`, `cancelled` or `not_executed`.
- `startedAt`/`endedAt` are UTC RFC 3339 with `Z` and up to six fractional
  digits, parse as real times, and `startedAt <= endedAt`.
- `commit` is a full lower-case 40-hex SHA-1.
- `toolchain` has `pythonVersion`, `platform`, `machine`; `environment` has
  `localOS`, `peerProduct`, `peerVersion`, `peerRole`, `peerOS`,
  `networkScope`, `tls`. Values are printable ASCII, 1..128 characters,
  without leading or trailing spaces.
- `cases` (at most 256) is non-empty for execution statuses. Each case has a
  unique `id` matching `^[a-z0-9][a-z0-9._-]{0,63}$`, a `status` among the
  four execution statuses, an `exitCode` that is `null` or an integer 0..255,
  and 1..32 `evidence` descriptions (printable ASCII, 1..200 characters).
  Exit codes must agree: `passed` is 0, `failed` is nonzero, `timed_out` is
  `null` or 124, `cancelled` is `null` or 130.
- Top-level `passed` requires every case `passed`. `failed`, `timed_out` and
  `cancelled` each require at least one case with that same status.
- `privacy` requires exact booleans: every `contains*` flag and
  `rawCaptureCommitted` are `false`, `sanitizationReviewed` is `true`.
- `artifacts` (at most 256) have `path`, `sha256`, `byteLength`, `kind`
  (`sanitized-fixture`, `sanitized-log`, `machine-report`, `manual-record`)
  and `reviewStatus` (`reviewed`, `pending-review`). A `passed` result
  requires every artifact `reviewed`.

The committed JSON Schema describes the same contract. Rules that JSON Schema
cannot express (timestamp order, artifact Issue match, file hashes, unique
ids, sensitive-marker checks) are enforced by the validator and listed in the
schema description.

## Privacy and path model

Artifact paths are relative POSIX paths of at most 512 characters with no
absolute prefix, backslash, NUL, empty, `.`, `..` or hidden segment, under
`evidence/e2e/<issueId>/` or `Tests/Fixtures/`. Every component is checked with
`lstat`; any symlink fails. The final file must be regular; its SHA-256 and
length are streamed and must match. Artifacts are hashed as bytes and are never
scanned as text.

The result file must not list itself as an artifact (`artifact_is_result`),
because a file cannot contain its own hash.

Descriptive text (`toolchain`, `environment`, case `evidence`,
`approvedDecisionRef`) rejects control characters and a bounded,
deterministic set of obvious markers: private key headers, `password`,
`secret`, `token`, API key and bearer or authorization markers, common SSH,
GitHub, Slack and AWS key prefixes, URLs (`://`), e-mail addresses, IPv4
addresses and runs of 40 or more token characters. This is a guard rail
against accidental inclusion. It is not a secret scanner and does not prove
that evidence is free of typed text, clipboard payloads, hostnames or other
private data; sanitization review remains a human responsibility recorded by
`sanitizationReviewed` and `reviewStatus`.

## Validation coverage

Validator tests cover happy paths for every status and both artifact roots,
invalid and duplicate-key JSON, non-finite numbers, deep nesting, unknown and
missing fields at every level, schema version, Issue and wrong Issue,
timestamps and order, commit, metadata text, every privacy flag, case exit
consistency and status mixing, `not_executed` decisions, artifact traversal,
absolute, backslash, NUL and prefix paths, symlinked files and directories,
missing files, hash and length mismatch, unreviewed artifacts, result
symlink, result outside the root, oversize result, CLI output, use from
another cwd, and schema/validator consistency.

Runner tests use temporary repository fixtures with injected `Popen`, commit
and output boundaries, plus real `bash` for timeout process-group cleanup and
script failure. They cover invalid Issues, zero, multiple, symlinked and
unsafe scripts, symlinked script roots, argv without shell, script failure
with a `passed` result, missing, stale, invalid, symlinked and wrong-Issue
results, every terminal status, `not_executed`, timeout, cancellation,
SIGKILL escalation, no raw output replay, read-only behavior and Makefile
argument quoting. Output-cap tests cover retention of exactly the cap,
the at-cap boundary, an over-limit fake stream, stream read failure, and a
real `bash` flood that must end nonzero with its background child killed, its
process group gone and the script reaped, and a real `bash` leader that exits
while a SIGTERM-ignoring background child keeps its pipes open, which must be
escalated to group SIGKILL with the child killed and readers drained. Cleanup
tests cover a reaped leader with an undrained pipe escalating to SIGKILL, an
undrainable pipe after SIGKILL as `cleanup_failed`, the direct
`terminate()` fallback after a `killpg` PermissionError or group race, the
direct `kill()` fallback, unreaped processes and wait errors as
`cleanup_failed`, and `main` redacting unexpected exceptions while restoring
signal handlers. Tests make no network calls and do not touch real evidence.

## Security and rollback

The change adds repository tooling, tests, a schema and this document only. It
adds no product runtime behavior, protocol contract, network access, TLS or
trust change, dependency, secret or private data.

Rollback by reverting the M1-TOOLING-001 PR. Any Issue whose gate depends on
`make e2e` is then blocked until an equivalent fail-closed runner and
validator are restored; results produced under this contract remain retained
evidence and must not be deleted.
