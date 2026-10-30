"""Start this lease's disposable HTTP fixtures; inspect the server only, never the browser."""
from pathlib import Path
import datetime, hashlib, json, os, subprocess, sys, time
from urllib.request import urlopen

first, last = map(int, os.environ['LANE_SITE_PORT_RANGE'].split('-'))
port = first + 1
assert first <= port <= last
folder = Path('qa-tools')
folder.mkdir(exist_ok=True)
log = folder / 'condition-server-console.log'
with log.open('ab') as stream:
    process = subprocess.Popen(
        [sys.executable, 'test-site/server.py', '--site-root', 'test-site', '--offset', '1', '--log', 'qa-tools/condition-server-events.jsonl'],
        stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True,
    )
metadata = {
    'pid': process.pid, 'port': port,
    'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'source_sha256': hashlib.sha256(Path('test-site/server.py').read_bytes()).hexdigest(),
    'console_log': str(log), 'event_log': 'qa-tools/condition-server-events.jsonl',
    'scope': 'Lease-owned disposable fixture server only; no browser operation or acceptance result',
}
(folder / 'condition-server-process.json').write_text(json.dumps(metadata, indent=2) + '\n')
ready = None
for _ in range(20):
    if process.poll() is not None:
        raise RuntimeError('Fixture process exited: ' + str(process.returncode))
    try:
        with urlopen(f'http://127.0.0.1:{port}/ready', timeout=1) as response:
            ready = json.load(response)
        break
    except OSError:
        time.sleep(0.05)
assert ready is not None, 'Fixture server did not become ready'
assert '/article/' in ready['routes']
articles = []
for _ in range(2):
    with urlopen(f'http://127.0.0.1:{port}/article/?tab=B&run=TC-PHI507-reader-readiness', timeout=2) as response:
        body = response.read()
        assert response.status == 200 and b'<article>' in body and b'<textarea' in body
        articles.append({'status': response.status, 'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()})
assert articles[0]['sha256'] != articles[1]['sha256'], 'Each HTTP visit must have a fresh document identifier'
metadata.update(ready=ready, article_http_checks=articles, browser_reader_tested=False)
(folder / 'condition-server-process.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(json.dumps(metadata, indent=2))
