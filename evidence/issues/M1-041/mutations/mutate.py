"""M1-041 mutation runner.

Usage: python3 -I mutate.py <repository> <output.json>

Applies each mutant to BarrierKeyboardDecoder.swift (every anchor must occur exactly once), runs
the M1-041 suite, records the failing test names, restores the source from a backup copy in a
temporary directory, and checks with `git diff --exit-code` that nothing is left. The source
must match the index (committed or staged) before the run.
"""

import json
import pathlib
import re
import subprocess
import sys
import tempfile

REPO = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
SOURCE_REL = "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierKeyboardDecoder.swift"
SOURCE = REPO / SOURCE_REL

FINAL_RETURN = """    return BarrierKeyEvent(
      phase: token.phase, identifier: press ?? identifier, modifiers: modifiers, button: button,
      pairing: pairing)
"""
DKUP_CASE = "    case .dkup:\n      press = held.removeValue(forKey: button)\n"
DKDN_CASE = "      press = held[button]\n      if press == nil { held[button] = identifier }\n"
CATCH = "      failure = error\n      throw error\n"

MUTANTS = [
    {
        "id": "1",
        "mutation": "a release uses its own identifier instead of the press's",
        "edits": [
            (
                "identifier: press ?? identifier, modifiers",
                "identifier: token == .dkup ? identifier : press ?? identifier, modifiers",
            )
        ],
    },
    {
        "id": "2",
        "mutation": "an unpaired release is dropped instead of emitted (no event: decode throws)",
        "edits": [
            (
                DKUP_CASE,
                "    case .dkup:\n"
                "      guard let released = held.removeValue(forKey: button) else {\n"
                "        throw .invalidBodyLength(token: token, bodyByteCount: body.count)\n"
                "      }\n"
                "      press = released\n",
            )
        ],
    },
    {
        "id": "3a",
        "mutation": "mask bits beyond the five are kept: 0x2000, 0x4000, 0x8000 read as Caps Lock",
        "edits": [("capsLock: mask & capsLockBit != 0)", "capsLock: mask & 0xF000 != 0)")],
    },
    {
        "id": "3b",
        "mutation": "mask bits beyond the five are kept: 0x0008 read as Alt",
        "edits": [("option: mask & altBit != 0,", "option: mask & 0x000C != 0,")],
    },
    {
        "id": "4",
        "mutation": "a DKRP with count N > 1 yields N repeats (the extra ones on the next decode calls)",
        "edits": [
            (
                "  private(set) var failure: BarrierKeyboardDecoderError?\n",
                "  private(set) var failure: BarrierKeyboardDecoderError?\n"
                "  private var pendingRepeats: [BarrierKeyEvent] = []\n",
            ),
            (
                "    if let failure { throw failure }\n",
                "    if let failure { throw failure }\n"
                "    if let pending = pendingRepeats.popLast() { return pending }\n",
            ),
            (
                FINAL_RETURN,
                "    let event = BarrierKeyEvent(\n"
                "      phase: token.phase, identifier: press ?? identifier, modifiers: modifiers, button: button,\n"
                "      pairing: pairing)\n"
                "    let count = Int(Self.uint16(body, at: 4))\n"
                "    if token == .dkrp, count > 1 { pendingRepeats = Array(repeating: event, count: count - 1) }\n"
                "    return event\n",
            ),
        ],
    },
    {
        "id": "5a",
        "mutation": "heldKeys is cleared after a fail-closed error",
        "edits": [(CATCH, "      failure = error\n      held.removeAll()\n      throw error\n")],
    },
    {
        "id": "5b",
        "mutation": "the failure is not latched after a fail-closed error",
        "edits": [(CATCH, "      throw error\n")],
    },
    {
        "id": "6",
        "mutation": "a second DKDN on a held button replaces the held identity (latest press wins)",
        "edits": [(DKDN_CASE, "      press = nil\n      held[button] = identifier\n")],
    },
    {
        "id": "R1",
        "mutation": "the token is checked before the latch, so an unknown token after a failure "
        "reports itself instead of the latched error",
        "edits": [
            (
                "    if let failure { throw failure }\n",
                "    guard BarrierKeyboardToken(payloadPrefix: payload) != nil else {\n"
                "      if failure == nil { failure = .unknownToken(payloadByteCount: payload.count) }\n"
                "      throw .unknownToken(payloadByteCount: payload.count)\n"
                "    }\n"
                "    if let failure { throw failure }\n",
            )
        ],
    },
    {
        "id": "R2",
        "mutation": "the held set evicts its lowest button beyond 8 entries",
        "edits": [
            (
                DKDN_CASE,
                DKDN_CASE
                + "      if held.count > 8, let lowest = held.keys.min() { held[lowest] = nil }\n",
            )
        ],
    },
    {
        "id": "F1",
        "mutation": "identifier fallback: an unpaired DKUP frees a held entry with the same identifier",
        "edits": [
            (
                DKUP_CASE,
                "    case .dkup:\n"
                "      if let released = held.removeValue(forKey: button) {\n"
                "        press = released\n"
                "      } else if let match = held.filter({ $0.value == identifier }).keys.min() {\n"
                "        press = held.removeValue(forKey: match)\n"
                "      } else {\n"
                "        press = nil\n"
                "      }\n",
            )
        ],
    },
    {
        "id": "F2",
        "mutation": "identifier first: a DKUP frees the lowest held button with the same identifier "
        "before trying its own button",
        "edits": [
            (
                DKUP_CASE,
                "    case .dkup:\n"
                "      if let match = held.filter({ $0.value == identifier }).keys.min() {\n"
                "        press = held.removeValue(forKey: match)\n"
                "      } else {\n"
                "        press = held.removeValue(forKey: button)\n"
                "      }\n",
            )
        ],
    },
    {
        "id": "G1",
        "mutation": "the identifier is misread (byte-swapped)",
        "edits": [
            (
                "BarrierKeyIdentifier(rawValue: Self.uint16(body, at: 0))",
                "BarrierKeyIdentifier(rawValue: Self.uint16(body, at: 0).byteSwapped)",
            )
        ],
    },
    {
        "id": "G2",
        "mutation": "the button is misread (byte-swapped)",
        "edits": [
            (
                "Self.uint16(body, at: token.bodyByteCount - 2))",
                "Self.uint16(body, at: token.bodyByteCount - 2).byteSwapped)",
            )
        ],
    },
]


