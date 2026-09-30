#!/usr/bin/env python3
import datetime
import os
import shlex
import signal
import subprocess
import sys
from pathlib import Path

LOGDIR = Path(__file__).resolve().parent
ROOT = Path(os.environ.get('COMMAND_CWD', '/Users/apgx/Documents/Codex Projects/초파리/siliconfly'))

if len(sys.argv) < 3:
    raise SystemExit('usage: run_command.py NAME [TIMEOUT_SECONDS] COMMAND [ARG ...]')
name = sys.argv[1]
timeout_arg = sys.argv[2]
if timeout_arg == '-':
    timeout = None
    args = sys.argv[3:]
else:
    timeout = float(timeout_arg)
    args = sys.argv[3:]
if not args:
    raise SystemExit('missing command')
log_path = LOGDIR / f'{name}.log'
cmdline = shlex.join(args)
now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
env = os.environ.copy()
try:
    p = subprocess.Popen(args, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, start_new_session=True)
except Exception as exc:
    log_path.write_text(f'COMMAND: {cmdline}\nSTART_TIME: {now}\nLAUNCH_ERROR: {exc!r}\nEXIT_CODE: 127\n', encoding='utf-8')
    print(f'{name}: EXIT_CODE=127 LOG={log_path}')
    raise SystemExit(127)
try:
    output, _ = p.communicate(timeout=timeout)
    rc = p.returncode
    timed_out = False
except subprocess.TimeoutExpired:
    timed_out = True
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        output, _ = p.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = p.communicate()
    rc = p.returncode
text = output.decode('utf-8', errors='replace')
with log_path.open('w', encoding='utf-8') as f:
    f.write(f'COMMAND: {cmdline}\nSTART_TIME: {now}\n')
    if timeout is not None:
        f.write(f'TIMEOUT_LIMIT_SECONDS: {timeout:g}\n')
    f.write('----- FULL OUTPUT BEGIN -----\n')
    f.write(text)
    if text and not text.endswith('\n'):
        f.write('\n')
    f.write('----- FULL OUTPUT END -----\n')
    if timed_out:
        f.write(f'RESULT: TIMEOUT (terminated process group; termination exit={rc})\nEXIT_CODE: TIMEOUT\n')
    else:
        f.write(f'EXIT_CODE: {rc}\n')
print(f'{name}: ' + ('TIMEOUT' if timed_out else f'EXIT_CODE={rc}') + f' LOG={log_path}')
if timed_out:
    raise SystemExit(124)
raise SystemExit(rc)
