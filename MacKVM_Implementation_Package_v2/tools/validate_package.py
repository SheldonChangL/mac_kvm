#!/usr/bin/env python3
import json
from collections import defaultdict, deque
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'issues_manifest.json').read_text(encoding='utf-8'))
issues = manifest['issues']
ids = [i['id'] for i in issues]
errors = []
if len(ids) != len(set(ids)):
    errors.append('duplicate issue IDs')
known = set(ids)
for issue in issues:
    for dep in issue['depends_on']:
        if dep not in known:
            errors.append(f"{issue['id']}: unknown dependency {dep}")
    path = root / issue['issue_file']
    if not path.exists():
        errors.append(f"{issue['id']}: missing issue file {path}")
    text = path.read_text(encoding='utf-8') if path.exists() else ''
    required = ['## Exact Files','## Acceptance Criteria','## Required Commands','## Expected Evidence','## Prohibited Shortcuts','## Stop Conditions']
    for heading in required:
        if heading not in text:
            errors.append(f"{issue['id']}: missing heading {heading}")
    if issue['size'] not in {'XS','S','M'}:
        errors.append(f"{issue['id']}: issue too large ({issue['size']})")

indegree = {i:0 for i in ids}
adj = defaultdict(list)
for issue in issues:
    for dep in issue['depends_on']:
        indegree[issue['id']] += 1
        adj[dep].append(issue['id'])
q = deque([i for i,d in indegree.items() if d == 0])
seen = 0
while q:
    cur = q.popleft(); seen += 1
    for nxt in adj[cur]:
        indegree[nxt] -= 1
        if indegree[nxt] == 0: q.append(nxt)
if seen != len(ids): errors.append('dependency cycle detected')

for required_path in ['README.md','FROZEN_DECISIONS.md','ARCHITECTURE_GUARDRAILS.md','CONTRACT_CATALOG.md','reference/KVMContracts/Package.swift']:
    if not (root / required_path).exists(): errors.append(f'missing {required_path}')

if errors:
    print('PACKAGE INVALID')
    for e in errors: print('-', e)
    raise SystemExit(1)
print(f"PACKAGE OK: {len(issues)} issues, {len(manifest['milestones'])} milestones, {len(manifest['epics'])} epics")
