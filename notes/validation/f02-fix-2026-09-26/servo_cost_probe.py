"""Wall-clock cost of 20 ms real quanta: participant inactive vs. held-moving."""
import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'flygym_bridge'))
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand

body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
try:
    cmd = LocomotorCommand(forward=0.0)
    n = round(0.020 / body.physics_timestep_s)
    world = body.lab_world

    def bench(label, reps=3, quanta=50):
        best = None
        for _ in range(reps):
            t0 = time.perf_counter()
            for _ in range(quanta):
                body.step_exact(cmd, n)
            dt = (time.perf_counter() - t0) / quanta * 1000.0
            best = dt if best is None else min(best, dt)
        print(f'{label}: best {best:.2f} ms wall per 20 ms quantum', flush=True)

    world.set_player_active(False)
    bench('inactive')
    world.set_player_active(True)
    world.set_player_pose(position_mm=[24, 0, 8])
    world.player.set_input_state(move_axes=[0.3, 0.0], look_delta=[0, 0], held_actions=[])
    bench('active+moving')
    world.player.clear_input_state()
    bench('active+idle')
finally:
    body.close()