def main() -> int:
    original = SOURCE.read_text(encoding="utf-8")
    backup = pathlib.Path(tempfile.mkdtemp()) / "BarrierKeyboardDecoder.swift"
    backup.write_text(original, encoding="utf-8")
    results = []
    for mutant in MUTANTS:
        text = original
        for old, new in mutant["edits"]:
            if text.count(old) != 1:
                raise SystemExit(f"mutant {mutant['id']}: anchor occurs {text.count(old)} times")
            text = text.replace(old, new)
        SOURCE.write_text(text, encoding="utf-8")
        try:
            run = subprocess.run(
                [
                    "swift", "test", "--package-path", "Packages/BarrierCompatibility",
                    "--filter", "BarrierKeyboardDecoderTests",
                ],
                cwd=REPO, capture_output=True, text=True, timeout=900,
            )
        finally:
            SOURCE.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")
        output = run.stdout + run.stderr
        failed = sorted(set(re.findall(r"✘ Test (\w+)\(\) failed", output)))
        summary = [
            line for line in output.splitlines()
            if line.startswith("✘ Test run") or line.startswith("✔ Test run")
        ]
        compile_errors = [line for line in output.splitlines() if ": error:" in line]
        diff = subprocess.run(
            ["git", "diff", "--exit-code", "--stat", "--", SOURCE_REL],
            cwd=REPO, capture_output=True, text=True,
        )
        result = {
            "id": mutant["id"],
            "mutation": mutant["mutation"],
            "exitCode": run.returncode,
            "summary": summary,
            "compileErrors": compile_errors,
            "failedTests": failed,
            "restoredByteForByte": SOURCE.read_text(encoding="utf-8") == original,
            "gitDiffExitCodeAfterRestore": diff.returncode,
        }
        results.append(result)
        print(json.dumps(result), flush=True)
    OUT.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
