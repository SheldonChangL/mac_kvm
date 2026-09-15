#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [repository-root]" >&2
  exit 64
fi

repository_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if [[ ! -d "$repository_root" ]]; then
  echo "repository root does not exist: $repository_root" >&2
  exit 66
fi

swift package --package-path "$repository_root" dump-package |
  python3 -c '
import json
import sys

manifest = json.load(sys.stdin)
targets = {target["name"]: target for target in manifest.get("targets", [])}
expected = {
    "MacKVMUnitTests": (
        "Tests/Unit",
        {"KVMContracts", "KVMCore"},
    ),
    "MacKVMIntegrationTests": (
        "Tests/Integration",
        {"KVMContracts", "KVMCore", "BarrierCompatibility", "NativeProtocol"},
    ),
    "MacKVMSystemTests": (
        "Tests/SystemTests",
        {
            "KVMContracts",
            "KVMCore",
            "BarrierCompatibility",
            "MacPlatform",
            "NativeProtocol",
        },
    ),
}

def dependency_names(target):
    names = set()
    for dependency in target.get("dependencies", []):
        for value in dependency.values():
            if isinstance(value, list) and value and isinstance(value[0], str):
                names.add(value[0])
            elif isinstance(value, str):
                names.add(value)
    return names

for name, (path, dependencies) in expected.items():
    target = targets.get(name)
    if target is None:
        raise SystemExit(f"missing Swift test target: {name}")
    if target.get("type") != "test":
        raise SystemExit(f"target is not a test target: {name}")
    found_path = target.get("path")
    if found_path != path:
        raise SystemExit(
            f"invalid path for {name}: expected {path}, found {found_path}"
        )
    actual_dependencies = dependency_names(target)
    if actual_dependencies != dependencies:
        raise SystemExit(
            f"invalid dependencies for {name}: "
            f"expected {sorted(dependencies)}, found {sorted(actual_dependencies)}"
        )
'

python3 - "$repository_root" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
schema_path = root / "Tests/Fixtures/fixture-metadata.schema.json"
barrier_readme = root / "Tests/Fixtures/Barrier/README.md"
native_readme = root / "Tests/Fixtures/Native/README.md"
unit_source = root / "Tests/Unit/UnitTargetTests.swift"
system_source = root / "Tests/SystemTests/SystemTargetTests.swift"

for path in (schema_path, barrier_readme, native_readme, unit_source, system_source):
    if not path.is_file():
        raise SystemExit(f"missing M1-007 file: {path.relative_to(root)}")

schema = json.loads(schema_path.read_text())
if schema.get("properties", {}).get("schemaVersion", {}).get("const") != 1:
    raise SystemExit("fixture schemaVersion must be const 1")
if set(schema.get("properties", {}).get("protocol", {}).get("enum", [])) != {
    "barrier",
    "native",
}:
    raise SystemExit("fixture protocol must allow exactly barrier and native")
if schema.get("additionalProperties") is not False:
    raise SystemExit("fixture metadata must reject unknown top-level fields")

sanitization = schema.get("properties", {}).get("sanitization", {})
if "containsSensitiveData" not in sanitization.get("required", []):
    raise SystemExit("fixture sanitization must require containsSensitiveData")
if (
    sanitization.get("properties", {})
    .get("containsSensitiveData", {})
    .get("const")
    is not False
):
    raise SystemExit("fixture containsSensitiveData must be const false")

payload_pattern = (
    schema.get("properties", {})
    .get("payload", {})
    .get("properties", {})
    .get("path", {})
    .get("pattern")
)
if not payload_pattern:
    raise SystemExit("fixture payload path pattern is required")
if re.fullmatch(payload_pattern, "../secret.bin"):
    raise SystemExit("fixture payload path pattern must reject traversal")
if not re.fullmatch(payload_pattern, "capture/payload.bin"):
    raise SystemExit("fixture payload path pattern rejects a valid relative path")

for source in (root / "Tests/Unit").rglob("*.swift"):
    contents = source.read_text()
    for framework in ("AppKit", "CoreGraphics", "IOKit", "Network", "Security"):
        if re.search(rf"^\s*import\s+{framework}\s*$", contents, re.MULTILINE):
            raise SystemExit(
                f"unit tests must not import OS permission framework {framework}: "
                f"{source.relative_to(root)}"
            )

system_contents = system_source.read_text()
if ".disabled(" not in system_contents or "explicit system-test opt-in" not in system_contents:
    raise SystemExit("system test scaffold must use an explicit disabled trait")
PY

swift test --package-path "$repository_root" --arch arm64

echo "M1-007 test targets and fixtures OK"
