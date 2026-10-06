# M1-040 Manual Verification

## Procedure

- Product Owner/operator confirmed Linux Barrier server input could reach the macOS Barrier client before capture.
- The scripted key sequence was declared before the accepted capture attempt and contained only non-text keys: Right Arrow, Shift+Left Arrow, Caps Lock, Caps Lock, Down Arrow hold/release.
- Linux peer ran the Barrier server; macOS ran Barrier client with encryption disabled for this controlled observation.
- `tcpdump` captured Barrier TCP traffic in a private Linux directory outside the repository.
- The Linux side executed the predeclared non-text scripted key sequence: Right Arrow, Shift+Left Arrow, Caps Lock, Caps Lock, Down Arrow hold/release.
- Raw pcap was copied to a private macOS directory and sanitized into repository fixture JSON.

## Expected

- Capture includes Barrier keyboard-related application payload bytes from Linux server to macOS client.
- No raw pcap, address, hostname, username, typed text, clipboard payload, credential or key material is committed.
- No stuck key or suppressed local input remains after the attempt.

## Actual

- Sanitized fixture contains 62 ordered direction runs and 744 decoded application payload bytes.
- Directions present: client-to-server, server-to-client.
- Raw packet capture is not committed.
- Windows was not executed.
- No stuck key or suppressed local input was reported by the operator after the capture window.

## Reviewer requirement

`evidence/issues/M1-040/independent-review.md` must be authored by a reviewer who did not implement this capture package before M1-040 can be treated as complete.
