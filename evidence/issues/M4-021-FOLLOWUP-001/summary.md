# M4-021-FOLLOWUP-001 Evidence Summary

## Scope

Files: `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxTrustedServerStore.swift`,
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxTrustedServerStoreTests.swift`,
`docs/platform/linux/M4-021-FOLLOWUP-001-linux-trusted-server-store.md`, and this directory.

`LinuxTrustedServerStore` is the Linux client's conformer of the C-015 `SecureStorageBackend`
contract (M4-002). In the client role it keeps the C-009 trust state: one trusted SHA-256 server
fingerprint per `host:port`, in `<config>/mackvm/trusted-servers`, and never a private key. The
directory is 0700 and the file 0600; every operation checks both with `lstat`, opens them with
`O_NOFOLLOW` and compares `fstat`; writes go to an `O_EXCL` 0600 temporary file and `rename`; every
operation holds `flock`. `LinuxTrustPolicy` decides prompt, allow, reject or identity changed, with a
redacted change warning. `LinuxFirstUseTrust` applies the owner's answer: insert if absent, then
re-read. The policy is first-party, built from the repository's contracts (C-009, C-015, plan a.7);
no Barrier behavior is involved. Tier C/S, risk critical (issue #348, PR #367).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Where is the state? | `$XDG_CONFIG_HOME/mackvm/trusted-servers` (absolute only), else `$HOME/.config/...`; with neither, `secureStorageUnavailable`. | Component doc, Location. |
| What does a refusal look like? | Any bad path, type, link, mode or owner is `security(.secureStorageUnavailable)`, never an unknown server. | Component doc, File rules 3 to 5; mutants M1 to M5. |
| Is a malformed file repaired? | No: it is rejected whole and never rewritten (blank line, comment, CR, uppercase hex, wrong length, duplicate key, non-normalized key, over 1 MiB). | Component doc, Record format; mutants M6 to M8. |
| How are concurrent writers serialized? | `flock` on the directory descriptor, shared for a load and exclusive for an insert or remove; the same lock covers separate processes. | Component doc, File rules 7; mutant M12. |
| Is the configuration directory itself checked? | After the review: it must not be writable by group or other unless sticky. Its own parents are not checked. | Review resolution; mutants M21, M22; Known limitations. |
| Crash-left temporary files | Removed under the exclusive lock before each write. | Review resolution; mutant M23. |
| Where is the policy? | A first-party copy of the Mac app's internal `TrustPolicy`, in the same order; it moves to `KVMCore` with M3-014. | Component doc, Trust policy; mutants M14, M15. |
| Revoked state | V1 has none: removing a record returns a server to unknown. | Issue #348; Known limitations. |
| Security reviewer | The owner decided on 2026-11-17 that a fresh-context security review replaces the designated Codex Security Reviewer for Tier S PRs. | `security-review.md`. |
| Which tests does `make verify-linux ISSUE=M4-021-FOLLOWUP-001` mean? | The Linux suite run in `swift:6.2.3-jammy`, plus the CI `verify-linux` job, which is the gate of record. | `commands.json` toolchain note. |

## RED

Against a compiling stub (store operations fail, the parser and policy return fixed values), the
focused run (`commands.json`, first command, exit 1, recorded as an expected failure) ended:
`✘ Test run with 31 tests in 5 suites failed after 0.884 seconds with 48 issues.` Refusal tests pass
trivially on a stub. Only the date was recorded for this run.

## GREEN

Linux, `swift:6.2.3-jammy`, linux/arm64, built with `-warnings-as-errors`, after the review notes
(`fc806ef`):

- Focused `LinuxTrust|LinuxFirstUse`, as root: `✔ Test run with 37 tests in 5 suites passed after
  0.195 seconds.`
- The same, as a non-root user: `✔ Test run with 37 tests in 5 suites passed after 0.191 seconds.`
- Full root package: `✔ Test run with 434 tests in 45 suites passed after 0.353 seconds.`
- Before the review notes the focused run was 31 tests in 5 suites, as root and as a non-root user,
  and the full run was 428 tests in 45 suites.

macOS, after the review notes:

- Full root package: `✔ Test run with 301 tests in 28 suites passed after 0.143 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 301 tests in 28 suites passed after 0.144
  seconds.`
- Both format lints (the two files, and the repository) exit 0; `docs check OK`; `architecture
  check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `make verify` exit 0 (the
  `[PASSED]` lines are in `commands.json`; the review resolution counts 25 gates).
