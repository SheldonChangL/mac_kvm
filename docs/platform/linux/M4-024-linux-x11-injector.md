# M4-024 Linux X11 Injector

## Outcome

`LinuxPlatform` provides `LinuxX11Injector`, the Linux conformer of the C-015
`InputInjectionBackend` contract (M4-002), and `LinuxInjectionDrain`, the
dedicated drain thread that feeds it. Both are in
`Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Injector.swift`, with
`package` access. The injector turns `KVMEvent` input into XTest requests on
an X11 display connection it owns. Everything below is first-party policy,
built from the X11 public API (`keysymdef.h`, `XF86keysym.h`, XTest) and the
repository's contracts. Nothing is derived from Barrier source.

The `${LINUX_SOURCE_ROOT}` placeholders of the issue resolve, by
`MacKVM_Implementation_Package_v2/toolchain.m4.lock.json`, to
`Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Injector.swift` and
`Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxX11InjectorTests.swift`.

## API

| Member | Meaning |
| --- | --- |
| `LinuxX11Injector.init(displayName:screen:)` | Opens the display (`DISPLAY` when `nil`). Throws `lifecycle.subsystemUnavailable` without a display and `permission.capabilityUnavailable` without XTest |
| `inject(_:)`, `flush()`, `releaseAllHeld()` | The C-015 calls |
| `release(_:)` | `ClientInputSafety.release`: `inject` of the release, then `XSync`; an `.unsupported` release counts as done (plan h.6) |
| `releaseRemaining()` | `ClientInputSafety.releaseRemaining`: `releaseAllHeld()`, then `XSync` (plan h.1) |
| `restoreLocalInput()` | No-op: the client never suppresses local input |
| `close()` | Releases what is held, syncs and closes the connection; idempotent |
| `LinuxKeySymMapper.keysym(for:)` | The pure key table |
| `LinuxX11PointerMath` | Pure pixel, button and wheel conversions |
| `LinuxX11InputPort`, `init(port:screen:)` | The seam over the X11 calls; tests use an in-memory port |
| `LinuxInjectionDrain` | Bounded FIFO and one dedicated `Thread`; `start()`, `enqueue(_:)`, `clearTransientState()` |

`LinuxPlatform` does not import `KVMCore`, so the injector and the drain do not
declare `ClientInputSafety` conformance. The composition root
(M4-020-FOLLOWUP-001) adapts them: `clearTransientState()` is the drain's,
the other three steps are the injector's.

## Key table

US ANSI positional, as M1-043; other layouts are not claimed.

| C-005 member | Keysym |
| --- | --- |
| `letter(n)`, `0...25` | `XK_a + n` |
| `digit(n)`, `0...9` | `XK_0 + n` |
| `function(n)`, `1...24` | `XK_F1 + n − 1` |
| punctuation, in `PunctuationKey` order | `XK_minus`, `XK_equal`, `XK_bracketleft`, `XK_bracketright`, `XK_backslash`, `XK_semicolon`, `XK_apostrophe`, `XK_grave`, `XK_comma`, `XK_period`, `XK_slash` |
| `enter`, `escape`, `tab`, `space`, `backspace`, `delete` | `XK_Return`, `XK_Escape`, `XK_Tab`, `XK_space`, `XK_BackSpace`, `XK_Delete` |
| arrows, `home`, `end`, `pageUp`, `pageDown` | `XK_Left/Right/Up/Down`, `XK_Home`, `XK_End`, `XK_Prior`, `XK_Next` |
| `shift`, `control`, `option`, `command`, `capsLock` | `XK_Shift_L`, `XK_Control_L`, `XK_Alt_L`, `XK_Super_L`, `XK_Caps_Lock` |
| `volumeUp`, `volumeDown`, `mute` | `XF86XK_AudioRaiseVolume`, `XF86XK_AudioLowerVolume`, `XF86XK_AudioMute` |
| `unknown`, out-of-domain payloads | none: `.unsupported(.unknownKey)` in every phase |

The key code is `XKeysymToKeycode` of the keysym; 0 is
`.unsupported(.noPlatformKeyCode)`. The keysym values are written as numbers
with their names, because the system-library shim includes only `Xlib.h`.

## Events

