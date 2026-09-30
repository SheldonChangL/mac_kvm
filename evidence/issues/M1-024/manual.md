# M1-024 Manual and On-Device Evidence

GitHub Issue: #17

Repository head at author run: `8b4170159b5d1ffda7d9ccbe550abbe80cf0dc40`

That value is the repository head this session ran every recorded check over,
with the eleven implementation-author Exact Files still uncommitted. It is
deliberately not called the implementation commit: the implementation commit is
created when root commits those eleven files, and it cannot be named from inside
the files it will contain. The validator therefore requires the recorded value to
be a full commit id that is an ancestor of, or equal to, the current head, and
the generated `evidence/e2e/M1-024/result.json` separately carries the exact head
of each E2E execution. See "Commit provenance and review sequence" below.

This record describes one controlled black-box observation of two lawfully
installed external Barrier programs, and the local repository work that turned
the released sanitized bytes into the working-tree fixture and evidence package
prepared for root to commit.
Every real host name, user name, address, port value, SSH target and private
directory path is referenced only through the placeholder names defined in
`Tests/SystemTests/Plans/M1-024-barrier-client-handshake-fixtures.md`.

## Roles actually separated

| Role | Session | What it did |
|---|---|---|
| Capture operator and producer | Root session | Recorded the pre-capture host and peer metadata, then ran preflight, capture, cleanup and the sanitizer in private directories outside the repository; released the sanitized bytes and their digest |
| Implementation author | This Claude session | Authored the plan, the system script, the fixture metadata, and this evidence package; copied the released bytes unchanged into the working tree for root to commit; ran only local repository checks. It committed nothing |
| Independent reviewer | A fresh isolated session that is neither of the above | Has not run yet; it alone writes `evidence/issues/M1-024/independent-review.md` |

The implementation author did not run `ssh`, `scp`, `tcpdump`, `dumpcap`,
`barrierc`, `barriers`, any network operation, or the sanitizer, and did not read
a raw packet capture or a private log. The only captured content the author read
is the sanitized JSON document the producer released.

## Capture-time environment metadata, recorded before the capture

Issue #17 requires the build, OS, hardware, network, keyboard layout, display
and peer metadata to be recorded before the test matrix runs. For the accepted
attempt 8 the producer queried and recorded all of the following first, and only
then started the observation. The machine-readable copy is
`evidence/issues/M1-024/environment.json`.

| Fact | Capture host | Linux peer |
|---|---|---|
| OS and build | macOS 26.6.2 build 25G83 | Ubuntu 22.04 |
| CPU architecture | arm64 | x86_64 |
| Model | MacBook Pro, model identifier Mac16,7 | reported by CPU model only |
| Processor | Apple M4 Pro, 14 cores, 10 performance and 4 efficiency | Intel(R) Core(TM) i7-6500U CPU @ 2.50GHz, 4 logical CPUs |
| Memory | 24 GB | 16660443136 bytes |
| Keyboard layout | Active input source `com.apple.keylayout.ZhuyinBopomofo` | X keyboard rules `evdev`, model `pc105`, layouts `cn,us,gb`, no variant set |
| Display | Combined desktop bounds left -1920, top 0, right 1728, bottom 1117 | X display `:0`, 1920x1080 pixels, 508x286 mm, 96x96 dpi |
| Network | Peer loopback only, reached over an encrypted local forward | Same single loopback path |
| Peer product versions | `barrierc` 2.4.0-release, protocol 1.6 | `barriers` 2.4.0-release, protocol 1.6 |

Two deliberate limits on what those facts mean:

- The macOS input-source identifier is the active logical input source at that
  moment. It is not proof of a physical keyboard form factor, so the physical
  layout is recorded as not captured rather than inferred from it.
- The Finder bounds prove the combined desktop coordinate layout that was
  reported immediately before capture. Individual display models and
  resolutions were not reported, so none is recorded or derived from them.

The OS, toolchain and Barrier facts are unchanged from the earlier record and
still match `MacKVM_Implementation_Package_v2/toolchain.lock.json` exactly.

## Observation, as reported and verified by the capture producer

This is accepted attempt 8.