- CI run 44011697234 at `fc806ef`: both jobs passed.
- The machine-readable report is `tests/swift-testing-xunit-swift-testing.xml`, the full Linux run
  after the review notes (the report's header reads `tests="394"`, `skipped="40"`, `failures="0"`).

## Mutation checks

23 mutants in `mutations/mutations.json`, run by `mutations/run_mutations.py` (the baseline passes,
`allKilled` is true): 23 killed by a failing test, none by timeout.

| Ids | Area | Killing tests |
| --- | --- | --- |
| M1, M2, M10, M11 | directory and file modes: wider than 0700 or 0600 accepted, file created 0644, directory created 0755 | `a directory with a mode wider than 0700 is refused`; `a record file with a mode wider than 0600 is refused`; `insert, load and remove round-trip through a 0600 file in a 0700 directory` |
| M3, M4 | a symbolic link accepted for the record file or the directory | `a symbolic link in place of the record file is refused`; `a symbolic link in place of the directory is refused` |
| M5 | owner check removed | the two `owned by another user is refused (injected stat)` tests |
| M6 to M8 | an unknown line skipped, duplicate keys accepted, a non-normalized key accepted | `a malformed line rejects the whole file and nothing is rewritten`; `anything that is not exactly a list of records is refused` |
| M9 | the file rewritten in place | `a write replaces the file by rename and leaves no temporary file` |
| M12 | no `flock` on the directory | the three concurrent-insert tests, including the separate-process one |
| M13, M17, M18 | an existing record replaced; no re-read after insert; a cancelled load or insert acts | `a duplicate insert returns the existing record and changes nothing`; `first use: trust never replaces a different record and reports the change`; `load and insert from a cancelled task do nothing; remove still runs` |
| M14 to M16 | policy: wrong length not rejected; a different fingerprint not `identityChanged`; the warning not redacted | `the policy table`; `the change warning is redacted everywhere but its two display fields` |
| M19, M20 | the opened file or directory need not be the one `lstat` checked (added after the review) | `a record file replaced between lstat and open is refused (injected stat)`; `a directory replaced between lstat and open is refused (injected stat)` |
| M21, M22 | a group or other writable configuration directory accepted, or a sticky one refused (added after the review) | `a configuration directory writable by group or other is refused unless sticky` |
| M23 | stale temporary files kept (added after the review) | `a temporary file left behind by a crash is ignored` |

## Acceptance mapping

| Criterion (issue #348) | Tests and evidence |
| --- | --- |
| File location, 0700 directory, 0600 file created with `O_EXCL` | The location and round-trip tests; mutants M10, M11 |
| `lstat` first; a symlink, a mode wider than 0600 or another owner is `secureStorageUnavailable`, on the file and on the directory | The wide-mode, symbolic-link and injected-owner tests for both; mutants M1 to M5, M19, M20 |
| Writes go to a 0600 temporary file, then `rename` | `a write replaces the file by rename and leaves no temporary file`; mutants M9, M10 |
| One `<host:port> <64 lowercase hex>` record per line; an unknown line rejects the whole file | The parser table and malformed-file tests; mutants M6 to M8 |
| `LinuxTrustPolicy`; the warning is redacted with only the two displays readable | The policy table (31- and 33-byte presented fingerprints) and the reflection test; mutants M14 to M16 |
| `LinuxFirstUseTrust` inserts if absent and re-reads | `first use: trust stores and allows`; `first use: trust never replaces a different record and reports the change`; mutant M17 |
| C-015 behavior: wrong length is `trustRejected` before storage; cancelled load or insert is `cancellation.requested`; remove is idempotent and runs when cancelled | The wrong-length and cancellation tests; mutant M18 |
| Two concurrent inserts keep one record | Concurrent inserts from separate instances, and from four separate processes; mutant M12 |
| No revoked state (documented limitation against C-009) | Known limitations below and the component doc |
| Required commands and the Tier C/S reviews | `commands.json`: Linux 434 tests in 45 suites, `make verify`, `validate_package.py`, architecture check; `independent-review.md` and `security-review.md` |

## Independent review

- A fresh-context Opus reviewer (Tier C) approved PR #367 at `492dc1e`: 0 Critical, 0 High, 1
  Medium, 3 Low (`independent-review.md`). The reviewer ran 31 tests in 5 suites on arm64
  `swift:6.2.3-jammy` and 6 mutants of its own, 5 killed (the file same-object check survived).
- A fresh-context Opus security review (the owner's 2026-11-17 decision, see `security-review.md`)
  approved with nothing blocking: 2 Low and 3 Info. It ran attack tests as root and as a non-root
  user.
- All Medium, Low and Low-severity security findings were addressed in `fc806ef`: a two-process
  test, two swap tests, a stricter configuration-directory check, stale temporary file cleanup, and
  documentation; the Info items are accepted or documented. The new mutants are M19 to M23.

## Merge

Pending owner authorization; the branch is behind main and needs `gh pr update-branch` first.

## Known limitations

- V1 has no revoked state: `forget` (remove) returns a server to unknown, so the next connection
  prompts. This falls short of C-009's revoked case and is left to M3-014.
- The C-009 policy is duplicated from the Mac app's internal `TrustPolicy` until M3-014.
- Only the configuration directory is checked for group and other write access; the components above
  it (for example `$HOME`) are not.
- The ownership rule is "owned by the effective user", so a client run as root accepts root-owned
  state; running the client as root is not supported.
- Only one directory level (plus the configuration directory) is created; a missing grandparent
  fails closed.
- A file of 1 MiB or more is refused whole, which fails closed beyond about 11,000 records.
- Network file systems where `flock` is advisory-only or emulated are not supported.
- A same-user hard link to the record file passes the checks; exploiting it needs write access to the
  victim's 0700 directory.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21
clang-1700.6.3.2); Linux `swift:6.2.3-jammy`); the machine-readable test report is in `tests/`.
