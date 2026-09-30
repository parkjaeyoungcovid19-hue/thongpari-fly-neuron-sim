import sys, os, cProfile, pstats, io
root = sys.argv[1]; sys.path.insert(0, os.path.join(root, "flygym_bridge")); os.chdir(root)
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
b = RealFlyBody(config={}, show_viewer=False)
cmd = LocomotorCommand(forward=1.0)
for _ in range(20): b.step(cmd, 0.02)
m = b.sim.mj_model if hasattr(b.sim,'mj_model') else None
for name in ('mj_model','model','_mj_model'):
    if hasattr(b.sim, name): m = getattr(b.sim, name); break
if m is not None: print("ngeom", m.ngeom, "nbody", m.nbody, "npair", m.npair, "nv", m.nv, "nmocap", m.nmocap)
pr = cProfile.Profile(); pr.enable()
for _ in range(60): b.step(cmd, 0.02)
pr.disable()
s = io.StringIO(); pstats.Stats(pr, stream=s).sort_stats("tottime").print_stats(14); print(s.getvalue()[-3500:])
