#!/usr/bin/env python3
"""M2-022 Barrier server-side capture driver (runs on the Ubuntu test host).

Topology, all on loopback and on throwaway virtual displays so the operator's
desktop and any running Barrier client are untouched:

  barriers (DISPLAY=:91, 127.0.0.1:24910)  <--  relay 127.0.0.1:24911  <--  barrierc (DISPLAY=:92)

Input is driven with xdotool on :91 (the server's display). The relay logs
every chunk in both directions as JSON lines {t, dir, hex}; the driver writes
marker lines {t, marker} into the same log, so frames can be correlated with
the action that produced them. Crypto is disabled on both ends only so the
plaintext protocol can be recorded; nothing here is a product configuration.

Usage: python3 m2_022_capture.py OUTPUT_DIR
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

START = time.monotonic()
log_lock = threading.Lock()
log_file = open(LOG_PATH, "w")


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

procs = []


def spawn(args, env_display=None, name=""):
    env = dict(os.environ)
    if env_display:
        env["DISPLAY"] = env_display
    out = open(os.path.join(OUT, f"{name}.log"), "w")
    proc = subprocess.Popen(args, env=env, stdout=out, stderr=subprocess.STDOUT)
    procs.append(proc)
    return proc


def xdo(*args):
    env = dict(os.environ, DISPLAY=SERVER_DISPLAY)
    subprocess.run(["xdotool", *args], env=env, check=False)


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
    # CIAK (server acknowledges client info) marks the end of the handshake.
    wait_for(lambda: log_contains("s2c", b"CIAK".hex()), 15, "handshake")
    time.sleep(1.0)

    cx, cy = SERVER_SIZE[0] // 2, SERVER_SIZE[1] // 2
    step("park-center", "mousemove", str(cx), str(cy))
    step("enter-1", "mousemove", str(SERVER_SIZE[0] - 1), str(cy))
    step("enter-1-push", "mousemove_relative", "--", "30", "0", gap=0.6)

    for dx, dy in [(10, 0), (0, 10), (-10, 0), (0, -10), (100, 50), (1, 1)]:
        step(f"move {dx} {dy}", "mousemove_relative", "--", str(dx), str(dy))

    for button, name in [(1, "left"), (3, "right"), (2, "middle"), (8, "back"), (9, "forward")]:
        step(f"click {name}", "click", str(button))
    step("down left", "mousedown", "1")
    step("drag", "mousemove_relative", "--", "15", "5")
    step("up left", "mouseup", "1")
    for button, name in [(4, "wheel-up"), (5, "wheel-down"), (6, "wheel-left"), (7, "wheel-right")]:
        step(f"click {name}", "click", str(button))

    keys = (
        [chr(c) for c in range(ord("a"), ord("z") + 1)]
        + [str(d) for d in range(10)]
        + ["Return", "Escape", "Tab", "space", "BackSpace", "Delete", "Left", "Right", "Up",
           "Down", "Home", "End", "Prior", "Next", "Insert"]
        + [f"F{n}" for n in range(1, 13)]
        + ["minus", "equal", "bracketleft", "bracketright", "backslash", "semicolon",
           "apostrophe", "grave", "comma", "period", "slash"]
        + ["KP_Enter", "XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86AudioMute"]
    )
    for key in keys:
        step(f"key {key}", "key", key, gap=0.15)

    for combo in ["shift+a", "shift+1", "shift+minus", "ctrl+c", "alt+a", "super+a",
                  "ctrl+shift+Escape"]:
        step(f"combo {combo}", "key", combo, gap=0.2)
    for modifier in ["Shift_L", "Control_L", "Alt_L", "Super_L", "Shift_R", "Control_R",
                     "Alt_R", "Super_R", "Caps_Lock"]:
        step(f"modifier {modifier}", "key", modifier, gap=0.15)
    step("caps-on a", "key", "a", gap=0.15)
    step("caps-off", "key", "Caps_Lock", gap=0.15)

    marker("hold-a-down")
    xdo("keydown", "a")
    time.sleep(1.2)
    marker("hold-a-up")
    xdo("keyup", "a")
    time.sleep(0.3)

    step("leave-1", "mousemove_relative", "--", "-3000", "0", gap=0.6)
    step("enter-2", "mousemove", str(SERVER_SIZE[0] - 1), str(cy))
    step("enter-2-push", "mousemove_relative", "--", "30", "0", gap=0.6)
    step("leave-2", "mousemove_relative", "--", "-3000", "0", gap=0.6)

    marker("idle-keepalive")
    time.sleep(10.0)
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
