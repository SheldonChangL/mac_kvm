# M1-CAPTURE-TOOLCHAIN-001 Evidence Summary

GitHub Issue: #274

Implementation commit: `60e8924c40f4536a72a06f1418a5aa5be78622c4`

## Trigger and correction

M1-024 requires a toolchain lock before any capture and forbids guessing
protocol bytes, but the package only shipped `toolchain.lock.example.json`,
which describes the M4 first-party production toolchain and stays
`UNRESOLVED_UNTIL_M4-001`. M1-024 also listed only four Exact Files while its
Expected Evidence and Deliverables require a fixture set and a full evidence
package.

This corrective issue adds the accepted ADR
`docs/adr/M1-CAPTURE-TOOLCHAIN-001-capture-readiness.md`, the closed M1-only
lock `MacKVM_Implementation_Package_v2/toolchain.lock.json`, the identical
M1-024 Issue and `issues_manifest.json` amendment, and the contract test
`Tests/Contracts/test_m1_024_capture_readiness.py`.

This corrective issue performs no capture and creates no M1-024 evidence. No
fixture, raw capture, `evidence/issues/M1-024/` file or `evidence/e2e/M1-024/`
result is produced here; all of those remain M1-024 deliverables.

## Capture provenance

The lock prepares a future controlled black-box observation: a lawfully
installed external macOS Barrier client (`barrierc`) connects to an external
Linux Barrier server (`barriers`), and the observed bytes serve only as
evidence for a later independent first-party implementation. No first-party
macOS Client participates in that capture, because its contract is not frozen
until M1-025.

## Acceptance criteria mapping

- Closed lock: `toolchain.lock.json` has `lock_id` `M1-CAPTURE-TOOLCHAIN-001`,
  status `LOCKED`, scope `M1_CONTROLLED_BARRIER_BLACK_BOX_CAPTURE_ONLY` and
  M1-024 as its only scoped Issue; it is deterministic JSON and the contract
  test rejects unknown or missing keys.
- Pinned environment: the lock pins the verified macOS capture host (macOS
  26.6.2 build 25G83, arm64, Apple Swift 6.2.3, Python 3.9.6 system and 3.14.7
  CI Homebrew, `barrierc` 2.4.0-release protocol 1.6) and Linux peer (Ubuntu
  22.04, x86_64, `barriers` 2.4.0-release protocol 1.6, Dumpcap/Wireshark 3.6.2
  package 3.6.2-2, tcpdump 4.99.1); the test rejects any changed version.
- Fail-closed drift: any OS, architecture, tool, Barrier or protocol version
  that differs from the lock stops M1-024 capture; only a new Product Owner
  approved ADR may change the lock.
- Barrier boundary: Barrier is an external test peer only
  (`EXTERNAL_TEST_PEER_ONLY`); no Barrier implementation is copied, linked or
  bundled into the repository.
- Raw capture and fixture content: raw packet capture remains outside the
  repository and is never committed; the future retained fixture holds only
  ordered direction plus uninterpreted application payload bytes. No field
  meaning, message code, endianness or compatibility is asserted, and the test
  rejects such claims in the M1-024 Issue and manifest.
- Windows: Windows is not executed in M1 (`windows_executed` is false), no
  Windows result is claimed, and the test rejects Windows execution claims.
- M1-024 Exact Files: the original four Exact Files remain first, followed by
  exactly the two fixture files and six evidence files; the package Issue and
  manifest agree, carry the required clarifications and reference the lock and
  ADR.
- Provenance: the ADR Context states the external black-box provenance above,
  and the test rejects any claim that a first-party macOS Client produced the
  capture.
- M4 preservation: `toolchain.lock.example.json` is byte-for-byte unchanged
  with its hash pinned by the test and keeps `UNRESOLVED_UNTIL_M4-001`; the M1
  lock records the M4 Windows and Linux production toolchain as
  `UNRESOLVED_UNTIL_M4-001` and not selected by this lock.
- Privacy: the lock enumerates the prohibited content (hostname, IP address,
  username, path containing a username, credential, key, token, certificate
  identity, certificate fingerprint, typed text, clipboard content); the test
  rejects identifying content in the lock, ADR and M1-024 Issue. This evidence
  contains none of it.
- Architecture: the ADR is Accepted with all required sections and does not
  change canonical or frozen product architecture, public contracts, runtime,
  protocol, TLS/trust or security defaults.
- Formal gates: the 15-test contract suite, package validation, docs check,
  architecture check, `git diff --check` and all 21 `make verify` gates
  (including repository-contract-tests, Swift package tests,
  swift-test-targets and native-arm64-build) passed locally at the
  implementation commit; see `commands.json`.

## Remaining gates

- GitHub CI on the pull request has not yet run; it is a PR gate.
- Issue #17 synchronization has not yet happened; it is a post-merge gate.
- M1-024 capture, fixture, evidence package and non-implementing independent
  review remain M1-024 work under this lock.

## Rollback

Revert the ADR, `toolchain.lock.json`, the M1-024 Issue and manifest changes,
the contract test and this evidence together in one change, and keep M1-024
blocked. Any fixture or evidence produced under this lock must then be treated
as unapproved and must not be used as M1-024 completion evidence.
`toolchain.lock.example.json` needs no rollback because it is unchanged.
