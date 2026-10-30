"""Read only this campaign's saved Codex tool events; never query the browser."""
from pathlib import Path
from collections import Counter
import argparse, datetime, json

p = argparse.ArgumentParser()
p.add_argument('session')
p.add_argument('--tool')
a = p.parse_args()
source = next(Path.home().glob('.codex/sessions/**/rollout-*' + a.session + '*.jsonl'))
items = []
for line in source.read_text().splitlines():
    payload = json.loads(line).get('payload', {})
    item = payload.get('item', {})
    if payload.get('type') == 'item_completed' and item.get('type') == 'McpToolCall':
        items.append(item)

def text_blocks(value):
    if isinstance(value, dict):
        for block in value.get('content', []):
            if block.get('type') != 'text':
                continue
            text = block.get('text', '')
            try:
                nested = json.loads(text)
            except (ValueError, TypeError):
                nested = None
            if isinstance(nested, dict) and 'content' in nested:
                yield from text_blocks(nested)
            elif len(text) < 100000 and not text.startswith('data:image/'):
                yield text

events = []
if a.tool:
    for item in items:
        if item.get('tool') == a.tool:
            events.append({k: item.get(k) for k in ('server', 'tool', 'status', 'arguments', 'duration', 'error')})
            events[-1]['returned_text'] = list(text_blocks(item.get('result', {})))
print(json.dumps({
    'session_id': a.session,
    'scope': 'Saved item_completed MCP events only; no live browser operation or state read',
    'recovered_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'mcp_call_count': len(items),
    'calls_by_server_tool': dict(Counter(i.get('server', '') + '/' + i.get('tool', '') for i in items)),
    'non_computer_use_events': [{k: i.get(k) for k in ('server', 'tool', 'status')} for i in items if i.get('server') != 'computer-use'],
    'selected_events': events,
}, ensure_ascii=False, indent=2))
