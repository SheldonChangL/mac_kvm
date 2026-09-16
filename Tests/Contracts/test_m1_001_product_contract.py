import hashlib
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_SPEC = REPOSITORY_ROOT / "docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md"
PRODUCT_CONTRACT = REPOSITORY_ROOT / "docs/adr/M1-001-product-contract.md"
FROZEN_DECISIONS = (
    REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md"
)
PRODUCT_ROADMAP = (
    REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2/PRODUCT_ROADMAP.md"
)
TRACEABILITY = (
    REPOSITORY_ROOT
    / "MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md"
)


def missing_required_markers(document, requirements):
    return [label for label, marker in requirements if marker not in document]


def product_contract_drift_violations(
    contract, frozen_decisions, roadmap, traceability
):
    violations = []
    violations.extend(
        missing_required_markers(
            frozen_decisions,
            (
                (
                    "frozen decision 1: first-party native product path",
                    "正式產品的 Server 與 Client 都必須使用第一方應用與 Native Protocol 工作",
                ),
                (
                    "frozen decision 2: client first",
                    "Client-first 是驗證策略，不是產品縮限。",
                ),
                (
                    "frozen decision 3: KVMEvent boundary",
                    "KVMEvent 是唯一 Core event language。",
                ),
                (
                    "frozen decision 4: Barrier tokens stay out of Core",
                    "Barrier-specific tokens/types 不可進 KVMCore。",
                ),
                (
                    "frozen decision 5: native Swift stack",
                    "macOS M1～M3 使用 Swift／SwiftUI+AppKit／Network.framework／CGEvent／NSPasteboard／Keychain。",
                ),
                (
                    "frozen decision 6: TLS and identity fail closed",
                    "TLS/security 預設 fail closed。",
                ),
                (
                    "frozen decision 7: terminal cleanup",
                    "任何 terminal path 必須釋放 keys/buttons、停止 suppression、恢復 local state。",
                ),
                (
                    "frozen decision 8: privacy-safe logging",
                    "不記錄 typed text、clipboard payload、password、private key 或可重建內容。",
                ),
                (
                    "frozen decision 9: independent implementation",
                    "不複製 Barrier/Deskflow GPL implementation 到第一方核心。",
                ),
            ),
        )
    )
    violations.extend(
        missing_required_markers(
            contract,
            (
                (
                    "product contract: production TLS default",
                    "Production behavior uses TLS by default; insecure TCP is not a production fallback.",
                ),
                (
                    "product contract: changed identity fails closed",
                    "Unknown, changed or revoked identities fail closed according to later frozen trust contracts.",
                ),
                (
                    "product contract: KVMEvent boundary",
                    "`KVMEvent` is the single platform-neutral event boundary",
                ),
                (
                    "product contract: Barrier adapter containment",
                    "Barrier exists only inside an independently implemented Protocol Adapter.",
                ),
                (
                    "product contract: input engine isolation",
                    "It does not depend on Barrier tokens, message codes or networking implementation.",
                ),
                (
                    "product contract: terminal cleanup",
                    "All terminal paths must release pressed keys/buttons and restore local input.",
                ),
                (
                    "product contract: privacy-safe logging",
                    "Logs and diagnostics must not contain typed text, clipboard payloads, passwords or key material.",
                ),
            ),
        )
    )
    violations.extend(
        missing_required_markers(
            roadmap,
            (
                (
                    "roadmap: client before server",
                    "M1 Barrier Server → First-party Mac Client",
                ),
                (
                    "roadmap: native protocol before production",
                    "M3 First-party Mac Server ↔ First-party Mac Client (Native)",
                ),
                (
                    "roadmap: Barrier optional at 1.0",
                    "M5 Production 1.0; Barrier optional only",
                ),
            ),
        )
    )
    violations.extend(
        missing_required_markers(
            traceability,
            (
                (
                    "traceability: canonical M1-001 source",
                    "docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md",
                ),
                (
                    "traceability: M1-001 contract test",
                    "Tests/Contracts/test_m1_001_product_contract.py",
                ),
            ),
        )
    )
    return violations


class M1001ProductContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.canonical = CANONICAL_SPEC.read_text()
        cls.contract = PRODUCT_CONTRACT.read_text()
        cls.frozen_decisions = FROZEN_DECISIONS.read_text()
        cls.roadmap = PRODUCT_ROADMAP.read_text()
        cls.traceability = TRACEABILITY.read_text()

    def test_all_authoritative_sources_exist_and_are_nonempty(self):
        for path in (
            CANONICAL_SPEC,
            PRODUCT_CONTRACT,
            FROZEN_DECISIONS,
            PRODUCT_ROADMAP,
            TRACEABILITY,
        ):
            with self.subTest(path=path):
                self.assertTrue(path.is_file())
                self.assertTrue(path.read_text().strip())

    def test_current_documents_preserve_reviewed_frozen_refinements(self):
        self.assertEqual(
            product_contract_drift_violations(
                self.contract,
                self.frozen_decisions,
                self.roadmap,
                self.traceability,
            ),
            [],
        )

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

    def test_drift_check_rejects_weakened_production_tls_fail_closed_language(self):
        weakened_contract = self.contract.replace(
            "Production behavior uses TLS by default; insecure TCP is not a production fallback.",
            "Production behavior may use TLS when configured.",
        )
        violations = product_contract_drift_violations(
            weakened_contract,
            self.frozen_decisions,
            self.roadmap,
            self.traceability,
        )
        self.assertIn("product contract: production TLS default", violations)

    def test_drift_check_rejects_removed_changed_identity_fail_closed_language(self):
        weakened_contract = self.contract.replace(
            "Unknown, changed or revoked identities fail closed according to later frozen trust contracts.",
            "Unknown identities are handled by later trust contracts.",
        )
        violations = product_contract_drift_violations(
            weakened_contract,
            self.frozen_decisions,
            self.roadmap,
            self.traceability,
        )
        self.assertIn("product contract: changed identity fails closed", violations)

    def test_drift_check_rejects_weakened_frozen_tls_decision(self):
        weakened_frozen_decisions = self.frozen_decisions.replace(
            "TLS/security 預設 fail closed。",
            "TLS/security 可由實作者決定預設值。",
        )
        violations = product_contract_drift_violations(
            self.contract,
            weakened_frozen_decisions,
            self.roadmap,
            self.traceability,
        )
        self.assertIn(
            "frozen decision 6: TLS and identity fail closed",
            violations,
        )


if __name__ == "__main__":
    unittest.main()
