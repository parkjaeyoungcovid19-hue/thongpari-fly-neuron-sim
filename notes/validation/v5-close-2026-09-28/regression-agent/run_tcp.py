#!/usr/bin/env python3
import datetime
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path('/Users/apgx/Documents/Codex Projects/초파리/siliconfly')
OUT = Path(__file__).resolve().parent
PYTHON = ROOT / 'flygym-venv/bin/python'
BIN = OUT / 'buildsrc/ThongpariFlyNeuronSim'
PORTS = (17841, 17842)


def listen_info(port):
    p = subprocess.run(['lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN'],
                       text=True, capture_output=True)
    return p.stdout.strip()


def is_connectable(port):
    with socket.socket() as s:
        s.settimeout(0.2)
        try:
            s.connect(('127.0.0.1', port))
            return True
        except OSError:
            return False


def run_one(mode, loop, timeout):
    label = f'{mode}-{loop}'
    log = OUT / f'tcp-{label}.log'
    start = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
    lines = [f'COMMAND: launch fresh {mode} backend, then {BIN} --{loop}',
             f'START_TIME: {start}', f'ROOT: {ROOT}', f'BACKEND_MODE: {mode}',
             'PORTS_CHECKED: 127.0.0.1:17841, 127.0.0.1:17842']
    for port in PORTS:
        existing = listen_info(port)
        if existing or is_connectable(port):
            lines += [f'PRECHECK_FAIL: port {port} is already occupied', existing or '(connectable but lsof did not identify listener)', 'EXIT_CODE: BLOCKED']
            log.write_text('\n'.join(lines) + '\n', encoding='utf-8')
            print(f'{label}: BLOCKED listener port {port}; LOG={log}')
            return False
    env = os.environ.copy()
    env['THONGPARI_BRIDGE_PORT'] = '17841'
    if mode == 'headless':
        env['THONGPARI_RENDER_PORT'] = '17842'
        backend_args = [str(PYTHON), '-u', str(ROOT / 'flygym_bridge/bridge.py'), '--flygym-headless']
    else:
        env.pop('THONGPARI_RENDER_PORT', None)
        backend_args = [str(PYTHON), '-u', str(ROOT / 'flygym_bridge/bridge.py'), '--mock']
    b = None
    t = None
    out_b = b''
    out_t = b''
    rc = None
    timed_out = False
    fail_repro = False
    try:
        b = subprocess.Popen(backend_args, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
        lines += ['BACKEND_PID: '+str(b.pid), 'BACKEND_COMMAND: '+' '.join(backend_args)]
        ready_deadline = time.monotonic() + (240 if mode == 'headless' else 15)
        ready = False
        while time.monotonic() < ready_deadline:
            if b.poll() is not None:
                break
            if listen_info(17841) and is_connectable(17841):
                if mode == 'headless' and not (listen_info(17842) and is_connectable(17842)):
                    time.sleep(0.1)
                    continue
                ready = True
                break
            time.sleep(0.1)
        out_b = b'' if b.stdout is None else b''
        if not ready:
            tmsg = 'backend exited before readiness' if b.poll() is not None else 'backend readiness TIMEOUT'
            lines += [f'BACKEND_READY: FAIL ({tmsg})']
            if b.poll() is None:
                timed_out = True
                rc = None
            else:
                out_b = b.communicate(timeout=5)[0]
                rc = b.returncode
            lines += ['----- BACKEND OUTPUT BEGIN -----', out_b.decode('utf-8', errors='replace').rstrip(), '----- BACKEND OUTPUT END -----']
            lines += ['RESULT: TIMEOUT' if timed_out else f'EXIT_CODE: {rc}']
            return_code_ok = False
        else:
            lines += ['BACKEND_READY: PASS']
            t = subprocess.Popen([str(BIN), f'--{loop}'], cwd=ROOT, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 start_new_session=True)
            lines += ['TEST_PID: '+str(t.pid), 'TEST_COMMAND: '+str(BIN)+' --'+loop]
            try:
                out_t, _ = t.communicate(timeout=timeout)
                rc = t.returncode
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(t.pid, signal.SIGTERM)
                try:
                    out_t, _ = t.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(t.pid, signal.SIGKILL)
                    out_t, _ = t.communicate()
                rc = t.returncode
            lines += ['----- TEST OUTPUT BEGIN -----', out_t.decode('utf-8', errors='replace').rstrip(), '----- TEST OUTPUT END -----']
            # Any nonzero loop exit must be rerun once to capture the minimum reproduction.
            return_code_ok = (not timed_out and rc == 0)
            if not return_code_ok and not timed_out:
                fail_repro = True
                lines += ['REPRODUCTION: one additional run against the same fresh backend']
                t2 = subprocess.Popen([str(BIN), f'--{loop}'], cwd=ROOT, env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      start_new_session=True)
                lines += ['REPRO_PID: '+str(t2.pid)]
                try:
                    repro, _ = t2.communicate(timeout=timeout)
                    lines += [f'REPRO_EXIT_CODE: {t2.returncode}', '----- REPRO OUTPUT BEGIN -----', repro.decode('utf-8', errors='replace').rstrip(), '----- REPRO OUTPUT END -----']
                except subprocess.TimeoutExpired:
                    os.killpg(t2.pid, signal.SIGTERM)
                    try:
                        repro, _ = t2.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(t2.pid, signal.SIGKILL)
                        repro, _ = t2.communicate()
                    lines += ['REPRO_EXIT_CODE: TIMEOUT', '----- REPRO OUTPUT BEGIN -----', repro.decode('utf-8', errors='replace').rstrip(), '----- REPRO OUTPUT END -----']
                # Keep both runs in the original log; the exact assertion is visible there.
                return_code_ok = False
    finally:
        # Kill ONLY PIDs created above.
        for proc in (t, b):
            if proc is not None and proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
                except ProcessLookupError:
                    pass
            if proc is not None and proc.stdout is not None:
                try:
                    if proc is b and not out_b:
                        out_b, _ = proc.communicate(timeout=1)
                    elif proc is t and not out_t:
                        out_t, _ = proc.communicate(timeout=1)
                except Exception:
                    pass
        if b is not None and out_b:
            lines += ['----- BACKEND OUTPUT BEGIN -----', out_b.decode('utf-8', errors='replace').rstrip(), '----- BACKEND OUTPUT END -----']
        for port in PORTS:
            info = listen_info(port)
            lines += [f'POSTCHECK_PORT_{port}: '+(info or 'FREE')]
            if info or is_connectable(port):
                lines += [f'PORT_LEAK: {port}', 'PORT_PROCESS_INFO: '+(info or 'unknown')]
        lines += ['RESULT: TIMEOUT' if timed_out else f'EXIT_CODE: {rc}']
        log.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'{label}: '+('TIMEOUT' if timed_out else f'EXIT_CODE={rc}')+f' LOG={log}')
    return return_code_ok and not fail_repro

ok = True
for mode, loop in [('mock','bridgeloop'), ('mock','labloop'), ('mock','interactionloop'),
                   ('headless','bridgeloop'), ('headless','labloop'), ('headless','interactionloop')]:
    print(f'Running {mode} --{loop} (sequential)', flush=True)
    if not run_one(mode, loop, 120):
        ok = False
print('ALL_TCP_RUNS_EXIT_CODE='+('0' if ok else '1'))
sys.exit(0 if ok else 1)
