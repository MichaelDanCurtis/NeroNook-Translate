#!/usr/bin/env python3
"""Exercise TranslateApp's stdio protocol-test mode, the way Tools/nook.py does for stdio plugins.

Tools/nook.py refuses application plugins, so this script is the equivalent check for Translate. Standard
library only. From the repository root:

    python3 -I scripts/protocol-test.py [path to TranslateApp] [--seconds 12]
    python3 -I scripts/protocol-test.py --self-check

The default app is .build/debug/TranslateApp. The script starts

    <app> --neronook-plugin --protocol-test

with pipes on stdin and stdout (stderr goes to a scratch file whose tail is shown on failure; the host
discards it) and the reduced environment the host uses (HOME, TMPDIR, PATH). It then:

  1. writes one `hello` line: apiVersion 1, pluginID cafe.nero.plugin.translate, a fresh session UUID,
     sequence 0 and the features appearance-v1, panels-v1, actions-v1, custom-views-v1, transient-caption-v1;
  2. reads newline-delimited JSON from stdout for up to --seconds, requiring that
       - the first message is `ready` with the same session, sequence 0 and a non-empty `features` list;
       - every later message has apiVersion 1, the same pluginID and session, a strictly increasing integer
         sequence and a `type` that is one of snapshot, heartbeat, caption, bus, frame, present;
       - no line is longer than 128 KiB (and none is empty or not a JSON object);
       - at least 3 `snapshot` messages carry a non-empty `snapshot.title` and at least 1 `heartbeat` arrives;
  3. after the first snapshot, sends one `action` message (`action: "configure"`, next host sequence) and
     requires that the plugin is still running afterwards (opening a window is fine; no result is needed);
  4. stops reading once all of that is satisfied and the plugin has had 1.5 s after the action (or at the
     deadline), closes stdin and requires the process to exit with status 0 within 5 s.

It prints a summary with counts and ends with PASS or FAIL; the exit status is 0 for PASS, 1 for FAIL and
2 for a usage error (for example a missing app). A snapshot without a title is counted and reported but does
not fail the run by itself; only having fewer than 3 titled snapshots does.

--self-check runs the same harness against tiny in-process fake plugins (a Python child that answers
correctly, plus misbehaving variants that must each be rejected for the right reason) and the validator on
hand-made lines. It needs no build and starts no real plugin. Nothing here installs or signs anything.
"""
from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import os
import selectors
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Dict, List, Optional

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / '.build' / 'debug' / 'TranslateApp'

PLUGIN_ID = 'cafe.nero.plugin.translate'
FEATURES = ['appearance-v1', 'panels-v1', 'actions-v1', 'custom-views-v1', 'transient-caption-v1']
VALID_TYPES = ('snapshot', 'heartbeat', 'caption', 'bus', 'frame', 'present')
MAX_LINE = 128 * 1024          # the host's per-message bound
MIN_SNAPSHOTS = 3
MIN_HEARTBEATS = 1
SETTLE_AFTER_ACTION = 1.5      # seconds the plugin must be observed running after the action
EXIT_TIMEOUT = 5.0             # seconds allowed between closing stdin and the process exiting
ACTION = 'configure'


class Violation(Exception):
    """The plugin broke a protocol rule; the message names the rule."""


