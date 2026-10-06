import math, sys, io, contextlib
sys.path.insert(0, "flygym_bridge")
import numpy as np
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
world = body.lab_world; model, data = world.model, world.data
tid = world.force_body_ids["thorax"]
# every body in the fly's subtree (root = thorax's root ancestor)
root = int(model.body_rootid[tid])
fly = [b for b in range(model.nbody) if int(model.body_rootid[b]) == root and model.body_mass[b] > 0]
m_fly = float(sum(model.body_mass[b] for b in fly)); m_th = float(model.body_mass[tid])
print(f"fly bodies {len(fly)}, mass total {m_fly:.3e}, thorax {m_th:.3e} ({m_th/m_fly:.0%}), g {-model.opt.gravity[2]:.0f} mm/s2", flush=True)
sub = int(round(0.01 / body.sim.timestep))
def tilt():
    return math.degrees(math.acos(max(-1, min(1, data.xmat[tid].reshape(3, 3)[2, 2]))))
def run(label, accel, forward, distributed, seconds=1.5):
    body.reset_body(); data.xfrc_applied[:] = 0
    cmd = LocomotorCommand(forward=forward)
    for _ in range(30): body.step_exact(cmd, sub)
    p0 = np.array(body._thorax_position()); tmax = 0.0
    for b in (fly if distributed else [tid]):
        data.xfrc_applied[b, 1] = model.body_mass[b] * accel if distributed else m_th * accel
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(err):
        for _ in range(int(seconds / 0.01)):
            body.step_exact(cmd, sub); tmax = max(tmax, tilt())
    data.xfrc_applied[:] = 0
    d = np.array(body._thorax_position()) - p0
    unstable = "unstable" in err.getvalue()
    print(f"{label:11s} a {accel:6.0f} fwd {forward:.1f}: dy {d[1]:+8.2f} dx {d[0]:+7.2f} dz {d[2]:+6.2f} mm  "
          f"tilt≤{tmax:5.1f}°  {'UNSTABLE' if unstable else 'stable'}", flush=True)
for fwd in (0.0, 0.6):
    for accel in (5000, 10000, 15000, 20000, 25000, 30000):
        run("distributed", accel, fwd, True)
    for accel in (10000, 18000):
        run("thorax", accel, fwd, False)
