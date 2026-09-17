import copy
import hashlib
import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
REGISTER_PATH = REPOSITORY_ROOT / "evidence/registers/M1-023.json"
DOCUMENTATION_PATH = (
    REPOSITORY_ROOT / "docs/evidence/M1-023-barrier-evidence-register.md"
)


def nested_value(value, dotted_path):
    current = value
    for component in dotted_path.split("."):
        if component not in current:
            raise ValueError(f"missing required field: {dotted_path}")
        current = current[component]
    return current


def validate_entry(register, entry):
    contract = register["entryContract"]
    allowed_object_keys = contract["allowedObjectKeys"]
    objects = {
        "$": entry,
        "source": entry.get("source", {}),
        "capture": entry.get("capture", {}),
        "peer": entry.get("peer", {}),
        "peer.os": entry.get("peer", {}).get("os", {}),
        "transport": entry.get("transport", {}),
        "transport.tls": entry.get("transport", {}).get("tls", {}),
        "provenance": entry.get("provenance", {}),
        "provenance.reviewer": entry.get("provenance", {}).get("reviewer", {}),
        "sanitization": entry.get("sanitization", {}),
        "fixture": entry.get("fixture", {}),
        "coverage": entry.get("coverage", {}),
    }
    for path, value in objects.items():
        unexpected = set(value) - set(allowed_object_keys[path])
        if unexpected:
            raise ValueError(f"unexpected fields at {path}: {sorted(unexpected)}")

    for path in contract["requiredFields"]:
        value = nested_value(entry, path)
        if isinstance(value, str) and not value.strip():
            raise ValueError(f"empty required field: {path}")

    if not re.fullmatch(contract["evidenceIdPattern"], entry["evidenceId"]):
        raise ValueError("invalid evidence id")
    if entry["source"]["category"] not in contract["sourceCategories"]:
        raise ValueError("invalid source category")
    if not re.fullmatch(contract["relatedIssuePattern"], entry["relatedIssue"]):
        raise ValueError("invalid related issue")
    if not re.fullmatch(contract["utcDateTimePattern"], entry["capture"]["capturedAt"]):
        raise ValueError("capture timestamp must be UTC")
    if not entry["capture"]["tools"]:
        raise ValueError("at least one capture tool is required")
    for tool in entry["capture"]["tools"]:
        unexpected = set(tool) - set(allowed_object_keys["capture.tools[]"])
        if unexpected:
            raise ValueError(f"unexpected capture tool fields: {sorted(unexpected)}")
        if not tool.get("name", "").strip() or not tool.get("version", "").strip():
            raise ValueError("capture tool name and version are required")
    if entry["provenance"]["disposition"] not in contract["dispositions"]:
        raise ValueError("invalid disposition")
    if entry["coverage"]["direction"] not in contract["directions"]:
        raise ValueError("invalid direction")
    if not re.fullmatch(contract["fixturePathPattern"], entry["fixture"]["path"]):
        raise ValueError("fixture must remain under Tests/Fixtures/Barrier")
    if not re.fullmatch(contract["sha256Pattern"], entry["fixture"]["sha256"]):
        raise ValueError("invalid fixture digest")
    if entry["fixture"]["byteLength"] < 0:
        raise ValueError("negative fixture byte length")
    if entry["sanitization"]["status"] != "sanitized":
        raise ValueError("fixture is not sanitized")
    if entry["sanitization"]["containsSensitiveData"] is not False:
        raise ValueError("sensitive fixture is prohibited")
    if not set(entry["sanitization"]["removedCategories"]).issubset(
        register["policy"]["prohibitedContent"]
    ):
        raise ValueError("unknown sanitization category")

    tls = entry["transport"]["tls"]
    if not isinstance(tls["enabled"], bool):
        raise ValueError("TLS enabled must be boolean")
    if tls["enabled"] and not tls["protocolVersion"]:
        raise ValueError("enabled TLS requires an observed protocol version")
    if not tls["enabled"] and tls["protocolVersion"] is not None:
        raise ValueError("disabled TLS cannot claim a protocol version")
    if tls["certificateIdentitySanitized"] is not True:
        raise ValueError("certificate identity must be sanitized")

    reviewer = entry["provenance"]["reviewer"]
    if entry["provenance"]["disposition"] == contract["consumableDisposition"]:
        if reviewer["independentFromProducer"] is not True:
            raise ValueError("approved evidence requires independent review")
        if reviewer["identity"] == entry["provenance"]["producer"]:
            raise ValueError("producer cannot independently approve evidence")
        if not entry["coverage"]["wireClaims"]:
            raise ValueError("approved evidence requires at least one wire claim")

    claim_ids = set()
    established_field_ids = set()
    for claim in entry["coverage"]["wireClaims"]:
        unexpected = set(claim) - set(allowed_object_keys["coverage.wireClaims[]"])
        if unexpected:
            raise ValueError(f"unexpected wire claim fields: {sorted(unexpected)}")
        if claim["claimId"] in claim_ids:
            raise ValueError("duplicate claim id")
        for field in ("claimId", "assertion"):
            if not claim.get(field, "").strip():
                raise ValueError(f"empty wire claim {field}")
        if not claim["establishedFieldIds"] or not claim["evidenceLocations"]:
            raise ValueError("wire claim lacks fields or evidence locations")
        claim_ids.add(claim["claimId"])
        established_field_ids.update(claim["establishedFieldIds"])

    unknown_field_ids = set()
    for field in entry["ambiguousFields"]:
        unexpected = set(field) - set(allowed_object_keys["ambiguousFields[]"])
        if unexpected:
            raise ValueError(f"unexpected ambiguous fields: {sorted(unexpected)}")
        if field["status"] != "unknown":
            raise ValueError("ambiguous field must remain unknown")
        if not field.get("fieldId", "").strip() or not field.get("observation", "").strip():
            raise ValueError("ambiguous field id and observation are required")
        unknown_field_ids.add(field["fieldId"])
    if unknown_field_ids & established_field_ids:
        raise ValueError("unknown field cannot support an established wire claim")


