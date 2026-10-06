import math, sys, time
sys.path.insert(0, "flygym_bridge")
import numpy as np
import lab_world
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand

body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
world = body.lab_world
tid = world.force_body_ids["thorax"]
m_thorax = float(world.model.body_mass[tid])
m_total = float(sum(world.model.body_mass[b] for b in range(world.model.nbody)
                    if world.model.body(b).name.startswith("fly") or "fly/" in world.model.body(b).name))
print(f"thorax mass {m_thorax:.3e}  fly total mass {m_total:.3e} (model units)  gravity {world.model.opt.gravity}")
n = body.sim.timestep
sub = int(round(0.01 / n))

def tilt():
    xm = world.data.xmat[tid].reshape(3, 3)
    return math.degrees(math.acos(max(-1, min(1, xm[2, 2]))))

def run(accel, strength, forward=0.0, seconds=1.0):
    body.reset_body()
    lab_world.WIND_ACCEL_MAX_MM_S2 = accel
    world.stop_wind()
    cmd = LocomotorCommand(forward=forward)
    for _ in range(int(0.3 / 0.01)):           # settle
        body.step_exact(cmd, sub)
    p0 = body._thorax_position(); tmax = 0.0
    world.set_wind(strength=strength, direction_deg=90, continuous=True, physical=True, sensory=False)
    t0 = time.perf_counter()
    for _ in range(int(seconds / 0.01)):
        body.step_exact(cmd, sub); tmax = max(tmax, tilt())
    wall = time.perf_counter() - t0
    p1 = body._thorax_position()
    world.stop_wind()
    ok = all(math.isfinite(v) for v in p1)
    print(f"accel {accel:>7.0f} s {strength:.1f} fwd {forward:.1f}: dy {p1[1]-p0[1]:+7.2f} dx {p1[0]-p0[0]:+6.2f} dz {p1[2]-p0[2]:+5.2f} mm"
          f"  max tilt {tmax:5.1f}°  finite {ok}  wall {wall:.2f}s", flush=True)

for accel in (10000, 30000, 60000, 100000, 200000):
    for s in (0.3, 1.0):
        run(accel, s)
