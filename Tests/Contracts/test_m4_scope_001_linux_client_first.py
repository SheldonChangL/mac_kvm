import csv
import json
import re
import unittest
from collections import defaultdict, deque
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2"
SCOPE_ADR = REPOSITORY_ROOT / "docs/adr/M4-SCOPE-001-linux-client-first.md"
MANIFEST = PACKAGE_ROOT / "issues_manifest.json"
INDEX = PACKAGE_ROOT / "issues_index.csv"
EXECUTION_ORDER = PACKAGE_ROOT / "EXECUTION_ORDER.md"
PRODUCT_ROADMAP = PACKAGE_ROOT / "PRODUCT_ROADMAP.md"

GOAL = "新目標就是直接取代Barrier, server + client都可以用我們的kvm"
DECISIONS = ("「先沿用 Barrier 協定」", "「Swift」", "「Mac 控制 Linux」", "「先只做 X11」")

# Dependencies after this ADR, and the edges it removed.
SUPERSEDED = {
    "M4-001": ((), ("M3-039",)),
    "M4-002": (("M4-001", "M1-013"), ("M3-034",)),
    "M4-034": (("M4-021", "M4-022"), ("M4-023",)),
    "M4-036": (("M4-022", "M4-024", "M4-026", "M4-027", "M4-035"), ("M4-032", "M4-033")),
    "M1-062": (("M1-046", "M1-054"), ("M1-037",)),
    "M1-050": (("M1-046",), ("M1-049",)),
    "M4-027": (("M4-020",), ("M1-039", "M2-019")),
}
M1_043_FILES = (
    "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierVirtualKeyMapper.swift",
    "Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierVirtualKeyMapperTests.swift",
)
FOLLOW_UPS = (
    "M1-029-FOLLOWUP-001",
    "M1-063-FOLLOWUP-001",
    "M1-055-FOLLOWUP-001",
    "M4-021-FOLLOWUP-001",
    "M4-020-FOLLOWUP-001",
    "M4-036-FOLLOWUP-001",
)
NOTE = "docs/adr/M4-SCOPE-001-linux-client-first.md"


def manifest_issues():
    return {issue["id"]: issue for issue in json.loads(MANIFEST.read_text(encoding="utf-8"))["issues"]}


def issue_text(issue):
    return (PACKAGE_ROOT / issue["issue_file"]).read_text(encoding="utf-8")


def frontmatter_dependencies(text):
    match = re.search(r'(?m)^depends_on:\n((?:  - ".*"\n)+|  \[\]\n)', text)
    return tuple(re.findall(r'  - "(.*)"', match.group(1))) if match else None


def index_dependencies():
    with INDEX.open(encoding="utf-8-sig", newline="") as handle:
        return {
            row["id"]: tuple(filter(None, row["depends_on"].split(",")))
            for row in csv.DictReader(handle)
        }


def execution_order_dependencies(issue_id):
    text = EXECUTION_ORDER.read_text(encoding="utf-8")
    match = re.search(rf"(?m)^\| \d+ \| \[{re.escape(issue_id)}\]\(.*\| ([^|]*) \|$", text)
    if not match:
        return None
    cell = match.group(1).strip()
    return () if cell == "—" else tuple(part.strip() for part in cell.split(","))


class M4Scope001LinuxClientFirstTests(unittest.TestCase):
    def test_adr_records_the_owner_goal_and_decisions(self):
        text = SCOPE_ADR.read_text(encoding="utf-8")
        self.assertIn("Accepted on 2026-10-29", text)
        self.assertIn("Issue #330", text)
        self.assertIn(GOAL, text)
        for decision in DECISIONS:
            self.assertIn(decision, text)
        self.assertIn("Barrier-compatible", text)

    def test_superseded_dependencies_agree_in_every_record(self):
        issues = manifest_issues()
        index = index_dependencies()
        for issue_id, (expected, removed) in SUPERSEDED.items():
            with self.subTest(issue=issue_id):
                issue = issues[issue_id]
                text = issue_text(issue)
                self.assertEqual(tuple(issue["depends_on"]), expected)
                self.assertEqual(frontmatter_dependencies(text), expected)
                self.assertEqual(index[issue_id], expected)
                self.assertEqual(execution_order_dependencies(issue_id), expected)
                for dependency in removed:
                    self.assertNotIn(dependency, issue["depends_on"])
                self.assertIn(NOTE, text)

    def test_m1_043_maps_barrier_keys_outside_kvmcore(self):
        issue = manifest_issues()["M1-043"]
        text = issue_text(issue)
        for path in M1_043_FILES:
            self.assertIn(path, issue["exact_files"])
            self.assertIn(f"`{path}`", text)
        self.assertFalse([path for path in issue["exact_files"] if path.startswith("Packages/KVMCore/")])
        self.assertNotIn("Packages/KVMCore/", text)
        self.assertIn(NOTE, text)

    def test_follow_ups_are_named_in_the_adr(self):
        text = SCOPE_ADR.read_text(encoding="utf-8")
        for follow_up in FOLLOW_UPS:
            self.assertIn(f"| {follow_up} |", text)

    def test_roadmap_points_m3_and_m4_at_the_adr(self):
        text = PRODUCT_ROADMAP.read_text(encoding="utf-8")
        for heading in ("## M3 — ", "## M4 — "):
            start = text.index(heading)
            end = text.index("### Exit Criteria", start)
            section = text[start:end]
            self.assertIn(NOTE, section, heading)
            self.assertIn("Issue #330", section, heading)

    def test_dependency_graph_stays_acyclic(self):
        issues = manifest_issues()
        indegree = {issue_id: len(issue["depends_on"]) for issue_id, issue in issues.items()}
        dependants = defaultdict(list)
        for issue_id, issue in issues.items():
            for dependency in issue["depends_on"]:
                self.assertIn(dependency, issues)
                dependants[dependency].append(issue_id)
        ready = deque(issue_id for issue_id, count in indegree.items() if count == 0)
        visited = 0
        while ready:
            current = ready.popleft()
            visited += 1
            for dependant in dependants[current]:
                indegree[dependant] -= 1
                if indegree[dependant] == 0:
                    ready.append(dependant)
        self.assertEqual(visited, len(issues))


if __name__ == "__main__":
    unittest.main()
