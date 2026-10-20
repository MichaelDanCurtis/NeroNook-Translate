#!/usr/bin/env python3
"""Resident Hy-MT2 translator for the Milestone 1c comparison, run with Voice's interpreter
environment (owner approval 9, read-only use). Measurement only; nothing here ships.

  <venv>/bin/python hymt2-server.py --model <translator dir>

Loads the model once (verifying it against the folder's receipt.json like Voice's worker does), then
reads one JSON request per line on stdin and writes one JSON reply per line on stdout:
  request: {"id": "...", "text": "...", "target": "en|es|zh", "context": ["previous sentence", ...]}
  reply:   {"id": "...", "text": "...", "firstTokenMs": 123, "generationMs": 456, "tokens": 42}
The prompt follows the Hunyuan-MT instruction format Voice's worker used; `context` is prepended as
"Previous sentences, for context only:" so the comparison can measure what context buys.
"""
import argparse, hashlib, json, os, sys, time
from pathlib import Path
os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_IMPLICIT_TOKEN='1', TOKENIZERS_PARALLELISM='false')
LANGUAGES = {'en': 'English', 'es': 'Spanish', 'zh': 'Chinese'}

def verified(path):
    path = Path(path).resolve()
    receipt = json.loads((path / 'receipt.json').read_text())
    for name, digest in receipt['files'].items():
        f = (path / name).resolve()
        if not str(f).startswith(str(path)) or hashlib.sha256(f.read_bytes()).hexdigest() != digest:
            raise SystemExit('Model verification failed: ' + name)
    return path

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--model', required=True); parser.add_argument('--max-tokens', type=int, default=384)
    args = parser.parse_args()
    import mlx.core as mx
    mx.set_cache_limit(128 * 1024 * 1024)
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler
    started = time.monotonic()
    model, tokenizer = load(verified(args.model), tokenizer_config={'trust_remote_code': False})
    sys.stdout.write(json.dumps({'type': 'ready', 'loadMs': int((time.monotonic() - started) * 1000)}) + '\n'); sys.stdout.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        request = json.loads(line)
        rid = request.get('id', '')
        try:
            text = request['text'].strip(); target = LANGUAGES[request['target']]
            if not text or len(text.encode()) > 2048: raise ValueError('Empty or oversized text')
            context = [c for c in request.get('context', []) if isinstance(c, str) and c.strip()][-3:]
            prompt = ''
            if context:
                prompt += 'Previous sentences, for context only (do not translate them):\n' + '\n'.join(context) + '\n\n'
            prompt += 'Translate the following text into ' + target + '. Note that you should only output the translated result without any additional explanation:\n\n' + text
            prompt = tokenizer.apply_chat_template([{'role': 'user', 'content': prompt}], tokenize=False, add_generation_prompt=True)
            t0 = time.monotonic(); first = None; output = ''; tokens = 0; finish = None
            for r in stream_generate(model, tokenizer, prompt=prompt, max_tokens=args.max_tokens, sampler=make_sampler(temp=0)):
                if first is None: first = time.monotonic()
                output += r.text; tokens += 1; finish = r.finish_reason
            if finish == 'length' or not output.strip(): raise ValueError('Incomplete translation')
            reply = {'id': rid, 'text': output.strip(), 'firstTokenMs': int((first - t0) * 1000) if first else -1, 'generationMs': int((time.monotonic() - t0) * 1000), 'tokens': tokens}
        except Exception as error:
            reply = {'id': rid, 'error': str(error)[:240]}
        sys.stdout.write(json.dumps(reply, ensure_ascii=False) + '\n'); sys.stdout.flush()

if __name__ == '__main__':
    main()
