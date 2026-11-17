#!/usr/bin/env python3
"""Mutation runner for M1-063-FOLLOWUP-001.

Usage: run_mutations.py <repository> [output.json]
Each mutant is applied to ClientCoordinator.swift, its killing test is run, and the source is
restored from a backup. Exit 0 only when every mutant is killed.
"""

import json
import pathlib
import shutil
import subprocess
import sys

SOURCE = "Packages/KVMCore/Sources/KVMCore/ClientCoordinator.swift"
MUTANTS = [
    ("M1", "enter does not move the pointer first",
     "guard effects.moveLocalPointer(to: position) else {", "guard true else {",
     "enterMovesThePointerFirstThenBecomesActive"),
    ("M2", "key and button input accepted while inactive",
     "    case .key, .mouseButton:\n      guard current.screen == .active else { return dropInactive() }",
     "    case .key, .mouseButton:", "inputWhileInactiveIsDroppedAndCounted"),
    ("M3", "unpaired repeat injected",
     "      current.diagnostics.droppedUnheldRepeat += 1\n      return .dropped",
     "      current.diagnostics.droppedUnheldRepeat += 1\n      return inject(event)",
     "unpairedRepeatIsNeverInjected"),
    ("M4", "duplicate down injected",
     "      current.diagnostics.droppedDuplicateDown += 1\n      return .dropped",
     "      current.diagnostics.droppedDuplicateDown += 1\n      return inject(event)",
     "duplicateDownIsDropped"),
    ("M5", "leave injects no releases",
     "    for step in plan.steps {", "    for step in [KVMEvent]() {",
     "leaveReleasesInPlanOrderThenResetsAndBecomesInactive"),
    ("M6", "leave releases in reverse of the plan order",
     "    for step in plan.steps {", "    for step in plan.steps.reversed() {",
     "leaveReleasesInPlanOrderThenResetsAndBecomesInactive"),
    ("M7", "leave does not reset the ledger",
     "    current.ledger.reset()\n    if current.screen == .active {",
     "    if current.screen == .active {",
     "leaveReleasesInPlanOrderThenResetsAndBecomesInactive"),
    ("M8", "inbound clipboard skips the loop guard",
     "      try current.clipboardGuard.admitInbound(payload, limit: clipboardLimit)",
     "      _ = payload", "inboundClipboardPassesTheLoopGuardBeforeItIsApplied"),
    ("M9", "inject failure ignored",
     "      current.diagnostics.injectFailures += 1\n      return failClosed()\n    }\n"
     "    current.diagnostics.injected += 1\n    return .accepted",
     "      current.diagnostics.injectFailures += 1\n      return .accepted\n    }\n"
     "    current.diagnostics.injected += 1\n    return .accepted",
     "injectFailureFailsClosed"),
    ("M10", "terminate does not close the session",
     "  private func close() {\n    current.open = false", "  private func close() {",
     "terminateReleasesEverything"),
    ("M11", "terminate skips the cleanup hooks",
     "    let outcome = await hooks.runOnce(trigger, generation: generation)",
     "    let outcome = CleanupOutcome(ran: true, disposition: .completed)",
     "streamEndReleasesEverything"),
    ("M12", "old generation events accepted",
     "    guard current.open, current.generation == generation else {",
     "    guard current.open else {", "oldGenerationStreamCannotInjectIntoTheNewSession"),
    ("M13", "new session allowed while the old one is open",
     "      guard current.claimed, !current.cleaning else { return false }",
     "      guard !current.cleaning else { return false }",
     "newGenerationStartsOnlyAfterTheOldCleanup"),
    ("M14", "a finished stream is not terminated",
     "    return await terminate(trigger, generation: generation)\n  }\n\n  private func terminate",
     "    _ = trigger\n    return .skipped\n  }\n\n  private func terminate",
     "streamEndReleasesEverything"),
]


def main() -> int:
    repo = pathlib.Path(sys.argv[1]).resolve()
    default_out = repo / "evidence/issues/M1-063-FOLLOWUP-001/mutations/mutations.json"
    out = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else default_out
    path = repo / SOURCE
    backup = path.with_suffix(".swift.bak")
    shutil.copyfile(path, backup)
    original = path.read_text()
    results = []
    try:
        for mid, desc, old, new, test in MUTANTS:
            if original.count(old) != 1:
                results.append({"id": mid, "mutation": desc, "killingTest": test,
                                "status": "not-applied"})
                print(mid, "NOT APPLIED", flush=True)
                continue
            path.write_text(original.replace(old, new))
            proc = subprocess.run(
                ["swift", "test", "--filter", f"ClientCoordinatorTests.*{test}"],
                cwd=repo, capture_output=True, text=True, timeout=900)
            killed = proc.returncode != 0
            results.append({"id": mid, "mutation": desc, "killingTest": test,
                            "exitCode": proc.returncode,
                            "status": "killed" if killed else "survived"})
            print(mid, "killed" if killed else "SURVIVED", flush=True)
    finally:
        shutil.copyfile(backup, path)
        backup.unlink()
    out.write_text(json.dumps({"schemaVersion": 1, "issue": "M1-063-FOLLOWUP-001",
                               "source": SOURCE, "results": results}, indent=2) + "\n")
    return 0 if all(r["status"] == "killed" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
