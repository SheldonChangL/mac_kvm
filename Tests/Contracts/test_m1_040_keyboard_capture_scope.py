import copy
import csv
import hashlib
import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2"
LOCK = PACKAGE_ROOT / "toolchain.lock.json"
MANIFEST = PACKAGE_ROOT / "issues_manifest.json"
INDEX = PACKAGE_ROOT / "issues_index.csv"
ADR = REPOSITORY_ROOT / "docs/adr/M1-040-UNBLOCK-001-keyboard-capture-scope.md"

# Pinned while M1-040-UNBLOCK-001 is Proposed; only an accepted ADR may change the lock.
LOCK_SHA256 = "a5d3136d86e25bf7db31d25a22f547a31111c63b0995809b3978ac2a6fec5fc4"

ORIGINAL_EXACT_FILES = [
    "Tests/SystemTests/Plans/M1-040-barrier-keyboard-fixtures.md",
    "Tests/SystemTests/Scripts/M1-040-barrier-keyboard-fixtures.sh",
    "evidence/e2e/M1-040/README.md",
    "evidence/e2e/M1-040/result.json",
]
FIXTURE_DIR = "Tests/Fixtures/Barrier/m1-040-linux-keyboard"
NEW_EXACT_FILES = [
    f"{FIXTURE_DIR}/metadata.json",
    f"{FIXTURE_DIR}/keyboard-capture.json",
    "evidence/issues/M1-040/summary.md",
    "evidence/issues/M1-040/commands.json",
    "evidence/issues/M1-040/tests/e2e-validation.json",
    "evidence/issues/M1-040/environment.json",
    "evidence/issues/M1-040/manual.md",
    "evidence/issues/M1-040/independent-review.md",
]
REQUIRED_FOCUS = (
    "按鍵輸入只使用 capture 前宣告的 scripted key sequence，不得組成可識別文字",
    "Raw packet capture 保留在 repository 外，不得提交",
    "keyboard-capture.json 只保存有序 direction 與未解讀的 application-payload bytes",
    "不得宣稱 key code 意義、message code、endianness 或相容性",
    "M1-040-UNBLOCK-001 未經 Product Owner Accepted 且 toolchain.lock.json 未將 M1-040 列入 scoped_issues 前不得 capture",
)
REQUIRED_STOP_CONDITIONS = (
    "`docs/adr/M1-040-UNBLOCK-001-keyboard-capture-scope.md` 尚未由 Product Owner Accepted。",
    "`toolchain.lock.json` 的 `scoped_issues` 未包含 M1-040，或實際環境與 lock 不一致。",
    "Scripted key sequence 未於 capture 前宣告，或會組成可識別文字。",
    "宣告的 fixture 與 evidence 檔案不是來自真實 Linux Barrier Server capture 時，不得宣稱 M1-040 完成。",
)
COMPLETION_KEYS = ("status", "state", "completed", "done", "closed")


def section(text, heading, level="##"):
    pattern = rf"(?ms)^{re.escape(level)} {re.escape(heading)}\n(.*?)(?=^{re.escape(level)} |\Z)"
    match = re.search(pattern, text)
    return match.group(1) if match else ""


def bullets(text):
    return [line[2:] for line in text.splitlines() if line.startswith("- ")]


def completion_blockers(adr_text, lock, root=REPOSITORY_ROOT):
    """Reasons M1-040 cannot be claimed complete; empty only after real capture is in place."""
    blockers = []
    if "Accepted" not in section(adr_text, "Status").split(".")[0]:
        blockers.append("adr not accepted")
    if "M1-040" not in lock["scoped_issues"]:
        blockers.append("lock does not scope M1-040")
    for path in NEW_EXACT_FILES:
        if not (root / path).is_file():
            blockers.append(f"missing {path}")
    return blockers


def scope_violations(entry, issue_text):
    violations = []
    exact = [b.strip("`") for b in bullets(section(issue_text, "Exact Files"))]
    for label, files in (("manifest", entry["exact_files"]), ("issue", exact)):
        if files != ORIGINAL_EXACT_FILES + NEW_EXACT_FILES:
            violations.append(f"{label}: exact files must be original four plus eight declared paths")
    scope = bullets(section(issue_text, "Scope"))
    for marker in REQUIRED_FOCUS:
        if marker not in entry["focus"] or marker not in scope:
            violations.append(f"missing focus: {marker}")
    stops = bullets(section(issue_text, "Stop Conditions"))
    for marker in REQUIRED_STOP_CONDITIONS:
        if marker not in stops:
            violations.append(f"missing stop condition: {marker}")
    if re.search(r"(?m)^- \[[xX]\]", issue_text):
        violations.append("issue has checked completion boxes")
    for key in COMPLETION_KEYS:
        if key in entry:
            violations.append(f"manifest records completion key: {key}")
    return violations


