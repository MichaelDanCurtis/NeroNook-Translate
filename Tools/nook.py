#!/usr/bin/env python3
"""Local authoring tools for independent NeroNook native starter projects."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parent))
from signing import resolve as resolve_signing, sign, verify_update, verify_distribution, SigningError
from integrity import verify as verify_sources, fingerprints, IntegrityError

HERE = Path(__file__).resolve().parent
FEATURES = ['dashboard-v1', 'panels-v1', 'control-cards-v1', 'actions-v1', 'actions-long-running-v1', 'forms-v1', 'custom-views-v1']
MAX_LINE = 128 * 1024

class Problem(Exception):
    pass

def kit_metadata():
    value = json.loads((HERE/'kit.json').read_text())
    if value.get('apiVersion') != 1 or value.get('distribution') != 'local-preview':
        raise Problem('Unsupported creator kit metadata.')
    return value

def verify_project_sdk(project):
    count = verify_sources(project/'Vendor/NookPluginSDK', project/'SDK-SNAPSHOT.json')
    print('PASS: ' + str(count) + ' vendored SDK files match the recorded snapshot.')
    return count

def verify_creator_source():
    if HERE.name == 'Tools':
        verify_project_sdk(HERE.parent)
    elif (HERE.parent/'KIT-SNAPSHOT.json').exists():
        verify_sources(HERE.parent, HERE.parent/'KIT-SNAPSHOT.json', allow_snapshot=True)

def build_sdk():
    value = os.environ.get('NERONOOK_SDK_PATH')
    return Path(value).resolve() if value else Path(run(['xcrun','--sdk','macosx','--show-sdk-path'],capture=True).decode().strip()).resolve()

def sdk_options():
    return ['--sdk',build_sdk()] if os.environ.get('NERONOOK_SDK_PATH') else []

def write_report(path, value):
    path = path.absolute()
    if path.is_symlink():
        raise Problem('Report destination must not be a link.')
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', prefix='.nook-report-', dir=path.parent, delete=False) as temporary:
        name = Path(temporary.name)
        json.dump(value, temporary, indent=2); temporary.write('\n')
    try:
        os.replace(name, path)
    finally:
        name.unlink(missing_ok=True)

def doctor(root, report=None):
    if report:
        try:
            relative = report.resolve().relative_to(root.resolve())
        except ValueError:
            relative = None
        if relative is not None and (not relative.parts or relative.parts[0] != 'build'):
            raise Problem('Keep reports outside the source tree or under build/. No source was overwritten.')
    checks = []
    def check(name, action):
        try:
            detail = action()
            checks.append(dict(name=name, status='pass', detail=detail))
        except (Problem, IntegrityError, SigningError, OSError, ValueError, KeyError, TypeError) as error:
            # A source check's bounded relative-file diagnostics are useful;
            # filesystem/tool errors must not dump paths, environment or payloads.
            detail = str(error) if isinstance(error, (Problem, IntegrityError)) else 'Check failed; inspect the selected source or development tool.'
            checks.append(dict(name=name, status='fail', detail=detail))
    is_kit = (root/'KIT-SNAPSHOT.json').is_file()
    if is_kit:
        check('Kit source snapshot', lambda: str(verify_sources(root, root/'KIT-SNAPSHOT.json', allow_snapshot=True)) + ' files match.')
    else:
        check('Vendored SDK snapshot', lambda: str(verify_sources(root/'Vendor/NookPluginSDK', root/'SDK-SNAPSHOT.json')) + ' files match.')
        check('Project manifest', lambda: 'Identity ' + manifest(root)['id'] + '; full SDK validation still runs during validate/test.')
        def package_source():
            if not (root/'Package.swift').is_file() or (root/'Package.swift').is_symlink():
                raise Problem('Missing regular Package.swift.')
            return 'Swift package present.'
        check('Standalone project', package_source)
    def mac():
        version = platform.mac_ver()[0]
        if platform.system() != 'Darwin' or not version or int(version.split('.')[0]) < 14:
            raise Problem('Development requires macOS 14 or newer.')
        return 'macOS ' + version
    def swift():
        output = run(['swift', '--version'], capture=True).decode(errors='replace')
        match = re.search(r'Swift version (\d+)\.([\d.]+)', output)
        if not match or int(match[1]) < 6:
            raise Problem('Swift 6 or newer is required.')
        return 'Swift ' + match[1] + '.' + match[2]
    def sdk():
        value = build_sdk()
        if not value.is_dir(): raise Problem('macOS SDK is unavailable.')
        match = re.fullmatch(r'MacOSX(\d+)(?:\.\d+)*\.sdk',value.name)
        if match and int(match[1]) >= 27:
            compiler = Path(run(['xcrun','--find','swiftc'],capture=True).decode().strip()).resolve()
            plugins = [compiler.parents[1]/'lib/swift/host/plugins/libSwiftUIMacros.dylib',
                       value.parents[1]/'usr/lib/swift/host/plugins/libSwiftUIMacros.dylib']
            if not any(path.is_file() for path in plugins):
                raise Problem('Selected SDK needs SwiftUI macro support. Select full Xcode or set NERONOOK_SDK_PATH to a compatible installed SDK.')
        return 'macOS build SDK is available: '+value.name
    check('macOS', mac); check('Swift', swift); check('Build SDK', sdk)
    def test_tools():
        try:
            executable = run(['xcrun','--find','xctest'],capture=True).decode().strip()
        except Problem:
            raise Problem('Select a full Xcode installation for XCTest; Command Line Tools alone cannot run the starter tests.')
        if not Path(executable).is_file():
            raise Problem('The selected Xcode installation has no XCTest runner.')
        return 'XCTest runner is available.'
    check('Native test tools',test_tools)
    def package_tools():
        if not all(shutil.which(x) for x in ['codesign', 'ditto']):
            raise Problem('codesign and ditto are required.')
        return 'codesign and ditto are available.'
    check('Packaging tools', package_tools)
    value = dict(schemaVersion=1, kind='creator-preflight', creatorVersion=kit_metadata()['version'], license=kit_metadata().get('license'),
                 success=all(x['status']=='pass' for x in checks), checks=checks,
                 releaseGates=['This preflight does not verify a human creator trial', 'Each publisher must verify its own signature, notarization and delivery artifacts'])
    if report: write_report(report, value)
    for item in checks: print(item['status'].upper() + ': ' + item['name'] + ' — ' + item['detail'])
    print('Local preview checks only; public release gates remain separate.')
    if not value['success']: raise Problem('Preflight failed. No source, snapshot, installation or permission was changed.')
    return value

def run(args, cwd=None, capture=False, data=None):
    result = subprocess.run([str(x) for x in args], cwd=cwd, input=data, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        raise Problem('Command failed: ' + Path(str(args[0])).name + '. Inspect your project and toolchain; captured protocol data is not printed.')
    return result.stdout if capture else b''

def manifest(project):
    path = project / 'Resources/NookPlugin.json'
    if path.is_symlink() or path.stat().st_size > 8192:
        raise Problem('Manifest must be a regular file no larger than 8 KiB.')
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or not isinstance(value.get('id'), str):
        raise Problem('Manifest must be an object with a string plugin ID.')
    if not re.fullmatch(r'[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+', value.get('id', '')):
        raise Problem('Use a reverse-domain plugin ID.')
    return value

def build(project, release=False):
    verify_project_sdk(project)
    configuration = 'release' if release else 'debug'
    run(['swift', 'build', '-c', configuration, *sdk_options()], project)
    result = run(['swift', 'build', '-c', configuration, *sdk_options(), '--show-bin-path'], project, capture=True)
    return Path(result.decode().strip())

def validate(project, binaries):
    value = manifest(project)
    run([binaries/'PluginCheck', '--manifest'], capture=True, data=json.dumps(value).encode())
    if value.get('launchMode') is not None:
        raise Problem('This starter tool packages stdio apps. Use your platform-specific build for application-launch plugins.')
    print('PASS: manifest accepted by the vendored SDK.')
    return value

def package(project, binaries, value, identity=None, test_only=False, developer_id=False):
    if not test_only:
        identity, reference = resolve_signing(value['id'], identity)
    else:
        reference = None
    output = project/'build'
    output.mkdir(exist_ok=True)
    # Construct only in a new staging directory; never replace an in-use app.
    with tempfile.TemporaryDirectory(prefix='nook-pack-', dir=output) as temporary:
        app = Path(temporary)/'Module.app'
        (app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/Resources').mkdir()
        shutil.copy2(binaries/'ModuleApp', app/'Contents/MacOS/ModuleApp')
        sdk_assets = binaries/'NookPluginSDK_NookPluginSDK.bundle'
        if sdk_assets.exists(): shutil.copytree(sdk_assets, app/'Contents/Resources'/sdk_assets.name)
        shutil.copy2(project/'Resources/NookPlugin.json', app/'Contents/Resources/NookPlugin.json')
        licenses = app/'Contents/Resources/Licenses'; licenses.mkdir()
        shutil.copy2(project/'Vendor/NookPluginSDK/LICENSE', licenses/'NookPluginSDK.txt')
        views = project/'Resources/Views'
        if views.exists():
            assets = list(views.rglob('*'))
            files = [p for p in assets if p.is_file()]
            if views.is_symlink() or any(p.is_symlink() for p in assets) or len(files) > 512 or sum(p.stat().st_size for p in files) > 32*1024*1024:
                raise Problem('Custom view assets must be normal files within the 512-file / 32 MiB limit.')
            if any(p.stat().st_size > 2*1024*1024 for p in files): raise Problem('A custom view asset exceeds 2 MiB.')
            shutil.copytree(views, app/'Contents/Resources/Views')
        info = dict(CFBundleName=value['name'], CFBundleDisplayName=value['name'], CFBundleIdentifier=value['id'],
                    CFBundleExecutable='ModuleApp', CFBundlePackageType='APPL', CFBundleShortVersionString=value['version'],
                    CFBundleVersion='1', LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True, LSUIElement=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        if test_only:
            info['CFBundleIdentifier'] = value['id'] + '.protocol-test'
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            run(['codesign', '--force', '--sign', '-', app], capture=True)
        else:
            sign(app, identity, *(['--options', 'runtime', '--timestamp'] if developer_id else []))
            if developer_id: verify_distribution(app)
            verify_update(app, reference)
        run(['codesign', '--verify', '--deep', '--strict', app], capture=True)
        digest = hashlib.sha256()
        for path in sorted(app.rglob('*')):
            if path.is_file():
                digest.update(str(path.relative_to(app)).encode()); digest.update(b'\0'); digest.update(path.read_bytes())
        final = output/(value['id']+'-'+value['version']+'-'+digest.hexdigest()[:12]+'.app')
        if not final.exists(): shutil.move(str(app), final)
        else:
            # A modified existing result must not silently masquerade as this build.
            expected = {p.relative_to(app) for p in app.rglob('*') if p.is_file()}
            actual = {p.relative_to(final) for p in final.rglob('*') if p.is_file()}
            if final.is_symlink() or actual != expected or any(p.is_symlink() for p in final.rglob('*')):
                raise Problem('Existing output was modified. Keep it for recovery and use a fresh build directory.')
            for relative in expected:
                if (final/relative).read_bytes() != (app/relative).read_bytes():
                    raise Problem('Existing output was modified. Keep it for recovery and use a fresh build directory.')
    return final

def create(destination, plugin_id, name):
    if destination.exists() or destination.is_symlink(): raise Problem('Destination already exists; no files were overwritten.')
    if not re.fullmatch(r'[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+', plugin_id) or len(plugin_id)>100:
        raise Problem('Use a valid reverse-domain ID, for example com.example.my-module.')
    if not name.strip() or len(name)>80 or any(ord(c)<32 for c in name): raise Problem('Use a 1–80 character display name.')
    verify_creator_source()
    metadata = kit_metadata()
    sdk = HERE.parent/'NookPluginSDK' if HERE.name == 'Creator' else HERE.parent/'Vendor/NookPluginSDK'
    if not (sdk/'Package.swift').is_file(): raise Problem('The creator kit is missing its SDK snapshot.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.nook-create-', dir=destination.parent) as temporary:
        staged = Path(temporary)/'project'
        shutil.copytree(HERE/'Templates/Native', staged)
        shutil.copytree(sdk, staged/'Vendor/NookPluginSDK', ignore=shutil.ignore_patterns('.build', '.swiftpm', '.DS_Store'))
        shutil.copy2(sdk/'LICENSE', staged/'LICENSE')
        shutil.copytree(HERE, staged/'Tools', ignore=shutil.ignore_patterns('__pycache__', 'Tests', 'export-kit.py'))
        (staged/'Resources').mkdir(exist_ok=True)
        value = dict(id=plugin_id, name=name, version='0.1.0', apiVersion=1,
                     summary='An independent local demo module built with the NeroNook creator kit.',
                     icon=dict(symbol='square.stack.3d.up.fill', color='A78BFA'),
                     capabilities=['Shows local demo state and changes a demo counter', 'Publishes read-only demo status through the shared SDK'])
        (staged/'Resources/NookPlugin.json').write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')
        (staged/'.gitignore').write_text('.build/\nbuild/\n.swiftpm/\n.DS_Store\n__pycache__/\n')
        hashes = fingerprints(staged/'Vendor/NookPluginSDK')
        (staged/'SDK-SNAPSHOT.json').write_text(json.dumps(dict(hostBaseline=metadata['starterMinimumHost'], sourceHostVersion=metadata['sourceHostVersion'], creatorVersion=metadata['version'], apiVersion=1, license=metadata['license'], files=hashes),indent=2)+'\n')
        staged.rename(destination)
    print('Created independent project: '+str(destination))
    print('Next: python3 Tools/nook.py doctor . and python3 Tools/nook.py test .')

def protocol_test(project, app, binaries, value, features, replay=None):
    arguments = [app/'Contents/MacOS/ModuleApp', '--neronook-plugin', '--protocol-test']
    if replay: arguments += ['--replay', replay]
    environment = {key: os.environ[key] for key in ['HOME','TMPDIR','PATH'] if key in os.environ}
    process = subprocess.Popen([str(a) for a in arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment)
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    expected_replay = json.loads(replay.read_text()) if replay else None
    session = str(uuid.uuid4()); buffer = b''; sequence = -1; snapshots = 0; messages = 0; deadline = time.monotonic()+12
    def send(kind, **fields):
        process.stdin.write((json.dumps(dict(apiVersion=1,type=kind,pluginID=value['id'],session=session,sequence=0,**fields))+'\n').encode());process.stdin.flush()
    try:
        send('hello',features=features)
        while snapshots < 3 and time.monotonic()<deadline:
            if not selector.select(0.25):
                if process.poll() is not None: raise Problem('Module exited before completing the handshake and timed snapshots.')
                continue
            data = os.read(process.stdout.fileno(), MAX_LINE)
            if not data: raise Problem('Module closed its output unexpectedly.')
            buffer += data
            while b'\n' in buffer:
                line,buffer=buffer.split(b'\n',1);messages+=1
                if len(line)>MAX_LINE or messages>200: raise Problem('Protocol output exceeded its limits.')
                message = json.loads(line)
                run([binaries/'PluginCheck'], capture=True, data=line+b'\n')
                if message.get('pluginID') != value['id'] or message.get('session','').lower()!=session.lower(): raise Problem('Module returned the wrong identity or session.')
                current=message.get('sequence')
                if not isinstance(current,int) or current<=sequence: raise Problem('Module sequence repeated or moved backward.')
                if sequence==-1 and (message.get('type')!='ready' or current!=0): raise Problem('First message must be ready at sequence zero.')
                sequence=current
                if message.get('type')=='snapshot':
                    if expected_replay:
                        expected = expected_replay[min(snapshots,len(expected_replay)-1)]
                        if message['snapshot']['status'] != expected['message'] or message['snapshot']['badge'] != ('Demo' if expected['available'] else 'Offline'):
                            raise Problem('Starter replay did not produce the expected ordered status/availability.')
                    snapshots+=1
            if len(buffer)>MAX_LINE: raise Problem('Unterminated protocol output exceeded its limit.')
        if snapshots<3: raise Problem('Timed snapshots did not arrive before the deadline.')
        process.stdin.close()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: raise Problem('Hosted module did not exit after its connection closed.')
        if process.returncode!=0: raise Problem('Module exited abnormally after connection closure.')
        print('PASS: '+('modern' if features else 'legacy')+' handshake, SDK validation, three snapshots and clean EOF. No actions invoked.')
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        for pipe in [process.stdin,process.stdout]:
            if pipe and not pipe.closed: pipe.close()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    new=sub.add_parser('create',help='Create an independent Swift module project')
    new.add_argument('destination',type=Path);new.add_argument('--id',required=True);new.add_argument('--name',required=True)
    preflight=sub.add_parser('doctor',help='Read-only kit/project source and development-environment checks')
    preflight.add_argument('project',type=Path,nargs='?',default=Path('.'))
    preflight.add_argument('--report',type=Path,help='Write a bounded local JSON result without payloads or credentials')
    for command in ['validate','test','pack','dev']:
        p=sub.add_parser(command);p.add_argument('project',type=Path,nargs='?',default=Path('.'))
        if command in ['dev','test']:p.add_argument('--replay',type=Path,help='Starter-only bounded local demo-state replay')
        if command in ['pack','dev']:p.add_argument('--identity',help='Stable certificate; defaults to the installed app identity or NERONOOK_SIGNING_IDENTITY')
        if command=='pack':p.add_argument('--developer-id',action='store_true',help='Require Developer ID, hardened runtime and secure timestamp; notarization is a separate explicit step')
    args=parser.parse_args()
    if args.command=='create':create(args.destination.absolute(),args.id,args.name);return
    if args.command=='doctor':doctor(args.project.absolute(),args.report);return
    project=args.project.resolve()
    if not (project/'Package.swift').is_file():raise Problem('Choose a generated native starter project.')
    binaries=build(project,release=args.command=='pack')
    value=validate(project,binaries)
    if args.command=='validate':return
    app=package(project,binaries,value,getattr(args,'identity',None),test_only=args.command=='test',developer_id=getattr(args,'developer_id',False))
    if args.command=='test':
        run(['swift','test',*sdk_options()],project)
        replay=args.replay.resolve() if args.replay else None
        protocol_test(project,app,binaries,value,[],replay)
        protocol_test(project,app,binaries,value,FEATURES,replay)
    elif args.command=='dev':
        arguments=['open','-n',app]
        if args.replay:arguments+=['--args','--replay',args.replay.resolve()]
        run(arguments)
        print('Opened standalone preview. Install through NeroNook to verify the actual shared surface.')
    else:
        archive=app.with_suffix('.zip')
        run(['ditto','-c','-k','--sequesterRsrc','--keepParent',app,archive])
        print('Signed local app: '+str(app));print('Archive: '+str(archive))
        print('This is not notarization or a public-release approval.')

if __name__=='__main__':
    try:main()
    except (Problem,IntegrityError,SigningError,OSError,ValueError,KeyError) as error:
        print('Error: '+str(error),file=sys.stderr);sys.exit(1)
