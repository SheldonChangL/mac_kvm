#!/usr/bin/env python3
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text(encoding='utf-8'))
required = ['issue_id','commit','started_at','finished_at','environment','cases','result']
missing = [k for k in required if k not in d]
if missing:
    print('missing:', ', '.join(missing)); raise SystemExit(1)
if d['result'] not in ['pass','fail','blocked']:
    print('invalid result'); raise SystemExit(1)
print('evidence OK')
