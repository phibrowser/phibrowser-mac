"""Save explicit parent review facts and verify retained CU image provenance.

Input is a parent-authored JSON file, not an automatic grading rule. Only list
raw numbers whose retained images the parent actually viewed.
"""
from pathlib import Path
import argparse, datetime, hashlib, json

p = argparse.ArgumentParser()
p.add_argument('input')
a = p.parse_args()
review = json.loads(Path(a.input).read_text())
qa = Path('PHI-507')
round_no = review['round']
job = review['job']
ev = qa / f'qa-evidence/r{round_no}'
meta = json.loads((ev / (job + '-evidence.json')).read_text())
run = json.loads((ev / (job + '-run.json')).read_text())
audit = run['computer_use_audit']
assert not audit['non_computer_use_calls']
assert not audit['non_computer_use_mcp_events']
assert not run.get('missing_units')
sources = []
for number in review.pop('viewed_raw_numbers'):
    expected = f'{job}-{number:03}.jpg'
    matches = [m for m in meta if m.get('source_file') == expected]
    assert len(matches) == 1, expected
    item = matches[0]
    raw = Path(f'scratch-PHI507-r{round_no}') / job / 'raw' / expected
    digest = hashlib.sha256(raw.read_bytes()).hexdigest()
    assert digest == item['source_sha256']
    sources.append(dict(raw_number=number, raw_file=expected,
        raw_sha256=digest, viewed_file=item['file'],
        viewed_sha256=hashlib.sha256((ev/item['file']).read_bytes()).hexdigest(),
        marker=item['original_marker']))
assert sources
review.update(reviewer='Ripley', reviewed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    computer_use_completed=audit['completed_mcp_event_count'],
    non_computer_use_calls=0, sources=sources)
output = ev / review.pop('output')
assert not output.exists(), 'Preserve previous reviews; explicitly revise instead of silently overwriting'
output.write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n')
print('Saved',len(sources),'explicitly reviewed image records:',output)
