"""From repo root: flygym-venv/bin/python notes/validation/v6-2-2026-10-05/run_labloop.py {mock|real}
Starts a fresh test-owned backend on 17841 (refuses if the port is taken), runs
--labloop, and always terminates the backend."""
import socket, subprocess, sys, time
from pathlib import Path
root = Path(__file__).resolve().parents[3]; out = Path(__file__).resolve().parent
mode = sys.argv[1]; port = 17841
with socket.socket() as s:
    s.bind(("127.0.0.1", port))  # fails loudly if someone else owns the port
flag = "--mock" if mode == "mock" else "--flygym-headless"
log = open(out / f"labloop-{mode}-backend.log", "w")
backend = subprocess.Popen([str(root / "flygym-venv/bin/python"), str(root / "flygym_bridge/bridge.py"), flag],
                           cwd=root, stdout=log, stderr=subprocess.STDOUT)
code = 2
try:
    t0 = time.monotonic()
    while True:
        assert backend.poll() is None, "backend died"
        try:
            socket.create_connection(("127.0.0.1", port), timeout=.2).close(); break
        except OSError:
            assert time.monotonic() - t0 < 90, "backend readiness"; time.sleep(.2)
    owner = subprocess.check_output(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], text=True).split()
    assert owner == [str(backend.pid)], owner
    with open(out / f"labloop-{mode}.log", "w") as f:
        code = subprocess.run([str(root / "ThongpariFlyNeuronSim"), "--labloop"], cwd=root,
                              stdout=f, stderr=subprocess.STDOUT, timeout=120).returncode
finally:
    backend.terminate()
    try: backend.wait(15)
    except subprocess.TimeoutExpired: backend.kill(); backend.wait()
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port))
    print(f"{mode}: labloop exit={code} backend={backend.returncode} port bindable")
sys.exit(code)
