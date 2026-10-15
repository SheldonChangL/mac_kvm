import copy
import csv
import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2"
MANIFEST = PACKAGE_ROOT / "issues_manifest.json"
INDEX = PACKAGE_ROOT / "issues_index.csv"
TRACEABILITY = PACKAGE_ROOT / "SOURCE_TRACEABILITY.md"
FROZEN_DECISIONS = PACKAGE_ROOT / "FROZEN_DECISIONS.md"
GUARDRAILS = PACKAGE_ROOT / "ARCHITECTURE_GUARDRAILS.md"

# M1-030-SCOPE-001 (GitHub Issue #317): M1-030 tests exercise the M1-029
# BarrierClientHandshake, so they belong to BarrierCompatibilityTests. Frozen
# Decision 4 keeps Barrier-specific types out of KVMCore.
CORRECTED_EXACT_FILES = [
    "Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierHandshakeTestsTests.swift",
    "docs/components/M1-030-barrier-handshake-tests.md",
]
PROHIBITED_EXACT_FILES = (
    "Packages/KVMCore/Sources/KVMCore/BarrierHandshakeTests.swift",
    "Packages/KVMCore/Tests/KVMCoreTests/BarrierHandshakeTestsTests.swift",
)
CORRECTED_COMMANDS = [
    "swift test --package-path Packages/BarrierCompatibility",
    "xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build",
    "python3 Tools/Backlog/validate_package.py",
    "make architecture-check",
]
PROHIBITED_COMMAND = "swift test --package-path Packages/KVMCore"
DEPENDS_ON = ["M1-020", "M1-029"]
HANDSHAKE_SOURCE = "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClientHandshake.swift"
TEST_PATH = "Tests/Contracts/test_m1_030_barrier_handshake_test_scope.py"
COMPLETION_KEYS = ("status", "state", "completed", "done", "closed")


def section(text, heading, level="##"):
    pattern = rf"(?ms)^{re.escape(level)} {re.escape(heading)}\n(.*?)(?=^{re.escape(level)} |\Z)"
    match = re.search(pattern, text)
    return match.group(1) if match else ""


def bullets(text):
    return [line[2:] for line in text.splitlines() if line.startswith("- ")]


def issue_exact_files(issue_text):
    return [b.strip("`") for b in bullets(section(issue_text, "Exact Files"))]


def issue_commands(issue_text):
    match = re.search(r"(?ms)^```bash\n(.*?)^```", section(issue_text, "Required Commands"))
    return match.group(1).splitlines() if match else []


def issue_depends_on(issue_text):
    match = re.search(r'(?ms)^depends_on:\n((?:  - "[^"]+"\n)*)', issue_text)
    return re.findall(r'"([^"]+)"', match.group(1)) if match else []


def scope_violations(entry, issue_text):
    """Reasons the M1-030 scope disagrees with the M1-030-SCOPE-001 correction."""
    violations = []
    for label, files in (("manifest", entry["exact_files"]), ("issue", issue_exact_files(issue_text))):
        if files != CORRECTED_EXACT_FILES:
            violations.append(f"{label}: exact files must be the corrected BarrierCompatibility test and doc")
        for path in files:
            if path.startswith("Packages/KVMCore/"):
                violations.append(f"{label}: KVMCore exact file {path}")
    for label, commands in (("manifest", entry["commands"]), ("issue", issue_commands(issue_text))):
        if commands != CORRECTED_COMMANDS:
            violations.append(f"{label}: required commands must target BarrierCompatibility")
        if PROHIBITED_COMMAND in commands:
            violations.append(f"{label}: KVMCore required command")
    for label, depends_on in (("manifest", entry["depends_on"]), ("issue", issue_depends_on(issue_text))):
        if depends_on != DEPENDS_ON:
            violations.append(f"{label}: depends_on must remain M1-020, M1-029")
    if re.search(r"(?m)^- \[[xX]\]", issue_text):
        violations.append("issue has checked completion boxes")
    for key in COMPLETION_KEYS:
        if key in entry:
            violations.append(f"manifest records completion key: {key}")
    return violations