| Event | XTest |
| --- | --- |
| `mouseMove` | `XTestFakeMotionEvent(dpy, -1, origin + round(x·(w−1)), origin + round(y·(h−1)), 0)`, clamped; the inverse of the decoder's `(pixel − origin)/(extent − 1)` |
| `mouseButton` | `XTestFakeButtonEvent`: left 1, middle 2, right 3, auxiliary 8. A button above `XGetPointerMapping`'s count is `.unsupported(.buttonUnavailable)` |
| `scroll` | per notch, a press and release of 4 (`deltaY > 0`, up), 5 (down), 6 (`deltaX > 0`, left), 7 (right); vertical first; at most 32 notches per axis |
| `key .down/.up` | `XTestFakeKeyEvent` |
| `key .repeatKey` | never injected: `.unsupported(.repeatNotInjected)`; the X server autorepeats XTest-held keys (plan decision 6, risk f.4) |
| `clipboard`, `enterScreen`, `leaveScreen` | `internal.preconditionFailed`, nothing changes |

Each injected event is followed by `XFlush`; `flush()` is `XSync`. A failed
XTest, flush or sync request is `lifecycle.subsystemUnavailable`.

## Held input and the sweep

The injector records each held key and button with the key code or button it
was pressed with, in memory only, never logged. A release of held input uses
that code, so a keymap change between press and release cannot strand it, and
such a release is never `.unsupported`. `releaseAllHeld()` releases keys other
than modifiers, then buttons, then the modifier group (`shift`, `control`,
`option`, `command`, `capsLock`), each group in reverse press order. Input
whose release fails stays recorded and the call fails with
`inputSafety.cleanupPartial`; a later call retries it. A second call after a
success releases nothing.

## Drain thread and the terminal path

`LinuxInjectionDrain` is a bounded FIFO with one dedicated `Thread`
(`mackvm-inject`, within the 15-byte Linux thread-name limit), never a `Task` on the cooperative pool
(M1-063). `enqueue(_:)` never blocks and returns `false` when the queue is
full or the drain is stopped; the caller then fails closed. An injection
failure is reported once through `onFailure` and stops the worker.
`clearTransientState()` stops the worker, waits for the event it is
injecting, then drops the queue (plan h.6). It is idempotent, and a stopped
drain accepts nothing; each session uses a new drain.

The terminal path is therefore: `drain.clearTransientState()` →
`ReleaseAllKeys` plan through `injector.release(_:)` →
`injector.releaseRemaining()` → ledger cleared → disconnect. A release the
reset dropped after the ledger had counted it is still freed by the sweep
(plan h.1, risk f.16).

## Threads

The composition root calls `XInitThreads()` once before any Xlib call (plan
a.3). The injector serializes every use of its own connection with one lock,
so calls from any thread take effect one at a time, in call order.

## Tests and evidence

- `LinuxX11InjectorTests.swift`: the pure table and pointer arithmetic; the
  injector's rules over an in-memory port (unknown keys, repeats, missing key
  codes, keymap change, buttons, wheel, motion, non-input events, display loss,
  release order, partial sweep, `release`, `releaseRemaining`, `close`); the
  drain (order, dedicated thread, join of the in-flight event, bounds, failure,
  the h.1 dropped release); and, under Xvfb (`.x11`), the M2-035 smoke's
  key codes (`a` 38, Shift 50, `b` 56, Return 36, `1` 10, F5 71, minus 20),
  buttons, wheel and motion delivered to a test window on a second connection,
  autorepeat of a held key, an empty `XQueryKeymap` and button mask after the
  terminal path, and `permission.capabilityUnavailable` from an Xvfb started
  with `-extension XTEST`.
- Mutations: `evidence/issues/M4-024/mutations/`.

## Known limitations

- Xlib's default I/O error handler exits the process when the display
  connection breaks. Installing a handler that turns display loss into
  `lifecycle.subsystemUnavailable` is the composition root's job
  (M4-020-FOLLOWUP-001); until then display loss ends the process.
- Only US-layout positions are claimed (risk f.5); `XKeysymToKeycode` picks the
  first key code for a keysym.
- Lock and modifier state at enter are not synthesized (owner decision 3, risk
  f.6).
- A crash of the client leaves XTest-held input pressed (risk f.9).
- The Tier H evidence is the Xvfb suite now and the owner E2E (M4-036-FOLLOWUP-001)
  later.