class M1040KeyboardCaptureScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock_bytes = LOCK.read_bytes()
        cls.lock = json.loads(cls.lock_bytes)
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cls.entry = next(i for i in cls.manifest["issues"] if i["id"] == "M1-040")
        cls.issue_text = (PACKAGE_ROOT / cls.entry["issue_file"]).read_text(encoding="utf-8")
        cls.adr = ADR.read_text(encoding="utf-8")

    def test_adr_is_proposed_not_accepted(self):
        status = section(self.adr, "Status")
        self.assertIn("Proposed, pending Product Owner approval", status)
        self.assertIn("Issue #282", status)
        self.assertNotIn("Accepted by", status)
        for path in NEW_EXACT_FILES:
            with self.subTest(path=path):
                self.assertIn(path, section(self.adr, "Decision (proposed)"))

    def test_lock_is_not_silently_changed(self):
        self.assertEqual(hashlib.sha256(self.lock_bytes).hexdigest(), LOCK_SHA256)
        self.assertEqual(self.lock["scoped_issues"], ["M1-024"])
        self.assertEqual(self.lock["lock_id"], "M1-CAPTURE-TOOLCHAIN-001")

    def test_no_keyboard_fixture_or_evidence_exists_yet(self):
        self.assertFalse((REPOSITORY_ROOT / FIXTURE_DIR).exists())
        for path in ORIGINAL_EXACT_FILES + NEW_EXACT_FILES:
            with self.subTest(path=path):
                self.assertFalse((REPOSITORY_ROOT / path).exists())

    def test_issue_and_manifest_declare_scope_and_stop_conditions(self):
        self.assertEqual(scope_violations(self.entry, self.issue_text), [])

    def test_scope_check_rejects_drift_or_completion_claim(self):
        entry = copy.deepcopy(self.entry)
        entry["exact_files"].remove("evidence/issues/M1-040/independent-review.md")
        entry["status"] = "done"
        violations = scope_violations(entry, self.issue_text)
        self.assertIn("manifest: exact files must be original four plus eight declared paths", violations)
        self.assertIn("manifest records completion key: status", violations)
        text = self.issue_text.replace(f"- {REQUIRED_STOP_CONDITIONS[0]}\n", "", 1)
        text = text.replace("- [ ] E2E result JSON", "- [x] E2E result JSON", 1)
        violations = scope_violations(self.entry, text)
        self.assertIn(f"missing stop condition: {REQUIRED_STOP_CONDITIONS[0]}", violations)
        self.assertIn("issue has checked completion boxes", violations)

    def test_m1_040_cannot_be_claimed_complete_before_real_fixture(self):
        blockers = completion_blockers(self.adr, self.lock)
        self.assertIn("adr not accepted", blockers)
        self.assertIn("lock does not scope M1-040", blockers)
        self.assertIn(f"missing {FIXTURE_DIR}/keyboard-capture.json", blockers)
        accepted = self.adr.replace(
            "Proposed, pending Product Owner approval.", "Accepted by Product Owner.", 1
        )
        lock = dict(self.lock, scoped_issues=["M1-024", "M1-040"])
        blockers = completion_blockers(accepted, lock)
        self.assertNotIn("adr not accepted", blockers)
        self.assertNotIn("lock does not scope M1-040", blockers)
        self.assertIn(f"missing {FIXTURE_DIR}/keyboard-capture.json", blockers)

    def test_index_row_still_agrees_with_manifest(self):
        with INDEX.open(encoding="utf-8-sig", newline="") as handle:
            row = next(r for r in csv.DictReader(handle) if r["id"] == "M1-040")
        self.assertEqual(row["title"], self.entry["title"])
        self.assertEqual(row["tier"], self.entry["tier"])
        self.assertEqual(row["depends_on"].split(","), self.entry["depends_on"])
        self.assertEqual(row["issue_file"], self.entry["issue_file"])


if __name__ == "__main__":
    unittest.main()
