# M4-020-FOLLOWUP-001 Linux Client App

## Outcome

`mackvm-client` is the first-party Barrier-compatible client for Linux (X11). It
connects to the MacKVM server on the Mac over TLS, pins the server's certificate,
and injects the server's input into the local X display. This document covers the
command line, the composition root that wires the merged client components, the
lifecycle monitor, the systemd user unit and `make dist-linux`
(docs/adr/M4-SCOPE-001-linux-client-first.md, step 5; master plan b.16 with the
amendments h.3, h.5, h.6 and h.8). Every rule here is first-party policy; Barrier
names and meanings come only from M1-PROTOCOL-002/003.

Exact Files:

- `Package.swift`: the `MacKVMClient` executable target and the `mackvm-client`
  product under `#if os(Linux)`; the `NIOTLS` product on `LinuxPlatform`, which
  `LinuxTLSTransport` imports (M1-055-FOLLOWUP-001 left it to this owner); on
  Linux, `MacKVMIntegrationTests` also depends on `MacKVMClient` and
  `LinuxPlatform` for the runtime test.
- `Apps/Linux/MacKVMClient/`: `main.swift`, `ClientConfiguration.swift`,
  `ClientRuntime.swift`, `ClientEffects.swift`, `ClientReport.swift`.
- `Apps/Linux/systemd/mackvm-client.service`.
- `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxLifecycleMonitor.swift` and
  its tests.
- `Tests/Integration/LinuxClientRuntimeTests.swift` (Linux only).
- `Makefile` (`dist-linux`).

## Command line

```text
mackvm-client connect <host>[:port] --name <screen-name> [--display <:n>] [--non-interactive]
mackvm-client fingerprint show <host>[:port]
mackvm-client fingerprint trust <host>[:port] <sha256>
mackvm-client fingerprint forget <host>[:port]
```

- The default port is 24800. A host is a name or an IPv4 address; an IPv6
  address is bracketed (`[fe80::1]:24800`).
- The screen name is 1 to 64 of `[A-Za-z0-9_-]` and must equal the Mac's
  `--client`.
- `--display` takes `[host]:n[.screen]`; without it `DISPLAY` is used. A
  Wayland session is refused (only X11 is supported).
- `<sha256>` is `AA:BB:…` (32 pairs) or 64 hex digits, either case.
- The client refuses to run as root: the trust store accepts files owned by the
  effective user, which for root is root-owned state anywhere
  (M4-021-FOLLOWUP-001).

| Exit code | Meaning |
| --- | --- |
| 0 | ended by SIGINT, SIGTERM or SIGHUP, or a `fingerprint` command succeeded |
| 1 | any other failure (also: running as root) |
| 64 | usage error |
| 69 | no X11 display, no XTest, or the display was lost |
| 78 | a trust decision is needed: unknown or changed identity, or an unusable trust store |

## Composition root

`ClientMain` parses, refuses root, checks the display environment, then
`ClientBootstrap` opens the backends in the order h.8 requires:

1. `XInitThreads()`, before any `Display` is opened.
2. The root's Xlib error handlers (below).
3. `LinuxScreenBackend`, then `LinuxX11Injector` (its `screen` callback reads a
   geometry cache, never Xlib or the injector, because it runs under the
   injector's lock), then `LinuxX11Clipboard`.

`ClientRuntime` then wires:

- `ClientEffects`, the `ClientCoordinatorEffects` and `ClientInputSafety`
  adapter. `inject` and pointer moves go into a `LinuxInjectionDrain` (a bounded
  FIFO with one dedicated `Thread`), a new drain per session generation. The plan
  named `CaptureQueue`; the drain replaces it because h.6 and M1-063 require the
  worker to be a `Thread` that the terminal path stops and joins. A full or
  stopped drain returns `false`, and the coordinator fails closed. Inbound
  clipboard text is written by one task, newest payload only.
- `FailSafeCoordinator`, `CleanupHooks` and `ClientCoordinator` over it, with a
  disconnect that closes the current generation's session.
- `ReconnectManager`, whose attempt reads the trusted fingerprint, builds a fresh
  `LinuxTLSTransport` and `BarrierClientProtocolSession`, connects, calls
  `established()`, feeds the session's events to `ClientCoordinator.run`, and
  returns or throws as the session ended (a.5).
- `RecoveryCoordinator`, fed by `LinuxLifecycleMonitor`.
- Pumps for the screen's changes (the geometry cache and `DINF` updates), the
  clipboard's owner changes (read only while input is on this screen, then
  `localClipboardChanged` and `send`), the lifecycle signals and the reconnect
  states (status lines; the network poll is armed while a reconnect waits).
