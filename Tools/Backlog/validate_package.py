#!/usr/bin/env python3

import runpy
from pathlib import Path


repository_root = Path(__file__).resolve().parents[2]
validator = (
    repository_root
    / "MacKVM_Implementation_Package_v2"
    / "tools"
    / "validate_package.py"
)

if not validator.is_file():
    raise SystemExit(f"canonical package validator is missing: {validator}")

runpy.run_path(str(validator), run_name="__main__")
