"""Decode an M2-022 capture stream and correlate frames with driver markers.

Frames are 4-byte big-endian length-prefixed payloads. Field layouts are
inferred only from payload lengths and from the known inputs at each marker.
"""

import collections
import json
import sys

path = sys.argv[1]
records = [json.loads(line) for line in open(path)]

# Rebuild frames per direction with the time of the chunk that completed them.
buffers = collections.defaultdict(bytearray)
frames = []  # (t, dir, payload)
for record in records:
    if "dir" not in record:
        frames.append((record["t"], "marker", record["marker"]))
        continue
    buffer = buffers[record["dir"]]
    buffer += bytes.fromhex(record["hex"])
    while len(buffer) >= 4:
        size = int.from_bytes(buffer[:4], "big")
        if len(buffer) < 4 + size:
            break
        payload = bytes(buffer[4 : 4 + size])
        del buffer[: 4 + size]
        frames.append((record["t"], record["dir"], payload))


def s16(b):
    return int.from_bytes(b, "big", signed=True)


def u16(b):
    return int.from_bytes(b, "big")


def describe(payload):
    code = payload[:4].decode("latin1")
    body = payload[4:]
    n = len(body)
    if code in ("DMMV",) and n == 4:
        return f"{code} x={u16(body[0:2])} y={u16(body[2:4])}"
    if code in ("DMDN", "DMUP") and n == 1:
        return f"{code} button={body[0]}"
    if code == "DMWM" and n == 4:
        return f"{code} xDelta={s16(body[0:2])} yDelta={s16(body[2:4])}"
    if code in ("DKDN", "DKUP") and n == 6:
        return f"{code} key=0x{u16(body[0:2]):04X} mask=0x{u16(body[2:4]):04X} button={u16(body[4:6])}"
    if code == "DKRP" and n == 8:
        return (f"{code} key=0x{u16(body[0:2]):04X} mask=0x{u16(body[2:4]):04X} "
                f"count={u16(body[4:6])} button={u16(body[6:8])}")
    if code == "CINN" and n == 10:
        return (f"{code} x={u16(body[0:2])} y={u16(body[2:4])} "
                f"seq={int.from_bytes(body[4:8], 'big')} mask=0x{u16(body[8:10]):04X}")
    if code == "DINF" and n == 14:
        v = [s16(body[i : i + 2]) for i in range(0, 14, 2)]
        return f"{code} x={v[0]} y={v[1]} w={v[2]} h={v[3]} warp={v[4]} mx={v[5]} my={v[6]}"
    if code == "DCLP":
        return f"{code} len={n} head={body[:12].hex()}"
    return f"{code} len={n} body={body[:24].hex()}"


summary = collections.defaultdict(list)
current = "pre-start"
for t, direction, payload in frames:
    if direction == "marker":
        current = payload
        continue
    if direction == "c2s" and payload[:4] in (b"CNOP",):
        continue
    text = describe(payload) if payload[:4].isascii() else payload.hex()
    summary[current].append(f"{t:8.3f} {direction} {text}")

for name, lines in summary.items():
    print(f"== {name}")
    for line in lines:
        print("   " + line)
