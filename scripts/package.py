#!/usr/bin/env python3
"""Stage, sign and package Translate.app for NeroNook without installing anything.

Run from the repository root with the standard library only:

    python3 -I scripts/package.py [--identity NAME] [--skip-build] [--out build/] [--dry-run]

Application plugins cannot go through Tools/nook.py (it refuses launchMode "application"), so this is the
packaging path. It mirrors NeroNook-Voice/scripts/package.py and reuses this repository's Tools/signing.py.

Steps (each is printed; the first failure prints "error: <reason>" and exits 1):

  1. Validate Resources/NookPlugin.json (id cafe.nero.plugin.translate, application launch mode) and
     Resources/Entitlements.plist (exactly com.apple.security.device.audio-input).
  2. Resolve the signing identity: --identity, else NERONOOK_SIGNING_IDENTITY, else the certificate of the
     installed Translate plugin (Tools/signing.py). Ad hoc signing is refused, as in Voice.
  3. Build: `swift build -c release` (TranslateApp, TranslateCheck) and
     `swift build -c release --package-path Engine` (TranslateEngine, TranslateASR). The Engine build uses
     --disable-automatic-resolution so Engine/Package.resolved, which mirrors Voice's pins, is never rewritten.
  4. Locate the products under .build/release and Engine/.build/release.
  5. `.build/release/TranslateCheck --manifest Resources/NookPlugin.json` must print OK.
  6. Stage Translate.app in a scratch folder inside --out:
       Contents/MacOS/TranslateApp
       Contents/Helpers/TranslateEngine, TranslateASR   (stripped with strip -S -x)
       Contents/Helpers/mlx.metallib                    (the MLX shader library the Engine build produced)
       Contents/Resources/NookPlugin.json
       Contents/Resources/Models/*.json                 (recipes only, never weights)
       Contents/Resources/Licenses/                     (only if Resources/Licenses exists)
       Contents/Resources/NookPluginSDK_NookPluginSDK.bundle   (only if the release build produced it)
       Contents/Info.plist
     Never staged: model weights, recordings, Fixtures/, reports/, .build contents. Any such path in the
     staged tree is refused.
  7. Sign inside out: mlx.metallib, then each helper with `--options runtime`, then the app with
     `--options runtime --entitlements Resources/Entitlements.plist`.
  8. Verify: Tools/signing.verify_update against the installed reference (when one exists), the hardened
     runtime flag, the audio-input entitlement in the signature, and `codesign --verify --deep --strict`.
     Refuse more than 256 MiB, more than 4096 regular files, or any symlink (the host's package rules).
  9. Write <out>/cafe.nero.plugin.translate-<version>-<sha256[:12] of the signed app>.app, a `ditto -c -k`
     zip beside it and <out>/latest-package.txt. Existing outputs are never overwritten.

--dry-run performs every check that does not need a build, a signature or a write (manifest, entitlements,
tools, identity resolution, product discovery, TranslateCheck, the staging plan and its size and file
limits), prints what each remaining step would do, and exits 1 if any check found a problem. Missing
products are reported plainly, not as a crash.

--skip-build uses the products already under .build. It warns when a source file is newer than a product.

Nothing here installs a plugin, restarts the host or touches Voice. The script does not commit anything.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import List, Optional, Tuple
from xml.parsers.expat import ExpatError

sys.dont_write_bytecode = True  # importing Tools/signing.py must not leave a __pycache__ behind

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'Engine'
MANIFEST = ROOT / 'Resources' / 'NookPlugin.json'
ENTITLEMENTS = ROOT / 'Resources' / 'Entitlements.plist'
MODELS = ROOT / 'Resources' / 'Models'
LICENSES = ROOT / 'Resources' / 'Licenses'
SIGNING = ROOT / 'Tools' / 'signing.py'
BIN = ROOT / '.build' / 'release'
ENGINE_BIN = ENGINE / '.build' / 'release'

EXPECTED_ID = 'cafe.nero.plugin.translate'
APP_NAME = 'Translate.app'
DISPLAY_NAME = 'Translate'
EXECUTABLE = 'TranslateApp'
HELPERS = ('TranslateEngine', 'TranslateASR')
SDK_BUNDLE = 'NookPluginSDK_NookPluginSDK.bundle'
METALLIB_NAME = 'mlx.metallib'  # the name MLX looks for beside the helper executables
EXPECTED_ENTITLEMENTS = {'com.apple.security.device.audio-input': True}

MAX_BYTES = 256 * 1024 * 1024  # host limits for native plugin packages (NATIVE-PLUGINS.md)
MAX_FILES = 4096
MAX_MANIFEST_BYTES = 8192  # TranslateCheck's own limit
MAX_RECIPE_BYTES = 1024 * 1024
VERSION = re.compile(r'[0-9]+(\.[0-9]+){1,3}([-+][0-9A-Za-z.-]+)?')
MACHO_MAGIC = {bytes.fromhex(x) for x in ('cffaedfe', 'feedfacf', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}

# Things that must never end up inside the package, wherever they sit in the staged tree.
FORBIDDEN_NAMES = {'.build', '.git', '.swiftpm', 'Fixtures', 'reports', '__pycache__', '.DS_Store'}
FORBIDDEN_SUFFIXES = ('.safetensors', '.gguf', '.ckpt', '.pt', '.pth', '.onnx', '.npz', '.bin', '.dsym',
                      '.wav', '.flac', '.m4a', '.mp3', '.caf', '.aif', '.aiff', '.ogg', '.opus')

STEPS = (
    'Validate the manifest and entitlements',
    'Check tools and resolve the signing identity',
    'Build the release products',
    'Locate the built products',
    'Validate the manifest with TranslateCheck',
    'Stage Translate.app',
    'Strip and sign (metallib, helpers, then the app)',
    'Verify the signature and the package limits',
    'Write the package',
)

USAGE_TEXT = {
    'NSMicrophoneUsageDescription':
        'Translate listens to your selected microphone only while a translated call is running, so it can caption '
        'and translate what you say. Audio is processed on this Mac and is kept only if you choose to save the meeting.',
    'NSSpeechRecognitionUsageDescription':
        'Translate turns speech into captions with on-device Apple speech recognition so it can translate them.',
    'NSAudioCaptureUsageDescription':
        'Translate captures the audio of the call app you choose, so it can caption and translate what the other '
        'person says. Audio is processed on this Mac.',
}


class Failure(Exception):
    """A packaging failure; the message is the one-line reason printed after "error:"."""


def say(text: str = '') -> None:
    print(text, flush=True)


def step(number: int) -> None:
    say(f'[{number}/{len(STEPS)}] {STEPS[number - 1]}')


def oneline(text, limit: int = 400) -> str:
    text = ' '.join(str(text).split())
    return text if len(text) <= limit else text[:limit - 3] + '...'


def mib(size: int) -> str:
    return f'{size / 1048576:.1f} MiB' if size >= 1048576 else f'{size / 1024:.1f} KiB'


def rel(path: Path) -> str:
    try:
        return str(Path(path).relative_to(ROOT))
    except ValueError:
        return str(path)


class Context:
    """Failure policy. A real run stops at the first problem; a dry run records each one and carries on."""

    def __init__(self, dry_run: bool) -> None:
        self.dry = dry_run
        self.problems: List[str] = []

    def check(self, ok: bool, message: str) -> bool:
        if ok:
            return True
        if not self.dry:
            raise Failure(message)
        self.problems.append(message)
        say(f'  PROBLEM: {message}')
        return False

    def attempt(self, action):
        try:
            return action()
        except (Failure, RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
            if not self.dry:
                raise
            self.check(False, oneline(error))
            return None


def run(args, *, capture: bool = False, timeout: Optional[float] = None, what: Optional[str] = None):
    shown = ' '.join(shlex.quote(rel(a) if isinstance(a, Path) else str(a)) for a in args)
    say(f'  $ {shown}')
    try:
        result = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=capture, text=capture, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Failure(f'{what or Path(str(args[0])).name} did not finish within {timeout:g} s')
    except OSError as error:
        raise Failure(f'cannot run {Path(str(args[0])).name}: {error.strerror or error}')
    if result.returncode:
        detail = oneline((result.stderr or result.stdout or '')[-600:]) if capture else 'see the output above'
        raise Failure(f'{what or Path(str(args[0])).name} failed with exit {result.returncode}: {detail}')
    return result


def load_signing():
    if not SIGNING.is_file():
        raise Failure('Tools/signing.py is missing')
    spec = importlib.util.spec_from_file_location('translate_signing', SIGNING)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for name in ('SigningError', 'resolve', 'sign', 'verify_update', 'installed_reference', 'command'):
        if not hasattr(module, name):
            raise Failure(f'Tools/signing.py has no {name}; its API changed')
    return module


def load_manifest() -> Tuple[bytes, dict]:
    try:
        data = MANIFEST.read_bytes()
    except OSError as error:
        raise Failure(f'cannot read {rel(MANIFEST)}: {error.strerror}')
    if len(data) > MAX_MANIFEST_BYTES:
        raise Failure(f'{rel(MANIFEST)} exceeds the {MAX_MANIFEST_BYTES}-byte limit TranslateCheck enforces')
    try:
        value = json.loads(data)
    except ValueError as error:
        raise Failure(f'{rel(MANIFEST)} is not valid JSON: {error}')
    if not isinstance(value, dict):
        raise Failure(f'{rel(MANIFEST)} is not a JSON object')
    if value.get('id') != EXPECTED_ID:
        raise Failure(f"manifest id is {value.get('id')!r}, expected {EXPECTED_ID}")
    version = value.get('version')
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise Failure(f'manifest version {version!r} is not a dotted number')
    if value.get('launchMode') != 'application':
        raise Failure('manifest launchMode must be "application"')
    if value.get('apiVersion') != 1:
        raise Failure('manifest apiVersion must be 1')
    return data, value


def load_entitlements() -> None:
    try:
        value = plistlib.loads(ENTITLEMENTS.read_bytes())
    except (OSError, ValueError, ExpatError, plistlib.InvalidFileException) as error:
        raise Failure(f'cannot read {rel(ENTITLEMENTS)}: {oneline(getattr(error, "strerror", None) or error)}')
    if value != EXPECTED_ENTITLEMENTS:
        raise Failure(f'{rel(ENTITLEMENTS)} must contain exactly {sorted(EXPECTED_ENTITLEMENTS)}; found {sorted(value)}')


def info_plist(manifest: dict) -> dict:
    return dict(
        CFBundleDevelopmentRegion='en',
        CFBundleIdentifier=manifest['id'],
        CFBundleName=DISPLAY_NAME,
        CFBundleDisplayName=DISPLAY_NAME,
        CFBundleExecutable=EXECUTABLE,
        CFBundlePackageType='APPL',
        CFBundleInfoDictionaryVersion='6.0',
        CFBundleShortVersionString=manifest['version'],
        CFBundleVersion=manifest['version'],
        LSUIElement=True,
        LSMinimumSystemVersion='26.0',
        NSHighResolutionCapable=True,
        **USAGE_TEXT,
    )


# ---------------------------------------------------------------------------------------------- products

@dataclasses.dataclass
class Products:
    app: Optional[Path] = None
    check: Optional[Path] = None
    engine: Optional[Path] = None
    asr: Optional[Path] = None
    metallib: Optional[Path] = None
    sdk_bundle: Optional[Path] = None


def is_macho(path: Path) -> bool:
    try:
        with open(path, 'rb') as handle:
            return handle.read(4) in MACHO_MAGIC
    except OSError:
        return False


def locate_executable(ctx: Context, label: str, path: Path, hint: str) -> Optional[Path]:
    if path.is_symlink():
        ctx.check(False, f'{label} is a symlink: {rel(path)}')
    elif not path.is_file():
        ctx.check(False, f'{label} is missing: {rel(path)} ({hint})')
    elif not is_macho(path) or not os.access(path, os.X_OK):
        ctx.check(False, f'{label} is not an executable Mach-O file: {rel(path)}')
    else:
        say(f'  {label}: {rel(path)} ({mib(path.stat().st_size)})')
        return path
    return None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def locate_metallib(ctx: Context) -> Optional[Path]:
    """The Engine build leaves default.metallib inside mlx-swift_Cmlx.bundle (Voice copies it as mlx.metallib)."""
    found = sorted(ENGINE_BIN.glob('*.metallib'))
    for bundle in sorted(ENGINE_BIN.glob('*.bundle')):
        found += sorted(bundle.rglob('*.metallib'))
    found = [p for p in found if p.is_file() and not p.is_symlink()]
    if not found:
        ctx.check(False, f'no *.metallib next to the Engine helpers under {rel(ENGINE_BIN)} (build Engine; MLX cannot run without it)')
        return None
    if len({sha256_file(p) for p in found}) > 1:
        ctx.check(False, 'the Engine build produced different *.metallib files: ' + ', '.join(rel(p) for p in found))
        return None
    say(f'  metallib: {rel(found[0])} ({mib(found[0].stat().st_size)}), staged as Contents/Helpers/{METALLIB_NAME}')
    return found[0]


def locate_products(ctx: Context) -> Products:
    products = Products()
    products.app = locate_executable(ctx, EXECUTABLE, BIN / EXECUTABLE, 'swift build -c release')
    products.check = locate_executable(ctx, 'TranslateCheck', BIN / 'TranslateCheck', 'swift build -c release')
    products.engine = locate_executable(ctx, 'TranslateEngine', ENGINE_BIN / 'TranslateEngine',
                                        'swift build -c release --package-path Engine')
    products.asr = locate_executable(ctx, 'TranslateASR', ENGINE_BIN / 'TranslateASR',
                                     'swift build -c release --package-path Engine')
    products.metallib = locate_metallib(ctx)
    bundle = BIN / SDK_BUNDLE
    if bundle.is_dir() and not bundle.is_symlink():
        products.sdk_bundle = bundle
        say(f'  SDK resource bundle: {rel(bundle)}')
    else:
        say(f'  SDK resource bundle: {SDK_BUNDLE} not produced by this build; not staged')
    return products


def newest_source(paths) -> Tuple[float, Optional[Path]]:
    best: Tuple[float, Optional[Path]] = (0.0, None)
    for base in paths:
        if base.is_file():
            candidates = [base]
        elif base.is_dir():
            candidates = [p for p in base.rglob('*') if p.is_file() and '.build' not in p.parts]
        else:
            continue
        for candidate in candidates:
            mtime = candidate.stat().st_mtime
            if mtime > best[0]:
                best = (mtime, candidate)
    return best


def warn_if_stale(products: Products) -> None:
    groups = (
        (products.app, [ROOT / 'Sources', ROOT / 'Package.swift', ROOT / 'Vendor' / 'NookPluginSDK' / 'Sources']),
        (products.engine, [ENGINE / 'Sources', ENGINE / 'Package.swift']),
        (products.asr, [ENGINE / 'Sources', ENGINE / 'Package.swift']),
    )
    for product, sources in groups:
        if product is None:
            continue
        mtime, newest = newest_source(sources)
        if newest is not None and mtime > product.stat().st_mtime:
            say(f'  warning: {rel(newest)} is newer than {rel(product)}; omit --skip-build to rebuild')


# ---------------------------------------------------------------------------------------------- staging

@dataclasses.dataclass
class Entry:
    dest: str                            # path inside the app, POSIX style
    src: Optional[Path] = None           # file or folder to copy
    data: Optional[bytes] = None         # or literal contents
    executable: bool = False
    strip: bool = False
    sign: Optional[Tuple[str, ...]] = None   # codesign options for this item alone; None = signed with the app


def recipe_entries(ctx: Context) -> List[Entry]:
    entries: List[Entry] = []
    if not MODELS.is_dir():
        ctx.check(False, f'{rel(MODELS)} is missing')
        return entries
    for path in sorted(MODELS.iterdir()):
        if path.suffix != '.json' or path.is_symlink() or not path.is_file():
            say(f'  ignoring {rel(path)} (only regular *.json recipes are packaged)')
            continue
        if path.stat().st_size > MAX_RECIPE_BYTES:
            ctx.check(False, f'{rel(path)} is larger than {MAX_RECIPE_BYTES} bytes; recipes are small JSON, weights are never packaged')
            continue
        try:
            ok = isinstance(json.loads(path.read_bytes()), dict)
        except ValueError:
            ok = False
        if ctx.check(ok, f'{rel(path)} is not a JSON object'):
            entries.append(Entry(f'Contents/Resources/Models/{path.name}', src=path))
    ctx.check(bool(entries), f'no model recipes (*.json) in {rel(MODELS)}')
    return entries


def make_entries(ctx: Context, products: Products, manifest_bytes: bytes, manifest: dict) -> List[Entry]:
    entries: List[Entry] = []
    if products.app:
        entries.append(Entry(f'Contents/MacOS/{EXECUTABLE}', src=products.app, executable=True))
    for name, path in (('TranslateEngine', products.engine), ('TranslateASR', products.asr)):
        if path:
            entries.append(Entry(f'Contents/Helpers/{name}', src=path, executable=True, strip=True, sign=('--options', 'runtime')))
    if products.metallib:
        entries.append(Entry(f'Contents/Helpers/{METALLIB_NAME}', src=products.metallib, sign=()))
    entries.append(Entry('Contents/Resources/NookPlugin.json', data=manifest_bytes))
    entries.extend(recipe_entries(ctx))
    if LICENSES.is_dir():
        entries.append(Entry('Contents/Resources/Licenses', src=LICENSES))
    else:
        say(f'  {rel(LICENSES)} does not exist; no licenses folder is staged')
    if products.sdk_bundle:
        entries.append(Entry(f'Contents/Resources/{SDK_BUNDLE}', src=products.sdk_bundle))
    entries.append(Entry('Contents/Info.plist', data=plistlib.dumps(info_plist(manifest))))
    return entries


def forbidden_reason(relative: str) -> Optional[str]:
    parts = PurePosixPath(relative).parts
    for part in parts:
        if part in FORBIDDEN_NAMES or part.lower().endswith('.dsym'):
            return f'{part} must not be packaged'
    if parts and parts[-1].lower().endswith(FORBIDDEN_SUFFIXES):
        return f'{parts[-1]} looks like model weights, audio or debug data'
    return None


@dataclasses.dataclass
class Measure:
    files: int = 0
    size: int = 0
    symlinks: List[str] = dataclasses.field(default_factory=list)
    forbidden: List[str] = dataclasses.field(default_factory=list)


def measure(entry: Entry) -> Measure:
    result = Measure()
    if entry.data is not None:
        result.files, result.size = 1, len(entry.data)
    elif entry.src is not None and entry.src.is_dir():
        for folder, folders, files in os.walk(entry.src):
            for name in folders + files:
                path = Path(folder) / name
                if path.is_symlink():
                    result.symlinks.append(f'{entry.dest}/{path.relative_to(entry.src).as_posix()}')
            for name in files:
                path = Path(folder) / name
                if path.is_symlink():
                    continue
                result.files += 1
                result.size += path.lstat().st_size
                inside = f'{entry.dest}/{path.relative_to(entry.src).as_posix()}'
                reason = forbidden_reason(inside)
                if reason:
                    result.forbidden.append(f'{inside}: {reason}')
    elif entry.src is not None:
        if entry.src.is_symlink():
            result.symlinks.append(entry.dest)
        else:
            result.files, result.size = 1, entry.src.stat().st_size
    reason = forbidden_reason(entry.dest) if entry.src is None or not entry.src.is_dir() else None
    if reason:
        result.forbidden.append(f'{entry.dest}: {reason}')
    return result


def report_plan(ctx: Context, entries: List[Entry]) -> None:
    total_files, total_size = 1, 0  # one for _CodeSignature/CodeResources
    for entry in entries:
        m = measure(entry)
        total_files += m.files
        total_size += m.size
        origin = 'generated' if entry.data is not None else rel(entry.src) if entry.src else '?'
        suffix = f" ({m.files} file{'' if m.files == 1 else 's'})" if entry.src is not None and entry.src.is_dir() else ''
        notes = ' [strip, sign --options runtime]' if entry.strip else ' [sign]' if entry.sign is not None else ''
        say(f'  {entry.dest}{suffix}  {mib(m.size)}  <- {origin}{notes}')
        for link in m.symlinks:
            ctx.check(False, f'symlink in the package: {link}')
        for item in m.forbidden:
            ctx.check(False, f'forbidden content: {item}')
    say(f'  staged total: {total_files} files, {mib(total_size)} before stripping (limits {MAX_FILES} files, {mib(MAX_BYTES)})')
    ctx.check(total_files <= MAX_FILES and total_size <= MAX_BYTES,
              f'package would exceed the host limit of {MAX_FILES} files and {mib(MAX_BYTES)}')


def stage(app: Path, entries: List[Entry]) -> None:
    ignore = shutil.ignore_patterns('.DS_Store', '__pycache__', '*.dSYM')
    for entry in entries:
        target = app / entry.dest
        target.parent.mkdir(parents=True, exist_ok=True)
        if entry.data is not None:
            target.write_bytes(entry.data)
        elif entry.src is not None and entry.src.is_dir():
            shutil.copytree(entry.src, target, symlinks=True, ignore=ignore)
        else:
            shutil.copy2(entry.src, target)
        if entry.executable:
            target.chmod(0o755)
        elif target.is_file():
            target.chmod(0o644)


def inspect_tree(app: Path) -> Tuple[int, int]:
    """Count regular files and bytes; refuse symlinks and forbidden content in the staged tree."""
    files = size = 0
    for folder, folders, names in os.walk(app):
        for name in folders + names:
            path = Path(folder) / name
            if path.is_symlink():
                raise Failure(f'symlink in the package: {path.relative_to(app).as_posix()}')
        for name in names:
            path = Path(folder) / name
            relative = path.relative_to(app).as_posix()
            reason = forbidden_reason(relative)
            if reason:
                raise Failure(f'forbidden content in the package: {relative}: {reason}')
            files += 1
            size += path.lstat().st_size
    return files, size


def enforce_limits(app: Path) -> Tuple[int, int]:
    files, size = inspect_tree(app)
    if files > MAX_FILES or size > MAX_BYTES:
        raise Failure(f'package is {files} files and {mib(size)}; the host limit is {MAX_FILES} files and {mib(MAX_BYTES)}')
    return files, size


def tree_digest(app: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted((p for p in app.rglob('*') if p.is_file()), key=lambda p: p.relative_to(app).as_posix()):
        executable = b'x' if path.stat().st_mode & stat.S_IXUSR else b'-'
        digest.update(path.relative_to(app).as_posix().encode() + b'\0' + executable + b'\0')
        with open(path, 'rb') as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b''):
                digest.update(chunk)
        digest.update(b'\0')
    return digest.hexdigest()


# ---------------------------------------------------------------------------------------------- signing

def signed_entitlements(signing, app: Path) -> dict:
    output = signing.command(['/usr/bin/codesign', '-d', '--xml', '--entitlements', '-', app])
    match = re.search(r'<\?xml.*?</plist>', output, re.S)
    return plistlib.loads(match.group(0).encode()) if match else {}


def strip_and_sign(signing, identity: str, app: Path, entries: List[Entry]) -> None:
    for entry in entries:
        if entry.strip:
            run(['xcrun', 'strip', '-S', '-x', app / entry.dest], what=f'strip {entry.dest}')
    for entry in sorted((e for e in entries if e.sign is not None), key=lambda e: e.sign != ()):  # metallib first
        say(f'  sign {entry.dest} {" ".join(entry.sign)}'.rstrip())
        signing.sign(app / entry.dest, identity, *entry.sign)
    say(f'  sign {APP_NAME} --options runtime --entitlements {rel(ENTITLEMENTS)}')
    signing.sign(app, identity, '--options', 'runtime', '--entitlements', ENTITLEMENTS)


def verify_signature(signing, app: Path, reference: Optional[Path]) -> None:
    candidate = signing.verify_update(app, reference)
    if reference:
        say(f'  matches the installed signing requirement ({reference})')
    else:
        say('  no installed Translate plugin to compare with (first install)')
    if candidate.get('hardenedRuntime') is False:
        raise Failure('the signed app lacks the hardened runtime flag')
    if candidate.get('Identifier') != EXPECTED_ID:
        raise Failure(f"signed identifier is {candidate.get('Identifier')!r}, expected {EXPECTED_ID}")
    if signed_entitlements(signing, app) != EXPECTED_ENTITLEMENTS:
        raise Failure('the signature does not carry exactly the audio-input entitlement')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], capture=True, what='codesign --verify --deep --strict')
    say(f'  signed by {candidate.get("Authority")}; hardened runtime on; audio-input entitlement present')


# ---------------------------------------------------------------------------------------------- pipeline

def check_output_dir(ctx: Context, output: Path) -> None:
    probe = output
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    ctx.check(probe.is_dir() and os.access(probe, os.W_OK), f'cannot create or write the output folder {output}')


def build_package(ctx: Context, signing, identity: str, reference: Optional[Path], entries: List[Entry],
                  manifest: dict, output: Path) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.translate-pack-', dir=output) as scratch:
        app = Path(scratch) / APP_NAME
        stage(app, entries)
        files, size = enforce_limits(app)
        say(f'  staged {files} files, {mib(size)}')
        step(7)
        strip_and_sign(signing, identity, app, entries)
        step(8)
        verify_signature(signing, app, reference)
        files, size = enforce_limits(app)
        say(f'  limits ok: {files} files, {mib(size)}, no symlinks')
        step(9)
        digest = tree_digest(app)[:12]
        stem = f"{manifest['id']}-{manifest['version']}-{digest}"
        final, archive = output / f'{stem}.app', output / f'{stem}.zip'
        for path in (final, archive):
            if path.exists():
                raise Failure(f'output already exists; preserved it: {path}')
        staged = Path(scratch) / f'{stem}.app'
        app.rename(staged)
        zipped = Path(scratch) / f'{stem}.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', staged, zipped], what='ditto')
        staged.rename(final)
        zipped.rename(archive)
        pointer = output / 'latest-package.txt'
        temporary = output / '.latest-package.txt.tmp'
        temporary.write_text(str(final) + '\n')
        os.replace(temporary, pointer)
        say(f'  app: {final}')
        say(f'  zip: {archive}')
        say(f'  pointer: {pointer}')
        return final


def pipeline(ctx: Context, args) -> int:
    if sys.platform != 'darwin':
        raise Failure('packaging needs macOS (codesign, ditto, xcrun)')
    output = args.out.expanduser().resolve()
    say(f'Translate packaging {"(dry run: nothing is built, signed or written)" if ctx.dry else ""}'.rstrip())
    say(f'  repository: {ROOT}')
    say(f'  output: {output}')

    step(1)
    manifest_bytes, manifest = load_manifest()
    load_entitlements()
    say(f"  {manifest['id']} {manifest['version']}, launchMode application; entitlements: audio-input only")

    step(2)
    tools = ['xcrun', 'ditto', 'codesign'] + ([] if args.skip_build else ['swift'])
    missing = [t for t in tools if not shutil.which(t)]
    ctx.check(not missing, 'missing tools on PATH: ' + ', '.join(missing))
    signing = ctx.attempt(load_signing)
    resolved = ctx.attempt(lambda: signing.resolve(EXPECTED_ID, args.identity)) if signing else None
    identity, reference = resolved if resolved else (None, None)
    if identity:
        source = '--identity' if args.identity else 'NERONOOK_SIGNING_IDENTITY' if os.environ.get('NERONOOK_SIGNING_IDENTITY') \
            else 'the installed Translate plugin'
        say(f'  identity: {identity} (from {source}); reference: {reference or "none installed"}')
    check_output_dir(ctx, output)

    step(3)
    if args.skip_build:
        say('  skipped (--skip-build): using the products already built')
    elif ctx.dry:
        say('  would run: swift build -c release')
        say('  would run: swift build -c release --package-path Engine --disable-automatic-resolution')
    else:
        run(['swift', 'build', '-c', 'release'], what='swift build (app package)')
        run(['swift', 'build', '-c', 'release', '--package-path', 'Engine', '--disable-automatic-resolution'],
            what='swift build (Engine package)')

    step(4)
    products = locate_products(ctx)
    if args.skip_build:
        warn_if_stale(products)

    step(5)
    if products.check:
        result = ctx.attempt(lambda: run([products.check, '--manifest', 'Resources/NookPlugin.json'],
                                         capture=True, timeout=120, what='TranslateCheck --manifest'))
        if result is not None:
            first = (result.stdout.strip().splitlines() or [''])[0]
            if ctx.check(first.startswith('OK') and manifest['id'] in first, f'TranslateCheck did not print OK: {oneline(result.stdout)}'):
                say(f'  {first}')
    else:
        say('  TranslateCheck is not built; cannot validate')

    if ctx.dry:
        step(6)
        entries = make_entries(ctx, products, manifest_bytes, manifest)
        report_plan(ctx, entries)
        step(7)
        say('  would strip TranslateEngine and TranslateASR, sign mlx.metallib, sign both helpers with --options runtime,')
        say(f'  then sign {APP_NAME} with --options runtime --entitlements {rel(ENTITLEMENTS)}')
        step(8)
        say('  would run verify_update against the installed reference, check the hardened runtime flag and the')
        say('  audio-input entitlement, run codesign --verify --deep --strict and re-check the 256 MiB / 4096 file / symlink limits')
        step(9)
        say(f'  would write {output}/{EXPECTED_ID}-{manifest["version"]}-<sha256[:12] of the signed app>.app')
        say(f'  would write the matching .zip (ditto -c -k) and {output}/latest-package.txt; existing outputs are never overwritten')
        if ctx.problems:
            say(f'dry run: {len(ctx.problems)} problem(s) would stop a real run:')
            for problem in ctx.problems:
                say(f'  - {problem}')
            return 1
        say('dry run: every check passed; nothing was built, signed or written')
        return 0

    step(6)
    entries = make_entries(ctx, products, manifest_bytes, manifest)
    report_plan(ctx, entries)
    final = build_package(ctx, signing, identity, reference, entries, manifest, output)
    say(f'Packaged: {final}')
    return 0


def parse(argv) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], epilog='See the module docstring for the steps.')
    parser.add_argument('--identity', help='signing certificate name; default NERONOOK_SIGNING_IDENTITY, then the installed Translate plugin\'s certificate (ad hoc is refused)')
    parser.add_argument('--skip-build', action='store_true', help='use the products already under .build and Engine/.build')
    parser.add_argument('--out', type=Path, default=ROOT / 'build', help='output folder (default: build/ in the repository)')
    parser.add_argument('--dry-run', action='store_true', help='run every check that needs no build, signature or write; print the rest')
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse(argv)
    ctx = Context(args.dry_run)
    try:
        return pipeline(ctx, args)
    except Failure as error:
        print(f'error: {oneline(error)}', file=sys.stderr)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'error: {oneline(error)}', file=sys.stderr)
    except KeyboardInterrupt:
        print('error: interrupted; nothing was installed and no existing package was changed', file=sys.stderr)
        return 130
    if ctx.dry and ctx.problems:
        print(f'dry run: {len(ctx.problems)} problem(s) recorded before it stopped:', file=sys.stderr)
        for problem in ctx.problems:
            print(f'  - {problem}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