| Step | Expected | Actual |
|---|---|---|
| Pre-capture metadata recording | Recorded before the client starts | Recorded first, as listed above |
| Preflight against the capture toolchain lock | Every locked OS, architecture, Barrier and capture tool version matches exactly, otherwise stop | Matched; capture proceeded |
| Recorder selection | A locked recorder on the peer loopback | `tcpdump` 4.99.1, link type EN10MB, snapshot length 262144 |
| Alternative recorder | Version-checked only, never used to record | Dumpcap and Wireshark 3.6.2 were available under the lock and were not the selected recorder |
| Encryption state | Disabled for this one observation so application payload bytes are observable | Disabled for the observation only |
| Launcher start | Bounded window, at most 15 seconds to the peer disconnect | Launcher started 2026-09-30T07:01:02Z |
| Client start | Inside the same bounded window | The client log reported started at 2026-09-30T07:01:03Z |
| Termination request | Requested inside the window | Requested 2026-09-30T07:01:07Z |
| Peer server transitions | Accept and disconnect inside the bounded window | Accepted at 2026-09-30T07:01:05Z and disconnected at 2026-09-30T07:01:11Z, both at their equivalent capture-host local log time |
| Total observed window | Under the 15-second cap | 9 seconds measured conservatively from the launcher, and 8 seconds from the client log entry, to the peer disconnect |
| Client log | A connection to the server | The client log recorded that it connected to the server |
| Server log | An accepted client and a later disconnect | The server log recorded an accepted client connection, the synthetic screen name `m1-client` connected, then disconnected |
| Packet accounting | No kernel drop | 19 packets captured, 38 received by the filter, 0 dropped by the kernel |
| Raw artifact | Stays outside the repository | 1731 bytes, SHA-256 `836f3d55037f7936b9cc42f729dc490bb844b4b755b900e28eddfea118532c61`, never copied in |
| Raw transfer | Digests of both private copies identical before sanitization | Matched exactly |

Nobody typed, moved the pointer, copied to a clipboard or triggered a screen
switch during the window, so no typed text and no clipboard payload exists in
the raw capture or in the fixture.

## Why attempt 7 was superseded

Attempt 7 was a valid bounded observation and its sanitized output was well
formed. It was not rejected as protocol evidence. It was superseded because the
capture-time environment metadata that Issue #17 requires had only been queried
after that run, so the recording order the Issue requires was not met, and
retroactive conformance was never claimed for it.

The remedy was procedural, not a repeat until an outcome looked better: the
producer recorded the same non-sensitive host and peer facts first, then ran the
identical verified procedure again as attempt 8. Attempt 8's sanitized bytes are
the fixture intended for commit.

The attempt 7 sanitized bytes were never committed and never entered git
history. They were only the previous uncommitted working-tree fixture, and
attempt 8 then replaced them in the working tree. Nothing was removed from the
repository or from its history, because nothing had ever been added to it.

The two sanitized documents differ in exactly one observation, of identical
length and direction, with every other observation length, direction and hash
unchanged. This package does not interpret that difference and asserts nothing
about it; the working-tree fixture is the attempt 8 document byte for byte.

## Sanitizer and its negative self-test

The sanitizer is a temporary tool outside the repository. It is not an Exact
File and was never committed; it is identified here only by digest. It is
unchanged between attempt 7 and attempt 8.

| Item | Value |
|---|---|
| Sanitizer script SHA-256 | `d273a45575b75d433e07fb29fe6361aa9d76bf62a9585645affc19698be004a4` |
| Private synthetic self-test script SHA-256 | `d8c5c6db42f0e2eac39946ded502e83795b70f7b0a2a8771da57db782b5f8794` |
| Self-test outcome | 21 checks passed |

The self-test drove the sanitizer with private synthetic inputs only, and the
sanitizer rejected each one as the plan requires. The sanitizer then succeeded
fail-closed on the accepted raw capture and produced:

| Property | Value |
|---|---|
| Ordered observations | 7, contiguous, both directions present |
| Aggregate application payload | 133 bytes |
| Output size | 1079 bytes |
| Output SHA-256 | `57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2` |
| Private denylist scan | No prohibited value found; 0 hits |

The bytes in `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json`
are those released bytes, placed in the working tree without reserialization,
reordering, re-encoding or interpretation, for root to commit. The working-tree
copy hashes to the same value.

## Cleanup verification

| Check | Expected | Actual |
|---|---|---|
| Peer Barrier server process | None left | None |
| Peer recorder process | None left | None |
| Peer test listener | None left | None |
| Local tunnel and local listener | None left | None |
| Stuck key or stuck pointer button | None | None; no first-party input, permission or trust code ran at all |
| Suppressed local input | None | None; the local keyboard and pointer responded normally afterwards |
| Leaked trust state | No new trust entry and no new permission grant | None; the observation ran with encryption disabled, so no certificate identity was stored |

## Commit provenance and review sequence

M1-024 lands in two commits, and the author phase and the review phase are
recorded against different commits on purpose.

