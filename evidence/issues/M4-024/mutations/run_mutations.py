#!/usr/bin/env python3
"""M4-024 mutation runner.

Usage: run_mutations.py <repository> <scratch-path> <output.json>

Runs on Linux (the swift:6.2.3-jammy image with libx11-dev, libxtst-dev and xvfb). For each
mutant it rewrites one span of LinuxX11Injector.swift, rebuilds, runs the named killing tests
(under xvfb-run with MACKVM_X11_TESTS=1 when the test needs a display) and restores the file
from a backup. A mutant is killed when the killing tests fail, or hang past 180 s.
"""

import json
import os
import pathlib
import subprocess
import sys

SOURCE = "Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxX11Injector.swift"
SUITE = "LinuxPlatformTests"

MUTANTS = [
    ("M01", "letters start at XK_b", "KeySym(0x61) + KeySym(index)",
     "KeySym(0x62) + KeySym(index)", ["everyMemberMaps"], False),
    ("M02", "function keys off by one", "KeySym(0xFFBE) + KeySym(number) - 1",
     "KeySym(0xFFBE) + KeySym(number)", ["everyMemberMaps"], False),
    ("M03", "quote maps to XK_quotedbl", "case .quote: 0x27", "case .quote: 0x22",
     ["everyMemberMaps"], False),
    ("M04", "command maps to XK_Super_R", "case .command: return 0xFFEB",
     "case .command: return 0xFFEC", ["everyMemberMaps"], False),
    ("M05", "letter domain widened to 26", "index <= 25 ?", "index <= 26 ?",
     ["outOfDomain"], False),
    ("M06", "repeat is injected", "guard phase != .repeatKey else", "guard true else",
     ["repeatNotInjected"], False),
    ("M07", "release uses the current keymap", "let heldCode = heldKeys.first { $0.key == key }?.code",
     "let heldCode: UInt8? = nil", ["releaseUsesPressedCode"], False),
    ("M08", "key code 0 is injected", "guard code != 0 else", "guard true else",
     ["noKeyCode"], False),
    ("M09", "vertical wheel sign inverted", "deltaY > 0 ? 4 : 5", "deltaY > 0 ? 5 : 4",
     ["wheelTable", "scrollNotches"], False),
    ("M10", "horizontal wheel sign inverted", "deltaX > 0 ? 6 : 7", "deltaX > 0 ? 7 : 6",
     ["wheelTable"], False),
    ("M11", "notch cap 33", "maximumNotchesPerAxis = 32", "maximumNotchesPerAxis = 33",
     ["wheelCap"], False),
    ("M12", "auxiliary is X button 4", "case .auxiliary: 8", "case .auxiliary: 4",
     ["buttonTable"], False),
    ("M13", "pixel scale uses extent", "(value * Double(extent - 1))", "(value * Double(extent))",
     ["pixelRoundTrip"], False),
    ("M14", "sweep in press order", "let keys = Array(heldKeys.reversed())",
     "let keys = Array(heldKeys)", ["releaseOrder"], False),
    ("M15", "sweep skips buttons", "for held in heldButtons.reversed() {",
     "for held in heldButtons.reversed().prefix(0) {", ["releaseOrder", "releaseAllLeavesNothingDown"], True),
    ("M16", "failed release forgotten",
     "guard port.fakeKey(held.code, down: false) else { return false }",
     "_ = port.fakeKey(held.code, down: false)", ["partialSweep"], False),
    ("M17", "non-input injected as success",
     "    case .clipboard, .enterScreen, .leaveScreen:\n      return .failure(linuxInjectorError(.internalFailure(.preconditionFailed)))",
     "    case .clipboard, .enterScreen, .leaveScreen:\n      return .success(.injected)",
     ["notInput"], False),
    ("M18", "flush is XFlush, not XSync", "guard !closed, port.sync() else",
     "guard !closed, port.flush() else", ["releaseRemaining", "releaseStep"], False),
    ("M19", "release(_:) does not sync",
     "    if case .failure(let error) = inject(event) { throw error }\n    if case .failure(let error) = flush() { throw error }",
     "    if case .failure(let error) = inject(event) { throw error }",
     ["releaseStep"], False),
    ("M20", "drain does not join the worker", "while !finished { condition.wait() }", "",
     ["joinsInFlight"], False),
    ("M21", "drain keeps the queue", "    queue.removeAll()\n    head = 0\n  }", "  }",
     ["bounded", "joinsInFlight"], False),
    ("M22", "drain unbounded", "guard !stopping, queue.count - head < capacity else",
     "guard !stopping else", ["bounded"], False),
    ("M23", "failure does not stop the worker", "condition.withLock { stopping = true }", "",
     ["failureStops"], False),
    ("M24", "missing XTest accepted", "&major, &minor) != 0 else", "&major, &minor) >= 0 else",
     ["missingXTest"], True),
    ("M25", "pointer button count ignored", "if heldCode == nil, Int(code) > buttonCount {",
     "if false {", ["buttonUnavailable"], False),
    ("M26", "close does not release", "let swept = releaseAllHeldLocked()\n      _ = port.sync()",
     "let swept: CoreResult<Void> = .success(())\n      _ = port.sync()", ["closeReleases"], False),
    ("M27", "motion ignores the origin", "let x = geometry.originX + ", "let x = ",
     ["motion"], False),
    ("M28", "worker on the global queue, not a Thread", "worker.start()",
     "DispatchQueue.global().async { [self] in run() }", ["order"], False),
    ("M29", "modifiers released before buttons",
     "      for held in modifiers where !releaseKeyLocked(held) { failed = true }\n      if !port.flush()",
     "      if !port.flush()", ["releaseOrder"], False),
]


def run(command, cwd, env=None):
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)


def main() -> int:
    repository = pathlib.Path(sys.argv[1])
    scratch = sys.argv[2]
    output = pathlib.Path(sys.argv[3])
    source = repository / SOURCE
    original = source.read_text()
    results = []
    for ident, description, old, new, tests, x11 in MUTANTS:
        assert original.count(old) == 1, f"{ident}: span not unique ({original.count(old)})"
        source.write_text(original.replace(old, new))
        try:
            build = run(["swift", "build", "--build-tests", "--scratch-path", scratch], repository)
            if build.returncode != 0:
                status, failing = "killed-by-compiler", []
            else:
                filters = "|".join(tests)
                # A mutant that makes a test hang is killed by the 180 s limit.
                command = ["timeout", "180", "swift", "test", "--skip-build", "--scratch-path",
                           scratch, "--filter", f"{SUITE}.*({filters})"]
                env = dict(os.environ)
                if x11:
                    env["MACKVM_X11_TESTS"] = "1"
                    command = ["xvfb-run", "-a", "-s", "-screen 0 1600x900x24"] + command
                test = run(command, repository, env)
                output_text = test.stdout + test.stderr
                failing = sorted({line.split('"')[1] for line in output_text.splitlines()
                                  if line.startswith("✘ Test \"") and "failed after" in line})
                if test.returncode == 124:
                    status = "killed-by-timeout"
                else:
                    status = "killed" if test.returncode != 0 else "survived"
        finally:
            source.write_text(original)
        results.append({"id": ident, "mutation": description, "killingTests": tests,
                        "status": status, "failingTests": failing})
        print(ident, status, flush=True)

    output.write_text(json.dumps({"schemaVersion": 1, "issue": "M4-024", "mutants": results},
                                 indent=2) + "\n")
    return 0 if all(r["status"] != "survived" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
