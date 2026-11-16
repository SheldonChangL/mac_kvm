# M4-020 Linux Skeleton, Build and Test Infrastructure

## Outcome

The root SwiftPM package now builds on both platforms from one manifest. macOS
builds see the Mac app, `MacPlatform` and the system tests; Linux builds see
`LinuxPlatform`, its tests, four X11 system-library targets and the swift-nio,
swift-nio-ssl and swift-crypto dependencies. The shared targets (`KVMContracts`,
`KVMCore`, `BarrierCompatibility`, `NativeProtocol` and their tests) build on
both. `make verify-linux ISSUE=<id>` builds and tests the Linux side in the
image pinned by `MacKVM_Implementation_Package_v2/toolchain.m4.lock.json`
(LOCK), and CI runs it in an `ubuntu-22.04` job.

`LinuxSkeleton.swift` is the first `LinuxPlatform` source. It detects the
display server from the environment, holds the LOCK constants the build depends
on, and owns the switch that keeps X11 tests off unless a display is provided.

The layout and the changes outside the issue's Exact Files are those that
`docs/adr/M4-001-cross-platform-toolchain.md` (TOOL) authorizes for M4-020 in
"Changes M4-020 may make outside its Exact Files", as resolved by section b.10 of
the lead's Linux client plan (plan).

## Layout

| Path | Contents |
| --- | --- |
| `Packages/LinuxPlatform/Sources/LinuxPlatform` | target `LinuxPlatform` (`package` API) |
| `Packages/LinuxPlatform/Tests/LinuxPlatformTests` | target `LinuxPlatformTests` (Swift Testing) |
| `Packages/LinuxPlatform/Sources/CX11` | system library over `libX11` (`pkgConfig: "x11"`) |
| `Packages/LinuxPlatform/Sources/CXTest` | system library over `libXtst` (`pkgConfig: "xtst"`) |
| `Packages/LinuxPlatform/Sources/CXRandR` | system library over `libXrandr` (`pkgConfig: "xrandr"`) |
| `Packages/LinuxPlatform/Sources/CXFixes` | system library over `libXfixes` (`pkgConfig: "xfixes"`) |

Each system library is a `module.modulemap` and a `shim.h` that includes only
the documented Xlib header of that library. The Linux app target
(`Apps/Linux/MacKVMClient`, product `mackvm-client`) is added later by
M4-020-FOLLOWUP-001 with its sources, because an empty target does not build.

## Package manifest

- The shared targets stay in the `Package(...)` literal. `#if os(macOS)` adds
  the `MacKVM` product and the `MacKVM`, `MacPlatform` and `MacKVMSystemTests`
  targets with `package.products += ...` and `package.targets += ...`;
  `#if os(Linux)` adds the dependencies and the Linux targets the same way. The
  entries keep their earlier indentation, so the substrings that
  `Tests/Contracts/test_m1_006_package_boundaries.py` and `test_m1_005` pin are
  unchanged, and the macOS `swift package dump-package` that the M1-006 and
  M1-007 verifiers read lists the same targets as before.
- `LinuxPlatform` depends on `KVMContracts`, the four system libraries,
  `NIOCore`, `NIOPosix`, `NIOSSL` and `Crypto`. It also names `SwiftASN1`,
  `Atomics` and `SystemPackage`: those three packages are pinned directly (next
  item), and SwiftPM warns about a declared dependency that no target uses.
  swift-nio and swift-crypto use them anyway, so this adds no code.
- Every package in LOCK's `swift_dependencies` is declared with
  `.package(url:exact:)`, the transitive ones included (swift-asn1, swift-atomics,
  swift-collections, swift-system). Resolution therefore cannot pick a newer
  transitive release than the lock names.

### `Package.resolved`

Plan a.1 inferred that SwiftPM deletes a `Package.resolved` when the manifest it
evaluates has no dependencies, which is the case on macOS. M4-020 checked it: a
`Package.resolved` placed at the root was gone after `swift package resolve` on
macOS. The file is therefore not committed; `/Package.resolved` is in
`.gitignore`, and `verify-linux` checks the resolved graph against LOCK instead.

## `LinuxSkeleton.swift`

### Display-server detection

`LinuxDisplayEnvironment.detect(environment:)` returns a `LinuxDisplayServer`:
`.x11`, `.wayland` or `.headless`. It reads only the given dictionary, so it
never links or opens X11 and is safe in tests, headless processes and systemd
units. The rules are first-party policy:

1. a non-blank `WAYLAND_DISPLAY`, or `XDG_SESSION_TYPE` equal to `wayland` in any
   case, is `.wayland`, even when XWayland also sets `DISPLAY`;
2. otherwise a non-blank `DISPLAY` is `.x11`;
3. anything else is `.headless`, including `XDG_SESSION_TYPE=x11` without a
   `DISPLAY` (there is nothing to connect to).

Empty and whitespace-only values count as unset. Other session types (`tty`,
`mir`, ...) are ignored, so the `DISPLAY` rule decides. `isSupported` is true
only for `.x11`, because LOCK locks the display server to X11. A Wayland session
is reported as Wayland so that the composition root (M4-020-FOLLOWUP-001) can
refuse it with a clear message instead of injecting through XWayland.

