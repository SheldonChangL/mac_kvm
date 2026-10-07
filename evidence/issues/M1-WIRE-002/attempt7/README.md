# M1-WIRE-002 Attempt 7 Sanitized Stop Evidence

## Status

STOP. Attempt 7 produced a mechanically discriminating sanitized stream-analysis result, but the
attempt is not accepted width evidence because the approved section-16 runtime gate required the
external Barrier runtime connection to succeed. The server reported protocol errors and the
client reported connection failure, so the attempt stops under the approved plan.

## Outcome

- Sanitized artifact: `sanitized.json`
- Sanitized artifact SHA-256:
  `70c0a5930dd75cce1ae9d3536aaaa6f360fdb53e68aa15c8e0d4bd3f2f49c705`
- Sanitized artifact byte length: `1187597`
- Analyzer result: `DISCRIMINATING`
- Analyzer surviving reading: width `4`
- Analyzer rejected reading: width `2`
- Runtime stop label: `protocol-error-before-runtime-connection-success`
- Connections analyzed: `12`
- Direction streams analyzed per connection: `client-to-server` and `server-to-client`
- `client-to-server` stream byte length per connection: `70019`
- `server-to-client` stream byte length per connection: `23`
- Width-4 result: success on every stream.
- Width-2 result: failure on every `client-to-server` stream.
- First width-2 failure: `connection-1`, `client-to-server`, offset `57514`, reason
  `overrun`, declared `24929`, available `12503`.

## Trigger result

- Synthetic client screen-name byte length: `70000`
- Synthetic client screen-name SHA-256:
  `77bd9c6f87d1ad04ed3ca8de8ac34d46bac2824b4539b001f0e5a2fe0c24e9bc`
- Disposable server config byte length: `210491`
- Disposable server config SHA-256:
  `251efacfabe6bc6f21b00e140a011b379f5be69f8f3e5a7e6d02ffef84934d42`
- Runtime connection: not accepted by the plan. The server accepted TCP connections but logged
  `protocol error from client "<unknown>"`; the client logged `server reported a protocol
  error` and exited by timeout with code `124`.

## Raw handling

- Raw capture stayed on `role-capture` and was not committed.
- Raw capture SHA-256 on `role-capture`:
  `490714785d07380d04c71a2beb503258783f418f0721834cbffde1ca9e2859dc`
- Raw capture byte length: `854578`
- Raw capture packet-counter summary: `169 packets captured`, `338 packets received by filter`,
  `0 packets dropped by kernel`

## Consequence

No register entry, width ADR, fixture acceptance or `M1-025` unblock is produced by this
attempt. GitHub Issue #279 remains open.
