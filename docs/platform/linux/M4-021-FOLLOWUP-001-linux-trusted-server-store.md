# M4-021-FOLLOWUP-001 Linux Trusted-Server Store

## Outcome

`LinuxTrustedServerStore` is the Linux client's conformer of the C-015
`SecureStorageBackend` contract (M4-002). In the client role it keeps the C-009
trust state: one trusted SHA-256 server fingerprint per `host:port`, and never a
private key, certificate or revoked state. `LinuxTrustPolicy` decides what a
presented fingerprint means, and `LinuxFirstUseTrust` applies the owner's
answer to a first-use prompt. This is the interim store named by
`docs/adr/M4-SCOPE-001-linux-client-first.md`; every rule below is first-party
policy (no Barrier behavior is involved).

Exact Files:

- `Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxTrustedServerStore.swift`
- `Packages/LinuxPlatform/Tests/LinuxPlatformTests/LinuxTrustedServerStoreTests.swift`
- `docs/platform/linux/M4-021-FOLLOWUP-001-linux-trusted-server-store.md`
- `evidence/issues/M4-021-FOLLOWUP-001/`

## API

```swift
package struct LinuxTrustedServerStore: SecureStorageBackend {
  package init(configDirectory: URL? = nil, environment: LinuxTrustedServerStoreEnvironment = .live)
  package let directoryPath: String?   // <config>/mackvm
  package var filePath: String?        // <config>/mackvm/trusted-servers
}
package struct LinuxTrustedServerStoreEnvironment   // variables, effectiveUserID, adjustStatus (tests)
package enum LinuxTrustedServerRecordFile            // parse / serialize, 1 MiB limit
package enum LinuxFingerprintText                    // lowercase hex, canonical AA:BB:… display
package enum LinuxTrustPolicy { static func decide(stored: Data?, presented: Data) -> LinuxTrustDecision }
package enum LinuxTrustDecision { case prompt, allow, reject(SecurityErrorCode), identityChanged(LinuxFingerprintChangeWarning) }
package struct LinuxFingerprintChangeWarning          // trustedFingerprintDisplay, presentedFingerprintDisplay; redacted
package enum LinuxFirstUseOwnerDecision { case trust, reject }
package struct LinuxFirstUseTrust { evaluate(peer:presentedFingerprint:), apply(ownerDecision:peer:presentedFingerprint:) }
```

## Location

The configuration directory is `configDirectory` when given, else
`$XDG_CONFIG_HOME` when it is an absolute path, else `$HOME/.config`. A
relative `XDG_CONFIG_HOME` is ignored, as the XDG base directory specification
requires. With none of them, every operation fails with
`security(.secureStorageUnavailable)`. The store is
`<config>/mackvm/trusted-servers`.

## File rules

1. The `mackvm` directory is created 0700 on the first insert (the
   configuration directory too, 0700, if it is missing). A load or a remove
   never creates anything; with no directory, a load finds no record and a
   remove succeeds.
2. Every operation first checks the directory with `lstat`. It must be a
   directory, not a symbolic link, owned by the effective user, with no mode
   bit outside 0700 (group, other, setuid, setgid and sticky bits refuse).
   It is then opened with `O_DIRECTORY|O_NOFOLLOW`, and `fstat` of the
   descriptor must pass the same checks and name the same device and inode.
3. The record file is checked the same way with `fstatat(…, AT_SYMLINK_NOFOLLOW)`
   relative to the directory descriptor and opened with `O_NOFOLLOW`: a regular
   file, owned by the effective user, with no mode bit outside 0600. A missing
   file holds no records.
4. Any refusal is `security(.secureStorageUnavailable)` with
   `retryDisposition: .userActionRequired`, and nothing is read or written. A
   storage problem never looks like an unknown server.
5. Writes create a fresh `.trusted-servers.<random>.tmp` in the same directory
   with `O_CREAT|O_EXCL|O_NOFOLLOW` and mode 0600 (then `fchmod` 0600, so the
   umask cannot change it), write the whole new content, `fsync` it, `rename`
   it over `trusted-servers` and `fsync` the directory. A reader sees the old
   file or the new file, never a mixture. A temporary file left by a crash is
   never read, and the next write does not reuse its name.
6. Every operation holds `flock` on the directory descriptor: shared for a
   load, exclusive for an insert or remove (read, change, replace). This
   serializes threads and processes, so of concurrent inserts for one server
   exactly one reports `.inserted`, and concurrent inserts for different
   servers lose no record.
7. File work runs on a global dispatch queue, off the caller's executor.

## Record format

```text
<host:port> <64 lowercase hex digits>\n
```