### Headless test mode

Tests that need an X server are Swift Testing tests tagged `.x11` (the tag is
declared in `LinuxSkeletonTests.swift`) and enabled with
`.enabled(if: LinuxPlatformSkeleton.x11TestsEnabled(environment:))`. The switch
is on only when `MACKVM_X11_TESTS` is exactly `1`. A plain `swift test` is
therefore headless; `verify-linux` sets the variable under `xvfb-run`.

The one `.x11` test in M4-020 proves only that the gate works: under `xvfb-run`
the environment has a `DISPLAY` and detection says `.x11`. It does not link or
open X11, so it is not X11 evidence; the first X11 evidence comes from the
backends (M4-024, M4-026, M4-027).

### Toolchain lock constants

`LinuxPlatformSkeleton.toolchainLock` mirrors LOCK's language, build image,
target OS, architecture, display server, Swift dependency versions and system
libraries. The tests read LOCK and compare every field, and check that
`Package.swift` pins each dependency with `exact:` at the LOCK version, so a
drift in the constants, the manifest or LOCK fails a test (LOCK's
`FAIL_CLOSED` drift rule).

## `make verify-linux ISSUE=<id>`

`ISSUE` must be letters, digits and `-` (otherwise exit 64). The recipe runs
`docker run --rm --platform linux/amd64` on LOCK's image digest with the
repository mounted read-only at `/src`, `.build-linux/` at `/scratch` and
`artifacts/` at `/artifacts`. The host passes the commit it is run on. Inside
the container it:

1. prints `swift --version`, `uname -m` and the source commit;
2. installs `libx11-dev libxtst-dev libxrandr-dev libxfixes-dev xvfb xauth
   openssl` (`xauth` is what `xvfb-run` needs for its display cookie);
3. copies `/src` to `/work` without `.build`, `.build-linux`, `artifacts` and
   `.git`;
4. writes `swift package show-dependencies --format json` to
   `artifacts/ci/linux/<id>-dependencies.json` and compares every package in the
   graph with LOCK's `swift_dependencies`: a missing, extra or different version
   exits 65;
5. `swift build --build-tests`, then `swift test` for the root package with
   `--xunit-output artifacts/ci/linux/<id>-xunit.xml` (KVMCoreTests,
   MacKVMUnitTests, MacKVMIntegrationTests, LinuxPlatformTests);
6. `swift test` for the `KVMContracts` and `BarrierCompatibility` packages;
7. `MACKVM_X11_TESTS=1 xvfb-run -a -s "-screen 0 1600x900x24 +extension RANDR"
   swift test --filter LinuxPlatformTests`, with the report in
   `<id>-x11-xunit.xml`; the run fails if that report holds fewer than
   `LINUX_MIN_TESTS` test cases (15 today), so a renamed suite cannot pass with
   zero tests.

Any failure stops the run with a non-zero exit.

## CI

`.github/workflows/m1-ci.yml` gains the job `verify-linux` on `ubuntu-22.04`,
`timeout-minutes: 45`. It checks out without credentials, restores
`.build-linux` with `actions/cache` keyed by `hashFiles('Package.swift')` and the
image digest, runs `make verify-linux ISSUE=ci`, and uploads
`artifacts/ci/linux/` even on failure. The macOS job `build-test-manifest` is
unchanged. Making `verify-linux` a required check is a branch-protection
setting for the owner; until then a red Linux job blocks merges by policy.

## Architecture checker

`Tools/architecture-check/architecture-check.py` now:

- treats `Packages/LinuxPlatform` as a platform root, so it may not import
  `BarrierCompatibility` or `NativeProtocol` and may not use Barrier wire
  tokens;
- forbids `CX11`, `CXTest`, `CXRandR`, `CXFixes`, `Glibc`, `Musl`, `SwiftASN1`,
  `Atomics`, `SystemPackage`, `X509`, and every module whose name starts with
  `NIO`, `Crypto` or `_Crypto`, in `KVMCore` and `KVMContracts`;
- forbids the four X11 modules in the protocol packages as platform imports,
  and every `NIO*` module there as concrete networking (the C library modules
  `Glibc` and `Musl` stay allowed there, like `Darwin`);
- reports `XEvent`, `XKeyEvent` and `XButtonEvent` in `KVMContracts` as platform
  types (`XK_` constants were already caught).

`Tools/architecture-check/tests/test_architecture_check.py` covers each rule.
The plan reads TOOL's authorization of the checker change as including the
checker's own tests.

## Known limitations

- On an Apple silicon Mac, `verify-linux` runs the `linux/amd64` image under
  emulation; a cold build compiles BoringSSL and takes several minutes. The CI
  cache shortens warm runs.
- Detection reads the environment only. It does not prove that the display can
  be opened; the X11 backends report that when they connect.
- No X11 call is made yet. The system-library targets are compiled and linked
  by the first backend that imports them (M4-024, M4-026, M4-027).
