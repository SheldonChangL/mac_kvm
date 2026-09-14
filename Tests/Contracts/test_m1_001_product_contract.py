import hashlib
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_SPEC = REPOSITORY_ROOT / "docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md"
PRODUCT_CONTRACT = REPOSITORY_ROOT / "docs/adr/M1-001-product-contract.md"
TRACEABILITY = (
    REPOSITORY_ROOT
    / "MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md"
)


class M1001ProductContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.canonical = CANONICAL_SPEC.read_text()
        cls.contract = PRODUCT_CONTRACT.read_text()
        cls.traceability = TRACEABILITY.read_text()

    def test_canonical_source_contains_all_required_sections(self):
        digest = hashlib.sha256(CANONICAL_SPEC.read_bytes()).hexdigest()
        self.assertEqual(
            digest,
            "f56253ccadff8edac045d9ba3d09eda9dd5722d12460f236a74981f7d37eedc7",
        )
        for section in range(60, 65):
            self.assertRegex(self.canonical, rf"(?m)^# {section}\.")

    def test_contract_preserves_mandatory_architecture_boundaries(self):
        required_statements = (
            "implemented natively in Swift",
            "`KVMEvent` is the single platform-neutral event boundary",
            "Barrier exists only inside an independently implemented Protocol Adapter",
            "KVM Core and Input Engine do not depend on a socket implementation",
            "Input Engine accepts platform-neutral events",
            "TLS by default",
            "Adds the first-party macOS server after the client path has been validated",
        )
        for statement in required_statements:
            with self.subTest(statement=statement):
                self.assertIn(statement, self.contract)

    def test_contract_defines_replacement_gate_and_rejected_alternatives(self):
        required_sections = (
            "### Meaning of “replace Barrier”",
            "## Rejected alternatives",
            "## Consequences",
            "## Security impact",
            "## Compatibility impact",
            "## Rollback",
        )
        for section in required_sections:
            with self.subTest(section=section):
                self.assertIn(section, self.contract)
        self.assertIn("M5-028", self.contract)
        self.assertIn("BarrierCompatibility removed or disabled", self.contract)

    def test_traceability_points_directly_to_sections_60_through_64(self):
        for path in (CANONICAL_SPEC, PRODUCT_CONTRACT, TRACEABILITY):
            with self.subTest(path=path):
                self.assertTrue(path.is_file())
        self.assertIn("docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md", self.traceability)
        for anchor in (
            "#60-long-term-protocol-architecture",
            "#61-recommended-architecture-principle",
            "#62-final-architecture",
            "#64-recommended-mvp",
        ):
            with self.subTest(anchor=anchor):
                self.assertIn(anchor, self.traceability)

    def test_decision_documents_have_no_unowned_placeholders(self):
        unresolved = re.compile(r"\b(?:TODO|TBD)\b")
        self.assertIsNone(unresolved.search(self.contract))
        self.assertIsNone(unresolved.search(self.traceability))


if __name__ == "__main__":
    unittest.main()