class Checker:
    """Validates the plugin's output one line at a time. Pure logic, no I/O, so it can be tested directly."""

    def __init__(self, plugin_id: str, session: str) -> None:
        self.plugin_id = plugin_id
        self.session = session.lower()
        self.last_sequence = -1
        self.total = 0
        self.counts: Dict[str, int] = collections.Counter()
        self.titled = 0
        self.untitled = 0
        self.max_line = 0
        self.ready_features: Optional[List[str]] = None
        self.action_marked = False
        self.after_action = 0

    @property
    def ready(self) -> bool:
        return self.ready_features is not None

    def mark_action(self) -> None:
        self.action_marked = True

    def feed(self, line: bytes) -> None:
        self.total += 1
        number = self.total
        self.max_line = max(self.max_line, len(line))
        if len(line) > MAX_LINE:
            raise Violation(f'message {number} is {len(line)} bytes, over the {MAX_LINE}-byte line limit')
        if not line.strip():
            raise Violation(f'message {number} is an empty line')
        try:
            message = json.loads(line.decode('utf-8'))
        except ValueError as error:
            raise Violation(f'message {number} is not valid UTF-8 JSON: {error}')
        if not isinstance(message, dict):
            raise Violation(f'message {number} is not a JSON object')
        kind = message.get('type')
        if not isinstance(kind, str):
            raise Violation(f'message {number} has no string `type`')
        if message.get('apiVersion') != 1 or isinstance(message.get('apiVersion'), bool):
            raise Violation(f'message {number} ({kind}) has apiVersion {message.get("apiVersion")!r}, expected 1')
        if message.get('pluginID') != self.plugin_id:
            raise Violation(f'message {number} ({kind}) has pluginID {message.get("pluginID")!r}, expected {self.plugin_id}')
        session = message.get('session')
        if not isinstance(session, str) or session.lower() != self.session:
            raise Violation(f'message {number} ({kind}) has session {session!r}, expected the hello session')
        sequence = message.get('sequence')
        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0:
            raise Violation(f'message {number} ({kind}) has sequence {sequence!r}, expected a non-negative integer')
        if sequence <= self.last_sequence:
            raise Violation(f'message {number} ({kind}) has sequence {sequence} after {self.last_sequence}: not strictly increasing')

        if self.last_sequence == -1:
            if kind != 'ready':
                raise Violation(f'the first message must be ready, got {kind!r}')
            if sequence != 0:
                raise Violation(f'ready must have sequence 0, got {sequence}')
            features = message.get('features')
            if not isinstance(features, list) or not features or not all(isinstance(f, str) and f for f in features):
                raise Violation(f'ready must carry a non-empty `features` list of strings, got {features!r}')
            self.ready_features = features
        else:
            if kind not in VALID_TYPES:
                raise Violation(f'unexpected message type {kind!r} (expected one of {", ".join(VALID_TYPES)})')
            if kind == 'snapshot':
                snapshot = message.get('snapshot')
                title = snapshot.get('title') if isinstance(snapshot, dict) else None
                if isinstance(title, str) and title.strip():
                    self.titled += 1
                else:
                    self.untitled += 1
        self.last_sequence = sequence
        self.counts[kind] += 1
        if self.action_marked:
            self.after_action += 1


@dataclasses.dataclass
class Report:
    command: List[str]
    session: str = ''
    failures: List[str] = dataclasses.field(default_factory=list)
    warnings: List[str] = dataclasses.field(default_factory=list)
    checker: Optional[Checker] = None
    action_sent: bool = False
    exit_code: Optional[int] = None
    elapsed: float = 0.0
    stderr_tail: str = ''

    @property
    def ok(self) -> bool:
        return not self.failures

    def fail(self, reason: str) -> None:
        if reason not in self.failures:
            self.failures.append(reason)


