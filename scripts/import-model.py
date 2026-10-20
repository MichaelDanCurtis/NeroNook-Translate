#!/usr/bin/env python3
"""Import a pinned model checkpoint into Translate storage from a local folder (owner decision D-7).

Every file in the recipe is cloned (APFS clonefile, no extra space on the same volume), then its size
and SHA-256 are verified against the recipe before the folder is moved into place. Nothing is
downloaded, nothing outside the destination is written, and an existing destination is never overwritten.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, time
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--recipe', required=True, type=Path)
    parser.add_argument('--source', required=True, type=Path, help='Folder holding the checkpoint files named in the recipe')
    parser.add_argument('--destination', type=Path, help='Defaults to Translate plugin storage under Application Support')
    parser.add_argument('--receipt', type=Path, help='Write a JSON receipt (sizes, hashes, paths) here')
    args = parser.parse_args()
    recipe = json.load(open(args.recipe))
    for f in recipe['files']:
        name = f['name']
        if name.startswith('/') or '..' in name.split('/') or f['bytes'] <= 0 or len(f['sha256']) != 64:
            sys.exit('Invalid recipe entry: ' + name)
    source = args.source.resolve()
    tail = recipe['repository'].split('/')[-1] + '-' + recipe['revision']
    destination = args.destination or Path.home() / 'Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models' / tail
    if destination.exists() or destination.is_symlink():
        sys.exit('Destination already exists; nothing was changed: ' + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(destination.parent, 0o700)
    staging = destination.parent / ('.import-' + recipe['revision'][:12])
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(mode=0o700)
    results = []
    started = time.monotonic()
    try:
        for f in recipe['files']:
            src = source / f['name']
            dst = staging / f['name']
            if src.is_symlink() or not src.is_file():
                raise SystemExit('Source is missing or a link: ' + f['name'])
            dst.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['cp', '-c', str(src), str(dst)], check=True)
            digest = hashlib.sha256()
            size = 0
            with open(dst, 'rb') as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b''):
                    digest.update(chunk)
                    size += len(chunk)
            ok = size == f['bytes'] and digest.hexdigest() == f['sha256']
            results.append(dict(name=f['name'], bytes=size, sha256=digest.hexdigest(), verified=ok))
            if not ok:
                raise SystemExit('Verification failed for ' + f['name'] + '; the staged copy was removed')
        os.rename(staging, destination)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    receipt = dict(repository=recipe['repository'], revision=recipe['revision'], source=str(source), destination=str(destination),
                   method='cp -c (APFS clonefile) then SHA-256 verification of every file', importedAt=time.strftime('%Y-%m-%dT%H:%M:%S%z'),
                   seconds=round(time.monotonic() - started, 2), files=results)
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    print('Imported and verified ' + str(len(results)) + ' files into ' + str(destination))

if __name__ == '__main__':
    main()
