#!/usr/bin/env python3
"""Safely add English UI strings to lib/l10n/arb/app_en.arb and regenerate.

Concurrency-safe (fcntl lock) so several agents can add keys in parallel.

Usage:
  python3 tool/l10n_add.py '{"translateTitle": "Translate",
     "historyCount": {"value": "{count, plural, =1{1 entry} other{{count} entries}}",
                      "placeholders": {"count": {"type": "int"}}}}'

Rules: keys are lowerCamelCase and prefixed by feature (translate*, history*,
settings*, proofread*, common*). Existing keys with a different value are
reported and NOT overwritten (pick a new key). Re-adding an identical key is
a no-op. Regenerates lib/l10n/gen via `flutter gen-l10n` inside the lock.
"""
import fcntl, json, os, subprocess, sys
from collections import OrderedDict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB = os.path.join(ROOT, 'lib', 'l10n', 'arb', 'app_en.arb')
LOCK = os.path.join(ROOT, '.dart_tool', 'l10n.lock')

def main():
    new = json.loads(sys.argv[1], object_pairs_hook=OrderedDict)
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(ARB) as f:
            arb = json.load(f, object_pairs_hook=OrderedDict)
        conflicts = []
        for key, spec in new.items():
            value = spec['value'] if isinstance(spec, dict) else spec
            meta = OrderedDict()
            if isinstance(spec, dict):
                if 'description' in spec: meta['description'] = spec['description']
                if 'placeholders' in spec: meta['placeholders'] = spec['placeholders']
            if key in arb and arb[key] != value:
                conflicts.append(f'{key}: existing={arb[key]!r} new={value!r}')
                continue
            arb[key] = value
            if meta:
                arb['@' + key] = meta
            elif '@' + key not in arb:
                arb['@' + key] = OrderedDict(description=key)
        with open(ARB, 'w') as f:
            json.dump(arb, f, indent=2, ensure_ascii=False)
            f.write('\n')
        r = subprocess.run(['flutter', 'gen-l10n'], cwd=ROOT, capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        out = '\n'.join(l for l in out.splitlines() if 'root' not in l.lower() and 'superuser' not in l and l.strip() not in ('/', '📎'))
        if r.returncode != 0:
            print(out); sys.exit(1)
    if conflicts:
        print('CONFLICTS (not written):\n' + '\n'.join(conflicts)); sys.exit(2)
    print(f'ok: {len(new)} key(s)')

main()
