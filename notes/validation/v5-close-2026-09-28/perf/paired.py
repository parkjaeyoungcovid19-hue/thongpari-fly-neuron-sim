import sys, os, json, time, statistics
root = sys.argv[1]; sys.path.insert(0, os.path.join(root, "flygym_bridge")); os.chdir(root)
import mujoco
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
cfgs = [json.loads(a) for a in sys.argv[2:]]
bodies = []
for c in cfgs:
    b = RealFlyBody(config=c, show_viewer=False); b.vision_period = 1e9
    m=[getattr(b.sim,a) for a in dir(b.sim) if isinstance(getattr(b.sim,a,None), mujoco.MjModel)][0]
    bodies.append((json.dumps(c), b, m))
cmd = LocomotorCommand(forward=1.0)
for _ in range(10):
    for _,b,_ in bodies: b.step_exact(cmd, 200)
t = {k: [] for k,_,_ in bodies}
for r in range(int(os.environ.get("REPS","20"))):
    order = bodies if r % 2 == 0 else bodies[::-1]
    for k,b,_ in order:
        s=time.perf_counter(); b.step_exact(cmd, 200); t[k].append((time.perf_counter()-s)*1000)
base = t[bodies[0][0]]
for k,b,m in bodies:
    ratios=[x/y for x,y in zip(t[k], base)]
    print(f"{k:55s} ngeom {m.ngeom:5d} npair {m.npair:4d} nv {m.nv:3d} nbody {m.nbody:4d} median {statistics.median(t[k]):6.1f} ms  ratio {statistics.median(ratios):.3f}")
