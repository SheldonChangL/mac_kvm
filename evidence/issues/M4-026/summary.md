# M4-026 Evidence Summary

## Scope

Files: `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Clipboard.swift`,
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxX11ClipboardTests.swift`,
`docs/platform/linux/M4-026-linux-x11-clipboard.md`, and this directory.

The change adds `LinuxX11Clipboard`, the Linux `ClipboardBackend` (C-015) for the X11 `CLIPBOARD`
selection, UTF-8 text only (C-007). It owns the selection in process on a private unmapped window
(no `xclip`) and serves `TARGETS`, `UTF8_STRING`, `text/plain;charset=utf-8` and `STRING` (only
for Latin-1 text), using INCR above a quarter of `XMaxRequestSize`. Reads use
`XConvertSelection(UTF8_STRING)` with a 2 s monotonic deadline renewed per INCR chunk; the stated
INCR size, each chunk and the accumulated size are checked against the limit before content is
fetched, and the text is decoded strictly through `ClipboardTextCodec`. `ownerChanges` comes from
XFixes and never fires for the clipboard's own window. `contentHash` is the lowercase SHA-256 hex
of the UTF-8 bytes. All X traffic runs on one dedicated `Thread`; API calls reach it through a
mailbox and a wake pipe.

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| X error handler | Scoped (plan amendment h.8): the previous handler is kept, errors on the clipboard's own displays are ignored (registry under a lock), errors on other displays are chained to the previous handler, and it is restored when the last clipboard stops. | Tier H review Medium: a process-wide handler that never restored the previous one would swallow the X errors of every later Xlib user (M4-027, XTest). Mutants M16 and M17. |
| `XInitThreads` | Left to the composition root (M4-020-FOLLOWUP-001), which must call it before any `Display` opens; stated in the component doc and the PR. | Each display is used on one thread, so it holds today; no production code calls it yet. |
| Abandoned INCR transfer | Reads rotate through 4 private properties so a late chunk of an abandoned transfer cannot land in the next read. | A real bug the tests caught (test "an abandoned INCR transfer does not leak into the next read", mutant M14). |
| Where does Linux evidence come from? | The CI `verify-linux` job (pinned amd64 image) plus a native arm64 `swift:6.2.3-jammy` container with Xvfb for local runs. | amd64 emulation hangs locally (`commands.json`, note). |
| Xvfb reset | The test process keeps one connection open for its whole run. | Xvfb resets when its last client disconnects, and connections opened during the reset fail with ECONNRESET (errno 104); scoping the handler exposed it. This is a test-side fix. |
| Extras beyond the plan's API | `package enum LinuxX11ClipboardRules` (pure helpers for the plan's "Pure" tests) and `package var transferredByteCount` (count of fetched content bytes, never content, used to prove a refused read fetched nothing). | Marked in the PR as beyond the plan; the reviewer found both reasonable. |
| Tests import CX11 | The tests use an independent second-connection Xlib peer. | Needed to act as the X11 counterpart; the reviewer accepted it. |

## RED

- Linux, native arm64 container, RED stub: `✘ Test run with 23 tests in 2 suites failed after
  0.147 seconds with 29 issues.` (`commands.json`, `red-linux-x11-tests-stub`, exit 1, recorded as
  an expected failure). This line was transcribed from the session output; the raw file was lost
  with a session restart.

## GREEN

- Linux, native arm64 container with Xvfb (`linux-arm64-container-x11-tests`, exit 0):
  `Build complete! (13.30s)` with `-warnings-as-errors`, then `✔ Test run with 40 tests in 5
  suites passed after 2.498 seconds.` These 40 are all of `LinuxPlatformTests`; the clipboard's
  share is 24 tests in 2 suites (5 pure, 19 Xvfb `.x11`, serialized). The note records 0
  failures in 60 repeated Linux runs after the review fix.
- macOS: `swift test` `✔ Test run with 285 tests in 27 suites passed after 0.137 seconds.`
  (`swift-test`), and the same count with `-warnings-as-errors`
  (`swift-test-warnings-as-errors`).
- `swift format lint --strict` on the two files and on the repository exits 0; `docs check OK`;
  `architecture check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `make verify` exits 0
  (`make-verify`).
- CI `verify-linux`: at the reviewed head `4eb93e2`, run 43870289123 passed with `Test run with 39
  tests in 5 suites` (all of LinuxPlatform under Xvfb), and the 374 and 118 test runs passed
  (reviewer). At the review-fix head `ce8d93c`, run 43877941055 passed both jobs.

