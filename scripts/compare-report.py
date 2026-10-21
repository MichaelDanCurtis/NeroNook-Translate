#!/usr/bin/env python3
"""Score a comparison run against the plan's §6.1 pass bars.

Reads compare-receipt.json (or rows.jsonl while a run is still going) and prints Markdown: recognition
per candidate on the scripted items (clean and call-codec copies) with the per-category check scores,
paced delays, translation timings alone and under load, and a verdict line per candidate against the
bars. Items can be filtered (--items en/scripted) so a run whose natural transcript is wrong still
yields the scripted verdicts. Reads only. Run with python3 -I.

    python3 -I scripts/compare-report.py reports/m1c-engine-comparison-2026-10-20/run/compare [--items en/scripted]
"""
import argparse, json, sys
from collections import defaultdict
from pathlib import Path

BARS = {'wer_clean': 0.10, 'wer_codec': 0.15, 'cer_zh': 0.10, 'category': 0.95, 'final_s': 0.5}


def read_run(folder):
    receipt = folder / 'compare-receipt.json'
    if receipt.exists():
        d = json.loads(receipt.read_text())
        return d['recognition'], d['paced'], d['translation'], d.get('load', {}), d.get('notes', []), 'compare-receipt.json'
    rows = [json.loads(l) for l in (folder / 'rows.jsonl').read_text().splitlines() if l.strip()]
    pick = lambda kind: [r['row'] for r in rows if r['kind'] == kind]
    return pick('recognition'), pick('paced'), pick('translation'), {}, [], 'rows.jsonl (run still going)'


def rate(r):
    e = r['errorRate']
    return e['errors'] / e['total'] if e['total'] else 0.0


