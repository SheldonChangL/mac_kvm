#!/usr/bin/env python3
import argparse, json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--completed', required=True)
p.add_argument('--tier', default='A,B')
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root/'issues_manifest.json').read_text(encoding='utf-8'))
progress = json.loads(Path(args.completed).read_text(encoding='utf-8'))
completed = set(progress.get('completed', []))
blocked = set(progress.get('blocked', {}).keys())
active = set(progress.get('in_progress', []))
allowed = set(x.strip() for x in args.tier.split(',') if x.strip())
rows = []
for issue in manifest['issues']:
    if issue['id'] in completed | blocked | active: continue
    if not set(issue['depends_on']).issubset(completed): continue
    tiers = set(issue['tier'].split('/'))
    if not (tiers & allowed): continue
    rows.append(issue)
for issue in rows:
    print(f"{issue['id']}	{issue['tier']}	{issue['risk']}	{issue['title']}	{issue['issue_file']}")
if not rows:
    print('No runnable issues for requested tier.')
