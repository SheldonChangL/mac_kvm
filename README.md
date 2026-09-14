# MacKVM

MacKVM is a native Swift macOS KVM application under incremental development. M1 validates an independently implemented Barrier-compatible client while keeping protocol adapters, KVM Core, and platform input code separated by the canonical `KVMEvent` boundary.

## Repository layout

- `Apps/macOS/MacKVM/` — macOS application shell; protocol logic does not live here.
- `Packages/` — first-party Swift modules introduced by their owning Issues.
- `Tests/` — contract, unit, integration, conformance, and system-test roots.
- `Tools/` — repository verification and automation.
- `docs/` — canonical specifications, ADRs, build notes, and tooling documentation.
- `MacKVM_Implementation_Package_v2/` — Product Owner backlog and frozen governance inputs.

## Bootstrap verification

M1-004 creates structure, build metadata, and a zero-behavior application shell. Run:

```bash
Tools/verify/M1-004-repository-skeleton.sh
swift build
python3 MacKVM_Implementation_Package_v2/tools/validate_package.py
python3 -m unittest discover -s Tests/Contracts -p 'test_*.py' -v
```

Native arm64 build policy, package modules, test targets, and formal repository gates are added by M1-005 through M1-010. Until then, the Product Owner's M1 tooling-bootstrap authorization permits the executable validations above as temporary gates.

## Source priority

Canonical specifications and explicitly frozen decisions govern implementation. Roadmap files determine milestone order, and traceability files index source-to-code/test evidence without replacing the product contract.
