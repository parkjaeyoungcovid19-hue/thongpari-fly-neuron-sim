"""Swift TCP loop diagnostics against fresh test-owned backends. From repo root:
flygym-venv/bin/python notes/validation/v6-5-2026-10-06/run_loops.py

The Swift loop clients are fixed to 17841, so each run refuses to start if
anything already listens there, checks the listener is its own backend, and
always terminates it (port bindable afterwards).
"""
import socket
import subprocess
import sys
import time
from pathlib import Path

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
port = 17841
runs = [("mock", "--labloop"), ("mock", "--interactionloop"), ("mock", "--v4loop"),
        ("real", "--labloop"), ("real", "--bridgeloop")]
results = []
for mode, loop in runs:
    with socket.socket() as s:
        s.bind(("127.0.0.1", port))  # fails loudly if someone else owns the port
    name = f"{loop.lstrip('-')}-{mode}"
    log = open(out / f"{name}-backend.log", "w")
    flag = "--mock" if mode == "mock" else "--flygym-headless"
    backend = subprocess.Popen([str(root / "flygym-venv/bin/python"), str(root / "flygym_bridge/bridge.py"), flag],
                               cwd=root, stdout=log, stderr=subprocess.STDOUT)
    code = 2
    try:
        t0 = time.monotonic()
        while True:
            assert backend.poll() is None, "backend died"
            try:
                socket.create_connection(("127.0.0.1", port), timeout=.2).close()
                break
            except OSError:
                assert time.monotonic() - t0 < 120, "backend readiness"
                time.sleep(.2)
        owner = subprocess.check_output(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], text=True).split()
        assert owner == [str(backend.pid)], owner
        time.sleep(0.5)
        with open(out / f"{name}.log", "w") as f:
            code = subprocess.run([str(root / "ThongpariFlyNeuronSim"), loop], cwd=root,
                                  stdout=f, stderr=subprocess.STDOUT, timeout=180).returncode
    finally:
        backend.terminate()
        try:
            backend.wait(15)
        except subprocess.TimeoutExpired:
            backend.kill()
            backend.wait()
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", port))
    results.append((name, code))
    print(f"{name}: exit={code} backend={backend.returncode} port bindable", flush=True)
sys.exit(0 if all(code == 0 for _, code in results) else 1)