1. The author runs every check with the eleven implementation-author Exact Files
   uncommitted, over repository head
   `8b4170159b5d1ffda7d9ccbe550abbe80cf0dc40`. That value is recorded as
   `repositoryHeadAtAuthorRun` in `commands.json`, `environment.json` and
   `tests/e2e-validation.json`.
2. Root commits those eleven implementation-author files, and nothing else. That
   commit is the implementation commit, and the head moves past the author-run
   head. `independent-review.md` does not exist yet, so it is not in it.
3. The validator does not require the author-run value to equal the current
   head, because committing those files necessarily changes the head and an
   equality rule could never be satisfied by the resulting tree. It requires the
   value to be a full commit id that is an ancestor of, or equal to, the current
   head, checked read-only with `git merge-base --is-ancestor`. A malformed
   value, a value git cannot resolve, and a real commit outside the current
   history are each rejected, and no result file is written.
4. The fresh independent reviewer then runs against that implementation commit,
   creates the twelfth Exact File
   `evidence/issues/M1-024/independent-review.md` and records that exact SHA in
   it. The reviewer's own E2E run regenerates
   `evidence/e2e/M1-024/result.json` against the implementation commit, before
   the separate review commit that carries that twelfth file exists.
5. `result.json` always carries the exact head of the E2E execution that
   produced it, so the generated artifact stays pinned to a single commit even
   though the author-phase records do not.

## Local repository verification performed by the implementation author

All of the following ran on the locked macOS capture host, read-only against
the repository except where a command writes `evidence/e2e/M1-024/result.json`.
Exact commands, timestamps and exit codes are in
`evidence/issues/M1-024/commands.json`, and the machine-readable red, mutation
and green records are in `evidence/issues/M1-024/tests/e2e-validation.json`.

| Step | Expected | Actual |
|---|---|---|
| `bash -n` over the system script | Parses | Exit 0 |
| 15 fixture mutation checks against private mutated copies of the replacement fixture | Each rejected, each writing no result | Each exited 1 with a specific rejection reason; the result path stayed absent throughout |
| 3 provenance mutation checks against the author-run head values | Each rejected, each writing no result | Each exited 1 with a specific rejection reason |
| Control run against an unmutated private copy | Accepted, still writing no result | Exit 0 with `M1-024 fixture validation passed` |
| `make e2e ISSUE=M1-024` | `e2e disposition: passed` and `e2e exit: 0` | As expected |
| `python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-024/result.json` | Exit 0 | As expected |
| `python3 Tools/Backlog/validate_package.py` | Exit 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| `make architecture-check` | Exit 0 | `architecture check OK` |
| `make docs-check` | Exit 0 | `docs check OK` |
| Capture readiness contract test | Exit 0 | 15 tests, OK |
| Swift build and test | Exit 0 with every test passing | Build complete; 47 tests passed |
| `git diff --check` | Exit 0 | Exit 0 |
| Privacy scan over every Exact File present in the tree and the decoded payload | No finding | No finding; the 11 implementation-author files were scanned, and `independent-review.md` will join the same scan once the reviewer creates it |

`make code-quality-check` still could not complete inside this author session:
SwiftPM's own manifest cache and sandbox are denied by the session environment,
so the gate stops before it evaluates any repository file. Its exact non-zero
exit and the observed reason are recorded in `commands.json` rather than
reported as a pass, and the same test set was executed with the SwiftPM sandbox
disabled and passed with no compiler warning.

The root reviewer reran the exact `make code-quality-check` outside the managed
outer sandbox, from 2026-09-30T06:57:43Z to 2026-09-30T06:57:45Z, exit 0, with
`swift-format-version` exit 0, `swift-format-lint` exit 0 and
`swift-test-warnings-as-errors` exit 0. That run covered the uncommitted author
tree as it stood at that time, before the attempt 8 replacement document and the
provenance rename were applied; those later edits touch only markdown, JSON and
the local validator script, and no Swift source. It is recorded in
`commands.json` under `rootReviewerVerification`, attributed to root rather than
to the author, and it does not replace the fresh independent reviewer's own rerun
at the committed implementation head.

One SwiftPM packaging diagnostic is attributable to this Issue and is recorded
as a follow-up in `evidence/issues/M1-024/summary.md`.

## Raw artifact retention

The raw packet capture, the peer configuration and the private logs stay in the
producer's private directories outside the repository, and none of them entered
the repository or its history. They are deleted only after the repository
fixture is verified and the independent review is complete, so at the time of
writing they are retained privately and their deletion is not yet claimed.

## Reviewer

Not yet reviewed. `evidence/issues/M1-024/independent-review.md` is absent by
design and is authored only by a reviewer who is neither the capture producer
nor the implementation author. No reviewed disposition may be inferred from
this file.
