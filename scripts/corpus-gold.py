#!/usr/bin/env python3
"""Derive gold references from the corpus reading scripts (Fixtures/Corpus/scripts/*.md).

Each numbered sentence becomes one reference line in gold/<lang>/scripted.txt; the checks file
gold/<lang>/scripted.checks.json lists what the scoring looks for in a transcript, written by hand
next to this tool as scripts/corpus-checks/<lang>.json (accepted forms for names, numbers, dates,
negations and self-corrections). Reads scripts, writes gold only. Run with `python3 -I`.
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
        (gold / 'scripted.txt').write_text('\n'.join(text for _, text in lines) + '\n', encoding='utf-8')
        checks = ROOT / 'scripts/corpus-checks' / (lang + '.json')
        if checks.exists():
            (gold / 'scripted.checks.json').write_text(checks.read_text(encoding='utf-8'), encoding='utf-8')
        print('%s: %d sentences -> %s%s' % (lang, len(lines), gold / 'scripted.txt', ' (+checks)' if checks.exists() else ''))

if __name__ == '__main__':
    main()
