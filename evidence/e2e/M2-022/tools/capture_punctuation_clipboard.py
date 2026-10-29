#!/usr/bin/env python3
"""Barrier server-side capture of punctuation keys and clipboard transfer.

Runs on the Ubuntu test host. Same topology as the M2-022 capture, all on
loopback and on throwaway virtual displays, so the operator's desktop and any
running Barrier client are untouched:

  barriers (DISPLAY=:91, 127.0.0.1:24910)  <--  relay 127.0.0.1:24911  <--  barrierc (DISPLAY=:92)

Input is driven with xdotool on :91. Clipboard text is set with xclip on each
display; the probe strings are fixed, non-personal and contain multi-byte
UTF-8. The relay logs every chunk in both directions as JSON lines
{t, dir, hex}; marker lines {t, marker} correlate frames with actions. Crypto
is disabled on both ends only so the plaintext protocol can be recorded.

Usage: python3 capture_punctuation_clipboard.py OUTPUT_DIR
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
LOG_PATH = os.path.join(OUT, "stream.jsonl")
SERVER_PORT = 24910
RELAY_PORT = 24911
SERVER_DISPLAY = ":91"
CLIENT_DISPLAY = ":92"
SERVER_SIZE = (1920, 1080)
CLIENT_SIZE = (1600, 900)
SERVER_PROBE = "mackvm server probe ✓ café 中文"
CLIENT_PROBE = "mackvm client probe ✓ naïve 日本"
PUNCTUATION = ["minus", "equal", "bracketleft", "bracketright", "backslash", "semicolon",
               "apostrophe", "grave", "comma", "period", "slash"]

START = time.monotonic()
log_lock = threading.Lock()
log_file = open(LOG_PATH, "w")
procs = []


def stamp():
    return round(time.monotonic() - START, 6)


def write(record):
    with log_lock:
        log_file.write(json.dumps(record) + "\n")
        log_file.flush()


def marker(text):
    write({"t": stamp(), "marker": text})


def pump(src, dst, direction):
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                marker(f"eof-{direction}")
                break
            write({"t": stamp(), "dir": direction, "hex": chunk.hex()})
            dst.sendall(chunk)
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
        marker("relay-connection")
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


def spawn(args, env_display=None, name="", stdin=None):
    env = dict(os.environ)
    if env_display:
        env["DISPLAY"] = env_display
    out = open(os.path.join(OUT, f"{name}.log"), "w")
    proc = subprocess.Popen(args, env=env, stdout=out, stderr=subprocess.STDOUT,
                            stdin=subprocess.PIPE if stdin is not None else None)
    if stdin is not None:
        proc.stdin.write(stdin.encode("utf-8"))
        proc.stdin.close()
    procs.append(proc)
    return proc


def xdo(*args):
    env = dict(os.environ, DISPLAY=SERVER_DISPLAY)
    subprocess.run(["xdotool", *args], env=env, check=False)


def clipboard_text(display):
    env = dict(os.environ, DISPLAY=display)
    result = subprocess.run(["xclip", "-selection", "clipboard", "-o"], env=env,
                            capture_output=True, timeout=5)
    return result.stdout.decode("utf-8", "replace")


def wait_for(predicate, timeout, what):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.1)
    marker(f"timeout-waiting-for-{what}")
    return False


def log_contains(direction, token_hex):
    with log_lock:
        log_file.flush()
    with open(LOG_PATH) as handle:
        return any(
            json.loads(line).get("dir") == direction and token_hex in json.loads(line).get("hex", "")
            for line in handle
        )


def step(name, *xdotool_args, gap=0.25):
    marker(name)
    xdo(*xdotool_args)
    time.sleep(gap)


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
    marker("start-server")
    spawn(["barriers", "-f", "--no-tray", "--debug", "INFO", "--name", "capserver",
           "--disable-crypto", "--no-restart", "--address", f"127.0.0.1:{SERVER_PORT}",
           "-c", conf], env_display=SERVER_DISPLAY, name="barriers")
    time.sleep(1.5)
    marker("start-client")
    spawn(["barrierc", "-f", "--no-tray", "--debug", "INFO", "--name", "capclient",
           "--disable-crypto", "--no-restart", f"127.0.0.1:{RELAY_PORT}"],
          env_display=CLIENT_DISPLAY, name="barrierc")
    wait_for(lambda: log_contains("s2c", b"CIAK".hex()), 15, "handshake")
    time.sleep(1.0)

    marker("server-copy")
    spawn(["xclip", "-selection", "clipboard", "-i", "-loops", "0"], env_display=SERVER_DISPLAY,
          name="xclip-server", stdin=SERVER_PROBE)
    time.sleep(1.0)

    cx, cy = SERVER_SIZE[0] // 2, SERVER_SIZE[1] // 2
    step("park-center", "mousemove", str(cx), str(cy))
    step("enter-1", "mousemove", str(SERVER_SIZE[0] - 1), str(cy))
    step("enter-1-push", "mousemove_relative", "--", "30", "0", gap=1.0)
    marker("client-clipboard-after-enter-1 " + ("matches-server-probe"
           if clipboard_text(CLIENT_DISPLAY) == SERVER_PROBE else "differs"))

    for key in PUNCTUATION:
        step(f"key {key}", "key", key, gap=0.15)
        step(f"key shift+{key}", "key", f"shift+{key}", gap=0.15)

    marker("client-copy")
    spawn(["xclip", "-selection", "clipboard", "-i", "-loops", "0"], env_display=CLIENT_DISPLAY,
          name="xclip-client", stdin=CLIENT_PROBE)
    time.sleep(1.0)

    step("leave-1", "mousemove_relative", "--", "-3000", "0", gap=1.5)
    marker("server-clipboard-after-leave-1 " + ("matches-client-probe"
           if clipboard_text(SERVER_DISPLAY) == CLIENT_PROBE else "differs"))

    step("enter-2", "mousemove", str(SERVER_SIZE[0] - 1), str(cy))
    step("enter-2-push", "mousemove_relative", "--", "30", "0", gap=1.0)
    step("leave-2", "mousemove_relative", "--", "-3000", "0", gap=1.0)
    marker("stop")


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
    marker("end")
    log_file.close()