- `SIGINT`, `SIGTERM` and `SIGHUP` through `DispatchSource`, into the one
  shutdown.

### One cleanup per generation

- Every exit of an attempt ends its generation through
  `ClientCoordinator.terminate` (or `run`), including a cancelled attempt
  (h.3). The cleanup is the M1-064 chain: stop and join the drain, the ledger's
  release plan, the injector sweep, the ledger clear, a bounded disconnect.
- The runtime records every terminate it starts. Before the next generation it
  awaits them; `beginSession() == false` means "wait, then retry", never a
  failure. The retry polls every 5 ms for at most 10 s; on expiry the attempt
  reports a superseded `backoff` failure and the manager retries later. A later
  terminate that returns `skipped` does not wait.
- A wake ends the current generation (awaiting its cleanup) before
  `ReconnectManager.connect()`, so the old generation's input is released before
  the new session injects (h.5).
- A generation ended from outside its attempt (a wake, a sleep, a termination)
  makes the attempt report a superseded connection with a `backoff` disposition,
  so the error the cleanup causes never stops the manager.

### Trust (a.7)

- Before each connection the stored fingerprint is read; the TLS handshake's
  evaluator accepts only an equal one (`LinuxTrustPolicy`). Unknown, changed and
  malformed identities fail the handshake, so no application byte reaches an
  unaccepted server, and stop the reconnect generation (`userActionRequired`).
- Unknown, interactive (a terminal and no `--non-interactive`): the canonical
  display is shown and the person types `trust`; `LinuxFirstUseTrust.apply`
  stores it (never replacing a record) and the client connects again. Any other
  answer stores nothing and exits 78.
- Unknown, non-interactive: the display and the exact
  `mackvm-client fingerprint trust <host>[:port] <hex>` command are printed with
  the server left as a placeholder (the instructions name no host); exit 78;
  nothing is written.
- Changed: both displays are shown, nothing is stored or replaced; exit 78.
- The presented fingerprint is kept only for these displays. It is never logged,
  put in an error or status line, or sent anywhere.

### Shutdown (h.3, h.8)

`finish` runs once: it refuses `connect()` from then on, stops the lifecycle
monitor, first releases everything the injector holds (its own 1 s bound, so no
later step that blocks can leave input held), ends the current generation and
waits for its cleanup, disconnects the manager, stops the screen and clipboard,
and closes the injector (`close()` releases what it still holds; its `deinit`
does not). The whole shutdown is bounded by 5 s; when the bound fires the
status line "the shutdown did not finish in time; exiting" is printed, and the
process exits with its code either way.

The drain join of the terminal path is bounded (2 s, then `cleanupPartial`).
After a display loss the drain is not joined at all: its worker may be parked in
Xlib's I/O error handler for good, `inject` already refuses everything, and no
release touches Xlib.

A signal or a display loss while the interactive trust prompt waits is a
decline: nothing is stored, and the client exits with that ending's code (0 for
a signal, 69 for a display loss). End of input at the prompt exits 78.

Display loss is detected three ways: an injector failure with
`lifecycle.subsystemUnavailable`, a screen or clipboard stream that ends without
a stop, and Xlib's I/O error handler. Each marks the display lost (no later step
touches Xlib), runs the cleanup and exits 69. The backends deliberately leave a
lost connection unclosed on that assumption.

### Xlib error handlers (h.8)

The root installs its handlers after `XInitThreads()` and before any display is
opened, keeps the previous handlers and restores them after every backend
stopped. Each backend's scoped handler (M4-026) chains to the root's. The root
owns every display in the process, so it is the end of the chain: a protocol
error is counted and ignored rather than forwarded to Xlib's default, which
exits the process with input held. The I/O error handler reports display loss
once and parks the calling thread, because returning would let Xlib exit before
the cleanup.

## Status lines

Status lines use a closed vocabulary (`ClientStatus`): fixed text plus at most
a count or a frozen error code. They never contain a host, port, screen name,
address, key, position, clipboard text or fingerprint. The deliberate trust
texts (`ClientTrustText`) show fingerprints on purpose; only
`fingerprint show` echoes the server the person typed.

## Lifecycle monitor

`LinuxLifecycleMonitor` (`LifecycleBackend`) has no D-Bus, logind or netlink
dependency:

