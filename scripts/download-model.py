#!/usr/bin/env python3
"""Download a pinned model checkpoint into Translate storage (owner decision D-7, with the owner's approval).

The recipe names the repository, the exact commit and every file with its size and SHA-256 where the Hub
publishes one (LFS files). Files are fetched from huggingface.co at that commit into a staging folder and
verified against every value the recipe has; values the recipe lacks (small non-LFS files) are recorded,
and the recipe is rewritten complete. An existing destination is never overwritten. Runs with `python3 -I`.
"""
import argparse, hashlib, json, os, shutil, sys, time, urllib.request
from pathlib import Path

def fetch(url, destination, expected_bytes):
    request = urllib.request.Request(url, headers={'User-Agent': 'NeroNook-Translate/0.1 (pinned model download)'})
    with urllib.request.urlopen(request, timeout=180) as response, open(destination, 'wb') as out:
        if response.status != 200:
            raise SystemExit('HTTP %d for %s' % (response.status, url))
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = response.read(1 << 20)
            if not chunk: break
            out.write(chunk); digest.update(chunk); size += len(chunk)
            if expected_bytes is not None and size > expected_bytes:
                raise SystemExit('File is larger than the recipe says: ' + url)
            if size > 8 * 1024 ** 3:
                raise SystemExit('File exceeds 8 GB: ' + url)
    return size, digest.hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--recipe', required=True, type=Path)
    parser.add_argument('--destination', type=Path, help='Defaults to Translate plugin storage under Application Support')
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    recipe = json.load(open(args.recipe))
    repository, revision, files = recipe['repository'], recipe['revision'], recipe['files']
    if not (len(revision) == 40 and all(c in '0123456789abcdef' for c in revision)):
        raise SystemExit('Recipe revision must be a full commit hash')
    for f in files:
        if f['name'].startswith('/') or '..' in f['name'].split('/') or (f.get('sha256') and len(f['sha256']) != 64):
            raise SystemExit('Invalid recipe entry: ' + f['name'])
    tail = repository.split('/')[-1] + '-' + revision
    destination = args.destination or Path.home() / 'Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models' / tail
    if destination.exists() or destination.is_symlink():
        raise SystemExit('Destination already exists; nothing was changed: ' + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(destination.parent, 0o700)
    staging = destination.parent / ('.download-' + revision[:12])
    if staging.exists(): shutil.rmtree(staging)
    staging.mkdir(mode=0o700)
    total = sum(f.get('bytes') or 0 for f in files)
    results = []
    started = time.monotonic()
    try:
        done = 0
        for f in files:
            target = staging / f['name']
            target.parent.mkdir(parents=True, exist_ok=True)
            url = 'https://huggingface.co/%s/resolve/%s/%s' % (repository, revision, f['name'])
            size, digest = fetch(url, target, f.get('bytes'))
            ok = (f.get('bytes') is None or size == f['bytes']) and (not f.get('sha256') or digest == f['sha256'])
            results.append(dict(name=f['name'], bytes=size, sha256=digest, verified=bool(f.get('sha256')) and ok, recorded=not f.get('sha256')))
            if not ok:
                raise SystemExit('Verification failed for %s (got %d bytes, %s); the staged download was removed' % (f['name'], size, digest[:12]))
            f['bytes'], f['sha256'] = size, digest
            done += size
            print('  %5.1f%%  %s' % (100.0 * done / max(total, 1), f['name']), flush=True)
        os.rename(staging, destination)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    args.recipe.write_text(json.dumps(recipe, indent=2) + '\n')   # now complete: every file has a hash
    receipt = dict(repository=repository, revision=revision, destination=str(destination),
                   method='https://huggingface.co/<repo>/resolve/<commit>/<file>; LFS files verified against the Hub SHA-256, other files recorded',
                   downloadedAt=time.strftime('%Y-%m-%dT%H:%M:%S%z'), seconds=round(time.monotonic() - started, 1), files=results)
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    print('Downloaded %d files (%.2f GB) into %s; %d verified against Hub hashes, %d recorded' % (
        len(results), sum(r['bytes'] for r in results) / 1e9, destination, sum(r['verified'] for r in results), sum(r['recorded'] for r in results)))

if __name__ == '__main__':
    main()
