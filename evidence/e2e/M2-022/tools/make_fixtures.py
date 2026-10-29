"""Builds the sanitized M2-022 fixtures from the two raw capture streams.

Each observation is one complete frame (4-byte big-endian length prefix plus
payload) in capture order, base64-encoded, matching the M1 fixture format.
Timestamps, ports and addresses never enter a fixture. Client-to-server DCLP
data is zero-filled at its original length: it held only a synthetic probe
string, but clipboard bytes are never committed.
"""

import base64
import collections
import hashlib
import json
import pathlib
import sys

RUN1, RUN2, OUT = (pathlib.Path(p) for p in sys.argv[1:4])
DIRECTIONS = {"s2c": "server-to-client", "c2s": "client-to-server"}


def frames(stream_path):
    buffers = collections.defaultdict(bytearray)
    result = []
    for line in open(stream_path):
        record = json.loads(line)
        if "dir" not in record:
            continue
        buffer = buffers[record["dir"]]
        buffer += bytes.fromhex(record["hex"])
        while len(buffer) >= 4:
            size = int.from_bytes(buffer[:4], "big")
            if len(buffer) < 4 + size:
                break
            result.append((record["dir"], bytes(buffer[: 4 + size])))
            del buffer[: 4 + size]
    leftovers = {d: len(b) for d, b in buffers.items() if b}
    if leftovers:
        raise SystemExit(f"incomplete frames left over: {leftovers}")
    return result


def sanitize(direction, frame):
    payload = frame[4:]
    if direction == "c2s" and payload[:4] == b"DCLP":
        return frame[:8] + bytes(len(frame) - 8)
    return frame


def write_fixture(fixture_id, capture_name, stream_path, reference, removed):
    directory = OUT / fixture_id
    directory.mkdir(parents=True, exist_ok=True)
    observations = [
        {
            "sequence": index,
            "direction": DIRECTIONS[direction],
            "applicationPayloadBase64": base64.b64encode(sanitize(direction, frame)).decode(),
        }
        for index, (direction, frame) in enumerate(frames(stream_path), start=1)
    ]
    capture = {
        "schemaVersion": 1,
        "captureId": fixture_id,
        "encoding": "base64",
        "observations": observations,
    }
    capture_bytes = (json.dumps(capture, indent=2) + "\n").encode()
    (directory / capture_name).write_bytes(capture_bytes)
    metadata = {
        "schemaVersion": 1,
        "fixtureId": fixture_id,
        "protocol": "barrier",
        "provenance": {"sourceKind": "black-box-capture", "reference": reference},
        "payload": {
            "path": capture_name,
            "sha256": hashlib.sha256(capture_bytes).hexdigest(),
            "byteLength": len(capture_bytes),
        },
        "sanitization": {
            "status": "sanitized",
            "containsSensitiveData": False,
            "removedCategories": removed,
        },
    }
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    codes = collections.Counter(
        (o["direction"], base64.b64decode(o["applicationPayloadBase64"])[4:8].decode("latin1"))
        for o in observations
    )
    print(fixture_id, len(observations), "observations", len(capture_bytes), "bytes")
    print("  ", dict(sorted(codes.items())))


COMMON = (
    "Controlled black-box observation per Tests/SystemTests/Plans/M2-022-barrier-server-fixtures.md "
    "on the owner-approved Ubuntu 22.04 x86_64 host: external Barrier server barriers "
    "2.4.0-release protocol 1.6 and external Barrier client barrierc 2.4.0-release protocol 1.6, "
    "each on its own virtual X display, through a byte-logging loopback relay. Input was "
    "synthetic (xdotool on the server display). TLS disabled for this observation only; product "
    "TLS default stays enabled. Server is the Linux Barrier server, not a macOS one; Windows not "
    "executed (M2 validation is Linux-only by owner decision, 2026-10-28)."
)

write_fixture(
    "m2-022-linux-server-input",
    "server-input-capture.json",
    RUN1 / "stream.jsonl",
    COMMON + " Session: handshake, enter, pointer moves, buttons 1-5, drag, wheel in four "
    "directions, a key sweep with modifiers and auto-repeat, leave, second enter and leave, "
    "and idle keepalive.",
    ["ip-address"],
)
write_fixture(
    "m2-022-linux-client-clipboard-keepalive",
    "client-clipboard-keepalive-capture.json",
    RUN2 / "stream.jsonl",
    COMMON + " Session: handshake, enter, a synthetic clipboard change on the client display, "
    "leave, then the server process paused until the client gave up on keepalive. "
    "Client-to-server DCLP data is zero-filled at its original length.",
    ["ip-address", "clipboard-payload"],
)