class M1030BarrierHandshakeTestScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cls.issues = {i["id"]: i for i in cls.manifest["issues"]}
        cls.entry = cls.issues["M1-030"]
        cls.issue_text = (PACKAGE_ROOT / cls.entry["issue_file"]).read_text(encoding="utf-8")

    def test_issue_and_manifest_declare_corrected_scope(self):
        self.assertEqual(scope_violations(self.entry, self.issue_text), [])

    def test_exact_files_add_no_production_source(self):
        for path in self.entry["exact_files"]:
            with self.subTest(path=path):
                self.assertNotIn("/Sources/", path)
        self.assertTrue((REPOSITORY_ROOT / HANDSHAKE_SOURCE).is_file())

    def test_old_kvmcore_paths_do_not_exist(self):
        for path in PROHIBITED_EXACT_FILES:
            with self.subTest(path=path):
                self.assertFalse((REPOSITORY_ROOT / path).exists())

    def test_scope_check_rejects_old_kvmcore_scope(self):
        entry = copy.deepcopy(self.entry)
        entry["exact_files"] = list(PROHIBITED_EXACT_FILES) + [CORRECTED_EXACT_FILES[-1]]
        entry["commands"] = [PROHIBITED_COMMAND] + CORRECTED_COMMANDS[1:]
        entry["depends_on"] = ["M1-029"]
        entry["status"] = "done"
        violations = scope_violations(entry, self.issue_text)
        self.assertIn("manifest: exact files must be the corrected BarrierCompatibility test and doc", violations)
        for path in PROHIBITED_EXACT_FILES:
            self.assertIn(f"manifest: KVMCore exact file {path}", violations)
        self.assertIn("manifest: KVMCore required command", violations)
        self.assertIn("manifest: depends_on must remain M1-020, M1-029", violations)
        self.assertIn("manifest records completion key: status", violations)
        text = self.issue_text.replace(CORRECTED_EXACT_FILES[0], PROHIBITED_EXACT_FILES[1], 1)
        text = text.replace(CORRECTED_COMMANDS[0], PROHIBITED_COMMAND, 1)
        text = text.replace("- [ ] 至少一個 happy-path test。", "- [x] 至少一個 happy-path test。", 1)
        violations = scope_violations(self.entry, text)
        self.assertIn(f"issue: KVMCore exact file {PROHIBITED_EXACT_FILES[1]}", violations)
        self.assertIn("issue: KVMCore required command", violations)
        self.assertIn("issue has checked completion boxes", violations)

    def test_dependency_order_is_preserved(self):
        order = self.entry["topological_order"]
        for dependency in DEPENDS_ON:
            with self.subTest(dependency=dependency):
                self.assertLess(self.issues[dependency]["topological_order"], order)
        self.assertEqual(self.issues["M1-029"]["commands"][0], CORRECTED_COMMANDS[0])

    def test_index_row_still_agrees_with_manifest(self):
        with INDEX.open(encoding="utf-8-sig", newline="") as handle:
            row = next(r for r in csv.DictReader(handle) if r["id"] == "M1-030")
        self.assertEqual(row["title"], self.entry["title"])
        self.assertEqual(row["tier"], self.entry["tier"])
        self.assertEqual(row["depends_on"].split(","), self.entry["depends_on"])
        self.assertEqual(row["issue_file"], self.entry["issue_file"])

    def test_architecture_sources_still_prohibit_barrier_in_kvmcore(self):
        self.assertIn("**Barrier-specific tokens/types 不可進 KVMCore。**", FROZEN_DECISIONS.read_text(encoding="utf-8"))
        self.assertIn("`KVMCore` 不可 import `BarrierCompatibility`", GUARDRAILS.read_text(encoding="utf-8"))

    def test_traceability_links_correction_to_m1_030(self):
        chain = section(TRACEABILITY.read_text(encoding="utf-8"), "M1-030-SCOPE-001 Barrier Handshake Test Scope Correction")
        for marker in ("GitHub Issue #317", "GitHub Issue #53", "Frozen Decision 4", TEST_PATH, *CORRECTED_EXACT_FILES):
            with self.subTest(marker=marker):
                self.assertIn(marker, chain)


if __name__ == "__main__":
    unittest.main()
