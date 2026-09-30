import sys, math
sys.path.insert(0, ".")
import mujoco
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
from protocol import LabCommand, PlayerInputPacket
body = RealFlyBody(); w = body.lab_world
idle = LocomotorCommand(forward=0.0, moving=False)
w.set_player_active(True); w.set_player_pose(position_mm=[60, 20, 2.5]); mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
w.spawn_object(shape="box", object_id="b", position_mm=[70, 20, 5], size_mm=[10, 10, 10])
r = body.apply_lab_command(LabCommand(seq=1, op="interaction", args={"tool_id": "grab", "actor_id": "player", "ray_origin_mm": [61.5, 20, 2.5], "ray_direction": [1, 0, 0]}))
print("held", r["held_object_id"])
seq = [1]
def look(yaw):
    seq[0] += 1
    body.set_player_input(PlayerInputPacket(actor_id="player", seq=seq[0], move_axes=[0, 0], look_delta=[yaw, 0], held_actions=[]))
for q in range(50): body.step_exact(idle, 200)
start = list(w.player.position_mm)
look(math.radians(45))   # one mouse turn, then hands off
for q in range(1, 151):  # 3 s sim, no input
    body.step_exact(idle, 200)
    if q % 25 == 0:
        p = w.player.position_mm
        print(f"t={q*0.02:.1f}s player drift={math.dist(p, start):.2f}mm blocked={w.interaction.carry_blocked} box={[round(v,2) for v in w.objects['b'].position_mm[:2]]}")