- The key is a `PeerKey` in its normalized form (its own `rawValue`); a key
  that would normalize to another spelling, such as an uppercase host or a
  port with a leading zero, is not a record.
- One space separates the fields; every line ends with `\n`, including the
  last. An empty file has no records.
- Anything else — a blank line, a comment, `\r`, uppercase hex, a digest of
  another length, a second record for one key, or a file over 1 MiB — makes
  the whole file invalid (fail closed). The store never repairs or rewrites an
  invalid file.
- The store writes records sorted by key.

## Contract behavior (C-015 `SecureStorageBackend`)

- `loadTrustedFingerprint(for:)` returns the stored 32 bytes or `nil` when
  there is no record. From a cancelled task it fails with
  `cancellation.requested` and reads nothing.
- `insertTrustedFingerprintIfAbsent(_:for:)` refuses a value that is not 32
  bytes with `security.trustRejected` before any storage work, even from a
  cancelled task. Otherwise a cancelled task fails with
  `cancellation.requested`. An existing record is never replaced and is
  returned as `.existing(storedFingerprint:)`.
- `removeTrustedFingerprint(for:)` is idempotent and runs even from a cancelled
  task, because it only withdraws trust.

## Trust policy (C-009, plan a.7)

`LinuxTrustPolicy.decide` is a first-party copy of the Mac app's internal
`TrustPolicy`, in this order:

| Presented | Stored | Decision |
| --- | --- | --- |
| not 32 bytes (e.g. 31) | anything | `.reject(.trustRejected)` |
| 32 bytes | none | `.prompt` |
| 32 bytes | not 32 bytes | `.reject(.trustRejected)` |
| 32 bytes | equal | `.allow` |
| 32 bytes | different | `.identityChanged(warning)` |

Only `.allow` lets a connection proceed. `.prompt` fails the handshake with
`security.identityUnknown`; the CLI (M4-020-FOLLOWUP-001) then asks the owner
or prints instructions. A changed identity is never stored and never replaces
the trusted record.

`LinuxFingerprintChangeWarning` keeps only the two canonical displays
(`AA:BB:…`, the rule of the Mac app's `CertificateFingerprint.canonicalDisplay`).
Its `description`, `debugDescription`, interpolation, `dump` and `Mirror` are
redacted, and the raw digests are not kept.

## First-use trust

`LinuxFirstUseTrust.evaluate` loads and decides; it never writes, and a
storage failure is returned as a failure, never as a prompt. `apply`:

- a presented fingerprint that is not 32 bytes → `.reject(.trustRejected)`,
  nothing written;
- `.reject` → `.reject(.trustRejected)`, nothing written;
- `.trust` → insert if absent, then read the record again and decide from that
  read. It answers `.allow` only when the record now holds the presented
  fingerprint; a different existing record answers `.identityChanged` and is
  left as it was.

## Privacy

Nothing in this file logs. A fingerprint leaves it only as the warning's two
display fields, the deliberate presentation of plan a.7.

## Tests

`LinuxTrustedServerStoreTests.swift` (Linux only; each test uses its own
temporary `XDG_CONFIG_HOME`, passed through the store's environment):

- insert, load and remove; a second instance; a duplicate insert returning
  `.existing`; empty file; no directory created by a load or remove;
- wrong-length inserts refused before storage; cancellation;
- refusals with a wide file mode, a wide directory mode, a symbolic link in
  place of the file or the directory, the wrong object type, and another owner
  of the file or directory through the injected `adjustStatus`;
- malformed files rejected whole and left unchanged; the parser's table;
- the rename replace (new inode, no temporary file left) and a leftover
  temporary file ignored;
- concurrent inserts from separate instances (separate descriptors, so the
  same `flock` semantics as separate processes) for one server and for many;
- the policy table with 31- and 33-byte presented fingerprints, the warning's
  redaction by reflection, and the first-use flow.

The tests also pass as a non-root user. Eighteen mutants, one or more per
rule, are recorded under `evidence/issues/M4-021-FOLLOWUP-001/mutations/`.

## Known limitations

- V1 has no revoked state: `forget` (remove) returns a server to unknown, so
  the next connection prompts. This falls short of C-009's revoked case and is
  left to M3-014.
- The C-009 policy is duplicated from the Mac app's internal `TrustPolicy`; it
  moves to `KVMCore` when M3-014 arrives.
- The concurrency test uses separate store instances in one process, not two
  processes; `flock` locks open file descriptions, so the behavior is the same.
- The parent configuration directory itself is not checked (it is commonly a
  link into a dotfiles tree); the `mackvm` directory and the file are.
- Network file systems where `flock` is advisory-only or emulated are not
  supported.
