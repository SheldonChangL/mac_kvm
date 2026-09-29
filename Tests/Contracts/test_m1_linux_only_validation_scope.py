import copy
import hashlib
import json
import re
import unittest
from collections import defaultdict, deque
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2"
CANONICAL_SPEC = REPOSITORY_ROOT / "docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md"
PRIOR_ADR = REPOSITORY_ROOT / "docs/adr/M1-001-product-contract.md"
SCOPE_ADR = REPOSITORY_ROOT / "docs/adr/M1-SCOPE-001-linux-only-validation.md"
PRODUCT_ROADMAP = PACKAGE_ROOT / "PRODUCT_ROADMAP.md"
TRACEABILITY = PACKAGE_ROOT / "SOURCE_TRACEABILITY.md"
MANIFEST = PACKAGE_ROOT / "issues_manifest.json"

CANONICAL_SHA256 = "f56253ccadff8edac045d9ba3d09eda9dd5722d12460f236a74981f7d37eedc7"

SCOPED_ISSUES = ("M1-024", "M1-040", "M1-068", "M1-069", "M1-070")
LINUX_ONLY_EXIT = "真實 Linux Barrier Server 可控制 Mac 的 mouse、keyboard、scroll 與 UTF-8 clipboard。"
WINDOWS_NOT_EXECUTED_EXIT = (
    "Windows Barrier Server 在 M1 未執行、未測試；M1 evidence 不得宣稱 Windows 相容。"
)
OLD_DUAL_PLATFORM_MARKERS = (
    "Windows 與 Linux Barrier Server 均可控制",
    "Windows/Linux Barrier Server",
    "Windows 與 Linux Server 各至少一組",
    "至少 Windows Server 一組",
    "列出與 Windows 差異",
    "執行 Windows Barrier Server → Mac Client E2E",
)
CLAIM_WORDS = re.compile(r"(?i)\b(?:pass|passed|compatible)\b|相容|通過")
NEGATION_WORDS = re.compile(r"(?i)不|未|\bnot\b|\bno\b")
CLAIM_SECTIONS = ("Outcome", "Scope", "Acceptance Criteria")


def section(text, heading, level="##"):
    pattern = rf"(?ms)^{re.escape(level)} {re.escape(heading)}\n(.*?)(?=^{re.escape(level)} |\Z)"
    match = re.search(pattern, text)
    return match.group(1) if match else ""


def bullets(text):
    return [line[2:] for line in text.splitlines() if line.startswith("- ")]


def frontmatter(text):
    match = re.match(r"(?s)^---\n(.*?)\n---\n", text)
    block = match.group(1) if match else ""
    fields = {}
    for key in ("id", "title", "execution_tier"):
        found = re.search(rf'(?m)^{key}: "(.*)"$', block)
        fields[key] = found.group(1) if found else None
    labels_block = re.search(r"(?m)^labels:\n((?:  - .*\n?)*)", block)
    fields["labels"] = (
        re.findall(r'  - "(.*)"', labels_block.group(1)) if labels_block else []
    )
    return fields


def claims_windows_pass(entry, issue_text):
    lines = [entry["title"], entry["goal"], *entry["focus"]]
    for heading in CLAIM_SECTIONS:
        lines.extend(section(issue_text, heading).splitlines())
    return any(
        "windows" in line.lower()
        and CLAIM_WORDS.search(line)
        and not NEGATION_WORDS.search(line)
        for line in lines
    )


def required_commands(text):
    block = section(text, "Required Commands")
    match = re.search(r"(?s)```bash\n(.*?)```", block)
    return [line for line in match.group(1).splitlines() if line] if match else []


