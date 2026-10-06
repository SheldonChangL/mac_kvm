import copy
import csv
import base64
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

# Pinned after M1-040-UNBLOCK-001 Product Owner acceptance.
LOCK_SHA256 = "d9bc1e84dd4d9618c37d1dd6d4600a1ad6a97d8edc464673fb47c2b7f7a3057d"

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
REVIEW = REPOSITORY_ROOT / "evidence/issues/M1-040/independent-review.md"
REQUIRED_FOCUS = (
    "按鍵輸入只使用 capture 前宣告的 scripted key sequence，不得組成可識別文字",
    "Raw packet capture 保留在 repository 外，不得提交",
    "keyboard-capture.json 只保存有序 direction 與未解讀的 application-payload bytes",
    "不得宣稱 key code 意義、message code、endianness 或相容性",
    "M1-040-UNBLOCK-001 已由 Product Owner Accepted，且 toolchain.lock.json 已將 M1-040 列入 scoped_issues；capture 前仍須確認實際環境與 lock 完全一致",
)
REQUIRED_STOP_CONDITIONS = (
    "實際 capture 環境與 `toolchain.lock.json` 不一致。",
    "Scripted key sequence 未於 capture 前宣告，或會組成可識別文字。",
    "宣告的 fixture 與 evidence 檔案不是來自真實 Linux Barrier Server capture 時，不得宣稱 M1-040 完成。",
)
COMPLETION_KEYS = ("status", "state", "completed", "done", "closed")
IDENTIFYING_PATTERNS = {
    "ipv4": re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    "email": re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),
    "user path": re.compile(r"(?i)(?:/Users/|/home/|C:\\Users\\)[^/\s\\]+"),
    "token": re.compile(r"\b(?:ghp_|gho_|github_pat_|sk-|xox[abp]-)[\w-]+"),
    "pem material": re.compile(r"-----BEGIN [A-Z ]+-----"),
}


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
    review_path = root / "evidence/issues/M1-040/independent-review.md"
    if review_path.is_file():
        review_text = review_path.read_text(encoding="utf-8")
        if "APPROVED FOR M1-040 MERGE" not in review_text:
            blockers.append("independent review not approved")
        if re.search(r"(?m)^## High findings\n\n(?!None\.)", review_text):
            blockers.append("independent review has high findings")
        if re.search(r"(?m)^## Critical findings\n\n(?!None\.)", review_text):
            blockers.append("independent review has critical findings")
    return blockers


