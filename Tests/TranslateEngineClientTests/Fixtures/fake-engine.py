#!/usr/bin/env python3
"""A fake TranslateEngine for client tests: speaks the frame protocol without any model.

Launched exactly like the real engine (`<engine> --model <dir>`). The last path component of the
"model" argument selects a behaviour:
  burst      ready, then every synthesize gets 50 audio frames of 4 samples written in one burst, then done
  error-slot ready, then every synthesize is answered with an error carrying its id
  die        ready, then on the first synthesize: two audio frames, then exit 3 without done
  noready    write the pid to <dir>/pid, then sleep 30 s without ever sending ready
prepareVoice, ping and stats are answered normally in every mode. Cancel is acknowledged by marking
the next done as discarded. Nothing is written except the pid file in noready mode.
"""
import json, os, struct, sys, time

def write(header, payload=b''):
    h = json.dumps(header, sort_keys=True).encode()
    sys.stdout.buffer.write(struct.pack('>I', len(h)) + h + struct.pack('>I', len(payload)) + payload)
    sys.stdout.buffer.flush()

def read():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4: return None
    (hl,) = struct.unpack('>I', raw)
    header = json.loads(sys.stdin.buffer.read(hl))
    (pl,) = struct.unpack('>I', sys.stdin.buffer.read(4))
    payload = sys.stdin.buffer.read(pl) if pl else b''
    return header, payload

def main():
    model = sys.argv[sys.argv.index('--model') + 1]
    mode = os.path.basename(model.rstrip('/'))
    if mode == 'noready':
        os.makedirs(model, exist_ok=True)
        open(os.path.join(model, 'pid'), 'w').write(str(os.getpid()))
        time.sleep(30)
        return
    write({'type': 'ready', 'version': 1, 'sampleRate': 24000, 'loadMs': 1, 'residentBytes': 12345})
    cancelled = set()
    while True:
        message = read()
        if message is None: return
        header, payload = message
        kind, rid = header.get('type'), header.get('id', '')
        if kind == 'shutdown': return
        if kind == 'ping': write({'type': 'pong', 'id': rid})
        elif kind == 'stats': write({'type': 'stats', 'id': rid, 'residentBytes': 12345, 'activeBytes': 1, 'peakBytes': 2, 'cacheBytes': 3})
        elif kind == 'cancel': cancelled.add(rid)
        elif kind == 'prepareVoice':
            write({'type': 'voiceReady', 'id': rid, 'slot': header['slot'], 'seconds': len(payload) / 4 / 24000, 'prepareMs': 1, 'language': header['language'].lower(), 'residentBytes': 12345})
        elif kind == 'synthesize':
            if mode == 'error-slot':
                write({'type': 'error', 'id': rid, 'message': 'Voice slot is not prepared.'}); continue
            frames = 2 if mode == 'die' else 50
            for seq in range(frames):
                write({'type': 'audio', 'id': rid, 'seq': seq, 'sampleRate': 24000}, struct.pack('<4f', seq, 0.5, -0.5, 0.25))
            if mode == 'die':
                sys.exit(3)
            discarded = rid in cancelled
            write({'type': 'done', 'id': rid, 'frames': frames * 4, 'forwardedFrames': frames * 4, 'sampleRate': 24000, 'firstAudioMs': 1,
                   'generationMs': 2, 'discarded': discarded, **({'wastedMs': 1} if discarded else {})})
        else:
            write({'type': 'error', 'id': rid, 'message': 'Unknown request type.'})

if __name__ == '__main__':
    main()