## Mutation checks

17 mutants, each killed and restored byte for byte: baseline passing and every mutant `killed`
and `restoredCleanly` in `mutations/mutations.json` (runner `mutations/run_mutations.py`).

| Id | Mutation | Killed by |
| --- | --- | --- |
| M1 | TARGETS always lists STRING | TARGETS lists STRING only when the text is Latin-1, and STRING carries Latin-1 |
| M2 | scalars up to U+FFFF count as Latin-1 | Latin-1 conversion accepts U+0000 to U+00FF and refuses anything above |
| M3 | the stated INCR size is not checked | a read over the limit is refused before the content is transferred |
| M4 | received chunks are not checked against the limit | same test as M3 |
| M5 | the property size is not checked | same test as M3 |
| M6 | the own-window filter is dropped | ownerChanges stays quiet for our own writes |
| M7 | ownerChanges never yields | ownerChanges fires for another application's copy |
| M8 | the read deadline is 5 s | the read deadline is 2 seconds; an owner that never answers times out within the deadline |
| M9 | the write size check is dropped | a write over the limit is refused and leaves the clipboard as it was |
| M10 | writePlainText ignores cancellation | a call from a cancelled task fails with cancellation and changes nothing |
| M11 | shutdown does not answer the read in progress | stop while a read waits on a silent owner ends the read |
| M12 | hex digits are not zero-padded | the content hash is the lowercase SHA-256 hex of the UTF-8 bytes, and stable |
| M13 | INCR is never used | content larger than a quarter of the maximum request is sent with INCR; 1 MiB goes out through INCR |
| M14 | every read uses the same property | an abandoned INCR transfer does not leak into the next read |
| M15 | bytes are decoded with replacement characters | malformed UTF-8 fails with invalidUTF8 and is never repaired |
| M16 | the scoped handler swallows every error | an X error on another display reaches the previous handler, and stop restores it |
| M17 | the previous handler is never restored | same test as M16 |

M16 and M17 were added in the review round. The reviewer also ran four mutants of its own (remove
the INCR declared-size check, remove the own-window filter, rotation 4 to 1, remove the chunk
accumulation limit); all were killed.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| UTF-8 text read and write on X11 `CLIPBOARD` | the 19 Xvfb tests against an independent second-connection peer; mutants M1, M2, M12, M15 |
| Size limits enforced before allocation | the over-limit test and `transferredByteCount`; mutants M3 to M5, M9 |
| INCR for large content, no leakage between reads | the INCR tests; mutants M13, M14 |
| Read deadline, cancellation and stop | mutants M8, M10, M11 |
| `ownerChanges` without self-loops | mutants M6, M7 |
| No new warning, lint clean | `-warnings-as-errors` builds on Linux and macOS; both lints exit 0; `make verify` exit 0 |
| Linux CI | `verify-linux` runs 43870289123 and 43877941055 |
| Manual Verification on a real desktop (Tier H) | Not done here; it needs owner hardware E2E (#351). |

## Independent review

- A fresh-context Opus reviewer (Tier H) returned a conditional approval at `4eb93e2`
  (`independent-review.md`): 0 blockers, 2 Medium, 3 Low. The reviewer ran CI evidence, the
  native arm64 container tests (24 clipboard tests in 2 suites) and its own four mutants.
- Both Medium findings are resolved at `ce8d93c` (scoped error handler with mutants M16 and M17;
  `XInitThreads` recorded as plan amendment h.8 and documented). The Low findings on STRING and
  INCR chunk types and on the rotation edge are documented as fail-closed or accepted.

## Merge

Pending owner approval; the issue stays open (Part of #165) until owner E2E #351.

## Known limitations

- PRIMARY is not synchronized; `MULTIPLE` is refused; `CurrentTime` is used for selection
  requests.
- Xlib's I/O error handler may still exit the process when the display connection is lost; the
  display-loss policy belongs to the composition root.
- STRING (Latin-1) replies with bytes above 0x7F, and INCR chunks of another type, fail closed as
  `invalidUTF8` instead of being transcoded.
- A late chunk arriving after the fifth abandoned transfer could meet an in-use property
  (extreme; accepted).
- Interop with real desktop applications (GTK, Qt, Electron) needs owner E2E evidence (#351).

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2); Linux image `swift:6.2.3-jammy`, native arm64 locally);
the machine-readable test report is in `tests/`.
