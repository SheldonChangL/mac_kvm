"""Mutation runner for M1-033.

Applies one exact-string mutation at a time to the production decoder, runs the focused suite,
records which named tests failed, and always restores the source from the backup copy.
Usage: run-mutations.py <repository> <backup> <output-json>
"""

import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(sys.argv[1])
BACKUP = Path(sys.argv[2])
OUTPUT = Path(sys.argv[3])
SOURCE_RELATIVE = "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseButtonDecoder.swift"
SOURCE = REPO / SOURCE_RELATIVE

ORIGINAL = BACKUP.read_text()
assert SOURCE.read_text() == ORIGINAL, "source differs from the backup before starting"

MAPPING_BODY = """    switch wireValue {
    case 1: .left
    case 2: .middle
    case 3: .right
    case 4: .auxiliary
    default: nil
    }"""

ORDERED_GUARDS = """    guard direction == .serverToClient else {
      throw .unexpectedDirection(token: token, direction: direction)
    }
    let body = payload.dropFirst(BarrierMouseButtonToken.byteCount)
    guard body.count == bodyByteCount else {
      throw .invalidBodyLength(token: token, bodyByteCount: body.count)
    }"""

SWAPPED_GUARDS = """    let body = payload.dropFirst(BarrierMouseButtonToken.byteCount)
    guard body.count == bodyByteCount else {
      throw .invalidBodyLength(token: token, bodyByteCount: body.count)
    }
    guard direction == .serverToClient else {
      throw .unexpectedDirection(token: token, direction: direction)
    }"""

MUTANTS = [
    {
        "id": "R1",
        "required": True,
        "description": "map the wire value with MouseButton(rawValue:)",
        "old": MAPPING_BODY,
        "new": "    MouseButton(rawValue: wireValue)",
    },
    {
        "id": "R2",
        "required": True,
        "description": "decode wire 5 as .auxiliary instead of dropping it",
        "old": "    case 4: .auxiliary\n",
        "new": "    case 4, 5: .auxiliary\n",
    },
    {
        "id": "R3",
        "required": True,
        "description": "decode DMUP as a press (.down)",
        "old": "    case .dmup: .up\n",
        "new": "    case .dmup: .down\n",
    },
    {
        "id": "R4a",
        "required": True,
        "description": "accept wire 0 (as .left)",
        "old": "    case 4: .auxiliary\n    default: nil\n",
        "new": "    case 4: .auxiliary\n    case 0: .left\n    default: nil\n",
    },
    {
        "id": "R4b",
        "required": True,
        "description": "accept wire 6 (as .auxiliary)",
        "old": "    case 4: .auxiliary\n    default: nil\n",
        "new": "    case 4: .auxiliary\n    case 6: .auxiliary\n    default: nil\n",
    },
    {
        "id": "R4c",
        "required": True,
        "description": "accept wires 0 and 6 together (as .left)",
        "old": "    case 4: .auxiliary\n    default: nil\n",
        "new": "    case 4: .auxiliary\n    case 0, 6: .left\n    default: nil\n",
    },
    {
        "id": "X1",
        "required": False,
        "description": "treat 0...6 as the contract range (0 and 6 reported unrepresentable)",
        "old": "ClosedRange<UInt8> = 1...5",
        "new": "ClosedRange<UInt8> = 0...6",
    },
    {
        "id": "X2",
        "required": False,
        "description": "drop every DMUP (judged as value 0)",
        "old": "    let wireValue = body[body.startIndex]\n",
        "new": "    let wireValue = token == .dmup ? 0 : body[body.startIndex]\n",
    },
    {
        "id": "X3",
        "required": False,
        "description": "skip the direction check",
        "old": "    guard direction == .serverToClient else {\n",
        "new": "    guard direction == .serverToClient || direction == .clientToServer else {\n",
    },
    {
        "id": "X4",
        "required": False,
        "description": "accept a body of one byte or more",
        "old": "    guard body.count == bodyByteCount else {\n",
        "new": "    guard body.count >= bodyByteCount else {\n",
    },
    {
        "id": "X5",
        "required": False,
        "description": "judge the body length before the direction",
        "old": ORDERED_GUARDS,
        "new": SWAPPED_GUARDS,
    },
    {
        "id": "X6",
        "required": False,
        "description": "report wire 5 as out of contract",
        "old": "contractWireValues.contains(wireValue) ? .unrepresentableButton : .buttonOutOfContract",
        "new": ".buttonOutOfContract",
    },
    {
        "id": "X7",
        "required": False,
        "description": "emit DMDN 5 as an auxiliary press while DMUP 5 stays dropped",
        "old": "    let wireValue = body[body.startIndex]\n",
        "new": (
            "    let wireValue = body[body.startIndex]\n"
            "    if token == .dmdn && wireValue == 5 {\n"
            "      return .event(.mouseButton(button: .auxiliary, phase: .down))\n"
            "    }\n"
        ),
    },
]


def run_suite():
    process = subprocess.run(
        [
            "swift",
            "test",
            "--package-path",
            "Packages/BarrierCompatibility",
            "--filter",
            "BarrierMouseButtonDecoderTests",
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=900,
    )
    output = process.stdout + process.stderr
    failed = sorted(set(re.findall(r"✘ Test (\w+)\(\) failed after", output)))
    summary = re.findall(r"(?:✔|✘) Test run with .*", output)
    built = "Build complete" in output
    return {
        "exitCode": process.returncode,
        "built": built,
        "failedTests": failed,
        "summary": summary[-1] if summary else None,
    }


def git_diff_is_clean():
    return (
        subprocess.run(
            ["git", "diff", "--quiet", "--", SOURCE_RELATIVE], cwd=REPO
        ).returncode
        == 0
    )


results = []
try:
    baseline = run_suite()
    baseline.update({"id": "M0", "description": "no mutation (baseline)"})
    results.append(baseline)
    print("M0", baseline, flush=True)
    for mutant in MUTANTS:
        assert ORIGINAL.count(mutant["old"]) == 1, f"{mutant['id']}: pattern not unique"
        SOURCE.write_text(ORIGINAL.replace(mutant["old"], mutant["new"]))
        try:
            outcome = run_suite()
        finally:
            SOURCE.write_text(ORIGINAL)
        outcome.update(
            {
                "id": mutant["id"],
                "required": mutant["required"],
                "description": mutant["description"],
                "restoredIdentical": SOURCE.read_text() == ORIGINAL,
                "gitDiffClean": git_diff_is_clean(),
            }
        )
        results.append(outcome)
        print(mutant["id"], outcome, flush=True)
finally:
    SOURCE.write_text(ORIGINAL)

OUTPUT.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
print("final restore identical:", SOURCE.read_text() == ORIGINAL)
print("final git diff clean:", git_diff_is_clean())
