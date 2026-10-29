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
    step("enter-1-push", "mousemove_relative", "--", "30", "0", gap=0.8)

    marker("client-copy")
    env = dict(os.environ, DISPLAY=CLIENT_DISPLAY)
    copier = subprocess.Popen(["xclip", "-selection", "clipboard", "-i"], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    copier.stdin.write(b"m2-022-synthetic-probe")
    copier.stdin.close()
    procs.append(copier)
    time.sleep(1.0)

    step("leave-1", "mousemove_relative", "--", "-3000", "0", gap=1.5)

    server = next(p for p in procs if p.args[0] == "barriers")
    marker("server-sigstop")
    server.send_signal(19)  # SIGSTOP: the server stops sending keepalives
    time.sleep(15.0)
    marker("server-sigcont")
    server.send_signal(18)  # SIGCONT
    time.sleep(2.0)
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
