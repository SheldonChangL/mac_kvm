#!/usr/bin/env python3
"""M4-020-FOLLOWUP-001 mutation runner.

Usage (inside the pinned Linux image, from any directory):
  python3 run_mutations.py <repository> <scratch-path> <output.json> [mutant-id ...]

Each mutant replaces one exact snippet (which must occur exactly the given number of times),
builds, runs the focused Linux suites and records the failing tests. The source is restored
from a backup after every mutant; the runner fails if any file differs afterwards.
"""

import json
import pathlib
import re
import shutil
import subprocess
import sys
import time

APP = "Apps/Linux/MacKVMClient/"
MONITOR = "Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxLifecycleMonitor.swift"
UNIT = "Apps/Linux/systemd/mackvm-client.service"
FILTER = "LinuxClient|LinuxLifecycle"

# (id, rule, file, old, new, occurrence or None for "exactly once")
MUTANTS = [
    ("M01", "parser: default port", APP + "ClientConfiguration.swift",
     "static let defaultPort: UInt16 = 24_800", "static let defaultPort: UInt16 = 24_801", None),
    ("M02", "parser: screen name at most 64", APP + "ClientConfiguration.swift",
     "(1...64).contains(name.utf8.count)", "(1...65).contains(name.utf8.count)", None),
    ("M03", "parser: no extra fingerprint arguments", APP + "ClientConfiguration.swift",
     "return remaining.isEmpty ? command : nil", "return command", None),
    ("M04", "root is refused", APP + "ClientRuntime.swift",
     "guard process.effectiveUserID != 0 else {", "guard process.effectiveUserID != 0 || true else {", None),
    ("M05", "no X11 display exits 69", APP + "ClientRuntime.swift",
     "detect(environment: variables).isSupported else {",
     "detect(environment: variables).isSupported || true else {", None),
    ("M06", "h.8: handlers installed before any display", APP + "ClientEffects.swift",
     "    xlib.installHandlers(onDisplayLost: onDisplayLost)\n", "", None),
    ("M07", "h.8: a failed XInitThreads opens no display", APP + "ClientEffects.swift",
     "guard xlib.initializeThreads() else {", "guard xlib.initializeThreads() || true else {", None),
    ("M08", "h.8: the previous error handler is kept and restored", APP + "ClientEffects.swift",
     "previousError = setError(clientErrorHandler)", "_ = setError(clientErrorHandler)", None),
    ("M09", "h.8: display loss reported once", APP + "ClientEffects.swift",
     "guard !reported else { return nil }", "", None),
    ("M10", "trust: non-interactive prints instructions, never prompts", APP + "ClientRuntime.swift",
     "guard settings.interactive else {", "guard settings.interactive || true else {", None),
    ("M11", "trust: an unknown identity is never accepted", APP + "ClientRuntime.swift",
     "case .prompt: return .reject(.identityUnknown)", "case .prompt: return .accept", None),
    ("M12", "trust: a changed identity is never accepted", APP + "ClientRuntime.swift",
     "case .identityChanged: return .reject(.identityChanged)", "case .identityChanged: return .accept", None),
    ("M13", "trust: interactive trust stores the fingerprint", APP + "ClientRuntime.swift",
     "ownerDecision: .trust, peer:", "ownerDecision: .reject, peer:", None),
    ("M14", "cleanup: the ledger's releases reach the injector", APP + "ClientEffects.swift",
     "    try injector.release(event)\n", "", None),
    ("M15", "cleanup: the injector sweep runs (h.1)", APP + "ClientEffects.swift",
     "    try injector.releaseRemaining()\n", "", None),
    ("M16", "next generation gets a new drain", APP + "ClientRuntime.swift",
     "        effects.startSession()\n        return true\n      }\n      await terminations",
     "        return true\n      }\n      await terminations", None),
    ("M17", "next generation begins a new coordinator session", APP + "ClientRuntime.swift",
     "if fresh { return !lock.withLock({ refusing }) }", "return true", None),
    ("M18", "h.3: network state reported before each wake", APP + "ClientRuntime.swift",
     "      await recovery.handle(.networkAvailable(backends.lifecycle.isNetworkAvailable))\n", "", None),
    ("M19", "h.3: a cancelled attempt runs the cleanup", APP + "ClientRuntime.swift",
     "      await endOwnGeneration(\n        Task.isCancelled ? .cancelled : CleanupHooks.trigger(for: .failure(error)))\n",
     "", None),
    ("M20", "h.3: termination refuses connect()", APP + "ClientRuntime.swift",
     "  func connect() async {\n    guard !lock.withLock({ refusing }) else { return }\n",
     "  func connect() async {\n", None),
    ("M21", "h.3: termination stops the monitors", APP + "ClientRuntime.swift",
     "    backends.lifecycle.stop()\n", "", None),
    ("M22", "display loss exits 69", APP + "ClientRuntime.swift",
     "      case .displayLost:\n        return await finish(.displayLost, code: .unavailable)",
     "      case .displayLost:\n        return await finish(.displayLost, code: .failure)", None),
    ("M23", "an injector display loss ends the runtime", APP + "ClientRuntime.swift",
     "if error.code == .lifecycle(.subsystemUnavailable) {", "if false {", None),
    ("M24", "a screen stream end is a display loss", APP + "ClientRuntime.swift",
     "    guard !lock.withLock({ refusing }) else { return }\n    displayLost()\n",
     "    return\n", None),
    ("M25", "shutdown closes the injector (deinit does not sweep)", APP + "ClientEffects.swift",
     "    return injector.close()", "    return .success(())", None),
    ("M26", "no Xlib after a display loss", APP + "ClientEffects.swift",
     "    try requireDisplay()\n    try injector.release(event)", "    try injector.release(event)", None),
    ("M27", "an unusable trust store fails closed", APP + "ClientRuntime.swift",
     "    case .failure(let error):\n      await endOwnGeneration(.transportFailure(error))\n      throw error\n    }\n    let geometry",
     "    case .failure:\n      stored = nil\n    }\n    let geometry", None),
    ("M28", "fingerprint trust never replaces another value", APP + "ClientRuntime.swift",
     "case .success(.existing(let stored)) where stored == digest:", "case .success(.existing):", None),
    ("M29", "h.8: handlers restored after the runtime", APP + "ClientRuntime.swift",
     "if !runtime.effects.isDisplayLost { process.xlib.restoreHandlers() }", "_ = runtime", None),
    ("M30", "lifecycle: resume needs a jump over the threshold", MONITOR,
     "return offset - lastOffset > threshold", "return offset - lastOffset >= threshold", None),
    ("M31", "lifecycle: only changes are network edges", MONITOR,
     "guard let last, last != available else { return nil }", "guard let last else { return nil }", None),
    ("M32", "lifecycle: network polled only while armed", MONITOR,
     "guard !stopped, pollingNetwork else { return nil }", "guard !stopped else { return nil }", None),
    ("M33", "unit: exit codes 64 69 78 never restart", UNIT,
     "RestartPreventExitStatus=64 69 78", "RestartPreventExitStatus=64 69", None),
    ("M34", "h.5: a wake ends the old generation first (second line: beginSession waits)",
     APP + "ClientRuntime.swift",
     "    await runtime.endGeneration(.cancelled)\n", "", None),
    ("M35", "review: the cleanup never joins a parked drain without a bound",
     APP + "ClientEffects.swift",
     "    guard !isDisplayLost else { return }\n    guard\n      Self.bounded(Self.drainJoinTimeout, { [drain = currentDrain] in drain.clearTransientState() })\n    else {",
     "    currentDrain.clearTransientState()\n    guard true else {", None),
    ("M36", "review: a signal interrupts the trust prompt", APP + "ClientRuntime.swift",
     "    endingContinuation.yield(.terminated(signal: signal))\n    promptGate.interrupt()\n",
     "    endingContinuation.yield(.terminated(signal: signal))\n", None),
]


