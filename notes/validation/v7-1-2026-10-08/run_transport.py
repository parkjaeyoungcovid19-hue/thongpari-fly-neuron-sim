import json,os,socket,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[3];out=Path(__file__).parent;results=[]
runs=[('mock','--sceneloop'),('real','--sceneloop'),('mock','--v4loop'),('real','--v4loop'),('real','--labloop')]
for mode,flag in runs:
    with socket.socket() as s:s.bind(('127.0.0.1',17841))
    name=flag.lstrip('-')+'-'+mode
    with (out/(name+'-backend.log')).open('w') as log:
        backend=subprocess.Popen([str(root/'flygym-venv/bin/python'),str(root/'flygym_bridge/bridge.py'), '--mock' if mode=='mock' else '--flygym-headless'],cwd=root,stdout=log,stderr=subprocess.STDOUT)
        try:
            end=time.monotonic()+120
            while True:
                assert backend.poll() is None
                try:
                    with socket.create_connection(('127.0.0.1',17841),timeout=.2):pass
                    break
                except OSError:
                    assert time.monotonic()<end
                    time.sleep(.2)
            owner=subprocess.check_output(['lsof','-nP','-iTCP:17841','-sTCP:LISTEN','-t'],text=True).split()
            assert owner==[str(backend.pid)],owner
            time.sleep(.3)
            with (out/(name+'.log')).open('w') as f:r=subprocess.run([str(root/'ThongpariFlyNeuronSim'),flag],cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=240)
            results.append(dict(test=name,exit=r.returncode,pid=backend.pid))
        finally:
            backend.terminate()
            try:backend.wait(15)
            except subprocess.TimeoutExpired:backend.kill();backend.wait()
            with socket.socket() as s:
                s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',17841))
        print(name,r.returncode,'cleaned',flush=True)
        (out/'transport-results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(r['exit']==0 for r in results) else 1)
