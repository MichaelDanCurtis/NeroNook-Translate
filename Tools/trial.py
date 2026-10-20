#!/usr/bin/env python3
"""Run explicit local creator checks and save a bounded, portable trial receipt."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nook

HUMAN_CHECKS = ['install', 'inlineAction', 'cancelReview', 'customView',
                'nativeWindow', 'update', 'cancelRecovery', 'restore',
                'restart', 'multipleDisplays']


def local_environment():
    def value(args, pattern):
        result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        text = result.stdout.strip()
        return text if result.returncode == 0 and re.fullmatch(pattern, text) else 'unreported'
    return dict(osVersion=platform.mac_ver()[0], architecture=platform.machine(),
                osBuild=value(['/usr/bin/sw_vers', '-buildVersion'], r'[A-Za-z0-9.]{1,32}'),
                model=value(['/usr/sbin/sysctl', '-n', 'hw.model'], r'[A-Za-z0-9,]{1,64}'))


def local_dependency_only(project):
    value = json.loads(nook.run(['swift', 'package', 'show-dependencies', '--format', 'json'], project, capture=True))
    dependencies = value.get('dependencies', [])
    expected = (project/'Vendor/NookPluginSDK').resolve()
    if (len(dependencies) != 1 or Path(dependencies[0].get('path', '')).resolve() != expected
            or dependencies[0].get('dependencies') != []):
        raise nook.Problem('The trial project must depend only on its local vendored SDK.')


def collect(project, output, role='unreported', observations=None):
    project = project.resolve()
    # Reject unsafe report destinations before building or executing project code.
    relative = output.resolve().relative_to(project) if output.resolve().is_relative_to(project) else None
    if relative is not None and (not relative.parts or relative.parts[0] != 'build'):
        raise nook.Problem('Keep the trial report outside source folders or under build/.')
    if output.exists() or output.is_symlink():
        raise nook.Problem('Use a new result filename; previous trial receipts are retained.')
    supplied = observations or {}
    if any(key not in HUMAN_CHECKS or status not in ['pass', 'fail', 'skipped'] for key, status in supplied.items()):
        raise nook.Problem('Use a documented human check with pass, fail or skipped.')
    if role not in ['owner', 'external-creator', 'agent', 'unreported']:
        raise nook.Problem('Choose owner, external-creator, agent or unreported.')
    report = dict(schemaVersion=1, kind='nero-creator-trial',
                  observedAt=datetime.now(timezone.utc).isoformat(),
                  creatorVersion=nook.kit_metadata()['version'], environment=local_environment(),
                  reporterRole=role, automatedChecks=[],
                  humanChecks={key: dict(status=supplied.get(key, 'not-run'), evidence='reporter supplied' if key in supplied else 'none') for key in HUMAN_CHECKS},
                  uploads=False, installedByCollector=False,
                  note='Human observations are self-reported; automated success does not complete the human creator gate.')
    try:
        for stage, operation in [
            ('preflight', lambda: nook.doctor(project)),
            ('localSDKOnly', lambda: local_dependency_only(project)),
            ('buildTestsAndProtocols', lambda: nook.run([sys.executable, Path(__file__).parent/'nook.py', 'test', project]))]:
            try:
                operation()
            except (nook.Problem, OSError, ValueError, KeyError, subprocess.SubprocessError):
                report['automatedChecks'].append(dict(name=stage, status='fail'))
                raise
            report['automatedChecks'].append(dict(name=stage, status='pass'))
    except (nook.Problem, OSError, ValueError, KeyError, subprocess.SubprocessError):
        report['automatedPassed'] = False
        # Never copy compiler output, source, paths, transcripts or environment variables.
        nook.write_report(output, report)
        raise nook.Problem('Creator trial check failed. See the local terminal and saved stage result; nothing was uploaded or installed.')
    report['automatedPassed'] = True
    nook.write_report(output, report)
    print('Creator checks passed. Human UI observations remain separate; results stay on this Mac.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--role', choices=['owner', 'external-creator', 'agent', 'unreported'], default='unreported')
    parser.add_argument('--observed', action='append', default=[], metavar='CHECK=pass|fail|skipped', help='Only record UI checks you personally performed; omitted checks remain not-run')
    args = parser.parse_args()
    observations = {}
    for item in args.observed:
        if '=' not in item: raise nook.Problem('Use CHECK=pass|fail|skipped.')
        key, status = item.split('=', 1)
        if key in observations: raise nook.Problem('Do not repeat a human check.')
        observations[key] = status
    collect(args.project, args.output.absolute(), args.role, observations)


if __name__ == '__main__':
    try:
        main()
    except (nook.Problem, OSError, ValueError, KeyError) as error:
        print('Error: '+str(error), file=sys.stderr)
        sys.exit(1)