def frac(text):
    a, b = text.split('/')
    return (int(a), int(b))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('folder')
    parser.add_argument('--items', default='', help='comma-separated item prefixes to keep (default: all)')
    args = parser.parse_args()
    folder = Path(args.folder)
    recognition, paced, translation, load, notes, source = read_run(folder)
    keep = [p for p in args.items.split(',') if p]
    wanted = lambda item: not keep or any(item.split('@')[0].startswith(p) for p in keep)
    recognition = [r for r in recognition if wanted(r['item'])]
    paced = [r for r in paced if wanted(r['item'])]
    translation = [r for r in translation if wanted(r['item'])]
    print('# Comparison report · %s · source: %s%s\n' % (folder, source, (' · items: ' + ', '.join(keep)) if keep else ''))

    # Recognition per candidate: clean and codec, alone and under load
    by = defaultdict(dict)
    for r in recognition:
        if r.get('error'):
            continue
        kind = 'codec' if r['item'].endswith('@codec') else 'clean'
        by[r['recognizer']][(kind, r['underLoad'])] = r
    print('## Recognition, whole recording (phrase mode); check columns count the clean and codec copies together\n')
    print('| Candidate | Error rate clean | Error rate codec | Names | Numbers | Dates | Negation | Corrections | Checks | Clean, TTS running |')
    print('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    verdicts = {}
    for name in sorted(by):
        clean, codec, loaded = by[name].get(('clean', False)), by[name].get(('codec', False)), by[name].get(('clean', True))
        base = clean or codec
        cats = {}
        for c in ['name', 'number', 'date', 'negation', 'correction']:
            passed = total = 0
            for r in [x for x in [clean, codec] if x]:
                if c in r['byCategory']:
                    p, t = frac(r['byCategory'][c]); passed += p; total += t
            cats[c] = (passed, total)
        def cell(c):
            p, t = cats[c]
            return '%d/%d (%d%%)' % (p, t, round(100 * p / t)) if t else '–'
        checks = '%d/%d' % (sum(r['checksPassed'] for r in [clean, codec] if r), sum(r['checksTotal'] for r in [clean, codec] if r))
        print('| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
            name, '%.1f%%' % (100 * rate(clean)) if clean else '–', '%.1f%%' % (100 * rate(codec)) if codec else '–',
            cell('name'), cell('number'), cell('date'), cell('negation'), cell('correction'), checks,
            '%.1f%%' % (100 * rate(loaded)) if loaded else '–'))
        language = base['language'] if base else 'en'
        wer_bar = BARS['cer_zh'] if language == 'zh' else BARS['wer_clean']
        fails = []
        if clean and rate(clean) > wer_bar: fails.append('error rate clean %.1f%% > %d%%' % (100 * rate(clean), 100 * wer_bar))
        if codec and language != 'zh' and rate(codec) > BARS['wer_codec']: fails.append('error rate codec %.1f%% > %d%%' % (100 * rate(codec), 100 * BARS['wer_codec']))
        for c in ['name', 'number', 'date']:
            p, t = cats[c]
            if t and p / t < BARS['category']: fails.append('%ss %d%% < 95%%' % (c, round(100 * p / t)))
        verdicts[name] = fails

    # Paced
    pb = defaultdict(dict)
    for r in paced:
        if r.get('error'):
            continue
        kind = 'codec' if r['item'].endswith('@codec') else 'clean'
        pb[r['recognizer']][(kind, r['underLoad'])] = r
    if pb:
        print('\n## Paced, phrases fed in real time (clean recording)\n')
        print('| Candidate | Phrases | Coverage | Error rate | Final delay mean / p90 / max ms | First partial ms | Prefix re-run mean / max ms | Final p90, TTS running | Error rate codec |')
        print('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
        for name in sorted(pb):
            a, l, c = pb[name].get(('clean', False)), pb[name].get(('clean', True)), pb[name].get(('codec', False))
            if not a:
                continue
            print('| %s | %d | %d%% | %.1f%% | %d / %d / %d | %s | %s | %s | %s |' % (
                name, len(a['phrases']), round(100 * a.get('coverage', 0)), 100 * rate(a), a['meanFinalDelayMs'], a['p90FinalDelayMs'], a['maxFinalDelayMs'],
                a['meanPartialDelayMs'] if a.get('meanPartialDelayMs') is not None else '–',
                ('%d / %d' % (a['prefixRunMeanMs'], a['prefixRunMaxMs'] or 0)) if a.get('prefixRunMeanMs') is not None else '–',
                l['p90FinalDelayMs'] if l else '–', ('%.1f%%' % (100 * rate(c))) if c else '–'))
            worst = max(x['p90FinalDelayMs'] for x in [a, l] if x)
            if worst > BARS['final_s'] * 1000:
                verdicts.setdefault(name, []).append('final text p90 %d ms > %d ms' % (worst, BARS['final_s'] * 1000))

    # Translation timings
    tb = defaultdict(lambda: defaultdict(list))
    for r in translation:
        if r.get('error'):
            continue
        tb[r['translator']][(r['from'] + '→' + r['to'], r['underLoad'])].append(r)
    if tb:
        print('\n## Translation timing per line (meaning is rated by people from translation-review.md)\n')
        print('| Translator | Pair | Lines | Mean ms alone | Mean ms, TTS running | First token ms alone |')
        print('| --- | --- | --- | --- | --- | --- |')
        for name in sorted(tb):
            for pair in sorted({k[0] for k in tb[name]}):
                alone, loaded = tb[name].get((pair, False), []), tb[name].get((pair, True), [])
                first = [r['firstTokenMs'] for r in alone if r.get('firstTokenMs') is not None]
                print('| %s | %s | %d | %s | %s | %s |' % (name, pair, len(alone), round(sum(r['ms'] for r in alone) / len(alone)) if alone else '–',
                      round(sum(r['ms'] for r in loaded) / len(loaded)) if loaded else '–', round(sum(first) / len(first)) if first else '–'))

    if load:
        print('\n## Qwen TTS during the under-load passes\n')
        for k, v in sorted(load.items()):
            print('- %s: %d syntheses, RTF %.3f, first audio %d ms%s' % (k, v['syntheses'], v['realTimeFactor'], v['meanFirstAudioMs'], '' if v.get('errors', 0) == 0 and not v.get('stoppedEarly') else ' · NOT VALID'))

    print('\n## Against the §6.1 bars (names, numbers, dates ≥ 95%; error rate ≤ 10% clean, ≤ 15% codec; final text ≤ 0.5 s after the phrase)\n')
    for name in sorted(verdicts):
        fails = verdicts[name]
        print('- **%s**: %s' % (name, 'passes every bar measured here' if not fails else 'fails: ' + '; '.join(fails)))
    print('\nMeaning (translation), consistency and the listening set are rated by people; this report covers the measured bars only.')
    for note in notes[:2]:
        print('\n> ' + note)


if __name__ == '__main__':
    main()
