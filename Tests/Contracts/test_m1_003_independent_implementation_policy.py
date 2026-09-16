import hashlib
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_SPEC = REPOSITORY_ROOT / "docs/spec/CANONICAL_SPEC_SECTION_55.md"
POLICY = REPOSITORY_ROOT / "docs/adr/M1-003-independent-implementation-policy.md"
M1_001_CONTRACT = REPOSITORY_ROOT / "docs/adr/M1-001-product-contract.md"
M1_002_BOUNDARY = REPOSITORY_ROOT / "docs/adr/M1-002-architecture-boundary.md"
FROZEN_DECISIONS = (
    REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md"
)
PROTOCOL_EVIDENCE_POLICY = (
    REPOSITORY_ROOT
    / "MacKVM_Implementation_Package_v2/PROTOCOL_EVIDENCE_POLICY.md"
)
EVIDENCE_STANDARD = (
    REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2/EVIDENCE_STANDARD.md"
)
TRACEABILITY = (
    REPOSITORY_ROOT
    / "MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md"
)


def missing_required_markers(document, requirements):
    return [label for label, marker in requirements if marker not in document]


def independent_policy_drift_violations(
    policy, frozen_decisions, protocol_evidence_policy
):
    violations = []
    violations.extend(
        missing_required_markers(
            frozen_decisions,
            (
                (
                    "frozen decision 9: independent implementation",
                    "9. **獨立實作。** 不複製 Barrier/Deskflow GPL implementation 到第一方核心。",
                ),
            ),
        )
    )
    violations.extend(
        missing_required_markers(
            protocol_evidence_policy,
            (
                (
                    "protocol evidence policy: evidence register first",
                    "先建立 evidence register。",
                ),
                (
                    "protocol evidence policy: sanitized black-box fixtures",
                    "以合法的黑箱互通測試取得 sanitized fixtures。",
                ),
                (
                    "protocol evidence policy: frozen wire behavior",
                    "凍結 field layout/endian/limits/version behavior。",
                ),
                (
                    "protocol evidence policy: implementation from frozen evidence",
                    "parser/encoder Issue 只依 frozen contract + fixtures。",
                ),
                (
                    "protocol evidence policy: unknown fields are not guessed",
                    "未知欄位不得猜；新增 evidence/ADR 後才能實作。",
                ),
                (
                    "protocol evidence policy: GPL source excluded",
                    "不複製 GPL source/header/implementation 到第一方核心。",
                ),
            ),
        )
    )
    violations.extend(
        missing_required_markers(
            policy,
            (
                (
                    "independent implementation ADR: GPL use stops",
                    "Any contemplated use of GPL implementation must stop",
                ),
                (
                    "independent implementation ADR: prohibited material stops work",
                    "If prohibited material enters a working tree, patch, prompt, fixture or review, work stops.",
                ),
                (
                    "independent implementation ADR: no source copying",
                    "Do not copy Barrier or Deskflow source, headers, implementation structure, comments or source-derived tables",
                ),
                (
                    "independent implementation ADR: approved evidence only",
                    "Implement protocol encoders and decoders independently from approved behavioral evidence and frozen contracts.",
                ),
                (
                    "independent implementation ADR: uncertainty fails closed",
                    "Licensing uncertainty, changed identity, malformed evidence and missing provenance fail closed.",
                ),
                (
                    "independent implementation ADR: incident does not merge",
                    "Stop the affected implementation and do not merge, publish or distribute it.",
                ),
            ),
        )
    )
    return violations


