# M1-040 Barrier Keyboard Fixtures — Capture Plan

## Status

- Capture and sanitization completed from a private raw packet capture on 2026-10-06 (Asia/Taipei).
- Raw packet capture remains outside the repository.
- This document is not a protocol contract. It does not define or freeze key-code meaning, message-code meaning, endianness, framing, field semantics or compatibility.
- Windows is not executed in M1.

## Purpose

Produce one sanitized, reproducible fixture of uninterpreted Barrier keyboard-related TCP application payload bytes, in capture order with direction only, from a controlled black-box observation of two lawfully installed external Barrier programs:

- server: external Barrier Linux server `barriers` 2.4.0-release, protocol 1.6, on the locked Ubuntu 22.04 x86_64 test peer;
- client: external Barrier macOS client `barrierc` 2.4.0-release, on the locked macOS capture host.

Barrier stays an external test peer only. No Barrier or Deskflow source is read, copied, linked, bundled or vendored by this plan.

## Non-claims

- No key-code meaning, message-code meaning, message boundary, endianness, framing, version negotiation or semantic claim about any payload byte.
- No compatibility claim between Barrier and MacKVM, between Barrier versions, or between platforms.
- No security claim. Both external peers ran with encryption disabled solely so application payload bytes were observable for this controlled observation. MacKVM production TLS default remains enabled and fail-closed.
- Observation boundaries in the fixture are direction-change boundaries of captured byte stream only; they are not messages.
- No Windows result.

## Binding inputs

- Issue: `MacKVM_Implementation_Package_v2/issues/M1/M1-040-barrier-keyboard-fixtures.md`
- Toolchain lock: `MacKVM_Implementation_Package_v2/toolchain.lock.json` (`M1-CAPTURE-TOOLCHAIN-001`)
- ADR: `docs/adr/M1-040-UNBLOCK-001-keyboard-capture-scope.md`
- Scope ADR: `docs/adr/M1-SCOPE-001-linux-only-validation.md`
- Fixture metadata schema: `Tests/Fixtures/fixture-metadata.schema.json`

## Scripted key sequence

The capture uses only a predeclared non-text scripted sequence generated on the Linux server side after the pointer had been confirmed to reach the macOS client screen:

1. Right Arrow
2. Shift + Left Arrow
3. Caps Lock
4. Caps Lock
5. Down Arrow held for approximately one second, then released

The sequence intentionally contains no letters, digits, names, words, credentials or clipboard content.

## Capture procedure

1. Confirm Linux Barrier server can move pointer/input to the macOS Barrier client.
2. Start `tcpdump` on the Linux peer in a private directory outside the repository, capturing only Barrier TCP traffic.
3. Execute the scripted key sequence on the Linux server display using `xdotool`.
4. Stop `tcpdump`; copy the raw pcap to a private macOS directory.
5. Sanitize the pcap into `keyboard-capture.json` by extracting only TCP application payload bytes whose source or destination is the Barrier server port, coalescing adjacent records with the same direction, and retaining only ordered direction plus base64 payload bytes.
6. Discard IP addresses, ports, packet timestamps, hostnames, usernames and raw capture metadata from repository artifacts.
7. Verify no stuck key, no suppressed local input and no committed raw capture.

## Sanitized fixture

- Payload: `Tests/Fixtures/Barrier/m1-040-linux-keyboard/keyboard-capture.json`
- Metadata: `Tests/Fixtures/Barrier/m1-040-linux-keyboard/metadata.json`
- Runs: 62
- Aggregate decoded payload bytes: 744

## Rollback

Revert all M1-040 Exact Files and the M1-040 contract-test update together. Any downstream keyboard decoder or virtual-key work must then treat M1-040 as incomplete.