def issue_manifest_mismatches(entry, issue_text):
    mismatches = []
    meta = frontmatter(issue_text)
    if meta["id"] != entry["id"]:
        mismatches.append("id")
    if meta["title"] != entry["title"]:
        mismatches.append("title")
    if meta["execution_tier"] != entry["tier"]:
        mismatches.append("tier")
    if entry["kind"] not in meta["labels"]:
        mismatches.append("kind label")
    expected_tier_labels = {f"tier:{t}" for t in entry["tier"].split("/")}
    if {l for l in meta["labels"] if l.startswith("tier:")} != expected_tier_labels:
        mismatches.append("tier labels")
    if section(issue_text, "Outcome").strip().splitlines()[0] != entry["goal"]:
        mismatches.append("goal")
    scope = bullets(section(issue_text, "Scope"))
    if scope[: len(entry["focus"])] != entry["focus"]:
        mismatches.append("focus")
    if required_commands(issue_text) != entry["commands"]:
        mismatches.append("commands")
    exact = [b.strip("`") for b in bullets(section(issue_text, "Exact Files"))]
    if exact != entry["exact_files"]:
        mismatches.append("exact files")
    return mismatches


def m1_068_violations(entry, issue_text):
    violations = []
    if entry["tier"] == "H" or "C" not in entry["tier"].split("/"):
        violations.append("tier must require strong review, not execution-only H")
    if entry["kind"] == "e2e":
        violations.append("kind must not be e2e")
    if "Windows" not in entry["component"] or "E2E" in entry["component"]:
        violations.append("component must name the Windows disposition")
    if any(c.startswith("make e2e") for c in entry["commands"]):
        violations.append("commands must not execute e2e")
    if not any("not_executed" in f for f in entry["focus"]):
        violations.append("focus must require not_executed disposition")
    if not any("不執行任何 Windows 測試" in f for f in entry["focus"]):
        violations.append("focus must prohibit Windows execution")
    if "Issue #270" not in issue_text or "M1-SCOPE-001" not in issue_text:
        violations.append("issue must cite PO decision and ADR")
    if "不得將 disposition 記錄為 pass" not in issue_text:
        violations.append("issue must prohibit pass masquerade")
    if "e2e" in frontmatter(issue_text)["labels"]:
        violations.append("labels must not include e2e")
    if entry["exact_files"] != [
        "Tests/SystemTests/Plans/M1-068-windows-barrier-client-e2-e.md",
        "Tests/SystemTests/Scripts/M1-068-windows-barrier-client-e2-e.sh",
        "evidence/e2e/M1-068/README.md",
        "evidence/e2e/M1-068/result.json",
    ]:
        violations.append("exact files must keep the four existing paths")
    if claims_windows_pass(entry, issue_text):
        violations.append("must not claim Windows pass or compatibility")
    return violations


def m1_069_violations(entry, issue_text):
    violations = []
    if entry["tier"] != "H" or entry["kind"] != "e2e":
        violations.append("must remain Tier H e2e")
    if "make e2e ISSUE=M1-069" not in entry["commands"]:
        violations.append("must execute real e2e")
    focus = "\n".join(entry["focus"])
    if "真實" not in focus or "Linux Barrier Server" not in focus or "mock" not in focus:
        violations.append("must require a real Linux Barrier Server without mock")
    if "Windows 結果不可得且不在 M1 範圍" not in focus:
        violations.append("must state Windows results are unavailable")
    if "不可用 mock 取代" not in issue_text:
        violations.append("manual verification must reject mock")
    if any(marker in issue_text + focus for marker in OLD_DUAL_PLATFORM_MARKERS):
        violations.append("must not compare with Windows")
    return violations


def m1_070_violations(entry, issue_text):
    violations = []
    focus = "\n".join(entry["focus"])
    if "Linux-only M1 exit criteria" not in focus:
        violations.append("must evaluate Linux-only exit criteria")
    if "不得以 M1 evidence 宣稱 Windows 相容" not in focus:
        violations.append("must prohibit Windows compatibility claims")
    if claims_windows_pass(entry, issue_text):
        violations.append("must not claim Windows pass or compatibility")
    return violations


def fixture_violations(entry, fixture_marker):
    violations = []
    focus = "\n".join(entry["focus"])
    if fixture_marker not in focus:
        violations.append("must require a real Linux Barrier Server fixture")
    if "不可用 mock 取代" not in focus:
        violations.append("must reject mock substitutes")
    if any(marker in focus for marker in OLD_DUAL_PLATFORM_MARKERS):
        violations.append("must not require Windows fixtures")
    return violations