class Run:
    """One plugin process and the conversation with it."""

    def __init__(self, command: List[str], seconds: float, exit_timeout: float) -> None:
        self.seconds = seconds
        self.exit_timeout = exit_timeout
        self.session = str(uuid.uuid4())
        self.checker = Checker(PLUGIN_ID, self.session)
        self.report = Report(command=list(command), session=self.session, checker=self.checker)
        self.command = list(command) + ['--neronook-plugin', '--protocol-test']
        self.buffer = b''
        self.eof = False
        self.next_sequence = 0
        self.action_at: Optional[float] = None
        self.process: Optional[subprocess.Popen] = None

    # -- I/O -----------------------------------------------------------------------------------------

    def send(self, kind: str, **fields) -> None:
        message = dict(apiVersion=1, type=kind, pluginID=PLUGIN_ID, session=self.session, sequence=self.next_sequence, **fields)
        self.next_sequence += 1
        try:
            self.process.stdin.write((json.dumps(message) + '\n').encode())
            self.process.stdin.flush()
        except (BrokenPipeError, ValueError):
            raise Violation(f'the plugin closed its input before the {kind} message could be delivered')

    def pump(self, wait: float) -> None:
        """Read what is available (waiting up to `wait` s) and validate each complete line."""
        if self.eof or not self.selector.select(wait):
            return
        chunk = os.read(self.process.stdout.fileno(), 65536)
        if not chunk:
            self.eof = True
            if self.buffer:
                raise Violation('the output ended in the middle of a line')
            return
        self.buffer += chunk
        while True:
            end = self.buffer.find(b'\n')
            if end < 0:
                break
            line, self.buffer = self.buffer[:end], self.buffer[end + 1:]
            self.checker.feed(line)
        if len(self.buffer) > MAX_LINE:
            raise Violation(f'an unterminated line is already over the {MAX_LINE}-byte line limit')

    def settled(self) -> bool:
        c = self.checker
        return (c.titled >= MIN_SNAPSHOTS and c.counts['heartbeat'] >= MIN_HEARTBEATS and self.action_at is not None
                and c.after_action >= 1 and time.monotonic() - self.action_at >= SETTLE_AFTER_ACTION)

    def wait_for_exit(self, timeout: float) -> bool:
        end = time.monotonic() + timeout
        while self.process.poll() is None and time.monotonic() < end:
            if self.eof:
                time.sleep(0.02)
            else:
                self.pump(0.05)
        return self.process.poll() is not None

    # -- the test ------------------------------------------------------------------------------------

    def execute(self) -> Report:
        report = self.report
        started = time.monotonic()
        scratch = tempfile.TemporaryFile()
        environment = {key: os.environ[key] for key in ('HOME', 'TMPDIR', 'PATH') if key in os.environ}
        try:
            self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=scratch,
                                            env=environment, start_new_session=True)
        except OSError as error:
            report.fail(f'could not start the plugin: {error.strerror or error}')
            scratch.close()
            return report
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            self.send('hello', features=FEATURES)
            deadline = started + self.seconds
            while time.monotonic() < deadline and not self.eof:
                self.pump(0.1)
                if self.action_at is None and self.checker.counts['snapshot'] >= 1:
                    self.send('action', action=ACTION)
                    self.action_at = time.monotonic()
                    self.checker.mark_action()
                    report.action_sent = True
                if self.settled():
                    break
            alive = not self.eof and self.process.poll() is None
            self.evaluate(alive)
            if alive:
                self.process.stdin.close()
                if not self.wait_for_exit(self.exit_timeout):
                    report.fail(f'the plugin did not exit within {self.exit_timeout:g} s after stdin was closed')
                else:
                    drain_until = time.monotonic() + 0.5
                    while not self.eof and time.monotonic() < drain_until:
                        self.pump(0.05)
                    if self.process.returncode != 0:
                        report.fail(f'the plugin exited with code {self.process.returncode} after stdin was closed, expected 0')
        except Violation as violation:
            report.fail(str(violation))
        finally:
            self.selector.close()
            if self.process.poll() is None:
                self.terminate()
            report.exit_code = self.process.returncode
            for pipe in (self.process.stdin, self.process.stdout):
                try:
                    pipe.close()
                except OSError:
                    pass
            scratch.seek(0)
            report.stderr_tail = scratch.read()[-1500:].decode('utf-8', 'replace').strip()
            scratch.close()
            report.elapsed = time.monotonic() - started
        return report

    def evaluate(self, alive: bool) -> None:
        report, c = self.report, self.checker
        if not alive:
            self.wait_for_exit(1.0)
            code = self.process.returncode
            report.fail('the plugin stopped (' + (f'exit code {code}' if code is not None else 'output closed') +
                        ') before the test finished')
        if not c.ready:
            report.fail('no ready message arrived')
        if c.titled < MIN_SNAPSHOTS:
            report.fail(f'only {c.titled} snapshot message(s) with a non-empty title arrived, need {MIN_SNAPSHOTS}')
        if c.counts['heartbeat'] < MIN_HEARTBEATS:
            report.fail('no heartbeat message arrived')
        if not report.action_sent:
            report.fail('no snapshot arrived, so the action message was never sent')
        elif alive and c.after_action == 0:
            report.warnings.append('no message arrived after the action (the plugin was still running)')
        if c.untitled:
            report.warnings.append(f'{c.untitled} snapshot message(s) had no non-empty title')

    def terminate(self) -> None:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(self.process.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                self.process.wait(timeout=2)
                return
            except subprocess.TimeoutExpired:
                continue


def run_test(command: List[str], seconds: float, exit_timeout: float = EXIT_TIMEOUT) -> Report:
    return Run(command, seconds, exit_timeout).execute()


def print_report(report: Report) -> None:
    c = report.checker
    print('protocol-test: ' + shlex.join(report.command + ['--neronook-plugin', '--protocol-test']))
    print(f'  session    : {report.session}')
    if c.ready:
        print(f'  ready      : {", ".join(c.ready_features)}')
    else:
        print('  ready      : not received')
    kinds = ', '.join(f'{kind} {c.counts[kind]}' for kind in VALID_TYPES if c.counts[kind]) or 'none'
    print(f'  messages   : {c.total} read (ready {1 if c.ready else 0}; {kinds})')
    print(f'  snapshots  : {c.titled} with a title, {c.untitled} without (need {MIN_SNAPSHOTS} with a title)')
    print(f'  heartbeats : {c.counts["heartbeat"]} (need {MIN_HEARTBEATS})')
    print(f'  longest    : {c.max_line} bytes (limit {MAX_LINE})')
    if report.action_sent:
        print(f'  action     : {ACTION} sent after the first snapshot; {c.after_action} message(s) followed')
    else:
        print('  action     : not sent')
    print(f'  exit       : {report.exit_code if report.exit_code is not None else "n/a"} (need 0 within {EXIT_TIMEOUT:g} s of closing stdin)')
    print(f'  elapsed    : {report.elapsed:.1f} s')
    for warning in report.warnings:
        print(f'  warning    : {warning}')
    for failure in report.failures:
        print(f'  FAIL       : {failure}')
    if report.failures and report.stderr_tail:
        print('  plugin stderr (tail):')
        for line in report.stderr_tail.splitlines()[-15:]:
            print('    ' + line)
    print('PASS' if report.ok else 'FAIL')


# ------------------------------------------------------------------------------------------------ self-check

# A tiny fake plugin. argv[1] is the mode; the harness appends --neronook-plugin --protocol-test, which it ignores.
FAKE_PLUGIN = r'''
import json, os, sys, threading, time
mode = sys.argv[1]
PID = "cafe.nero.plugin.translate"
BAD_SESSION = "00000000-0000-4000-8000-000000000000"
session = json.loads(sys.stdin.readline())["session"]
lock = threading.Lock()
state = {"seq": 0, "stop": False, "acted": False}

def emit(kind, seq=None, **fields):
    with lock:
        message = {"apiVersion": 1, "type": kind, "pluginID": PID, "session": session, "sequence": state["seq"] if seq is None else seq}
        message.update(fields)
        if seq is None:
            state["seq"] += 1
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()

def snapshot(n):
    title = "" if mode == "empty-title" else "x" * 140000 if mode == "oversize" else "Fake Translate"
    return {"title": title, "status": "tick %d" % n, "activity": "", "fields": [], "actions": [{"id": "configure", "label": "Settings", "enabled": True}]}

def reader():
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("type") == "action":
            if mode == "dies-on-action":
                os._exit(0)
            state["acted"] = True
    state["stop"] = True

if mode == "silent":
    sys.stdin.read()
    sys.exit(0)
if mode == "no-ready":
    emit("snapshot", snapshot=snapshot(0))
elif mode == "wrong-session":
    emit("ready", features=["appearance-v1"], session=BAD_SESSION)
elif mode == "wrong-plugin":
    emit("ready", features=["appearance-v1"], pluginID="cafe.nero.plugin.other")
elif mode == "empty-features":
    emit("ready", features=[])
elif mode == "ready-seq-1":
    emit("ready", seq=1, features=["appearance-v1"])
else:
    emit("ready", features=["appearance-v1", "panels-v1"])
if mode == "repeat-sequence":
    emit("snapshot", seq=0, snapshot=snapshot(0))
elif mode == "bad-type":
    emit("mystery")
elif mode == "ready-twice":
    emit("ready", features=["appearance-v1"])
elif mode == "not-json":
    sys.stdout.write("this is not json\n"); sys.stdout.flush()

threading.Thread(target=reader, daemon=True).start()
n = 0
announced = False
while not state["stop"]:
    n += 1
    if mode != "few-snapshots" or n <= 2:
        emit("snapshot", snapshot=snapshot(n))
    if n % 3 == 0 and mode != "no-heartbeat":
        emit("heartbeat")
    if state["acted"] and not announced and mode != "few-snapshots":
        announced = True
        emit("snapshot", snapshot=dict(snapshot(n), status="settings opened"))
    time.sleep(0.2)
if mode == "exit-nonzero":
    sys.exit(3)
if mode == "ignores-eof":
    time.sleep(60)
sys.exit(0)
'''

# mode, harness seconds, whether it must pass, text the failure must contain
SELF_CHECK_CASES = (
    ('good', 8, True, None),
    ('silent', 2, False, 'no ready message'),
    ('no-ready', 4, False, 'first message must be ready'),
    ('wrong-session', 4, False, 'expected the hello session'),
    ('wrong-plugin', 4, False, 'pluginID'),
    ('empty-features', 4, False, 'non-empty `features`'),
    ('ready-seq-1', 4, False, 'ready must have sequence 0'),
    ('repeat-sequence', 4, False, 'not strictly increasing'),
    ('bad-type', 4, False, "unexpected message type 'mystery'"),
    ('ready-twice', 4, False, "unexpected message type 'ready'"),
    ('not-json', 4, False, 'not valid UTF-8 JSON'),
    ('oversize', 4, False, 'line limit'),
    ('few-snapshots', 2.5, False, 'only 2 snapshot'),
    ('empty-title', 2.5, False, 'only 0 snapshot'),
    ('no-heartbeat', 2.5, False, 'no heartbeat'),
    ('dies-on-action', 4, False, 'before the test finished'),
    ('exit-nonzero', 8, False, 'exited with code 3'),
    ('ignores-eof', 8, False, 'did not exit within 1 s'),
)


def self_check() -> int:
    results = []

    def record(name: str, ok: bool, detail: str = '') -> None:
        results.append(ok)
        print(('ok   ' if ok else 'FAIL ') + name + (f': {detail}' if detail else ''))

    # The validator on hand-made lines.
    session = str(uuid.uuid4())

    def line(**overrides) -> bytes:
        message = dict(apiVersion=1, type='ready', pluginID=PLUGIN_ID, session=session, sequence=0, features=['a'])
        message.update(overrides)
        return json.dumps(message).encode()

    checker = Checker(PLUGIN_ID, session)
    checker.feed(line(session=session.upper()))
    checker.feed(line(type='snapshot', sequence=1, snapshot={'title': 'T'}, features=None))
    record('validator accepts ready (any session case) then a titled snapshot', checker.ready and checker.titled == 1)
    for label, bad in (('apiVersion 2', line(apiVersion=2)), ('boolean sequence', line(sequence=True)),
                       ('string sequence', line(sequence='0')), ('negative sequence', line(sequence=-1)),
                       ('JSON array', b'[1]'), ('empty line', b''), ('line over 128 KiB', b'{' + b' ' * MAX_LINE + b'}')):
        try:
            Checker(PLUGIN_ID, session).feed(bad)
            record(f'validator rejects {label}', False, 'accepted')
        except Violation:
            record(f'validator rejects {label}', True)

    # The harness against fake plugins.
    for mode, seconds, must_pass, needle in SELF_CHECK_CASES:
        report = run_test([sys.executable, '-I', '-c', FAKE_PLUGIN, mode], seconds, exit_timeout=1.0)
        if must_pass:
            c = report.checker
            ok = (report.ok and report.exit_code == 0 and report.action_sent and c.titled >= MIN_SNAPSHOTS
                  and c.counts['heartbeat'] >= 1 and c.after_action >= 1 and c.ready)
            record(f'fake plugin "{mode}" passes', ok, '' if ok else '; '.join(report.failures) or 'incomplete counts')
        else:
            hit = [f for f in report.failures if needle in f]
            record(f'fake plugin "{mode}" is rejected for "{needle}"', bool(hit), '' if hit else f'got {report.failures or "a pass"}')
    passed = sum(results)
    print(f'self-check: {passed}/{len(results)} passed')
    return 0 if passed == len(results) else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], epilog='See the module docstring for the exact rules.')
    parser.add_argument('app', nargs='?', type=Path, default=DEFAULT_APP, help='path to TranslateApp (default: .build/debug/TranslateApp)')
    parser.add_argument('--seconds', type=float, default=12.0, help='how long to read plugin output (default 12)')
    parser.add_argument('--self-check', action='store_true', help='verify this script against in-process fake plugins; no app needed')
    args = parser.parse_args(argv)
    if args.self_check:
        return self_check()
    if not 0 < args.seconds <= 600:
        parser.error('--seconds must be between 0 and 600')
    app = args.app.expanduser()
    if not app.is_file() or not os.access(app, os.X_OK):
        print(f'error: {app} is not an executable file; build it with `swift build` or pass the path to TranslateApp', file=sys.stderr)
        return 2
    report = run_test([str(app.resolve())], args.seconds)
    print_report(report)
    return 0 if report.ok else 1


if __name__ == '__main__':
    sys.exit(main())
