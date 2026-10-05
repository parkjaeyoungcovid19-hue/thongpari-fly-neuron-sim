import os, re, socket, subprocess, sys, time
root = "/Users/apgx/Documents/Codex Projects/초파리/siliconfly"; S = os.path.dirname(os.path.abspath(__file__))
py = root + "/flygym-venv/bin/python"; port = 17841
env = dict(os.environ, THONGPARI_BRIDGE_PORT=str(port))
def run(variant):
    cmd = [py, root + "/flygym_bridge/bridge.py", "--flygym-headless"] if variant == "manifest" else \
          [py, S + "/nomanifest_bridge.py", root, "--flygym-headless"]
    log = open(f"{S}/ab-{variant}-backend.log", "w")
    b = subprocess.Popen(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        t0 = time.monotonic()
        while True:
            assert b.poll() is None, "backend died"
            try:
                socket.create_connection(("127.0.0.1", port), timeout=.2).close(); break
            except OSError:
                assert time.monotonic() - t0 < 90; time.sleep(.2)
        owner = subprocess.check_output(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], text=True).split()
        assert owner == [str(b.pid)], owner
        out = subprocess.run([root + "/ThongpariFlyNeuronSim", "--bridgeloop"], cwd=root, env=env,
                             capture_output=True, text=True, timeout=60).stdout
        m = re.search(r"body ([\d.]+) Hz, max body gap (\d+) ms, sim/wall ([\d.]+)", out)
        return m.groups() if m else ("?", "?", "?")
    finally:
        b.terminate(); b.wait(15)
        time.sleep(1)
for i in range(3):
    for v in ("manifest", "nomanifest"):
        print(i, v, "body_hz=%s gap_ms=%s sim_wall=%s" % run(v), flush=True)
