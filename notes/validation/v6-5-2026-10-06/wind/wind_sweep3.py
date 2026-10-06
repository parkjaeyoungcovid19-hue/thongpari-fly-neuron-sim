import math, sys
sys.path.insert(0, "flygym_bridge")
import mujoco, numpy as np
import lab_world
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
world = body.lab_world; model, data = world.model, world.data
tid = world.force_body_ids["thorax"]
sub = int(round(0.01 / body.sim.timestep))
BAD = int(mujoco.mjtWarning.mjWARN_BADQACC)
def tilt(): return math.degrees(math.acos(max(-1, min(1, data.xmat[tid].reshape(3, 3)[2, 2]))))
def run(accel, vmax, strength, forward, seconds=2.0):
    lab_world.WIND_ACCEL_MAX_MM_S2 = accel; lab_world.WIND_SPEED_MAX_MM_S = vmax
    body.reset_body(); world.stop_wind()
    cmd = LocomotorCommand(forward=forward)
    for _ in range(30): body.step_exact(cmd, sub)
    p0 = np.array(body._thorax_position()); bad0 = data.warning[BAD].number; tmax = 0.0; vpk = 0.0
    world.set_wind(strength=strength, direction_deg=90, continuous=True, physical=True, sensory=False)
    for _ in range(int(seconds / 0.01)):
        body.step_exact(cmd, sub); tmax = max(tmax, tilt()); vpk = max(vpk, float(data.qvel[54+1]))
    world.stop_wind()
    d = np.array(body._thorax_position()) - p0
    bad = data.warning[BAD].number - bad0
    print(f"A {accel:6.0f} V {vmax:3.0f} s {strength:.2f} fwd {forward:.1f}: dy {d[1]:+8.2f} dx {d[0]:+7.2f} dz {d[2]:+6.2f} mm"
          f"  peak vy {vpk:6.1f} mm/s  tilt≤{tmax:5.1f}°  badqacc {bad}", flush=True)
for accel in [float(a) for a in sys.argv[1].split(",")]:
    for fwd in (0.0, 0.6):
        for s in (0.25, 0.5, 1.0):
            run(accel, 30.0, s, fwd)
