# M4-026 Independent Review

- Reviewer: a fresh-context review agent (Opus, Tier H), started by the lead, not the
  implementer, 2026-11-17.
- Target: PR #363 at `4eb93e2` (the first head), read-only.
- The client master plan, including plan amendment h.8, is the lead's planning document and is
  not in the repository. The decisions it settled for this issue are restated in `summary.md`.

## Report

The report is verbatim, in English, as the reviewer wrote it.

> Reviewer: fresh-context Opus agent, Tier H (STRONG_REVIEW_PROMPT), 2026-11-17, target head 4eb93e2 (PR #363). Paths: Src = Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Clipboard.swift.
> Verdict: conditional APPROVE. No blocker; one Medium to fix or document before merge.
> MEDIUM Src:284: XSetErrorHandler(ignoreXErrors) is process-wide; each clipboard overwrites the previous handler and never restores it, so X errors of every later Xlib user (the concurrent M4-027 screen backend, XTest injection) on any display are silently swallowed (they should see BadWindow etc.); the handler does not distinguish displays. Suggest either one handler installed by the composition root dispatching per display, or wrap serve/answer with XSync while saving and restoring the previous handler.
> MEDIUM Src:122: the comment says the composition root calls XInitThreads, but no production code calls it, only the tests (Tests:363). Each display is used on its own thread so it holds today, but the error handler is global and will coexist with other backends; must be tracked in the M4 composition-root issue, not only in a comment.
> LOW Src:541-568: non-INCR reads check only format==8, not type UTF8_STRING; a STRING (Latin-1) reply with bytes > 0x7F fails as invalidUTF8 instead of transcoding; fail-closed, acceptable, document it.
> LOW Src:583: INCR chunks do not check type either.
> OK: limit checks precede allocation (zero-length XGetWindowProperty for size, Src:624-636; INCR declared size Src:547; accumulated size Src:594; all before takeProperty).
> LOW: abandoned INCR rotation uses 4 properties; a late chunk after the 5th could hit an in-use property (extreme); accepted.
> Extras: LinuxX11ClipboardRules pure functions, reasonable; transferredByteCount a package-level byte count, acceptable, mark it as beyond the plan in the PR. Tests importing CX11 to act as the X11 peer: necessary, acceptable. No print/log/Logger in Src.
> Ran: CI run 43870289123 verify-linux "Test run with 39 tests in 5 suites passed" (all of LinuxPlatform via Xvfb; the clipboard itself is 24 tests in 2 suites; clarify in the PR); 374 and 118 test runs also passed. Local Docker arm64 swift:6.2.3-jammy + Xvfb, MACKVM_X11_TESTS=1, --filter LinuxX11Clipboard: "24 tests in 2 suites passed". Own mutants, all killed: M1 remove INCR declared-size check (Src:547) fails Tests:467 (servedByteCount 2000, expected 0); M2 remove own-window filter fails Tests:606, :643; M3 rotation 4 to 1 fails Tests:498; M4 remove chunk accumulation limit (Src:594) fails Tests:478 (transferredByteCount 3000).

## Resolution (`ce8d93c`)

| Finding | Resolution |
| --- | --- |
| Medium: the X error handler is process-wide, overwrites the previous one and swallows errors of every later Xlib user | Fixed in `ce8d93c`: the previous handler is kept, only errors on the clipboard's own displays are ignored (registry under a lock), others are chained to the previous handler, and it is restored when the last clipboard stops. A new test covers foreign-display errors reaching the previous handler and the restore after stop; mutants M16 and M17 are killed. Scoping the handler exposed two test-side problems that were hidden before: the test peer sent a negative length (BadValue) after an abandoned transfer, and Xvfb resets when its last client disconnects, so connections opened during the reset got ECONNRESET (errno 104); the test process now keeps one connection open (60 runs, 0 failures). |
| Medium: no production code calls `XInitThreads` | The doc states that the composition root (M4-020-FOLLOWUP-001) must call it before any Display opens; recorded as plan amendment h.8. |
| Low: STRING (Latin-1) and INCR chunk types are not checked | Documented as fail-closed `invalidUTF8`. |
| Low: the abandoned INCR rotation uses 4 properties | Documented; accepted. |
| Extras and test counts | The PR body marks `transferredByteCount` as beyond the plan and states that 40 is all of LinuxPlatform and the clipboard has 24 tests in 2 suites. |
| Mutants | 17 of 17 killed; CI run 43877941055 passes both jobs. |