def run(command, cwd, timeout):
    started = time.time()
    try:
        result = subprocess.run(
            command, cwd=cwd, shell=True, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout + result.stderr, time.time() - started
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or b"").decode() if isinstance(error.stdout, bytes) else (error.stdout or "")
        return 124, output, time.time() - started


def failing_tests(output):
    names = set()
    for match in re.finditer(r'✘ Test "([^"]+)"', output):
        names.add(match.group(1))
    for match in re.finditer(r'✘ Test (\w+\([^)]*\))', output):
        names.add(match.group(1))
    return sorted(names)


def main():
    repo = pathlib.Path(sys.argv[1]).resolve()
    scratch = sys.argv[2]
    out = pathlib.Path(sys.argv[3])
    only = set(sys.argv[4:])
    results = []
    test = (
        f"swift build --build-tests --scratch-path {scratch} >/dev/null 2>&1 || exit 3; "
        f"timeout 400 swift test --skip-build --scratch-path {scratch} --filter '{FILTER}'")
    for mutant_id, rule, rel, old, new, occurrence in MUTANTS:
        if only and mutant_id not in only:
            continue
        path = repo / rel
        source = path.read_text()
        count = source.count(old)
        if count != 1:
            raise SystemExit(f"{mutant_id}: snippet occurs {count} times in {rel}")
        backup = path.with_suffix(path.suffix + ".mutation-backup")
        shutil.copyfile(path, backup)
        try:
            path.write_text(source.replace(old, new, 1))
            code, output, seconds = run(test, repo, 900)
        finally:
            shutil.copyfile(backup, path)
            backup.unlink()
        if path.read_text() != source:
            raise SystemExit(f"{mutant_id}: restore failed")
        failed = failing_tests(output)
        results.append({
            "id": mutant_id,
            "rule": rule,
            "file": rel,
            "exitCode": code,
            "killed": code != 0,
            "buildFailed": code == 3,
            "failingTests": failed,
            "seconds": round(seconds, 1),
        })
        print(f"{mutant_id} exit={code} killed={code != 0} tests={failed}", flush=True)
    out.write_text(json.dumps({"schemaVersion": 1, "issue": "M4-020-FOLLOWUP-001",
                               "filter": FILTER, "mutants": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()
