# M1-XCODE-001 Xcode Workspace and Shared Scheme

## Outcome

The repository owns a canonical `MacKVM.xcworkspace` and a shared `MacKVM`
scheme. This makes the M1 command contract executable from a fresh checkout:

```bash
xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build
```

`Package.swift` remains the single build-graph source of truth. The workspace
references the repository root with `group:` so Xcode discovers the root Swift
package without introducing a duplicate `.xcodeproj`. The shared scheme names
the `MacKVM` executable product and builds its declared SwiftPM dependencies.

## Portability and repository hygiene

- The workspace and scheme contain only repository-relative references.
- `xcuserdata`, absolute user paths, DerivedData, signing state, and credentials
  are neither required nor committed.
- `Tests/Contracts/test_m1_xcode_workspace.py` parses both XML files and rejects
  user-specific paths or a scheme that no longer resolves the `MacKVM` product.
- Normal Xcode user state remains excluded by `.gitignore`.

## Architecture and security impact

This corrective change adds build metadata only. It does not change SwiftPM
target dependencies, runtime behavior, protocol boundaries, TLS defaults,
input handling, diagnostic content, or application signing. Barrier remains
confined to `BarrierCompatibility`, and Core continues to depend only on
`KVMContracts`.

## Scope and rollback

This Issue does not implement M1-012 or any product behavior. Roll back by
reverting the PR that added `MacKVM.xcworkspace`; the existing Swift package
continues to build with `swift build` and `swift test`.