def validate_register(register):
    expected_top_level = {
        "schemaVersion",
        "registerId",
        "protocol",
        "status",
        "nextEvidenceIssue",
        "authoritativePolicyRefs",
        "policy",
        "entryContract",
        "entries",
    }
    if set(register) != expected_top_level:
        raise ValueError("unexpected register fields")
    if register["status"] not in {"initialized-no-approved-evidence", "active"}:
        raise ValueError("invalid register status")
    expected_status = "active" if register["entries"] else "initialized-no-approved-evidence"
    if register["status"] != expected_status:
        raise ValueError("register status does not match entry presence")

    evidence_ids = set()
    for entry in register["entries"]:
        validate_entry(register, entry)
        if entry["evidenceId"] in evidence_ids:
            raise ValueError("duplicate evidence id")
        evidence_ids.add(entry["evidenceId"])

    for entry in register["entries"]:
        fixture_path = REPOSITORY_ROOT / entry["fixture"]["path"]
        relative_fixture_path = Path(entry["fixture"]["path"])
        current = REPOSITORY_ROOT
        for component in relative_fixture_path.parts:
            current = current / component
            if current.is_symlink():
                raise ValueError("registered fixture path cannot contain a symlink")
        if not fixture_path.is_file():
            raise ValueError("registered fixture must be a regular non-symlink file")
        if fixture_path.stat().st_size != entry["fixture"]["byteLength"]:
            raise ValueError("registered fixture byte length mismatch")
        digest = hashlib.sha256()
        with fixture_path.open("rb") as fixture:
            for chunk in iter(lambda: fixture.read(64 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != entry["fixture"]["sha256"]:
            raise ValueError("registered fixture digest mismatch")


class BarrierEvidenceRegisterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.register = json.loads(REGISTER_PATH.read_text(encoding="utf-8"))
        cls.documentation = DOCUMENTATION_PATH.read_text(encoding="utf-8")
        validate_register(cls.register)

    def sample_entry(self):
        return {
            "evidenceId": "BARRIER-EVID-0001",
            "relatedIssue": "M1-024",
            "source": {
                "category": "black-box-capture",
                "acquisitionMethod": "controlled interoperability capture",
            },
            "capture": {
                "capturedAt": "2026-09-17T00:00:00Z",
                "tools": [{"name": "capture-tool", "version": "1.0"}],
            },
            "peer": {
                "product": "external-peer",
                "version": "1.0",
                "role": "server",
                "os": {"name": "test-os", "version": "1.0", "build": "1"},
            },
            "transport": {
                "networkScope": "isolated-lan",
                "tls": {
                    "enabled": True,
                    "protocolVersion": "TLS-test-version",
                    "certificateIdentitySanitized": True,
                },
            },
            "provenance": {
                "lawfulUseStatement": "Lawfully operated external black-box peer.",
                "permittedUse": "Independent interoperability implementation.",
                "producer": "producer-role",
                "reviewer": {
                    "identity": "reviewer-role",
                    "independentFromProducer": True,
                    "reviewedAt": "2026-09-17T00:00:00Z",
                },
                "disposition": "approved",
            },
            "sanitization": {
                "procedure": "Allowlist metadata and remove prohibited content.",
                "status": "sanitized",
                "containsSensitiveData": False,
                "removedCategories": ["hostname", "ip-address"],
            },
            "fixture": {
                "path": "Tests/Fixtures/Barrier/example/payload.bin",
                "sha256": "0" * 64,
                "byteLength": 1,
            },
            "coverage": {
                "direction": "server-to-client",
                "behaviors": ["example-observation"],
                "wireClaims": [
                    {
                        "claimId": "claim-0001",
                        "assertion": "Synthetic validator-only assertion.",
                        "establishedFieldIds": ["field-known"],
                        "evidenceLocations": ["fixture:0..0"],
                    }
                ],
            },
            "limitations": ["Validator-only in-memory sample; not register evidence."],
            "ambiguousFields": [
                {
                    "fieldId": "field-unknown",
                    "observation": "Meaning not established.",
                    "status": "unknown",
                    "blockedClaimIds": [],
                }
            ],
            "prohibitedInferences": ["Do not infer unobserved field semantics."],
            "frozenContractRefs": [],
            "consumingTests": [],
        }

    def test_register_and_documentation_define_fail_closed_contract(self):
        self.assertEqual(self.register["schemaVersion"], 1)
        self.assertEqual(self.register["registerId"], "M1-023")
        self.assertEqual(
            self.register["policy"]["unknownFieldPolicy"],
            "remain-unknown-and-block-wire-claim",
        )
        self.assertEqual(self.register["entries"], [])
        self.assertIn("No approved wire evidence exists yet", self.documentation)
        self.assertIn("M1-024", self.documentation)

    def test_complete_approved_entry_is_accepted(self):
        validate_entry(self.register, self.sample_entry())

    def test_missing_server_version_is_rejected(self):
        entry = self.sample_entry()
        del entry["peer"]["version"]
        with self.assertRaisesRegex(ValueError, "peer.version"):
            validate_entry(self.register, entry)

    def test_empty_server_version_is_rejected(self):
        entry = self.sample_entry()
        entry["peer"]["version"] = ""
        with self.assertRaisesRegex(ValueError, "peer.version"):
            validate_entry(self.register, entry)

    def test_enabled_tls_without_observed_version_is_rejected(self):
        entry = self.sample_entry()
        entry["transport"]["tls"]["protocolVersion"] = None
        with self.assertRaisesRegex(ValueError, "TLS"):
            validate_entry(self.register, entry)

    def test_sensitive_or_unreviewed_evidence_is_rejected(self):
        sensitive = self.sample_entry()
        sensitive["sanitization"]["containsSensitiveData"] = True
        with self.assertRaisesRegex(ValueError, "sensitive"):
            validate_entry(self.register, sensitive)

        unreviewed = self.sample_entry()
        unreviewed["provenance"]["reviewer"]["independentFromProducer"] = False
        with self.assertRaisesRegex(ValueError, "independent"):
            validate_entry(self.register, unreviewed)

    def test_unknown_field_cannot_be_promoted_to_wire_claim(self):
        entry = copy.deepcopy(self.sample_entry())
        entry["coverage"]["wireClaims"][0]["establishedFieldIds"] = ["field-unknown"]
        with self.assertRaisesRegex(ValueError, "unknown field"):
            validate_entry(self.register, entry)

    def test_fixture_path_traversal_and_unknown_metadata_are_rejected(self):
        traversal = self.sample_entry()
        traversal["fixture"]["path"] = "Tests/Fixtures/Barrier/example/../secret.bin"
        with self.assertRaisesRegex(ValueError, "fixture"):
            validate_entry(self.register, traversal)

        extra = self.sample_entry()
        extra["source"]["unreviewedNote"] = "unbounded metadata"
        with self.assertRaisesRegex(ValueError, "unexpected"):
            validate_entry(self.register, extra)

    def test_register_rejects_unvalidated_entries_and_duplicate_ids(self):
        sensitive = self.sample_entry()
        sensitive["sanitization"]["containsSensitiveData"] = True
        register = copy.deepcopy(self.register)
        register["status"] = "active"
        register["entries"] = [sensitive]
        with self.assertRaisesRegex(ValueError, "sensitive"):
            validate_register(register)

        duplicate = copy.deepcopy(self.sample_entry())
        duplicate["provenance"]["disposition"] = "pending-review"
        register["entries"] = [duplicate, copy.deepcopy(duplicate)]
        with self.assertRaisesRegex(ValueError, "duplicate evidence id"):
            validate_register(register)

    def test_register_status_tracks_entry_presence(self):
        entry = self.sample_entry()
        entry["provenance"]["disposition"] = "pending-review"
        register = copy.deepcopy(self.register)
        register["entries"] = [entry]
        with self.assertRaisesRegex(ValueError, "status"):
            validate_register(register)

    def test_approved_entry_requires_at_least_one_wire_claim(self):
        entry = self.sample_entry()
        entry["coverage"]["wireClaims"] = []
        with self.assertRaisesRegex(ValueError, "wire claim"):
            validate_entry(self.register, entry)


if __name__ == "__main__":
    unittest.main()