- A 1 s timer samples `CLOCK_BOOTTIME − CLOCK_MONOTONIC`. Both advance together
  while the machine runs; only the boot-time clock advances during a suspend. A
  jump over 5 s yields `didResume`. `willSuspend` is never yielded; a sleep is
  handled by the keepalive and the cleanup of the dead stream (plan f.10).
- `getifaddrs` with an interface that is up, not loopback and has an IPv4 or IPv6
  address is "network available". It is polled every 2 s only while armed (the
  runtime arms it while a reconnect waits). An edge yields `networkAvailable` or
  `networkUnavailable`; arming takes a fresh baseline.
- The runtime reports the current network state before each wake (h.3).
- The decisions (`LinuxResumeDetector`, `LinuxNetworkEdgeDetector`) are pure and
  tested with injected clocks and probes.

## systemd user unit

`Apps/Linux/systemd/mackvm-client.service`, installed to
`~/.config/systemd/user/` with the binary in `~/.local/bin/`:

- `[Unit]`: `Description=MacKVM Barrier-compatible client`,
  `After=` and `PartOf=graphical-session.target`.
- `[Service]`: `ExecStart=%h/.local/bin/mackvm-client connect <host> --name <name> --non-interactive`,
  `Restart=on-failure`, `RestartSec=5`, `RestartPreventExitStatus=64 69 78`,
  and hardening: `NoNewPrivileges=yes`, `LockPersonality=yes`,
  `RestrictSUIDSGID=yes`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`,
  `UMask=0077`. `DISPLAY` and `XAUTHORITY` are not set in the unit; they come
  from `import-environment`. `MemoryDenyWriteExecute`, `ProtectHome` and
  `ProtectSystem` are not used (unverified with the Swift runtime, and the trust
  store lives in the home directory).
- `[Install]`: `WantedBy=graphical-session.target`.

The owner edits `<host>` and `<name>`, runs
`systemctl --user import-environment DISPLAY XAUTHORITY`, then
`systemctl --user daemon-reload && systemctl --user enable --now mackvm-client`.
The server is trusted once from a terminal first; the unit exits 78 on an
unknown or changed identity and does not restart-loop. It runs as the user,
never as root.

## Distribution

`make dist-linux` builds `mackvm-client` in release mode in the pinned image with
`--static-swift-stdlib`, and writes `artifacts/linux/mackvm-client`, the unit file
and `SHA256SUMS`. The binary is not stripped (M4-035 owns size). The target PC
needs only `libx11-6 libxtst6 libxrandr2 libxfixes3` and an X11 session.

## Tests

- `Tests/Integration/LinuxClientRuntimeTests.swift` (Linux only): the parser
  matrix and exit codes; the runtime against an in-process
  `BarrierServerProtocolSession` (under `ServerSession`) over an in-memory
  duplex stream with fake backends: enter, move, buttons, keys, leave, and
  clipboard both ways; killing the server stream releases every held key and
  button and starts the next generation; a wake while connected releases the old
  input before the new session injects (h.5); the network state is reported
  before a wake, a cancelled attempt runs the cleanup, and termination stops the
  monitors and refuses `connect()` (h.3); display loss from the injector, the
  screen stream and Xlib's I/O error handler exits 69; the trust flow (unknown →
  78 with no host in the text and no write; interactive trust and decline;
  changed; unusable store); the bootstrap order (h.8); the handler chain; the
  unit file's structure (`systemd-analyze` is not in the image).
- `Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxLifecycleMonitorTests.swift`:
  resume and network edges with injected clocks and probes.
- Mutations: `evidence/issues/M4-020-FOLLOWUP-001/mutations/`.

## Known limitations

- The client is not supported as root (the trust store's ownership rule).
- A missing parent of the configuration directory makes the trust store fail
  closed (`secureStorageUnavailable`, exit 78); the status line says the
  directory must exist. Only `mackvm` itself is created.
- A suspend is not seen in advance (no logind): input held at suspend is released
  after resume, by the cleanup of the old connection.
- A crash of the process runs no cleanup; XTest-held input stays pressed
  (plan f.9).
- A shutdown step that hangs is cut by the 5 s bound; the process then exits
  without the rest of the shutdown. The release sweep runs first, so input
  held by this client is released before any step that can block. A bounded
  step that times out leaves its thread running until the process exits.
- Only `CLIPBOARD` UTF-8 text is synchronized; only US-layout key positions are
  claimed (M4-024, M4-026).
- Real-desktop behavior (a real X session, suspend and resume, network changes,
  the unit under systemd) is owner E2E evidence (M4-036-FOLLOWUP-001).
