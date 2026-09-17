# M1-012 Redacted Diagnostic Bundle Skeleton

## Outcome

`Tools/diagnostic-bundle/diagnostic-bundle.py` creates a new ZIP archive from a
bounded structured JSON input. It is an internal repository tool, not a public
product API or stable wire format. The tool only runs after an explicit CLI
invocation and never collects, uploads, rotates, or retains data on its own.

```bash
python3 Tools/diagnostic-bundle/diagnostic-bundle.py \
  --input structured-diagnostics.json \
  --output diagnostics.zip
```

The output contains exactly:

- `manifest.json`: internal schema version, safe local configuration metadata,
  and event count.
- `events.jsonl`: validated C-010 diagnostic envelopes.

## Fail-closed allowlists

The input root contains exactly `schemaVersion`, `config`, and `logs`.
Unknown fields are rejected before a temporary archive is created. The tool
reconstructs the output from validated values instead of copying source JSON.

Allowed configuration metadata is limited to:

- semantic `applicationVersion` tokens;
- a bounded `macOS-X.Y[.Z]` operating-system version;
- `protocolMode`: `barrierCompatibility`, `native`, or `disabled`;
- boolean `tlsEnabled`.

The initial internal event catalog is intentionally small:

| Event id | Category | Severity | Exact metadata |
|---|---|---|---|
| `connectivity.connection.failed` | `connectivity` | `warning` | closed `stage`, `reason`, and `retry` enums |
| `inputSafety.cleanup.completed` | `inputSafety` | `info` | `outcome` must be `completed` |

Each event must contain exactly `category`, `eventId`, `correlationId`, and
`metadata`. Correlation is absent or a canonical UUIDv4. Unknown events,
category mismatches, metadata keys, enum values, arbitrary strings, and
non-canonical correlation values fail closed.

Severity and the optional typed error code are fixed catalog properties, not
caller fields. The initial entries have no error code. A completed event cannot
carry `partial` or `failed`; those outcomes require separately reviewed event
ids so diagnostics never assert success for an unsuccessful cleanup.

This catalog supports only the skeleton tests and is not a Swift event API.
Adding an event or field requires the M1-011 catalog/privacy review and an
Issue that owns the emitting component.

## Privacy and security behavior

- Typed text, key codes/sequences, cursor trails, clipboard payloads/hashes,
  keychain data, secrets, tokens, certificates, fingerprints, private/public
  keys, raw frames, paths, host/network/device/peer identifiers, and arbitrary
  strings have no schema field and are rejected as `unknown_field`.
- Values are validated before serialization; there is no best-effort string
  scrubbing, hashing, truncation, debug bypass, or raw exception output.
- Input must be a regular non-symlink file and is read through one opened file
  descriptor with a hard 1 MiB bound. At most 256 event records are accepted.
- Output is created beside a mode-0600 temporary file, fully closed, then
  atomically linked into place. Existing output is never overwritten.
- Failure or `KeyboardInterrupt` removes the temporary archive. Error output is
  a fixed typed code and never includes source content or a caller path.

The tool has no access to Keychain, clipboard APIs, input APIs, networking, or
OSLog. It cannot weaken input cleanup, TLS, trust rejection, or application
lifecycle behavior.

## Exit behavior

- `0`: bundle created.
- `2`: typed arguments, validation, input, output, I/O, cleanup, or internal
  failure.
- `130`: cancellation by `KeyboardInterrupt`.

Success prints only `diagnostic bundle created`. Failure prints only
`diagnostic bundle failed: <closed-code>`; cancellation prints only
`diagnostic bundle cancelled`.

## Verification

```bash
python3 Tools/diagnostic-bundle/tests/test_diagnostic_bundle.py -v
xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build
python3 Tools/Backlog/validate_package.py
make architecture-check
```

The test suite covers the CLI happy path, maximum/over-limit boundaries,
malformed JSON, schema/type/category/event/value rejection, prohibited content
classes, output-preservation, cancellation cleanup, and bounded input.

## Known limitations and follow-ups

- This skeleton consumes structured diagnostic data; it does not integrate an
  application sink, OSLog, UI, retention scheduler, or upload workflow.
- The application must not invoke it automatically. A future UI must obtain an
  explicit owner export action and preserve this fail-closed boundary.
- The catalog intentionally exports no clipboard event payload, key/input
  detail, certificate/fingerprint, peer identity, address, or path.

## Rollback

Revert the M1-012 PR. Delete any locally generated test bundle if it is no
longer required. No product state, secure storage, input state, network state,
or migration is affected.
