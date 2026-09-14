# M1-005 macOS 14 Native arm64 Build

## Outcome

MacKVM's root Swift package requires macOS 14 or newer and produces a native arm64 executable on Apple Silicon without Rosetta translation.

## Build contract

- `Package.swift` declares `.macOS(.v14)`.
- `swift build --arch arm64` is the canonical native debug build during bootstrap.
- The resulting `MacKVM` Mach-O must report exactly `arm64` through `lipo -archs`.
- The build verifier fails when the host architecture is not arm64 or `sysctl.proc_translated` reports Rosetta translation.
- M1-008 must run the same verifier on a native Apple Silicon GitHub runner; an x86_64 runner or a translated process is a failure, not an allowed fallback.

## Verification

Run:

```bash
Tools/verify/M1-005-mac-arm64-build.sh
```

The verifier accepts an optional repository root, so CI and reviewers can invoke it from a different working directory. Invalid argument counts and missing roots return non-zero typed exits.

The generated Xcode scheme is a developer convenience, not the M1-005 gate. Because this repository selected the Issue-authorized SwiftPM workspace instead of `MacKVM.xcworkspace`, Xcode 26 may emit destination-variant warnings for the command-line executable even when it builds successfully. The canonical verifier avoids that ambiguous destination selection and checks the actual Mach-O output instead.

## Scope controls

- This Issue changes only deployment/build constraints and verification.
- The zero-behavior app shell remains unchanged.
- No module boundary, public API, protocol, networking, UI, input, permission, trust, logging, or third-party dependency is introduced.
- Universal and x86_64 product policy is outside M1-005; the M1 client build is arm64-only.

## Failure and cleanup

- A non-arm64 host, Rosetta translation, missing macOS 14 manifest declaration, failed build, missing executable, or non-arm64 product fails closed.
- SwiftPM build artifacts live under the ignored `.build/` directory and may be regenerated safely.
- The verifier does not change source files, trust state, credentials, application data, or OS configuration.

## Rollback

Revert the M1-005 PR to restore the prior unconstrained bootstrap manifest. No data or public API migration is required. M1-008 remains blocked until a compliant native build policy is restored.
