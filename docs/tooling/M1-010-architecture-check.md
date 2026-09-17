# M1-010 Architecture Boundary Checker

## Outcome

M1-010 establishes the canonical source-level architecture command:

```bash
make architecture-check
```

The existing `make verify`/GitHub CI pipeline invokes the identical Python entrypoint. Any violation, unreadable source, symlinked Swift source, missing KVMCore root, or cancellation returns non-zero.

## Enforced rules

### KVMCore forbidden imports

All Swift files under `Packages/KVMCore` reject plain or attributed imports of:

- `BarrierCompatibility`
- `NativeProtocol`
- `AppKit`
- `CoreGraphics`
- `ApplicationServices`

This preserves the frozen Core/protocol/platform separation. Foundation and other platform-neutral imports are not prohibited by this Issue.

### Barrier token containment

The canonical Barrier tokens `DKDN`, `DMMV`, `CINN`, and `COUT` are rejected in Swift source under `Apps`, `Packages`, and `reference` unless the source is beneath the single explicit allowlisted root:

```text
Packages/BarrierCompatibility
```

Matching requires a word boundary to avoid rejecting unrelated identifiers such as `DKDNextState`. Tokens in comments still fail intentionally: Core and non-adapter source must not carry Barrier vocabulary as code, examples, or implementation notes.

## Fail-closed behavior

- Swift source paths are deterministic and sorted.
- Nested SwiftPM `.build` directories are generated products, not repository
  source, and are excluded from both source and symlink discovery. Other hidden
  directories are not implicitly excluded.
- Symlinked `.swift` files are rejected rather than followed.
- Invalid UTF-8 or unreadable source is reported as a typed rule without logging file content.
- Diagnostics contain only repository-relative path, line, fixed rule id, and allowlisted module/token detail.
- Keyboard interruption and runner `SIGTERM` return 130 after the current in-memory scan stops; no external resource or child process exists to clean up.

## Relationship to other gates

M1-006's SwiftPM dependency-graph verifier remains authoritative for declared target dependencies. M1-010 adds source-level containment; it does not replace the package graph, formatter/lint, build, unit tests, manifest validation, or native-arm64 gates. The cumulative CI pipeline directly runs both the architecture-check and code-quality Python unit suites so the tools cannot silently regress while their happy-path commands still pass.

## Scope and rollback

No runtime product API, protocol encoding, wire byte, input behavior, networking, TLS, trust, or logging behavior is added. Make/CI integration and evidence/handoff additions are the authorized minimal tooling-bootstrap expansion.

Rollback by reverting the M1-010 PR. This removes the source-level architecture gate without changing runtime state or user data.
