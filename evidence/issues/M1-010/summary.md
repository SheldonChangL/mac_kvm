# M1-010 Evidence Summary

Implementation commit: `6a86e21e5887924a08bc37166d611adc57a9c584`

## Deliverables

- Canonical `make architecture-check` source-boundary gate.
- KVMCore forbidden-import detection for BarrierCompatibility, NativeProtocol, and macOS input frameworks, including attributed imports.
- Barrier token containment for DKDN, DMMV, CINN, and COUT with one explicit `Packages/BarrierCompatibility` allowlist root.
- Fail-closed unreadable-UTF-8, missing-KVMCore, file-symlink, directory-symlink, and cancellation behavior.
- Cumulative CI integration of the architecture command and both architecture/code-quality tooling unit suites.

## Acceptance criteria

- Happy repository and explicit allowlist pass.
- Forbidden imports/tokens, missing roots, unreadable sources, source-tree symlinks, and cancellation fail closed.
- Diagnostics use only relative path, line, fixed rule id, and allowlisted module/token detail.
- `make architecture-check` and full nine-gate `make verify` pass.
- No public Swift API, protocol, networking, platform input, wire format, security default, or runtime behavior changes.

## Scope and rollback

Make/CI integration, evidence, and handoff are authorized minimal tooling-bootstrap additions. The checker does not replace M1-006 SwiftPM graph validation or any existing build/test/lint/manifest gate.

Rollback is a single PR revert; no runtime state or user data migration exists.

## Known limitations

- The initial Barrier token catalog is the four canonical tokens named by the guardrails/Issue. Future protocol-token Issues must extend the explicit catalog within their PR when introducing another Barrier wire code.
- Tokens in comments outside the adapter intentionally fail to keep Barrier vocabulary out of Core/non-adapter source.
