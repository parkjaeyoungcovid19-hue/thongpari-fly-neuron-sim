"""From repo root: ./flygym-venv/bin/python notes/validation/v6-1-2026-10-05/run_real_gate.py"""
import json
import os
import socket
import subprocess
import time
from pathlib import Path

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
# runBridgeLoopTest constructs the default client on 17841 (not env-configured).
port = 17841
with socket.socket() as sock:
    sock.bind(("127.0.0.1", port))
env = dict(os.environ, THONGPARI_BRIDGE_PORT=str(port))
result = {"port": port, "mode": "fresh-real-headless", "started_at": time.time(),
          "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()}
with (out / "performance-backend.log").open("w") as log:
    backend = subprocess.Popen([str(root / "flygym-venv/bin/python"),
                                str(root / "flygym_bridge/bridge.py"), "--flygym-headless"],
                               cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
    result["backend_pid"] = backend.pid
    try:
        deadline = time.monotonic() + 90
        while True:
            if backend.poll() is not None:
                raise RuntimeError(f"backend exited {backend.returncode}")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.2):
                    pass
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise TimeoutError("backend readiness")
                time.sleep(.2)
        owner = subprocess.check_output(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], text=True).split()
        if owner != [str(backend.pid)]:
            raise RuntimeError(f"listener ownership mismatch: {owner}")
        with (out / "bridgeloop-real.log").open("w") as testlog:
            test = subprocess.run([str(root / "ThongpariFlyNeuronSim"), "--bridgeloop"],
                                  cwd=root, env=env, stdout=testlog, stderr=subprocess.STDOUT, timeout=60)
        result["exit"] = test.returncode
    except Exception as exc:
        result.update(error=str(exc), exit=2)
    finally:
        backend.terminate()
        try:
            backend.wait(timeout=15)
        except subprocess.TimeoutExpired:
            backend.kill()
            backend.wait()
        result["backend_returncode"] = backend.returncode
        try:
            with socket.socket() as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(("127.0.0.1", port))
            result["cleanup"] = "backend exited and port bindable"
        except OSError as exc:
            result.update(cleanup=str(exc), exit=2)
        (out / "performance-result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
raise SystemExit(result["exit"])
