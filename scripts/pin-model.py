#!/usr/bin/env python3
"""Write a pinned recipe for a Hugging Face model repository without downloading it.

The recipe records the exact commit, every file's size and, for LFS files, the SHA-256 the Hub publishes.
Small non-LFS files (configs, tokenizers) carry `sha256: null` until the first verified download or import
records their hash, after which the recipe is complete and reproducible. Only the Hub's metadata endpoint
is read. Runs with `python3 -I`.
"""
import argparse, json, sys, urllib.request
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('repository')
    parser.add_argument('--revision', default='main', help='Branch, tag or commit to pin; the commit hash is what gets written')
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--skip', action='append', default=['.gitattributes'], help='File names to leave out')
    args = parser.parse_args()
    url = 'https://huggingface.co/api/models/%s/revision/%s?blobs=true' % (args.repository, args.revision)
    request = urllib.request.Request(url, headers={'User-Agent': 'NeroNook-Translate/0.1 (pin model recipe)'})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.load(response)
    revision = data['sha']
    files = []
    for sibling in data.get('siblings', []):
        name = sibling['rfilename']
        if name in args.skip:
            continue
        lfs = sibling.get('lfs')
        files.append(dict(name=name, bytes=(lfs['size'] if lfs else sibling.get('size')), sha256=((lfs.get('sha256') or lfs.get('oid')) if lfs else None)))
    recipe = dict(repository=args.repository, revision=revision, license=data.get('cardData', {}).get('license') or (data.get('tags') and next((t[8:] for t in data['tags'] if t.startswith('license:')), None)),
                  pinnedAt=data.get('lastModified'), files=files)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(recipe, indent=2) + '\n')
    lfs_count = sum(1 for f in files if f['sha256'])
    print('Pinned %s @ %s: %d files, %d with Hub SHA-256, %.2f GB -> %s' % (args.repository, revision[:12], len(files), lfs_count,
          sum(f['bytes'] or 0 for f in files) / 1e9, args.out))

if __name__ == '__main__':
    main()
