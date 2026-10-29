# M2-035 Mac Server → Linux Barrier Client E2E Plan (bounded, manual)

## Status

Plan only. Live execution is blocked; see Preconditions. The runner script
for this Issue is a local, read-only precondition gate that exits 69 and
writes no result while any precondition is unmet. No live result is claimed.

## Scope

MacKVM on an Apple Silicon Mac as the server/input source; an existing
Ubuntu Barrier client (`barrierc` 2.4.0-release, protocol 1.6) as the
controlled peer. Windows is out of scope and not claimed.

## Preconditions (all must hold before any live step)

| ID | Precondition | Current state | Source |
|---|---|---|---|
| P1 | Accepted server wire contract (M2-023) | Proposed, not accepted | `docs/adr/M2-023-barrier-server-wire-contract.md` |
| P2 | Frozen pointer/button/wheel encoding (M2-026) | Not frozen | M1-PROTOCOL-001 and M1-PROTOCOL-002 §Non-claims |
| P3 | Frozen key encoding (M2-027) | Not frozen | same |
| P4 | Server TLS listener with provisioned server identity | Not implemented; no decision | M2-023 unsupported table |
| P5 | Approved capture/evidence plan if any capture is needed (M2-022) | None | M2-022 Issue |
| P6 | Composition root wiring event tap, queue, reducer, router, sessions and fail-safe in the app | Not implemented | follow-up |
| P7 | Human operator at the Mac and the Linux desktop | Required | this plan |

## Environment record (to fill at execution)

Date; build commit; macOS version/build; CPU architecture; display layout
and logical sizes; keyboard layout; network scope (no addresses or ports in
the repository); peer OS and version; X11 or Wayland session type on the
Linux desktop (`XDG_SESSION_TYPE` of the graphical session, not an SSH
session).

## Cases (each bounded to 2 minutes; stop on first safety failure)

| Case | Steps | Pass condition |
|---|---|---|
| C1 handshake | Start server; start client with the expected screen name | Client logs connected; server reaches ready; TLS on |
| C2 identity | Start a client with an unexpected screen name | Rejected; no session; local input unaffected |
| C3 enter/leave | Push pointer across the linked edge for the activation delay; return | Client logs entering/leaving; Mac cursor restored inside the edge |
| C4 mouse | Move, click left/right/middle, scroll while remote | Same actions on Linux; no local clicks on the Mac |
| C5 keyboard | Type a fixed non-personal probe string and modifiers while remote | Linux receives keys; no Mac input; nothing logged |
| C6 escape | Press Control+Option+Command+Delete while remote | Local input immediately restored without network |
| C7 held input | Hold a key and a button, then kill the client | No stuck key/button on either side; Mac local |
| C8 network loss | Disable the network while remote | Mac returns to local within the timeout |
| C9 sleep | Sleep the Mac while remote; wake | Mac local after wake; no suppression |
| C10 termination | Quit MacKVM while remote | Local input restored; tap released |
| C11 clipboard | Only if a UTF-8 clipboard wire contract is accepted | Otherwise recorded not applicable |

## Evidence rules

Save `result.json`, sanitized logs and the environment record under
`evidence/e2e/M2-035/`. No typed text, clipboard payload, key material,
addresses, ports, hostnames or screen recordings showing personal data.

## Abort and safety

Any case that leaves the Mac without local input fails the run immediately;
the operator uses the emergency chord, then the physical power key as last
resort. Abort steps are recorded.
