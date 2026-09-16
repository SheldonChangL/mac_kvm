import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = REPOSITORY_ROOT / "MacKVM.xcworkspace/contents.xcworkspacedata"
SCHEME = (
    REPOSITORY_ROOT
    / "MacKVM.xcworkspace/xcshareddata/xcschemes/MacKVM.xcscheme"
)


class M1XcodeWorkspaceContractTests(unittest.TestCase):
    def test_workspace_references_root_swift_package(self):
        root = ET.parse(WORKSPACE).getroot()

        self.assertEqual(root.tag, "Workspace")
        self.assertEqual(root.attrib.get("version"), "1.0")
        file_references = [
            element.attrib.get("location") for element in root.findall("FileRef")
        ]
        self.assertEqual(file_references, ["group:"])

    def test_shared_scheme_builds_the_mackvm_swift_package_product(self):
        root = ET.parse(SCHEME).getroot()

        self.assertEqual(root.tag, "Scheme")
        build_references = root.findall("./BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference")
        self.assertEqual(len(build_references), 1)
        reference = build_references[0]
        self.assertEqual(reference.attrib.get("BlueprintName"), "MacKVM")
        self.assertEqual(reference.attrib.get("BuildableName"), "MacKVM")
        self.assertEqual(reference.attrib.get("ReferencedContainer"), "container:")

    def test_workspace_and_scheme_are_portable(self):
        for path in (WORKSPACE, SCHEME):
            with self.subTest(path=path):
                contents = path.read_text(encoding="utf-8")
                self.assertNotIn("/Users/", contents)
                self.assertNotIn("xcuserdata", contents)
                self.assertNotIn("DerivedData", contents)


if __name__ == "__main__":
    unittest.main()
