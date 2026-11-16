# M4-027 Linux Screen Enumeration and Scaling Backend

## Outcome

`LinuxScreenBackend` is the Linux conformer of the C-015 `ScreenBackend` contract
(`PlatformBackendContracts.swift`, M4-002). It reports the local X11 desktop's size and the
pointer position, and notifies when the desktop's size changes, so the Linux client can send an
accurate DINF (screen info) message and re-send it after a resolution change.

The issue's Exact Files, resolved by `docs/adr/M4-001-cross-platform-toolchain.md` and section
b.11 of the lead's Linux client plan (plan):

- `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxScreenBackend.swift`
- `Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxScreenBackendTests.swift`
- `docs/platform/linux/M4-027-linux-screen-backend.md` (this file)

No shared file (`Package.swift`, `Makefile`, CI workflow, architecture checker) is touched, and no
public contract is added.

## Scope decisions (first-party policy unless a source is cited)

| Topic | Decision |
| --- | --- |
| Identity | None. X11 has one desktop rectangle; the contract's geometry carries no monitor identity. How the Mac server relates several monitors is an open P003 question and not this backend's business. |
| Origin | Always (0, 0): the root window of an X11 screen starts at the origin. |
| Scale and transform | None. X11 pixel coordinates are what the DINF message carries; the Linux client role needs no Retina normalization (`M4-SCOPE-001`). |
| Negative coordinates | Cannot occur on an X11 root window; the origin fields stay in the contract for platforms that have them. |
| Display server | X11 only (the toolchain lock). A Wayland session is refused earlier by `LinuxDisplayEnvironment`. |
| Hot-plug | A monitor or resolution change that changes the root window's size is reported through `changes` (RandR `RRScreenChangeNotify`). |

## Behaviour

- `init(displayName:)` opens the display (`nil` uses `$DISPLAY`). Failure to open it is
  `lifecycle.subsystemUnavailable`; an X server without RandR is
  `permission.capabilityUnavailable` (a change could not be observed, so the backend fails
  closed rather than report a geometry it cannot keep current). All errors are terminal
  (`retryDisposition: never`, `cleanupDisposition: notRequired`).
- `currentGeometry()` reads the size of the default screen's root window with `XGetGeometry`
  (live, not Xlib's cached screen structure) and the pointer with `XQueryPointer`. A width or
  height of 0, or above 0x7FFF (the DINF 16-bit range, M1-PROTOCOL-003), is
  `protocol.invariantViolation`. A pointer that is on another screen of the display is
  `lifecycle.subsystemUnavailable` (fails closed): a made-up position would mislead the server.
- `changes` is one `AsyncStream` for the backend's lifetime, observing from creation (the
  RandR selection is made and synchronized before the starting geometry is read). It yields
  only when the origin or the size differs from the last reported value, never for pointer
  movement alone, never a size below 1, and with `bufferingNewest(1)`: a consumer that falls
  behind receives the newest geometry.
- `stop()` is idempotent, serialized and bounded: it wakes and joins the event thread, finishes
  `changes`, closes both connections and the wake pipe. Later `currentGeometry()` calls fail with
  `lifecycle.subsystemUnavailable`. Dropping the backend stops it.

## Concurrency

The backend owns two X connections. The query connection serves `currentGeometry()` under a
lock. The event connection is touched only by one private `Thread`, which polls the connection
and a wake pipe, so it never blocks inside Xlib and `stop()` can end it. Before Xlib reads,
the thread peeks the connection for end-of-file, and `currentGeometry()` and the report path do
the same check on the query connection before every query (a server that dies while a query
is in flight cannot be guarded: Xlib's IO handler cannot return, so the composition root's
process exit is the backstop): Xlib's default handler would
terminate the process on a lost display. A lost display finishes `changes`, makes
`currentGeometry()` fail with `lifecycle.subsystemUnavailable`, and leaves the dead connections
unclosed (closing them would trigger the same handler). The drain loop reads only what Xlib
has already queued (`QueuedAlready`); a second socket read after the server closed the
connection would reach the fatal handler. The composition root exits on display loss
(exit 69, plan b.16) and treats the finished stream as the signal; it owns that policy, not
this backend.

Because no Xlib call from two threads shares a connection, this backend does not depend on
`XInitThreads()`. The composition root still calls it once before any other Xlib call, as plan
a.3 requires for the other backends. The backend never calls `XInitThreads()` and installs no
X error handler (`XSetErrorHandler`), as plan amendment h.8 requires: Xlib errors reach the
process's own handler.

## Tests

`LinuxScreenBackendTests.swift` (Swift Testing; Linux only):

- a test seam, `init(displayName:runsEventThread:)` (package): with no event thread, a test
  reaches the query guard that the event thread would otherwise pre-empt;
- pure rules, everywhere: range checks, change definition, error shapes, headless failure of an
  unreachable display;
- `.x11` tests (`MACKVM_X11_TESTS=1`): each starts its own Xvfb with `-displayfd` and a
  1600x900 RANDR screen, so it does not share the runner's display with the parallel X11 suites
  of other issues. They cover the root geometry, the pointer after `XWarpPointer`, `stop()`
  twice and concurrently, release of a waiting consumer, descriptor cleanup, queries right after
  the server is killed (no crash, with and without the event thread), a lost display seen by the stream, a resize report
  (and silence for pointer movement alone), coalescing to the newest geometry, and silence after
  `stop()`.

The resize tests need an Xvfb whose RandR size range allows the new size; when it does not, the
test records an issue instead of passing silently (the change path is then owner-E2E only).

## Known limitations

- Two lost-display guards cannot be killed deterministically by a named failing test: removing
  the event thread's EOF check makes Xlib end the process (a crash while the server-loss test
  runs, recorded as mutant L1), and reading the socket again in the drain loop (mutant L2,
  `QueuedAfterReading`) only misfires when the server's close arrives in the same wake-up as
  data, which a test cannot schedule. L2 is a documented survivor.
- Test harness and Xvfb: Xvfb resets when its last client disconnects, and a connection made
  during the reset is dropped (ECONNRESET; found by M4-026). Against Xvfb in the linux/arm64
  container a raw Xlib loop failed 556 of 600 opens without a client kept connected and 0 of
  600 with one. Each test server therefore keeps one sentinel connection for its whole life, and
  `openBackend` does not retry.
- Multi-monitor layouts are not described: only the root window rectangle is reported.
- Wayland is out of scope (see above).
- Hardware evidence (a real X session, resolution change and hot-plug on the owner's PC) belongs
  to the owner E2E of the composition root; the Xvfb tests are the automated evidence.