def identifying_content(text):
    findings = []
    for name, pattern in IDENTIFYING_PATTERNS.items():
        for match in pattern.finditer(text):
            if name == "ipv4":
                context = text[max(0, match.start() - 80) : match.end() + 80].lower()
                # Dotted tool versions such as Swift driver 1.127.14.1 are not
                # retained network addresses. They are pinned public toolchain
                # versions and intentionally recorded for drift checks.
                if any(marker in context for marker in ("swift", "driver", "python", "version")):
                    continue
            findings.append(name)
            break
    return sorted(findings)


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

    def test_adr_is_accepted_and_declares_future_paths(self):
        status = section(self.adr, "Status")
        self.assertIn("Accepted by Product Owner authorization", status)
        self.assertIn("Issue #282", status)
        for path in NEW_EXACT_FILES:
            with self.subTest(path=path):
                self.assertIn(path, section(self.adr, "Decision"))

    def test_lock_scopes_m1_040_after_acceptance(self):
        self.assertEqual(hashlib.sha256(self.lock_bytes).hexdigest(), LOCK_SHA256)
        self.assertEqual(self.lock["scoped_issues"], ["M1-024", "M1-040"])
        self.assertEqual(self.lock["lock_id"], "M1-CAPTURE-TOOLCHAIN-001")
        self.assertEqual(
            self.lock["drift_policy"]["statement"],
            "Any OS, architecture, tool, Barrier or protocol version that differs from this lock stops every capture scoped by this lock; only a new Product Owner approved ADR may change this lock.",
        )

    def test_keyboard_fixture_and_evidence_exist_after_real_capture(self):
        for path in ORIGINAL_EXACT_FILES + NEW_EXACT_FILES:
            with self.subTest(path=path):
                self.assertTrue((REPOSITORY_ROOT / path).is_file())

    def test_keyboard_fixture_is_sanitized_uninterpreted_payload(self):
        capture_path = REPOSITORY_ROOT / FIXTURE_DIR / "keyboard-capture.json"
        metadata_path = REPOSITORY_ROOT / FIXTURE_DIR / "metadata.json"
        capture_bytes = capture_path.read_bytes()
        capture = json.loads(capture_bytes)
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        self.assertEqual(capture["schemaVersion"], 1)
        self.assertEqual(capture["captureId"], "m1-040-linux-keyboard")
        self.assertEqual(capture["encoding"], "base64")
        observations = capture["observations"]
        self.assertGreaterEqual(len(observations), 10)
        total_payload_bytes = 0
        directions = set()
        for expected_sequence, observation in enumerate(observations, 1):
            self.assertEqual(observation["sequence"], expected_sequence)
            self.assertEqual(set(observation), {"sequence", "direction", "applicationPayloadBase64"})
            self.assertIn(observation["direction"], {"server-to-client", "client-to-server"})
            directions.add(observation["direction"])
            payload = base64.b64decode(observation["applicationPayloadBase64"], validate=True)
            self.assertGreater(len(payload), 0)
            total_payload_bytes += len(payload)
        self.assertEqual(directions, {"server-to-client", "client-to-server"})
        self.assertGreaterEqual(total_payload_bytes, 128)
        self.assertEqual(metadata["schemaVersion"], 1)
        self.assertEqual(metadata["fixtureId"], "m1-040-linux-keyboard")
        self.assertEqual(metadata["protocol"], "barrier")
        self.assertEqual(metadata["payload"]["path"], "keyboard-capture.json")
        self.assertEqual(metadata["payload"]["sha256"], hashlib.sha256(capture_bytes).hexdigest())
        self.assertEqual(metadata["payload"]["byteLength"], len(capture_bytes))
        self.assertEqual(metadata["sanitization"]["status"], "sanitized")
        self.assertIs(metadata["sanitization"]["containsSensitiveData"], False)

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
        self.assertEqual(blockers, [])

    def test_independent_review_approves_without_critical_or_high_findings(self):
        review = REVIEW.read_text(encoding="utf-8")
        self.assertIn("Reviewer: Claude independent reviewer", review)
        self.assertIn("APPROVED FOR M1-040 MERGE", review)
        self.assertRegex(review, r"(?m)^## Critical findings\n\nNone\.")
        self.assertRegex(review, r"(?m)^## High findings\n\nNone\.")

    def test_evidence_has_no_identifying_content_or_raw_capture(self):
        paths = [REPOSITORY_ROOT / path for path in ORIGINAL_EXACT_FILES + NEW_EXACT_FILES]
        combined = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in paths)
        self.assertEqual(identifying_content(combined), [])
        tracked = (REPOSITORY_ROOT / ".git").exists()
        self.assertTrue(tracked)
        for path in REPOSITORY_ROOT.rglob("*"):
            if ".git" in path.parts:
                continue
            self.assertFalse(path.name.endswith((".pcap", ".pcapng", ".cap")))

    def test_index_row_still_agrees_with_manifest(self):
        with INDEX.open(encoding="utf-8-sig", newline="") as handle:
            row = next(r for r in csv.DictReader(handle) if r["id"] == "M1-040")
        self.assertEqual(row["title"], self.entry["title"])
        self.assertEqual(row["tier"], self.entry["tier"])
        self.assertEqual(row["depends_on"].split(","), self.entry["depends_on"])
        self.assertEqual(row["issue_file"], self.entry["issue_file"])


if __name__ == "__main__":
    unittest.main()
