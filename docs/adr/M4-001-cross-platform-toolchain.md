# M4-001 Cross-platform Toolchain, Language and FFI

## Status

- **Linux:** the language is the Product Owner's decision of 2026-10-29, verbatim
  「Swift」, recorded in GitHub Issue #330 and
  [`M4-SCOPE-001`](M4-SCOPE-001-linux-client-first.md). The rest of the Linux toolchain
  below is accepted when the Product Owner merges this ADR. The Security Reviewer and
  a reviewer who is not the implementing agent must still check the evidence
  (`evidence/issues/M4-001/`).
- **Windows:** not decided. It is an open question owned by the Product Owner, and it
  blocks M4-004 and any Windows code.

The machine-readable record is
[`toolchain.m4.lock.json`](../../MacKVM_Implementation_Package_v2/toolchain.m4.lock.json).

## Decision owners

- Language and toolchain: Product Owner
- TLS, key handling and identity: designated Security Reviewer
- Evidence: a reviewer who is not the implementing agent

## Context

- Frozen Decision 5 keeps macOS on Swift, AppKit, Network.framework, CGEvent,
  NSPasteboard and Keychain. Frozen Decision 12 leaves the M4 toolchain to this ADR.
- [`M4-SCOPE-001`](M4-SCOPE-001-linux-client-first.md) makes the first M4 target a Linux
  client. It runs on Ubuntu 22.04 x86_64 with X11, talks to the first-party Mac server,
  and has no Linux server role yet.
- `KVMContracts`, `KVMCore` and `BarrierCompatibility` import only Foundation. They share
  `package`-level declarations with each other, so they have to stay in one SwiftPM
  package.
- The owner's Linux PC runs Ubuntu 22.04.5 x86_64 with an X11 session. It has
  `libx11-dev`, `libxtst-dev`, `libxrandr-dev` and `libxfixes-dev`. It has no Swift
  toolchain and no `libssl-dev`.

### Evidence gathered for this decision (2026-10-29)

All runs used the official image
`swift:6.2.3-jammy@sha256:33c73fc133767cdaafde26f0f9967c96ab25ff77618b7df1eabf46140bf2b6e6`
(Swift 6.2.3, Ubuntu 22.04, x86_64). The Mac ran it through Docker as `linux/amd64`.
The scripts are in `evidence/issues/M4-001/spikes/` and the output is in
`evidence/issues/M4-001/tests/`.

| Check | Result |
| --- | --- |
| `KVMContracts` tests | 64 passed |
| `BarrierCompatibility` tests | 245 passed |
| `KVMCore` tests (in one package with `KVMContracts`) | 172 passed |
| Separate packages for `KVMContracts` and `KVMCore` | fails: `cannot find type 'ScreenEdge'` (`package` access does not cross packages) |
| TLS pinning spike: swift-nio 2.104.0, swift-nio-ssl 2.37.5, swift-crypto 3.15.1 | builds as a release binary with `--static-swift-stdlib`; a TLS handshake ran a custom verification callback that hashed the leaf certificate with SHA-256 |
| Spike binary | 106 MB unstripped; dynamic libraries only `libc`, `libm`, `libstdc++`, `libgcc_s` and the loader |

## Selected for Linux

| Concern | Selection |
| --- | --- |
| Language | Swift 6.2.3, the same version as the macOS build |
| Build image | the pinned image above, for local builds (Docker on the Mac) and for CI. The Linux PC needs no toolchain; it runs the built binary |
| Package layout | one SwiftPM package: the root `Package.swift`. macOS-only targets are behind `#if os(macOS)`. The Linux targets and the swift-nio dependencies are behind `#if os(Linux)`, so macOS builds do not resolve them |
| Shared code | `KVMContracts`, `KVMCore` and `BarrierCompatibility`, unchanged |
| Linux platform code | target `LinuxPlatform` in `Packages/LinuxPlatform/Sources/LinuxPlatform`, tests in `Packages/LinuxPlatform/Tests/LinuxPlatformTests` |
| Linux app | executable target in `Apps/Linux/MacKVMClient` |
| TLS | swift-nio-ssl 2.37.5 on swift-nio 2.104.0. It bundles BoringSSL and links it statically. The server is pinned in `NIOSSLCustomVerificationCallback`: the SHA-256 of the leaf DER must match the trusted fingerprint (C-009); an unknown fingerprint prompts, a changed one is rejected, and anything else fails closed. Minimum TLS 1.2 |
| Hashing | swift-crypto 3.15.1 (`Crypto.SHA256`, the CryptoKit API on Linux) |
| X11 | system-library targets over `libX11`, `libXtst` (injection), `libXrandr` (screen geometry) and `libXfixes` (selection ownership). Only documented Xlib calls are used, and nothing is derived from Barrier |
| User interface | headless: a command line plus a `systemd --user` unit. No tray in the Beta |
| Packaging | release binary with `--static-swift-stdlib`. The `.deb` belongs to M4-035 |
| FFI | none. Linux is Swift end to end, and C interop is used only for the X11 system libraries |
| Native Protocol conformance | macOS and Linux share the Swift `NativeProtocol` package. M3-034/M3-035 vectors stay for the protocol itself; no cross-language runner is needed while both are Swift |

### Placeholder resolution for the M4 Linux issues

| Placeholder | Value |
| --- | --- |
| `${LINUX_SOURCE_ROOT}` | `Packages/LinuxPlatform/Sources/LinuxPlatform` |
| `${LINUX_TEST_ROOT}` | `Packages/LinuxPlatform/Tests/LinuxPlatformTests` |
| `${LINUX_SOURCE_EXT}`, `${LINUX_TEST_EXT}` | `swift` |
| file names | the kebab-case name becomes UpperCamelCase: `linux-skeleton` → `LinuxSkeleton.swift`, `linux-skeleton-tests` → `LinuxSkeletonTests.swift` |
| `make verify-linux ISSUE=<id>` | builds and tests the shared and Linux targets in the pinned image |

