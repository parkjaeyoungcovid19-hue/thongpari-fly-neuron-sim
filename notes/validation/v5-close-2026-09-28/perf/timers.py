import sys, os
root = sys.argv[1]; sys.path.insert(0, os.path.join(root, "flygym_bridge")); os.chdir(root)
import mujoco
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
import json
cfg = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
b = RealFlyBody(config=cfg, show_viewer=False)
b.vision_period = 1e9
cmd = LocomotorCommand(forward=1.0)
for _ in range(20): b.step(cmd, 0.02)
sim=b.sim
m=d=None
for a in dir(sim):
    v=getattr(sim,a,None)
    if isinstance(v, mujoco.MjModel): m=v
    if isinstance(v, mujoco.MjData): d=v
for t in d.timer: t.duration=0; t.number=0
ncon=[]; nefc=[]
for _ in range(60):
    b.step(cmd, 0.02); ncon.append(d.ncon); nefc.append(d.nefc)
names=[n for n in dir(mujoco.mjtTimer) if n.startswith('mjTIMER_')]
out={}
for n in names:
    i=int(getattr(mujoco.mjtTimer,n))
    if i < len(d.timer) and d.timer[i].number: out[n[8:]]=d.timer[i].duration
tot=out.get('STEP',1)
print(os.path.basename(root), sys.argv[2:] , "npair", m.npair, "nv", m.nv, "ncon~",sum(ncon)//len(ncon),"nefc~",sum(nefc)//len(nefc),"nbvh?",m.nbvh if hasattr(m,'nbvh') else '')
for k,v in sorted(out.items(), key=lambda kv:-kv[1])[:12]: print(f"  {k:22s} {v*1000/60:8.2f} ms/quantum")
