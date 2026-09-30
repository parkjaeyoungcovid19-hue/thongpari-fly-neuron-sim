import sys, time, statistics, os
root = sys.argv[1]; sys.path.insert(0, os.path.join(root, "flygym_bridge")); os.chdir(root)
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
import fly_body
b = RealFlyBody(config={}, show_viewer=False)
cmd = LocomotorCommand(forward=1.0)
for _ in range(20): b.step(cmd, 0.02)
ts = []
for r in range(5):
    t0 = time.perf_counter()
    for _ in range(50): b.step(cmd, 0.02)
    ts.append((time.perf_counter() - t0) / 50 * 1000)
import mujoco
m = b.sim.physics.model if hasattr(b.sim, "physics") else None
print(os.path.basename(root.rstrip('/')), "ms/step(20ms sim) runs:", [round(x,1) for x in ts], "median", round(statistics.median(ts),1), "substeps", int(round(0.02/b.sim.timestep)))
