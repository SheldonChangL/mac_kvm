import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
PACKAGE_ROOT = REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2"
ISSUE_PATH = PACKAGE_ROOT / "issues/M1/M1-014-domain-identifiers.md"
MANIFEST_PATH = PACKAGE_ROOT / "issues_manifest.json"

EXPECTED_EXACT_FILES = [
    "Packages/KVMContracts/Sources/KVMContracts/KVMEvent.swift",
    "Packages/KVMContracts/Sources/KVMContracts/DomainIdentifiers.swift",
    "Packages/KVMContracts/Tests/KVMContractsTests/DomainIdentifiersTests.swift",
    "docs/components/M1-014-domain-identifiers.md",
]


class M1014ExactFilesTests(unittest.TestCase):
    def test_issue_and_manifest_declare_the_required_extraction_file(self):
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        manifest_issue = next(
            issue for issue in manifest["issues"] if issue["id"] == "M1-014"
        )

        issue_text = ISSUE_PATH.read_text(encoding="utf-8")
        exact_files_section = issue_text.split("## Exact Files", 1)[1].split("##", 1)[0]
        issue_exact_files = re.findall(r"^- `([^`]+)`$", exact_files_section, re.MULTILINE)

        self.assertEqual(issue_exact_files, EXPECTED_EXACT_FILES)
        self.assertEqual(manifest_issue["exact_files"], EXPECTED_EXACT_FILES)
        self.assertEqual(len(issue_exact_files), len(set(issue_exact_files)))

    def test_m1_013_documentation_predeclares_semantics_preserving_extraction(self):
        documentation = (
            REPOSITORY_ROOT / "docs/components/M1-013-kvmevent.md"
        ).read_text(encoding="utf-8")

        self.assertIn("M1-014 owns the complete", documentation)
        self.assertIn("may extract shared identifier", documentation)
        self.assertIn("without changing these semantics", documentation)


if __name__ == "__main__":
    unittest.main()
