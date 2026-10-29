# M2-035 Automated Smoke (Mac server → real Linux Barrier client)

## Scope

Automated, no human operator. The MacKVM server ran as a DEBUG build with the
stdin smoke driver: commands stand in for captured input and go through the same
`ServerCoordinator`, ordered outbox, `ServerSession`, `BarrierServerProtocolSession`
and TLS listener as real input. The event tap, local suppression and the local
cursor were **not** exercised and the Mac's own input was never touched; those
need the human cases of the M2-035 plan.

The client was the real `barrierc` 2.4.0-release on Ubuntu 22.04.5, run on a
private Xvfb display with its own `--profile-dir`, so the host's own `barrierc`,
display and trusted-server list were left alone. The server listened on loopback
only (a LAN connection to the port was refused) and the client reached it through
`ssh -R`. A disposable server identity was created in the login Keychain for the
run and removed afterwards.

## Environment

| Item | Value |
|---|---|
| Server | macOS 26.6.2 (25G83), arm64, Apple Swift 6.2.3, DEBUG build |
| Client | `barrierc` 2.4.0-release, Ubuntu 22.04.5 LTS, OpenSSL 3.0.2, Xvfb 1600x900 |
| Channel | TLS 1.3, `TLS_AES_256_GCM_SHA384`, server pinned by SHA-256 fingerprint |
| Date | 2026-10-28 |

## Results

| Case | Plan case | Observed | Result |
|---|---|---|---|
| TLS handshake and fingerprint pin | C1 | client: `Fingerprint matches trusted fingerprint`, `connected to server`; server: `client m2-smoke ready (1600x900)` | pass |
| Unexpected screen name | C2 | server: `client handshake failed: security(trustRejected)` | pass |
| Enter | C3 (protocol half) | client pointer at (1, 450); client log `entering screen` | pass |
| Pointer motion | C4 | +(100, 50) → (101, 500); +(300, -200) → (401, 300) | pass |
| Buttons and wheel | C4 | X raw buttons 1, 3, 2; wheel up 4 once, down 5 twice | pass |
| Keys and modifiers | C5 | X raw keycodes 38 (a), 50+56 (Shift+b), 36 (Return), 10 (1), 71 (F5) | pass |
| Return edge releases held keys | C3/C7 | `a` held, pushed back past the left edge: client got the release, then `leaving screen` (runs 1–2; since run 3 a held letter keeps the pointer on the client and a held Shift is released instead) | pass |
| Emergency escape while remote | C6 (protocol half) | Control held then escape: release 37 delivered, `leaving screen`, server `local recovery: completed` | pass |
| Client lost while remote | C7 | client killed with Shift held: server `local recovery: completed`, `client disconnected` | pass |
| Reconnect | — | new session; enter + (20, 20) → (21, 470) | pass |
| Keepalive | C8 (idle half) | 13 s idle, then +(30, 0) → (51, 470) | pass |
| Quit while remote | C10 (protocol half) | Shift held, `quit`: release 50 delivered, `leaving screen`, server `stopped` | pass |

The full X raw event sequence on the client display is in `x-events.txt`
(32 events, all from the fixed probe input above).

## Runs

1. Exploratory run, driven by hand through the same smoke driver, on the code
   later committed as `f0b6b78`. Its logs are `server.log` (Mac, timestamps in
   UTC), `client.log` (the last client instance) and `x-events.txt` (decoded X
   raw events on the client display).
2. Scripted re-run at `99f77bd` with the reusable script below: every case
   passed. Both machines were checked clean afterwards: no smoke process, Xvfb,
   temporary directory or Keychain item remained, and the host's own `barrierc`
   was untouched.
3. Scripted re-run at `6700cdf`, after the independent review fixes (a held key
   or button now keeps the pointer on the client, so the return case releases a
   held modifier instead): every case passed (`script-output.txt`).

```sh
MACKVM_SMOKE_HOST=<ssh-alias> Tests/SystemTests/Scripts/M2-035-linux-smoke.sh
```

The script prints closed-vocabulary `M2-035 smoke: <case>=pass|fail` lines and
removes everything it created on both machines.

## Not covered (needs the human operator)

The CGEventTap path with physical input: suppression, cursor parking and return
placement, the emergency chord on a real keyboard, trackpad scrolling, sleep, and
real network loss. These are the remaining M2-035 plan cases.

## Sanitization

Logs contain only loopback addresses, temporary paths and the fingerprint of the
disposable identity, which no longer exists. No host names, LAN addresses or
typed text.
