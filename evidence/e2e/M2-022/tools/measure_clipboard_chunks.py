#!/usr/bin/env python3
"""Measures how Barrier 2.4 chunks large clipboard transfers.

Runs on the Ubuntu test host with the M2-022 topology, all on loopback and on
throwaway virtual displays, so the operator's desktop and any running Barrier
client are untouched:

  barriers (DISPLAY=:91, 127.0.0.1:24910)  <--  relay 127.0.0.1:24911  <--  barrierc (DISPLAY=:92)

The client copies synthetic text of several sizes with xclip while it is not
the active screen, so it sends its clipboard at once; then the server copies
synthetic text and the client is entered, so the server sends its clipboard.
The relay parses the frame envelope in both directions and records only the
direction, the message code, the DCLP id and mark, and lengths. No payload byte
is stored. Crypto is disabled on both ends only so the frames can be parsed.

Usage: python3 measure_clipboard_chunks.py OUTPUT_DIR
"""

import hashlib
import json
import os
import socket
import subprocess
import sys
import threading
import time

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
SERVER_PORT = 24910
RELAY_PORT = 24911
SERVER_DISPLAY = ":91"
CLIENT_DISPLAY = ":92"
SERVER_SIZE = (1920, 1080)
CLIENT_SIZE = (1600, 900)
CLIENT_SIZES = [100_000, 600_000, 3_000_000]
SERVER_SIZES = [600_000, 3_000_000]
PATTERN = "mackvm-chunk-probe-"

START = time.monotonic()
lock = threading.Lock()
frames = []
procs = []


def stamp():
    return round(time.monotonic() - START, 6)


