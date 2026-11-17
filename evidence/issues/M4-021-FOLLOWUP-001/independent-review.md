# M4-021-FOLLOWUP-001 Independent Review

- Reviewer: fresh-context Opus agent, Tier C (STRONG_REVIEW_PROMPT)
- Date: 2026-11-17
- Target: PR #367 at `492dc1e` (base `e4c8769`)
- Verdict: APPROVE; 0 Critical, 0 High, 1 Medium, 3 Low

## Review (verbatim)

> PR #367 (M4-021-FOLLOWUP-001 LinuxTrustedServerStore) Tier C review, fresh-context Opus, head 492dc1e
> Verdict: APPROVE (0 critical/high, 1 medium, 3 low).
> Verified: API shape per b.15 (LinuxTrustedServerStore: SecureStorageBackend, LinuxTrustPolicy.decide, LinuxTrustDecision, LinuxFirstUseTrust); apply(.trust) insert-if-absent then re-read; policy order matches Mac TrustPolicy.swift:68-80; warning redacted; C-015 contract (PlatformBackendContracts.swift:281-307) conformance: wrong-length insert -> trustRejected before cancel/storage, cancelled load/insert -> cancellation.requested, remove idempotent and runs when cancelled, storage failure never nil, concurrent insert one .inserted rest .existing; file rules 0700/0600, lstat->open O_NOFOLLOW->fstat same dev/inode, uid==euid, O_EXCL temp, fsync, renameat, dir fsync, flock; malformed file rejected whole; limitations documented as first-party.
> MEDIUM: b.15 requires two-process concurrent inserts; tests used in-process instances (LinuxTrustedServerStoreTests.swift:482-531).
> LOW1: file same-object check at LinuxTrustedServerStore.swift:371 untested (removal passed 31 tests); directory :320 not tried.
> LOW2: security-review.md missing from Exact Files.
> LOW3: :309 creates only one directory level; undocumented fail-closed.
> Ran: Docker arm64 swift:6.2.3-jammy, --filter "LinuxTrust|LinuxFirstUse": 31 tests/5 suites pass; non-root not verified (scratch perms). 6 own mutants, 5 killed: dup-key check removed (5 issues), uid check removed (9), apply(.trust) no re-read (1), file isSameObject removed SURVIVED, load cancel check removed (1), insert shared lock (43). swift format lint --strict exit 0; CI both pass; evidence free of paths/usernames/IPs.

## Resolution

Fixes are at `fc806ef`; CI run 44011697234 passed on both jobs.

| Finding | Resolution |
| --- | --- |
| Medium: the tests used in-process instances, not two processes | Fixed: a two-process test re-launches the test binary four times with `posix_spawn`, for three rounds; exactly one insert reports `.inserted` each round. Mutant M12 (no `flock`) is killed by it too. |
| Low 1: the file same-object check (`:371`) is untested, and the directory one (`:320`) was not tried | Fixed: tests `fileSwappedAfterCheck` and `directorySwappedAfterCheck` change the inode of the second status through `adjustStatus`. Mutants M19 and M20 remove each check and are killed. |
| Low 2: `security-review.md` is missing from Exact Files | Written at closing by the lead, with this file and `summary.md`; it is in the issue's Exact Files and Expected evidence. |
| Low 3: only one directory level is created, and the fail-closed result is undocumented | Kept fail-closed; documented in the component doc's File rules and tested (a missing parent fails with `secureStorageUnavailable` and creates nothing). |

Gates after the fixes: focused Linux 37 tests in 5 suites pass as root and as a non-root user; full
Linux 434 tests in 45 suites; macOS 301 tests in 28 suites in both modes; `make verify` passes (25
gates); the mutation batch is now 23 of 23 killed (new M19 to M23); CI run 44011697234 passed on
both jobs.
