# M4-036-FOLLOWUP-001 E2E Evidence

Status: **failed (not passed)**, by design. All 22 automated cases pass. The
owner-hardware half has not been run and is recorded as a pending (failed) case, so
`result.json` must not become `passed` until the owner completes
`evidence/issues/M4-036-FOLLOWUP-001/manual.md` and a reviewer who is not the agent
signs it.

## What ran

`make e2e ISSUE=M4-036-FOLLOWUP-001` at `65379c4` (this branch merged with `main` at
`a555a07`), 2026-11-19 (UTC), with `MACKVM_E2E_CONTAINER` set and the default test
port 24811. The earlier run of record at `cc4ccb8` (2026-11-17) failed
`clipboard-large-to-client`; see "History" below. Plan:
`Tests/SystemTests/Plans/M4-036-FOLLOWUP-001-linux-client-e2-e.md`.

| Item | Value |
| --- | --- |
| Server | macOS 26.6.2 (25G83), arm64, Apple Swift 6.2.3, `MacKVM smoke` DEBUG, loopback only, test port, disposable Keychain identity (removed) |
| Client | first-party `mackvm-client` DEBUG from the same commit, Ubuntu 22.04.5 arm64 container (`swift:6.2.3-jammy` + Xvfb 21.1.4, xdotool, xinput, xclip, and the libX11, libXtst, libXfixes and libXrandr headers to build the client), non-root user, Xvfb 1600x900 |
| Channel | TLS, server pinned by SHA-256 fingerprint; the client reached the Mac loopback listener through the Docker Desktop host gateway |

The Linux test host was reachable but has no Swift toolchain, and installing one was
not authorized, so the client ran in a local native arm64 container (not the emulated
amd64 image). The host's own `barrierc`, display and trust list were not touched;
nothing bound port 24800.

## Results

| Case | Result |
| --- | --- |
| fingerprint-changed-exit-78 | pass |
| fingerprint-changed-no-bytes | pass (server: `connection refused before the handshake`; no session) |
| handshake | pass |
| enter | pass (1, 450) |
| clipboard-to-client | pass |
| move-1, move-2 | pass |
| held-key-locks | pass (the key probe saw the held key down) |
| return | pass |
| clipboard-from-client | pass |
| escape | pass |
| clipboard-not-echoed | pass |
| clipboard-large-from-client (100 KB client → server) | pass |
| kill-client-no-stuck-key | pass (2 keys down before SIGTERM, 0 after, exit 0) |
| reconnect | pass |
| clipboard-on-reconnect | pass |
| keepalive-13s | pass |
| clipboard-large-to-client (600 KB server → client) | pass (matched by SHA-256, session kept) |
| quit-while-remote | pass |
| auto-reconnect | pass |
| client-sigterm-exit-0 | pass |
| x-events (keys, buttons, wheel 4/5 and horizontal 6/7) | pass |
| owner-hardware-half | pending (recorded as failed, exit 69) |

### History: `clipboard-large-to-client`

At `cc4ccb8` this case failed in all six runs: each 600 KB server clipboard ended the
client session with `transport.resourceExhausted`, and later server clipboards were not
applied. Two fixes on `main` address it: #373 (backpressure for inbound TLS data in
`LinuxTLSTransport`) and #376 (inbound clipboard hashing, so the second and later
server clipboards are applied). In this run the case passes, and `client.log` shows no
`resourceExhausted`.

### Observation (not a failure)

The kill-with-keys-held path emits a second release for Shift and `a` after they are
already up (`x-events.txt`: two redundant releases). A release of a key that is up
changes no X state; the check drops such releases and the script prints their count.

## Artifacts

`server.log`, `client.log` (status lines of the changed-fingerprint run and the two
client processes) and `x-events.txt` (decoded XI2 raw key and button events). The
fingerprints of the disposable identity are masked. No typed text, clipboard content,
address, host name or user name; the probes are fixed strings in the script.
