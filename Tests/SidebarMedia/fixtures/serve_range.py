"""Serve a generated ten-minute WAV fixture with single-byte-range support."""

from array import array
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from math import pi, sin
from pathlib import Path
from shutil import copy2
from tempfile import TemporaryDirectory
import os
import re
import wave


class RangeFileHandler(SimpleHTTPRequestHandler):
    def send_head(self):
        self._byte_range = None
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            source = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        size = os.fstat(source.fileno()).st_size
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", requested.strip())
            if not match or not any(match.groups()):
                source.close()
                self.send_error(416, "Unsupported byte range")
                return None
            start_text, end_text = match.groups()
            if start_text:
                start = int(start_text)
                end = min(int(end_text), size - 1) if end_text else size - 1
            else:
                suffix = int(end_text)
                start, end = max(0, size - suffix), size - 1
            if start >= size or end < start:
                source.close()
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return None
            self._byte_range = (start, end)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            length = end - start + 1
        else:
            self.send_response(200)
            length = size
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        return source

    def copyfile(self, source, outputfile):
        if self._byte_range is None:
            return super().copyfile(source, outputfile)
        start, end = self._byte_range
        source.seek(start)
        remaining = end - start + 1
        while remaining:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


def generate_tone(path):
    rate = 8000
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        for second in range(600):
            samples = array(
                "h", (int(1800 * sin(2 * pi * 220 * (second * rate + i) / rate))
                      for i in range(rate))
            )
            output.writeframes(samples.tobytes())


if __name__ == "__main__":
    with TemporaryDirectory(prefix="phi-media-ui-") as directory:
        root = Path(directory)
        copy2(Path(__file__).with_name("ui-test.html"), root / "ui-test.html")
        generate_tone(root / "long-tone.wav")
        handler = partial(RangeFileHandler, directory=directory)
        ThreadingHTTPServer(("127.0.0.1", 8766), handler).serve_forever()
