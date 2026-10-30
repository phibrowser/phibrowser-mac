# issue: PHI-507
# based_on: fixture-source-r2.html (SHA-256 d2b6a75d142a7c2624836557e90c07d0a15c8dd9ed0adb60f5fe2e152c951627)
"""Validate the disposable HTTP helper, without controlling or reading a browser."""
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit
from urllib.request import urlopen

SERVER = Path(sys.argv.pop(1)).resolve()
FIXTURE_SHA = 'd2b6a75d142a7c2624836557e90c07d0a15c8dd9ed0adb60f5fe2e152c951627'


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.scripts = 0

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            self.links.append(dict(attrs))
        if tag == 'script':
            self.scripts += 1


class FixtureLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        first, last = map(int, os.environ['LANE_SITE_PORT_RANGE'].split('-'))
        cls.port = first + 2
        assert cls.port <= last
        cls.base = 'http://127.0.0.1:' + str(cls.port)
        cls.scratch = tempfile.TemporaryDirectory(prefix='launcher-check-', dir='qa-tools')
        cls.process = subprocess.Popen(
            [sys.executable, str(SERVER), '--site-root', 'test-site', '--offset', '2',
             '--log', str(Path(cls.scratch.name) / 'events.jsonl')],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        for _ in range(30):
            if cls.process.poll() is not None:
                break
            try:
                with urlopen(cls.base + '/ready', timeout=1) as response:
                    cls.ready = json.load(response)
                return
            except (URLError, OSError):
                time.sleep(0.05)
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.scratch.cleanup()
        raise RuntimeError('The isolated fixture helper did not become ready')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.scratch.cleanup()

    def request(self, path):
        try:
            response = urlopen(self.base + path, timeout=2)
        except HTTPError as error:
            response = error
        with response:
            return response.code, response.read()

    def test_ordinary_links_preserve_requested_document_urls_and_original_fixture(self):
        run = 'TC-PHI507-launcher-' + 'x' * 70
        query = urlencode({'run': run, 'pages': 'A:normal,B:unsaved,A:normal'})
        status, body = self.request('/launch/?' + query)
        self.assertEqual(status, 200, 'The helper must serve the ordinary link launcher')
        parsed = Links()
        parsed.feed(body.decode('utf-8'))
        self.assertEqual(parsed.scripts, 0, 'Preparation must use ordinary clickable links')
        self.assertEqual(len(parsed.links), 3, 'Same-URL documents must not be deduplicated')
        for link, tab, kind in zip(parsed.links, ['A', 'B', 'A'], ['normal', 'unsaved', 'normal']):
            self.assertEqual(link.get('target'), '_blank')
            destination = urlsplit(link['href'])
            self.assertEqual(destination.path, '/fixture/')
            self.assertEqual(parse_qs(destination.query), {'run': [run], 'tab': [tab], 'kind': [kind]})
            with urlopen(urljoin(self.base, link['href']), timeout=2) as response:
                self.assertEqual(hashlib.sha256(response.read()).hexdigest(), FIXTURE_SHA)
        self.assertEqual(self.ready['fixture_sha256'], FIXTURE_SHA)

    def test_invalid_page_specification_is_rejected_before_preparation(self):
        query = urlencode({'run': 'TC-PHI507-invalid-launcher', 'pages': 'A:unavailable-kind'})
        status, _ = self.request('/launch/?' + query)
        self.assertEqual(status, 400)


if __name__ == '__main__':
    unittest.main(verbosity=2)
