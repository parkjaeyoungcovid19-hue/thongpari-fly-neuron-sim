import sys, math
sys.path.insert(0, ".")
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
body = RealFlyBody(); w = body.lab_world
w.set_player_active(True)
walk = LocomotorCommand(forward=1.0, moving=True)
start = list(w.player.position_mm)
contact_at = None
for q in range(250):  # 250 x 20 ms = 5 s sim, no player input at all
    body.step_exact(walk, 200)
    p = w.player.position_mm; t = body._thorax_position()
    d = math.dist(p, start)
    if q % 25 == 24:
        print(f"t={0.02*(q+1):.1f}s thorax_x={t[0]:.2f} player=({p[0]:.2f},{p[1]:.2f}) moved_without_input={d:.2f}mm")
