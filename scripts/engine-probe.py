#!/usr/bin/env python3
"""Minimal driver for TranslateEngine's framed protocol, for debugging without the Swift client.

Usage: engine-probe.py <engine> <model dir> <voices dir>
Prepares the three fixture voices, synthesizes one sentence on each, cancels one mid-way, and prints every
reply header (payload sizes only). Audio is never written anywhere.

The engine runs unsandboxed here (the Swift client is what applies sandbox-exec); set
TRANSLATE_PROBE_SANDBOX=1 to wrap it in the same profile the client uses.
"""
import json, os, struct, subprocess, sys, time, wave

def frame(header, payload=b''):
    h = json.dumps(header, sort_keys=True).encode()
    return struct.pack('>I', len(h)) + h + struct.pack('>I', len(payload)) + payload

def read_frame(pipe):
    raw = pipe.read(4)
    if len(raw) < 4: return None
    (hl,) = struct.unpack('>I', raw)
    header = json.loads(pipe.read(hl))
    (pl,) = struct.unpack('>I', pipe.read(4))
    payload = pipe.read(pl) if pl else b''
    return header, payload

def wav_floats(path):
    with wave.open(path, 'rb') as w:
        assert w.getframerate() == 24000 and w.getnchannels() == 1 and w.getsampwidth() == 2, 'fixture must be 24 kHz mono 16-bit'
        data = w.readframes(w.getnframes())
    ints = struct.unpack('<%dh' % (len(data) // 2), data)
    return struct.pack('<%df' % len(ints), *[i / 32768.0 for i in ints])

def main():
    engine, model, voices = sys.argv[1:4]
    t0 = time.monotonic()
    log = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.build', 'engine-probe-stderr.log')
    os.makedirs(os.path.dirname(log), exist_ok=True)
    command = [engine, '--model', model]
    if os.environ.get('TRANSLATE_PROBE_SANDBOX') == '1':
        home = os.path.expanduser('~'); tmp = os.environ.get('TMPDIR', '/tmp')
        profile = ('(version 1)(allow default)(deny network*)(deny device-microphone)(deny device-camera)'
                   '(deny file-write* (subpath "%s"))(allow file-write* (subpath "%s/Library/Caches") (subpath "%s"))' % (home, home, tmp))
        command = ['/usr/bin/sandbox-exec', '-p', profile] + command
    p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(log, 'wb'))
    def send(header, payload=b''):
        p.stdin.write(frame(header, payload)); p.stdin.flush()
    def recv():
        r = read_frame(p.stdout)
        if r is None: sys.exit('engine closed its output')
        h, payload = r
        print('%7.0f ms  <- %s%s' % ((time.monotonic() - t0) * 1000, json.dumps(h, sort_keys=True), '  [+%d bytes]' % len(payload) if payload else ''))
        return h, payload
    recv()  # ready
    for slot, name, lang in [('generic', 'generic-en', 'English'), ('local', 'local-en', 'Spanish'), ('remote', 'remote-es', 'English')]:
        transcript = open(os.path.join(voices, name + '.txt')).read().strip()
        send({'type': 'prepareVoice', 'id': 'prep-' + slot, 'slot': slot, 'transcript': transcript, 'language': lang, 'sampleRate': 24000}, wav_floats(os.path.join(voices, name + '.wav')))
        recv()
    texts = {'generic': 'Thanks, that works for me.', 'local': 'Gracias, eso me funciona.', 'remote': 'Thanks, that works for me.'}
    for slot in ['generic', 'local', 'remote']:
        send({'type': 'synthesize', 'id': 'syn-' + slot, 'slot': slot, 'text': texts[slot], 'streamingInterval': 0.32})
        chunks = 0
        while True:
            h, payload = recv()
            if h['type'] == 'audio': chunks += 1
            if h['type'] in ('done', 'error'): break
        print('   %s: %d audio chunks' % (slot, chunks))
    send({'type': 'synthesize', 'id': 'syn-cancel', 'slot': 'generic', 'text': texts['generic'] + ' ' + texts['generic'] + ' ' + texts['generic'], 'streamingInterval': 0.32})
    h, _ = recv()
    send({'type': 'cancel', 'id': 'syn-cancel'})
    while h['type'] not in ('done', 'error'):
        h, _ = recv()
    send({'type': 'stats', 'id': 'st'}); recv()
    send({'type': 'shutdown'})
    p.stdin.close(); p.wait(timeout=10)
    print('engine exit code', p.returncode)

if __name__ == '__main__':
    main()
