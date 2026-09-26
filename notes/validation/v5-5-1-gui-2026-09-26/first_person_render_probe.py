"""First-person frame while the participant is held against the obstacle box.

Renders the same MjData the app streams, with view_stream's anchor maths, and
counts box-coloured pixels for the old (r x 1.05) and current eye offsets.
"""
import math
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'flygym_bridge'))
import mujoco
import numpy as np
import view_stream
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand

body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
try:
    m, d = body.sim.mj_model, body.sim.mj_data
    world, player = body.lab_world, body.lab_world.player
    world.set_player_active(True)
    player.set_input_state(move_axes=[1, 0], look_delta=[0, 0], held_actions=[])
    for _ in range(80):
        body.step(LocomotorCommand(forward=0.0), 0.02)
    mujoco.mj_forward(m, d)
    pose = world.render_player()
    print('participant', [round(v, 3) for v in pose['position_mm']], flush=True)
    box_gid = next(g for g in range(m.ngeom)
                   if (world.semantic_target_for_geom(g) or {}).get('target_id') == 'obstacle_box')
    box_rgba = np.asarray(m.geom_rgba[box_gid][:3]) * 255
    renderer = mujoco.Renderer(m, height=240, width=320)
    for label, fraction in (('old r*1.05', 1.05), ('new', view_stream.FIRST_PERSON_EYE_FRACTION)):
        view_stream.FIRST_PERSON_EYE_FRACTION = fraction
        cam_spec = {'position_mm': [0, 0, 0], 'forward': [1, 0, 0], 'anchor': 'participant_first'}
        (px, py, pz), (fx, fy, fz) = view_stream._resolve_anchor(cam_spec, {'participant': pose})
        cam = mujoco.MjvCamera(); cam.type = mujoco.mjtCamera.mjCAMERA_FREE
        dist = 10.0
        cam.distance = dist
        cam.azimuth = math.degrees(math.atan2(fy, fx))
        cam.elevation = math.degrees(math.asin(fz))
        cam.lookat[:] = (px + fx * dist, py + fy * dist, pz + fz * dist)
        renderer.update_scene(d, camera=cam)
        view_stream._hide_participant_geom(m, renderer.scene)
        raw = renderer.render()
        from PIL import Image
        Image.fromarray(raw).save(str(Path(__file__).parent / f"first-person-{fraction}.png"))
        img = raw.astype(float)
        # magenta hue: strong red and blue, weak green (robust to lighting)
        close = (img[..., 0] > 150) & (img[..., 2] > 150) & (img[..., 1] < 120)
        print(f'{label}: eye_x={px:.3f} box_pixels={close.mean()*100:.1f}%', flush=True)
    renderer.close()
finally:
    body.close()
