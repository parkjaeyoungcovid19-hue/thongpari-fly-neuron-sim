"""Run each legacy labloop on its own backend; never reuse a V4 test session."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time

root = Path(__file__).resolve().parents[3]
os.chdir(root)
out = Path(__file__).resolve().parent
results = []
for mode in ['--mock', '--flygym-headless']:
    with socket.socket() as s:
        if s.connect_ex(('127.0.0.1', 17841)) == 0:
            raise RuntimeError('Existing listener: refusing to disturb it')
    env = dict(os.environ, NUMBA_DISABLE_JIT='1')
    tag = mode.removeprefix('--')
    with (out / f'fresh-{tag}-backend.log').open('w') as log:
        process = subprocess.Popen(
            ['./flygym-venv/bin/python', 'flygym_bridge/bridge.py', mode],
            stdout=log, stderr=subprocess.STDOUT, env=env)
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('backend exited before readiness')
                with socket.socket() as s:
                    if s.connect_ex(('127.0.0.1', 17841)) == 0:
                        break
                time.sleep(.25)
            else:
                raise RuntimeError('backend readiness timeout')
            with (out / f'fresh-{tag}-labloop.log').open('w') as testlog:
                result = subprocess.run(
                    ['./ThongpariFlyNeuronSim', '--labloop'], stdout=testlog,
                    stderr=subprocess.STDOUT, timeout=100)
            results.append(dict(mode=mode, test='labloop', exit=result.returncode))
            print(results[-1], flush=True)
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
(out / 'fresh-transport-results.json').write_text(json.dumps(results, indent=2))
