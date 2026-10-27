#!/usr/bin/env python3
"""Independent, read-only check of desktop JSONL token totals. Prints counts only."""
import datetime
import json
import os
from pathlib import Path
import stat
import sys

home = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
fields = ('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')
sessions = {}
now = datetime.datetime.now(datetime.timezone.utc)
for directory in ('sessions', 'archived_sessions'):
    for path in sorted((home / directory).rglob('*.jsonl')):
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            continue
        baseline = [0, 0, 0, 0]
        total = [0, 0, 0, 0]
        identity = None
        count = 0
        with path.open('rb') as stream:
            for line in stream:
                if not line.endswith(b'\n'):
                    break
                if len(line) > 4 * 1024 * 1024:
                    continue
                if b'"session_meta"' not in line and b'"token_count"' not in line:
                    continue
                try:
                    item = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                payload = item.get('payload', {})
                if not isinstance(payload, dict):
                    continue
                if item.get('type') == 'session_meta':
                    if identity is not None:
                        continue
                    if (payload.get('originator') != 'Codex Desktop' or not isinstance(payload.get('source'), str)
                            or 'parent_thread_id' in payload or 'forked_from_id' in payload):
                        break
                    identity = payload.get('id', payload.get('session_id'))
                elif identity and item.get('type') == 'event_msg' and payload.get('type') == 'token_count':
                    info = payload.get('info')
                    values = info.get('total_token_usage') if isinstance(info, dict) else None
                    if not isinstance(values, dict):
                        continue
                    v = [values.get(f, 0 if f in (fields[1], fields[3]) else None) for f in fields]
                    if any(type(n) not in (int, float) or n < 0 or n > 1e12 or int(n) != n for n in v):
                        continue
                    if v[1] > v[0] or v[3] > v[2]:
                        continue
                    delta = [a - b for a, b in zip(v, baseline)]
                    if any(n < 0 for n in delta) or delta[1] > delta[0] or delta[3] > delta[2]:
                        continue
                    baseline = v
                    if delta[0] + delta[2] == 0:
                        continue
                    try:
                        stamp = datetime.datetime.fromisoformat(item['timestamp'].replace('Z', '+00:00'))
                    except (ValueError, KeyError):
                        continue
                    count += 1
                    if stamp <= now:
                        total = [a + b for a, b in zip(total, delta)]
        if identity:
            rank = (count, st.st_size)
            if identity not in sessions or rank > sessions[identity][0]:
                sessions[identity] = (rank, total)
result = {f: sum(t[1][i] for t in sessions.values()) for i, f in enumerate(fields)}
result['total_tokens'] = result['input_tokens'] + result['output_tokens']
result['desktop_sessions'] = len(sessions)
if len(sys.argv) > 2:
    actual = json.loads(Path(sys.argv[2]).read_text())
    assert all(actual[k] == v for k, v in result.items()), 'Independent totals differ'
    print('PASS independent local totals match native scanner; no message/account data output')
else:
    print(json.dumps(result, sort_keys=True))
