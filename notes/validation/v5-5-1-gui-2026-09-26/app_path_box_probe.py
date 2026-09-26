"""Reproduce the GUI F-02 check headlessly: default ArenaConfig obstacle box,
participant at its spawn pose, held W through the interactive step() path."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'flygym_bridge'))
import mujoco
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand

body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
try:
    world = body.lab_world
    player = world.player
    box = world.objects.get('obstacle_box')
    print('box', box.position_mm if box else None, getattr(box, 'size_mm', None), flush=True)
    world.set_player_active(True)
    print('spawn', player.render_pose()['position_mm'], flush=True)
    player.set_input_state(move_axes=[1, 0], look_delta=[0, 0], held_actions=[])
    cmd = LocomotorCommand(forward=0.0)
    for i in range(150):              # 150 x 50 ms wall ticks -> capped 20 ms quanta
        body.step(cmd, 0.05)
        if i % 25 == 0:
            mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
            print(f'i={i} t={body.t:.3f} pos={[round(v, 3) for v in player.render_pose()["position_mm"]]}', flush=True)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    held = player.render_pose()['position_mm']
    player.clear_input_state()
    for _ in range(50):
        body.step(cmd, 0.05)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    after = player.render_pose()['position_mm']
    print('held', [round(v, 4) for v in held], 'after_release', [round(v, 4) for v in after], flush=True)
finally:
    body.close()
