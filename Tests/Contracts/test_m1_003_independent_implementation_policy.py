import hashlib
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_SPEC = REPOSITORY_ROOT / "docs/spec/CANONICAL_SPEC_SECTION_55.md"
POLICY = REPOSITORY_ROOT / "docs/adr/M1-003-independent-implementation-policy.md"
TRACEABILITY = (
    REPOSITORY_ROOT
    / "MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md"
)


class M1003IndependentImplementationPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.canonical = CANONICAL_SPEC.read_text()
        cls.policy = POLICY.read_text()
        cls.traceability = TRACEABILITY.read_text()

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


if __name__ == "__main__":
    unittest.main()
