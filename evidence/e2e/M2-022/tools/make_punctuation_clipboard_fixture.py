"""Builds the sanitized punctuation and clipboard fixture from its raw stream.

Each observation is one complete frame (4-byte big-endian length prefix plus
payload) in capture order, base64-encoded, as in the M2-022 fixtures. Clipboard
bytes are never committed: in every DCLP data chunk the marshalled clipboard
keeps its structure (format count, format ids and sizes) while each format's
content is zero-filled at its original length. The content was only the fixed
probe strings in capture_punctuation_clipboard.py.

Usage: python3 make_punctuation_clipboard_fixture.py STREAM.jsonl FIXTURE_DIR
"""

import base64
import collections
import hashlib
import json
import pathlib
import sys

STREAM, OUT = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
DIRECTIONS = {"s2c": "server-to-client", "c2s": "client-to-server"}
FIXTURE_ID = "m2-022-linux-punctuation-clipboard"
CAPTURE_NAME = "punctuation-clipboard-capture.json"


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


def zero_format_contents(data):
    """Zero-fills each format's content of one marshalled clipboard."""
    out = bytearray(data)
    count = int.from_bytes(data[0:4], "big")
    offset = 4
    for _ in range(count):
        size = int.from_bytes(data[offset + 4 : offset + 8], "big")
        start = offset + 8
        if start + size > len(data):
            raise SystemExit("malformed marshalled clipboard")
        out[start : start + size] = bytes(size)
        offset = start + size
    if offset != len(data):
        raise SystemExit("trailing bytes after marshalled clipboard")
    return bytes(out)


def sanitize(frame):
    payload = frame[4:]
    if payload[:4] != b"DCLP" or payload[9] != 2:
        return frame
    # DCLP: id u8, sequence u32, mark u8, then a u32-length string.
    length = int.from_bytes(payload[10:14], "big")
    data = payload[14 : 14 + length]
    return frame[:18] + zero_format_contents(data)


observations = [
    {
        "sequence": index,
        "direction": DIRECTIONS[direction],
        "applicationPayloadBase64": base64.b64encode(sanitize(frame)).decode(),
    }
    for index, (direction, frame) in enumerate(frames(STREAM), start=1)
]
capture = {"schemaVersion": 1, "captureId": FIXTURE_ID, "encoding": "base64",
           "observations": observations}
capture_bytes = (json.dumps(capture, indent=2) + "\n").encode()
directory = OUT / FIXTURE_ID
directory.mkdir(parents=True, exist_ok=True)
(directory / CAPTURE_NAME).write_bytes(capture_bytes)
metadata = {
    "schemaVersion": 1,
    "fixtureId": FIXTURE_ID,
    "protocol": "barrier",
    "provenance": {
        "sourceKind": "black-box-capture",
        "reference": (
            "Controlled black-box observation with evidence/e2e/M2-022/tools/"
            "capture_punctuation_clipboard.py on the owner-approved Ubuntu 22.04 x86_64 host: "
            "external Barrier server barriers 2.4.0-release and client barrierc 2.4.0-release, "
            "protocol 1.6, each on its own virtual X display, through a byte-logging loopback "
            "relay. Input was synthetic (xdotool on the server display); clipboard text was set "
            "with xclip to fixed probe strings on each display. TLS disabled for this observation "
            "only. Session: handshake, server clipboard sent on enter, the eleven US punctuation "
            "keys plain and shifted, a client copy, the client clipboard sent on leave, a second "
            "enter and leave."
        ),
    },
    "payload": {
        "path": CAPTURE_NAME,
        "sha256": hashlib.sha256(capture_bytes).hexdigest(),
        "byteLength": len(capture_bytes),
    },
    "sanitization": {
        "status": "sanitized",
        "containsSensitiveData": False,
        "removedCategories": ["ip-address", "clipboard-payload"],
    },
}
(directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(FIXTURE_ID, len(observations), "observations", len(capture_bytes), "bytes",
      hashlib.sha256(capture_bytes).hexdigest()[:16])
