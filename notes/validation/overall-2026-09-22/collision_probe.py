"""Independent held-input wall approach using the production real body."""
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
    world.spawn_object(shape='wall', object_id='audit-wall',
                       position_mm=[30, 0, 10], size_mm=[2, 40, 20])
    world.set_player_active(True)
    world.set_player_pose(position_mm=[24, 0, 8])
    player = world.player
    player.set_input_state(move_axes=[1, 0], look_delta=[0, 0], held_actions=[])
    cmd = LocomotorCommand(forward=0.0)
    n = round(0.020 / body.physics_timestep_s)
    max_x = 24.0
    for i in range(100):
        body.step_exact(cmd, n)
        mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
        pose = player.render_pose()['position_mm']
        max_x = max(max_x, pose[0])
        if i % 10 == 0:
            print(f'step={i} pose={pose} contacts={body.sim.mj_data.ncon}', flush=True)
    print(f'max_x={max_x} near_surface_limit=26.5 far_surface_clear=33.5', flush=True)
    print(f'crossed_wall={max_x > 33.5}', flush=True)
    contacts = [float(body.sim.mj_data.contact[j].dist)
                for j in range(body.sim.mj_data.ncon)
                if player.geom_id in (int(body.sim.mj_data.contact[j].geom1),
                                      int(body.sim.mj_data.contact[j].geom2))]
    print(f'player_contact_distances={contacts}', flush=True)
    player.clear_input_state()
    for _ in range(100):
        body.step_exact(cmd, n)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    print(f'after_release_pose={player.render_pose()["position_mm"]}', flush=True)
finally:
    body.close()