class M1003IndependentImplementationPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.canonical = CANONICAL_SPEC.read_text()
        cls.policy = POLICY.read_text()
        cls.m1_001_contract = M1_001_CONTRACT.read_text()
        cls.m1_002_boundary = M1_002_BOUNDARY.read_text()
        cls.frozen_decisions = FROZEN_DECISIONS.read_text()
        cls.protocol_evidence_policy = PROTOCOL_EVIDENCE_POLICY.read_text()
        cls.evidence_standard = EVIDENCE_STANDARD.read_text()
        cls.traceability = TRACEABILITY.read_text()

    def test_all_authoritative_sources_exist_and_are_nonempty(self):
        for path in (
            CANONICAL_SPEC,
            POLICY,
            M1_001_CONTRACT,
            M1_002_BOUNDARY,
            FROZEN_DECISIONS,
            PROTOCOL_EVIDENCE_POLICY,
            EVIDENCE_STANDARD,
            TRACEABILITY,
        ):
            with self.subTest(path=path):
                self.assertTrue(path.is_file())
                self.assertTrue(path.read_text().strip())

    def test_current_documents_preserve_frozen_decision_9_and_evidence_policy(self):
        self.assertEqual(
            independent_policy_drift_violations(
                self.policy,
                self.frozen_decisions,
                self.protocol_evidence_policy,
            ),
            [],
        )

    def test_authoritative_dependency_documents_preserve_identity_markers(self):
        reviewed_documents = (
            (
                self.m1_001_contract,
                "Barrier exists only inside an independently implemented Protocol Adapter.",
            ),
            (
                self.m1_002_boundary,
                "`KVMEvent` is the only event language accepted by KVM Core.",
            ),
            (
                self.evidence_standard,
                "不包含 typed text、clipboard payload、password、private key、token。",
            ),
            (
                self.evidence_standard,
                "失敗 evidence 不可刪除，只能附 remediation/retest。",
            ),
            (
                self.traceability,
                "Tests/Contracts/test_m1_003_independent_implementation_policy.py",
            ),
        )
        for document, marker in reviewed_documents:
            with self.subTest(marker=marker):
                self.assertIn(marker, document)

    def test_canonical_source_preserves_section_55_requirements(self):
        digest = hashlib.sha256(CANONICAL_SPEC.read_bytes()).hexdigest()
        self.assertEqual(
            digest,
            "195d5114d8ea015f7ffc1db2edeb3f41406ad3c94adf8602bde76434d43dd68d",
        )
        self.assertRegex(self.canonical, r"(?m)^# 55\. License Strategy$")
        for requirement in (
            "不要直接 fork Barrier",
            "不要直接 fork Deskflow",
            "自己實作 encoder / decoder",
            "自己實作 macOS input engine",
            "Barrier source",
            "Deskflow source",
            "重新評估 GPL 授權義務",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, self.canonical)

    def test_policy_defines_allowed_and_prohibited_sources(self):
        for section in (
            "### Allowed evidence sources",
            "### Prohibited implementation inputs",
            "### Clean-room roles and separation",
            "### Evidence register",
            "### Per-PR provenance declaration",
        ):
            with self.subTest(section=section):
                self.assertIn(section, self.policy)
        self.assertIn("publicly available protocol specifications", self.policy)
        self.assertIn("copied Barrier or Deskflow source files or snippets", self.policy)

    def test_policy_requires_stop_and_review_for_gpl_implementation(self):
        self.assertIn(
            "Any contemplated use of GPL implementation must stop",
            self.policy,
        )
        self.assertIn("licensing reassessment and Product Owner approval", self.policy)
        self.assertIn("do not merge, publish or distribute it", self.policy)

    def test_policy_protects_security_privacy_and_fail_closed_behavior(self):
        for requirement in (
            "size-bounded before parsing",
            "typed text, clipboard content, credentials, private keys, tokens",
            "Raw captures remain outside the repository until sanitized and reviewed",
            "fail closed",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, self.policy)

    def test_traceability_points_to_section_55_adr_and_tests(self):
        for path in (CANONICAL_SPEC, POLICY, TRACEABILITY):
            with self.subTest(path=path):
                self.assertTrue(path.is_file())
        self.assertIn("#55-license-strategy", self.traceability)
        self.assertIn("docs/adr/M1-003-independent-implementation-policy.md", self.traceability)
        self.assertIn(
            "Tests/Contracts/test_m1_003_independent_implementation_policy.py",
            self.traceability,
        )

    def test_decision_documents_have_no_unowned_placeholders(self):
        unresolved = re.compile(r"\b(?:TODO|TBD)\b")
        self.assertIsNone(unresolved.search(self.policy))
        self.assertIsNone(unresolved.search(self.traceability))

    def test_drift_check_rejects_removed_gpl_stop_condition(self):
        weakened_policy = self.policy.replace(
            "Any contemplated use of GPL implementation must stop",
            "Use of GPL implementation should be reviewed",
        )
        violations = independent_policy_drift_violations(
            weakened_policy,
            self.frozen_decisions,
            self.protocol_evidence_policy,
        )
        self.assertIn("independent implementation ADR: GPL use stops", violations)

    def test_drift_check_rejects_weakened_unknown_field_rule(self):
        weakened_evidence_policy = self.protocol_evidence_policy.replace(
            "未知欄位不得猜；新增 evidence/ADR 後才能實作。",
            "未知欄位可依相容性需求推測。",
        )
        violations = independent_policy_drift_violations(
            self.policy,
            self.frozen_decisions,
            weakened_evidence_policy,
        )
        self.assertIn("protocol evidence policy: unknown fields are not guessed", violations)

    def test_drift_check_rejects_weakened_frozen_independence_decision(self):
        weakened_frozen_decisions = self.frozen_decisions.replace(
            "不複製 Barrier/Deskflow GPL implementation 到第一方核心。",
            "可視情況參考 GPL implementation。",
        )
        violations = independent_policy_drift_violations(
            self.policy,
            weakened_frozen_decisions,
            self.protocol_evidence_policy,
        )
        self.assertIn("frozen decision 9: independent implementation", violations)

    def test_drift_check_rejects_removed_missing_provenance_fail_closed_language(self):
        weakened_policy = self.policy.replace(
            "Licensing uncertainty, changed identity, malformed evidence and missing provenance fail closed.",
            "Missing provenance is reviewed when practical.",
        )
        violations = independent_policy_drift_violations(
            weakened_policy,
            self.frozen_decisions,
            self.protocol_evidence_policy,
        )
        self.assertIn(
            "independent implementation ADR: uncertainty fails closed",
            violations,
        )


if __name__ == "__main__":
    unittest.main()