### Changes M4-020 may make outside its Exact Files

M4-020 has to create the layout above. This ADR authorizes these changes for it, and
for nothing else:

- root `Package.swift`: the OS gating, the `LinuxPlatform` and Linux app targets, and the
  Linux-only swift-nio, swift-nio-ssl and swift-crypto dependencies at the versions above;
- `Makefile`: a `verify-linux` target that runs the pinned image;
- `.github/workflows/`: an `ubuntu-22.04` job that runs `make verify-linux`;
- `Tools/architecture-check/architecture-check.py`: add `Packages/LinuxPlatform` to the
  platform and scan roots, and keep X11 types out of `KVMCore` and `KVMContracts`;
- `.gitignore`: the Linux scratch directory.

## Rejected

### Rust

Rust has the strongest Linux, Wayland and Windows libraries. It was rejected because
about 6,000 lines of contracts, Core, protocol, clipboard and fail-safe logic, and their
tests, would have to be written a second time. Both the Barrier wire and the Native
Protocol would also need a cross-language conformance suite. The owner chose Swift.

### C++ with Qt

Rejected: a third stack, no code reuse, and a structure close to Barrier's own, which
raises the M1-003 clean-room risk.

### Python or Go

Rejected: no reuse, weaker packaging (Python), and cgo for X11 (Go).

### System OpenSSL instead of swift-nio-ssl

Rejected as the primary choice, because it needs `libssl-dev` on every build host and a
matching `libssl3` at run time. It stays as the fallback, owned by M1-055-FOLLOWUP-001,
if swift-nio-ssl cannot pin the Mac server's certificate.

### Separate SwiftPM packages per module

Rejected: `package` access does not cross packages (verified above).

### Installing Swift on the Linux PC

Rejected as a requirement: builds run in the pinned image, and the PC needs only the
binary.

## Consequences

- Linux code is Swift, uses Swift Testing, and is covered by the same architecture
  checker.
- The release binary is about 100 MB before stripping. M4-035 owns size reduction.
- macOS builds do not change, because the Linux dependencies are declared only on Linux.
- CI gains a Linux job. Both Linux and macOS have to stay green.

## Security impact

- TLS is on by default and fails closed. Pinning replaces chain validation with an exact
  SHA-256 match on the leaf certificate (C-009): unknown prompts, changed rejects, and
  there is no trust on first use.
- The Linux client holds no private key, because the Mac server asks for no client
  certificate. A Linux listener identity is out of scope until a Linux server role is
  decided.
- Supply chain: dependency versions are pinned in `Package.resolved` and the build image
  by digest. Any drift stops the Linux build until a Product Owner approved change.
- X11 injection through XTest needs the user's own display connection. The client runs
  as the logged-in user, with no root and no uinput.

## Compatibility impact

Only Ubuntu 22.04 x86_64 with X11 is targeted. Other distributions, arm64, Wayland and
Windows are not claimed.

## Dependency intake (M1-003)

Licenses were read from the fetched sources on 2026-10-29.

| Dependency | Version | License | Use | Distribution |
| --- | --- | --- | --- | --- |
| swift-nio | 2.104.0 | Apache-2.0 | Linux runtime | statically linked |
| swift-nio-ssl | 2.37.5 | Apache-2.0; bundles BoringSSL (its NOTICE: "Combination ISC and OpenSSL license") | Linux runtime TLS | statically linked |
| swift-crypto | 3.15.1 | Apache-2.0 | Linux runtime hashing | statically linked |
| swift-asn1 1.7.3, swift-atomics 1.3.1, swift-collections 1.7.5, swift-system 1.8.1 | as listed | Apache-2.0 | transitive | statically linked |
| libX11, libXtst, libXrandr, libXfixes | Ubuntu 22.04 packages | X11/MIT style | Linux runtime | system libraries, not bundled |
| `swift:6.2.3-jammy` image | digest above | Swift: Apache-2.0 | build only | not distributed |

No GPL dependency. Distribution must ship the Apache-2.0 NOTICE texts and the BoringSSL
license text (M4-035).

## Open questions

| Question | Owner | Blocking condition |
| --- | --- | --- |
| Windows language and UI shell | Product Owner | Blocks M4-004 and any Windows code |
| Linux tray or settings UI | Product Owner | Blocks any Linux UI work; the Beta stays headless |
| Wayland libraries and helper language | Product Owner with Security Reviewer (M4-029) | Blocks M4-030 to M4-033 |
| Linux arm64 and other distributions | Product Owner | Blocks any claim beyond Ubuntu 22.04 x86_64 |
| Binary size reduction (strip, dead stripping) | M4-035 owner | Blocks the `.deb` release |
| swift-nio-ssl pinning against the Mac server's P-256 certificate over TLS 1.3 | M1-055-FOLLOWUP-001 owner with Security Reviewer | Blocks the Linux TLS transport; the fallback is system OpenSSL |

## Rollback

Revert this ADR and `toolchain.m4.lock.json`. No code depends on them yet. Changing the
language later needs a superseding ADR approved by the Product Owner.

## Acceptance record

- Product Owner: 「Swift」, 2026-10-29, GitHub Issue #330. Everything else in "Selected
  for Linux" is accepted when the Product Owner merges this ADR.
- Security Reviewer: pending (`evidence/issues/M4-001/security-review.md`).
- Evidence reviewer who is not the implementing agent: pending
  (`evidence/issues/M4-001/manual.md`).
- The implementing agent is not authorized to provide independent review or merge
  approval.
