#!/usr/bin/env python3
"""Local recorder for the Milestone 1c corpus (docs/M1C-PLAN.md).

Serves scripts/corpus-recorder.html on 127.0.0.1 and saves what the page records as 16-bit WAV into
Fixtures/Corpus/raw/<language>/<name>.wav, the files scripts/run-m1c.sh expects. Reads the reading
scripts for the teleprompter. Nothing leaves the machine; the folder is git-ignored. Run with python3 -I:

    python3 -I scripts/corpus-recorder.py            # then open http://127.0.0.1:8765
"""
import argparse, json, os, re, struct, sys, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ['en', 'es', 'zh']
NAMES = ['scripted', 'natural-1', 'natural-2', 'reference']
MAX_BYTES = 200 * 1024 * 1024


def parse_script(path):
    title, sentences, prompts = '', [], []
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.startswith('# ') and not title:
            title = line[2:].strip()
        m = re.match(r'^(\d+)\.\s+(.*\S)\s*$', line)
        if m:
            sentences.append(m.group(2))
        elif line.startswith('- '):
            prompts.append(line[2:].strip())
    return {'title': title, 'sentences': sentences, 'prompts': prompts}


def wav_seconds(path):
    try:
        with open(path, 'rb') as f:
            head = f.read(12)
            if head[:4] != b'RIFF' or head[8:12] != b'WAVE':
                return None
            rate, channels, bits, data = None, 1, 16, None
            while True:
                chunk = f.read(8)
                if len(chunk) < 8:
                    break
                tag, size = chunk[:4], struct.unpack('<I', chunk[4:])[0]
                if tag == b'fmt ':
                    fmt = f.read(size)
                    channels, rate = struct.unpack('<HI', fmt[2:8])
                    bits = struct.unpack('<H', fmt[14:16])[0]
                elif tag == b'data':
                    data = size
                    break
                else:
                    f.seek(size + (size & 1), 1)
            if rate and data:
                return round(data / (rate * channels * bits / 8), 1)
    except OSError:
        pass
    return None


class Recorder(BaseHTTPRequestHandler):
    corpus = ROOT / 'Fixtures/Corpus'
    page = ROOT / 'scripts/corpus-recorder.html'

    def send_json(self, status, payload):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def state(self):
        languages = {}
        for lang in LANGUAGES:
            script = self.corpus / 'scripts' / (lang + '.md')
            if not script.exists():
                continue
            entry = parse_script(script)
            files = {}
            for name in NAMES:
                wav = self.corpus / 'raw' / lang / (name + '.wav')
                other = [p.name for p in (self.corpus / 'raw' / lang).glob(name + '.*')] if (self.corpus / 'raw' / lang).exists() else []
                files[name] = {'exists': wav.exists() or bool(other), 'seconds': wav_seconds(wav) if wav.exists() else None, 'files': other}
            entry['files'] = files
            languages[lang] = entry
        return {'corpus': str(self.corpus), 'languages': languages}

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == '/':
            body = self.page.read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif url.path == '/api/state':
            self.send_json(200, self.state())
        else:
            self.send_json(404, {'error': 'not found'})

    def do_POST(self):
        url = urlparse(self.path)
        if url.path != '/api/upload':
            return self.send_json(404, {'error': 'not found'})
        query = parse_qs(url.query)
        lang, name = query.get('lang', [''])[0], query.get('name', [''])[0]
        overwrite = query.get('overwrite', ['0'])[0] == '1'
        if lang not in LANGUAGES or name not in NAMES:
            return self.send_json(400, {'error': 'language must be en, es or zh; name must be scripted, natural-1, natural-2 or reference'})
        length = int(self.headers.get('Content-Length', '0'))
        if length <= 44 or length > MAX_BYTES:
            return self.send_json(400, {'error': 'empty or oversized recording'})
        body = self.rfile.read(length)
        if body[:4] != b'RIFF' or body[8:12] != b'WAVE':
            return self.send_json(400, {'error': 'not a WAV file'})
        folder = self.corpus / 'raw' / lang
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / (name + '.wav')
        if target.exists() and not overwrite:
            return self.send_json(409, {'error': 'exists', 'seconds': wav_seconds(target)})
        fd, temp = tempfile.mkstemp(prefix=name + '.', suffix='.part', dir=str(folder))
        with os.fdopen(fd, 'wb') as f:
            f.write(body)
        os.replace(temp, target)
        self.send_json(200, {'path': str(target), 'seconds': wav_seconds(target)})

    def log_message(self, fmt, *args):
        if '/api/upload' in (args[0] if args else ''):
            sys.stderr.write('%s %s\n' % (self.log_date_time_string(), fmt % args))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--corpus', default=str(ROOT / 'Fixtures/Corpus'))
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    Recorder.corpus = Path(args.corpus).resolve()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Recorder)
    print('corpus recorder: open http://127.0.0.1:%d  (saving into %s/raw; Ctrl-C to stop)' % (args.port, Recorder.corpus), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