class M1LinuxOnlyValidationScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.adr = SCOPE_ADR.read_text()
        cls.roadmap = PRODUCT_ROADMAP.read_text()
        cls.traceability = TRACEABILITY.read_text()
        cls.manifest = json.loads(MANIFEST.read_text())
        cls.entries = {issue["id"]: issue for issue in cls.manifest["issues"]}
        cls.issue_texts = {
            issue_id: (PACKAGE_ROOT / cls.entries[issue_id]["issue_file"]).read_text()
            for issue_id in SCOPED_ISSUES
        }
        cls.milestones = {m["id"]: m for m in cls.manifest["milestones"]}

    def test_canonical_source_and_prior_adr_are_preserved(self):
        self.assertEqual(
            hashlib.sha256(CANONICAL_SPEC.read_bytes()).hexdigest(), CANONICAL_SHA256
        )
        prior = PRIOR_ADR.read_text()
        self.assertIn(
            "Accepted by Product Owner for implementation on 2026-09-14.", prior
        )
        self.assertIn(
            "- Connects to existing Windows and Linux Barrier servers through the Barrier Protocol Adapter.",
            prior,
        )
        self.assertNotIn("M1-SCOPE-001", prior)

    def test_scope_adr_is_accepted_and_cites_decision(self):
        status = section(self.adr, "Status")
        self.assertIn("Accepted on 2026-09-29", status)
        self.assertIn("Issue #270", status)
        self.assertIn("確定，決定Windows不執行", status)

    def test_scope_adr_names_exact_superseded_clauses_only(self):
        clauses = re.findall(r"(?m)^\d+\. ", section(self.adr, "Superseded clauses"))
        self.assertEqual(len(clauses), 6)
        superseded = section(self.adr, "Superseded clauses")
        for marker in (
            "Connects to existing Windows and Linux Barrier servers",
            "M1-024",
            "M1-040",
            "M1-068",
            "M1-069",
            "M1-070",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, superseded)

    def test_scope_adr_preserves_sources_and_non_m1_windows_scope(self):
        for marker in (
            "`docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md`](../spec/CANONICAL_SPEC_SECTIONS_60_64.md) remains the canonical source and is preserved byte-for-byte unchanged.",
            "remains Accepted historical context and is preserved byte-for-byte unchanged.",
            "M2, M4 and M5 Windows product scope remains unchanged.",
            "M4 first-party Windows support remains unchanged.",
            "Windows was not executed or tested in M1.",
            "production TLS default ON and fail closed",
            "Barrier exists only inside the Protocol Adapter",
            "Input Engine remains independent of Barrier codes and networking",
            "client before server",
            "independent implementation",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, self.adr)

    def test_roadmap_m1_is_linux_only_and_forbids_windows_claim(self):
        m1 = section(self.roadmap, "M1 — Mac Client MVP（Barrier 驗證）")
        self.assertIn("真實 Linux Barrier Server 驗證第一方 macOS Client", m1)
        self.assertIn(f"- [ ] {LINUX_ONLY_EXIT}", m1)
        self.assertIn(f"- [ ] {WINDOWS_NOT_EXECUTED_EXIT}", m1)
        self.assertIn("docs/adr/M1-SCOPE-001-linux-only-validation.md", m1)
        for marker in OLD_DUAL_PLATFORM_MARKERS:
            with self.subTest(marker=marker):
                self.assertNotIn(marker, m1)

    def test_manifest_m1_milestone_matches_roadmap(self):
        m1 = self.milestones["M1"]
        self.assertIn("真實 Linux Barrier Server", m1["goal"])
        self.assertNotIn("Windows", m1["goal"])
        self.assertIn(LINUX_ONLY_EXIT, m1["exit"])
        self.assertIn(WINDOWS_NOT_EXECUTED_EXIT, m1["exit"])
        roadmap_exit = bullets(
            section(
                section(self.roadmap, "M1 — Mac Client MVP（Barrier 驗證）"),
                "Exit Criteria",
                level="###",
            )
        )
        self.assertEqual([item.removeprefix("[ ] ") for item in roadmap_exit], m1["exit"])

    def test_manifest_keeps_seventy_m1_issues_and_acyclic_dependencies(self):
        issues = self.manifest["issues"]
        self.assertEqual(sum(1 for i in issues if i["milestone"] == "M1"), 70)
        indegree = {i["id"]: len(i["depends_on"]) for i in issues}
        dependents = defaultdict(list)
        for issue in issues:
            for dep in issue["depends_on"]:
                self.assertIn(dep, self.entries)
                dependents[dep].append(issue["id"])
        queue = deque(i for i, d in indegree.items() if d == 0)
        seen = 0
        while queue:
            current = queue.popleft()
            seen += 1
            for nxt in dependents[current]:
                indegree[nxt] -= 1
                if indegree[nxt] == 0:
                    queue.append(nxt)
        self.assertEqual(seen, len(issues))
        self.assertEqual(
            self.entries["M1-068"]["depends_on"],
            ["M1-051", "M1-054", "M1-059", "M1-065", "M1-067"],
        )
        self.assertEqual(self.entries["M1-069"]["depends_on"], ["M1-068"])
        self.assertEqual(self.entries["M1-070"]["depends_on"], ["M1-069"])

    def test_manifest_agrees_with_scoped_issue_files(self):
        for issue_id in SCOPED_ISSUES:
            with self.subTest(issue=issue_id):
                self.assertEqual(
                    issue_manifest_mismatches(
                        self.entries[issue_id], self.issue_texts[issue_id]
                    ),
                    [],
                )

    def test_manifest_mismatch_check_rejects_drift(self):
        entry = copy.deepcopy(self.entries["M1-068"])
        entry["tier"] = "H"
        entry["commands"] = ["make e2e ISSUE=M1-068"] + entry["commands"]
        mismatches = issue_manifest_mismatches(entry, self.issue_texts["M1-068"])
        self.assertIn("tier", mismatches)
        self.assertIn("commands", mismatches)

    def test_fixture_issues_require_real_linux_captures(self):
        self.assertEqual(
            fixture_violations(
                self.entries["M1-024"], "至少一組真實 Linux Barrier Server capture"
            ),
            [],
        )
        self.assertEqual(
            fixture_violations(
                self.entries["M1-040"],
                "至少一組真實 Linux Barrier Server keyboard fixture set",
            ),
            [],
        )
        self.assertIn("移除 hostname/IP/clipboard/input content", self.entries["M1-024"]["focus"])
        self.assertIn("附 metadata 與 capture reproduction steps", self.entries["M1-024"]["focus"])
        for issue_id in ("M1-024", "M1-040"):
            with self.subTest(issue=issue_id):
                self.assertEqual(self.entries[issue_id]["tier"], "H")
                self.assertIn(
                    "由 reviewer 確認操作結果", self.issue_texts[issue_id]
                )

    def test_fixture_check_rejects_mock_or_windows_requirement(self):
        entry = copy.deepcopy(self.entries["M1-024"])
        entry["focus"] = ["Windows 與 Linux Server 各至少一組", "mock capture"]
        violations = fixture_violations(entry, "至少一組真實 Linux Barrier Server capture")
        self.assertIn("must require a real Linux Barrier Server fixture", violations)
        self.assertIn("must reject mock substitutes", violations)
        self.assertIn("must not require Windows fixtures", violations)

    def test_m1_068_is_non_execution_disposition_gate(self):
        self.assertEqual(
            m1_068_violations(self.entries["M1-068"], self.issue_texts["M1-068"]), []
        )

    def test_m1_068_check_rejects_masquerading_as_windows_pass(self):
        entry = copy.deepcopy(self.entries["M1-068"])
        entry["tier"] = "H"
        entry["kind"] = "e2e"
        entry["commands"] = ["make e2e ISSUE=M1-068"]
        entry["focus"] = ["Windows Barrier Server E2E passed"]
        violations = m1_068_violations(entry, self.issue_texts["M1-068"])
        for expected in (
            "tier must require strong review, not execution-only H",
            "kind must not be e2e",
            "commands must not execute e2e",
            "focus must require not_executed disposition",
            "must not claim Windows pass or compatibility",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, violations)

    def test_m1_069_is_real_tier_h_linux_gate(self):
        self.assertEqual(
            m1_069_violations(self.entries["M1-069"], self.issue_texts["M1-069"]), []
        )

    def test_m1_069_check_rejects_windows_comparison_or_mock(self):
        entry = copy.deepcopy(self.entries["M1-069"])
        entry["tier"] = "S"
        entry["focus"] = ["Ubuntu LTS Server", "列出與 Windows 差異"]
        violations = m1_069_violations(entry, self.issue_texts["M1-069"])
        self.assertIn("must remain Tier H e2e", violations)
        self.assertIn("must require a real Linux Barrier Server without mock", violations)
        self.assertIn("must not compare with Windows", violations)

    def test_m1_070_prohibits_windows_claims(self):
        self.assertEqual(
            m1_070_violations(self.entries["M1-070"], self.issue_texts["M1-070"]), []
        )
        entry = copy.deepcopy(self.entries["M1-070"])
        entry["focus"] = ["逐條驗證 M1 exit criteria", "Windows compatible"]
        violations = m1_070_violations(entry, self.issue_texts["M1-070"])
        self.assertIn("must evaluate Linux-only exit criteria", violations)
        self.assertIn("must prohibit Windows compatibility claims", violations)
        self.assertIn("must not claim Windows pass or compatibility", violations)

    def test_non_m1_windows_product_scope_is_unchanged(self):
        m2_exit = self.milestones["M2"]["exit"]
        m4_exit = self.milestones["M4"]["exit"]
        m5_exit = self.milestones["M5"]["exit"]
        self.assertIn("Mac 可控制 Windows/Linux Barrier Client，並可安全返回本機。", m2_exit)
        self.assertIn("macOS、Windows、Linux 皆有第一方 Client。", m4_exit)
        self.assertIn("macOS、Windows 具備第一方 Server；Linux Server 依凍結支援矩陣交付。", m4_exit)
        self.assertIn(
            "完成 macOS notarization、Windows signing、Linux packages 與簽名更新/rollback。",
            m5_exit,
        )
        m4_roadmap = section(self.roadmap, "M4 — Cross-platform Beta（macOS / Windows / Linux）")
        self.assertIn("完成第一方 Windows 與 Linux 應用", m4_roadmap)
        self.assertIn("- [ ] macOS、Windows、Linux 皆有第一方 Client。", m4_roadmap)
        m4_windows = {
            i["component"]
            for i in self.manifest["issues"]
            if i["milestone"] == "M4" and i["component"].startswith("Windows")
        }
        for component in ("WindowsNativeClient", "WindowsNativeServer", "WindowsClientE2E", "WindowsServerE2E"):
            with self.subTest(component=component):
                self.assertIn(component, m4_windows)

    def test_traceability_records_chain_without_becoming_contract(self):
        chain = section(self.traceability, "M1 Validation Scope Supersession")
        self.assertIn("不是產品合約", chain)
        self.assertIn("docs/adr/M1-SCOPE-001-linux-only-validation.md", chain)
        self.assertIn("docs/adr/M1-001-product-contract.md", chain)
        self.assertIn("Issue #270", chain)
        self.assertIn("M2、M4、M5 Windows 產品範圍不變", chain)
        self.assertIn("Tests/Contracts/test_m1_linux_only_validation_scope.py", chain)

    def test_scope_documents_have_no_placeholders(self):
        unresolved = re.compile(r"\b(?:TODO|TBD)\b")
        for text in (self.adr, self.roadmap, self.traceability, *self.issue_texts.values()):
            self.assertIsNone(unresolved.search(text))


if __name__ == "__main__":
    unittest.main()