def probe(size):
    return (PATTERN * (size // len(PATTERN) + 1))[:size]


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def record(direction, payload):
    entry = {"t": stamp(), "dir": direction, "code": payload[:4].decode("ascii", "replace"),
             "length": len(payload)}
    if payload[:4] == b"DCLP" and len(payload) >= 14:
        entry["id"] = payload[4]
        entry["mark"] = payload[9]
        entry["dataLength"] = int.from_bytes(payload[10:14], "big")
    with lock:
        frames.append(entry)


def pump(src, dst, direction):
    buffer = bytearray()
    try:
        while True:
            chunk = src.recv(1 << 20)
            if not chunk:
                break
            dst.sendall(chunk)
            buffer += chunk
            offset = 0
            while len(buffer) - offset >= 4:
                length = int.from_bytes(buffer[offset:offset + 4], "big")
                if len(buffer) - offset - 4 < length:
                    break
                record(direction, bytes(buffer[offset + 4:offset + 4 + length]))
                offset += 4 + length
            del buffer[:offset]
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def relay():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", RELAY_PORT))
    listener.listen(4)
    while True:
        client, _ = listener.accept()
        upstream = socket.create_connection(("127.0.0.1", SERVER_PORT))
        threading.Thread(target=pump, args=(client, upstream, "c2s"), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client, "s2c"), daemon=True).start()


CONFIG = """section: screens
  capserver:
  capclient:
end
section: links
  capserver:
    right = capclient
  capclient:
    left = capserver
end
"""


def spawn(args, display=None, name="", stdin=None):
    env = dict(os.environ)
    if display:
        env["DISPLAY"] = display
    out = open(os.path.join(OUT, f"{name}.log"), "w")
    proc = subprocess.Popen(args, env=env, stdout=out, stderr=subprocess.STDOUT,
                            stdin=subprocess.PIPE if stdin is not None else None)
    if stdin is not None:
        proc.stdin.write(stdin.encode("utf-8"))
        proc.stdin.close()
    procs.append(proc)
    return proc


def xdo(*args):
    subprocess.run(["xdotool", *args], env=dict(os.environ, DISPLAY=SERVER_DISPLAY), check=False)


def clipboard_digest(display):
    result = subprocess.run(["xclip", "-selection", "clipboard", "-o"],
                            env=dict(os.environ, DISPLAY=display), capture_output=True, timeout=30)
    return hashlib.sha256(result.stdout).hexdigest()


def dclp_since(index, direction):
    with lock:
        return [f for f in frames[index:] if f["dir"] == direction and f["code"] == "DCLP"]


def wait_for_end(index, direction, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(f.get("mark") == 3 and f.get("id") == 0 for f in dclp_since(index, direction)):
            return True
        time.sleep(0.1)
    return False


def summarize(index, direction):
    transfer = [f for f in dclp_since(index, direction) if f.get("id") == 0]
    chunks = [f["dataLength"] for f in transfer if f.get("mark") == 2]
    return {"frames": len(transfer), "chunks": len(chunks),
            "largestChunkDataLength": max(chunks, default=0),
            "largestFramePayloadLength": max((f["length"] for f in transfer), default=0),
            "chunkDataTotal": sum(chunks)}


def main():
    conf = os.path.join(OUT, "server.conf")
    with open(conf, "w") as handle:
        handle.write(CONFIG)
    spawn(["Xvfb", SERVER_DISPLAY, "-screen", "0", f"{SERVER_SIZE[0]}x{SERVER_SIZE[1]}x24",
           "-nolisten", "tcp", "-ac"], name="xvfb-server")
    spawn(["Xvfb", CLIENT_DISPLAY, "-screen", "0", f"{CLIENT_SIZE[0]}x{CLIENT_SIZE[1]}x24",
           "-nolisten", "tcp", "-ac"], name="xvfb-client")
    time.sleep(1.0)
    threading.Thread(target=relay, daemon=True).start()
    spawn(["barriers", "-f", "--no-tray", "--debug", "INFO", "--name", "capserver",
           "--disable-crypto", "--no-restart", "--address", f"127.0.0.1:{SERVER_PORT}",
           "-c", conf], display=SERVER_DISPLAY, name="barriers")
    time.sleep(1.5)
    spawn(["barrierc", "-f", "--no-tray", "--debug", "INFO", "--name", "capclient",
           "--disable-crypto", "--no-restart", f"127.0.0.1:{RELAY_PORT}"],
          display=CLIENT_DISPLAY, name="barrierc")
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and not any(f["code"] == "CIAK" for f in frames):
        time.sleep(0.1)
    time.sleep(1.0)
    results = []

    for size in CLIENT_SIZES:
        index = len(frames)
        text = probe(size)
        spawn(["xclip", "-selection", "clipboard", "-i", "-loops", "0"], display=CLIENT_DISPLAY,
              name=f"xclip-client-{size}", stdin=text)
        ended = wait_for_end(index, "c2s")
        time.sleep(1.0)
        results.append({"direction": "client-to-server", "textBytes": size, "transferEnded": ended,
                        "peerClipboardMatches": clipboard_digest(SERVER_DISPLAY) == digest(text),
                        **summarize(index, "c2s")})

    cx, cy = SERVER_SIZE[0] // 2, SERVER_SIZE[1] // 2
    for size in SERVER_SIZES:
        xdo("mousemove", str(cx), str(cy))
        time.sleep(0.5)
        index = len(frames)
        text = probe(size)
        spawn(["xclip", "-selection", "clipboard", "-i", "-loops", "0"], display=SERVER_DISPLAY,
              name=f"xclip-server-{size}", stdin=text)
        time.sleep(1.0)
        xdo("mousemove", str(SERVER_SIZE[0] - 1), str(cy))
        time.sleep(0.3)
        xdo("mousemove_relative", "--", "30", "0")
        ended = wait_for_end(index, "s2c")
        time.sleep(1.0)
        results.append({"direction": "server-to-client", "textBytes": size, "transferEnded": ended,
                        "peerClipboardMatches": clipboard_digest(CLIENT_DISPLAY) == digest(text),
                        **summarize(index, "s2c")})
        xdo("mousemove_relative", "--", "-3000", "0")
        time.sleep(1.0)

    with open(os.path.join(OUT, "chunks.json"), "w") as handle:
        json.dump({"results": results, "frames": frames}, handle, indent=1)
    print(json.dumps(results, indent=1))


try:
    main()
finally:
    for proc in reversed(procs):
        proc.terminate()
    for proc in reversed(procs):
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
