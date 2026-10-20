"""Bounded, read-only source verification. Hashes detect drift, not publisher trust."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath

IGNORED = {'.build', '.swiftpm', '__pycache__', '.git', '.DS_Store', 'build'}
MAX_FILES = 2048
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024


class IntegrityError(ValueError):
    pass


def regular_file(root, relative):
    if not isinstance(relative, str):
        raise IntegrityError('Snapshot contains an invalid relative path.')
    path = PurePosixPath(relative)
    if (not relative or path.is_absolute()
            or '\\' in relative or any(p in ('', '.', '..') for p in relative.split('/'))):
        raise IntegrityError('Snapshot contains an invalid relative path.')
    result = root
    for part in path.parts:
        result = result / part
        if result.is_symlink():
            raise IntegrityError('Source links are not allowed: ' + relative)
    if not result.is_file() or result.stat().st_size > MAX_FILE:
        raise IntegrityError('Source is missing, not a regular file, or too large: ' + relative)
    return result


def source_files(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise IntegrityError('Source directory is missing or linked.')
    files = {}
    total = 0
    for folder, directories, names in os.walk(root, followlinks=False):
        directories[:] = sorted(x for x in directories if x not in IGNORED)
        for name in directories:
            if (Path(folder) / name).is_symlink():
                raise IntegrityError('Source directory contains a link.')
        for name in sorted(names):
            if name in IGNORED:
                continue
            relative = (Path(folder) / name).relative_to(root).as_posix()
            path = regular_file(root, relative)
            total += path.stat().st_size
            if total > MAX_TOTAL or len(files) >= MAX_FILES:
                raise IntegrityError('Source exceeds the file-count or byte limit.')
            files[relative] = path
    return files


def fingerprints(root):
    return {name: hashlib.sha256(path.read_bytes()).hexdigest()
            for name, path in source_files(root).items()}


def read_snapshot(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise IntegrityError('Snapshot must be a regular file no larger than 1 MiB.')

    def unique_pairs(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise IntegrityError('Snapshot contains duplicate fields.')
            value[key] = item
        return value

    value = json.loads(path.read_text(), object_pairs_hook=unique_pairs)
    files = value.get('files') if isinstance(value, dict) else None
    if not isinstance(files, dict) or not files or len(files) > MAX_FILES:
        raise IntegrityError('Snapshot needs a bounded, nonempty file map.')
    for name, digest in files.items():
        if not isinstance(name, str) or not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise IntegrityError('Snapshot contains an invalid source digest.')
    return value


def verify(root, snapshot_path, allow_snapshot=False):
    root = Path(root)
    expected = read_snapshot(snapshot_path)['files']
    # Validate every recorded path before reading any recorded file.
    for name in expected:
        regular_file(root, name)
    actual = fingerprints(root)
    if allow_snapshot:
        actual.pop(Path(snapshot_path).relative_to(root).as_posix(), None)
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = sorted(name for name in expected.keys() & actual.keys() if expected[name] != actual[name])
    if missing or extra or changed:
        details = []
        for label, names in [('missing', missing), ('extra', extra), ('changed', changed)]:
            if names:
                details.append(label + ': ' + ', '.join(names[:5]) + (' …' if len(names) > 5 else ''))
        raise IntegrityError('Source snapshot differs (' + '; '.join(details) + '). Review the SDK update; the snapshot was not rewritten.')
    return len(expected)
