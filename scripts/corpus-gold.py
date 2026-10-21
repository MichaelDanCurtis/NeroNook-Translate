#!/usr/bin/env python3
"""Derive gold references from the corpus reading scripts (Fixtures/Corpus/scripts/*.md).

Each numbered sentence becomes one reference line in gold/<lang>/scripted.txt; the checks file
gold/<lang>/scripted.checks.json lists what the scoring looks for in a transcript, written by hand
next to this tool as scripts/corpus-checks/<lang>.json (accepted forms for names, numbers, dates,
negations and self-corrections).

A speaker who read a sentence differently from the script records that in gold/<lang>/as-read.json:
{"9": {"text": "…what was actually said…", "checks": [ {category, accept}, … ]}}. The gold line and
that sentence's checks are then what was read, agreed before scoring, and the script itself stays
as written for the next speaker. Reads scripts, writes gold only. Run with `python3 -I`.
"""
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def sentences(markdown):
    out = []
    for line in markdown.splitlines():
        m = re.match(r'^(\d+)\.\s+(.*\S)\s*$', line)
        if m:
            text = re.sub(r'\s*（[^）]*）\s*$', '', m.group(2))   # drop pinyin notes in the Mandarin script
            out.append((int(m.group(1)), text))
    return out

def main():
    for lang in ['en', 'es', 'zh']:
        script = ROOT / 'Fixtures/Corpus/scripts' / (lang + '.md')
        if not script.exists(): continue
        lines = sentences(script.read_text(encoding='utf-8'))
        gold = ROOT / 'Fixtures/Corpus/gold' / lang
        gold.mkdir(parents=True, exist_ok=True)
        as_read_file = gold / 'as-read.json'
        as_read = json.loads(as_read_file.read_text(encoding='utf-8')) if as_read_file.exists() else {}
        texts = [as_read.get(str(number), {}).get('text', text) for number, text in lines]
        (gold / 'scripted.txt').write_text('\n'.join(texts) + '\n', encoding='utf-8')
        checks = ROOT / 'scripts/corpus-checks' / (lang + '.json')
        if checks.exists() and not as_read:
            (gold / 'scripted.checks.json').write_text(checks.read_text(encoding='utf-8'), encoding='utf-8')
        elif checks.exists():
            data = json.loads(checks.read_text(encoding='utf-8'))
            replaced = {int(k) for k, v in as_read.items() if 'checks' in v}
            kept = [c for c in data.get('checks', []) if c.get('sentence') not in replaced]
            for number in sorted(replaced):
                kept += [dict(c, sentence=number) for c in as_read[str(number)]['checks']]
            data['checks'] = sorted(kept, key=lambda c: (c.get('sentence') or 0))
            if as_read:
                data['asRead'] = 'sentences %s follow gold/%s/as-read.json (what the speaker said), agreed before scoring' % (', '.join(sorted(as_read, key=int)), lang)
            (gold / 'scripted.checks.json').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print('%s: %d sentences -> %s%s%s' % (lang, len(lines), gold / 'scripted.txt', ' (+checks)' if checks.exists() else '',
              ' (as read: %s)' % ', '.join(sorted(as_read, key=int)) if as_read else ''))

if __name__ == '__main__':
    main()
