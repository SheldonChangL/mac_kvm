# M4-021-FOLLOWUP-001 Security Review

- Reviewer: fresh-context Opus agent, not the implementer
- Date: 2026-11-17
- Target: PR #367 at `492dc1e` (base `e4c8769`)
- Verdict: APPROVE, nothing blocking; 0 Critical, 0 High, 0 Medium, 2 Low, 3 Info

## Reviewer designation

This is a Tier S PR (risk critical). On 2026-11-17 the Product Owner decided that a fresh-context
security review replaces the designated Codex Security Reviewer for Tier S PRs. The review below is
that fresh-context security review, done by a model that did not implement the change. It is
separate from the Tier C review in `independent-review.md`.

## Review (verbatim)

> Security review PR #367, fresh-context Opus. Verdict: APPROVE, nothing blocking.
> Verified: dir lstat, open O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC, fstat dev/ino/type/owner==euid/forbidden mode bits 0o7077/0o7177 (:304-321); file fstatat(AT_SYMLINK_NOFOLLOW), openat(O_NOFOLLOW|O_NONBLOCK), fstat same object (:359-376); write O_CREAT|O_EXCL|O_NOFOLLOW 0600, fchmod, full write, fsync, close, renameat, dir fsync, unlink on failure (:396-418); flock shared/exclusive with EINTR retry; strict parser (:97-116) 1 MiB cap incl. while reading, trailing \n, exactly 2 fields, normalized key round-trip, lowercase hex, no duplicate keys, PeerKey limited to '!'..'~'; policy (:483-500, :537-556) never overwrites, storage failure never prompts; no logging, warning prints LinuxFingerprintChangeWarning(redacted).
> LOW1 :309-315 parent path components not checked (defense in depth; swap limited to victim-owned 0700 dirs).
> LOW2 :397 crash-left .tmp files never cleaned (space only).
> INFO3 :350-351 running as root accepts root-owned state. INFO4 same-user hardlink passes (needs write to victim 0700 dir). INFO5 :98 1 MiB ~ 11k records, fail closed beyond.
> Attacks run (Docker arm64, root and non-root; PR tests 31 pass root, 32 root / 33 non-root with attack tests): FIFO record file, symlink record file, symlink mackvm dir, CRLF file, >1 MiB file, root-owned dir read as user, root-owned record in own dir -> all secureStorageUnavailable; trust A then .trust B -> identityChanged, A kept; 50 concurrent hosts -> 50 lines.

## Resolution

Fixes are at `fc806ef`; CI run 44011697234 passed on both jobs.

| Finding | Resolution |
| --- | --- |
| Low 1 (`:309-315`): the parent path components are not checked | Partly fixed: the configuration directory must not be writable by group or other unless its sticky bit is set (test: 0777, 0770 and 0722 refused, 1777 and 0755 accepted; mutants M21, M22). The components above it remain a known limitation, recorded in the component doc and `summary.md`. |
| Low 2 (`:397`): temporary files left by a crash are never cleaned | Fixed: stale `.trusted-servers.*.tmp` files are removed under the exclusive lock before each write (test `a temporary file left behind by a crash is ignored`; mutant M23). |
| Info 3 (`:350-351`): running as root accepts root-owned state | Documented: running the client as root is not supported (component doc, Known limitations). |
| Info 4: a same-user hard link passes | Accepted as is: exploiting it needs write access to the victim's 0700 directory. |
| Info 5 (`:98`): the 1 MiB limit is about 11,000 records | Accepted as is: the file fails closed beyond the limit. |

Gates after the fixes: focused Linux 37 tests in 5 suites pass as root and as a non-root user; full
Linux 434 tests in 45 suites; macOS 301 tests in 28 suites; `make verify` passes; 23 of 23 mutants
killed.
