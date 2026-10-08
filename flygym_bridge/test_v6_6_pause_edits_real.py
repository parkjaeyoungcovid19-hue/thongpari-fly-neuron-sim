"""V6.6 pause edit on real MuJoCo: refresh_poses shows the edit without time
passing. No listener/window."""
import unittest
import numpy as np
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand


class RealPauseEditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.body = RealFlyBody(config=ArenaConfig(), show_viewer=False)

    @classmethod
    def tearDownClass(cls): cls.body.close()

    def test_refresh_poses_moves_geoms_without_advancing_time(self):
        w = self.body.lab_world
        model, data = w.model, w.data
        w.spawn_object(shape="box", object_id="paused_box", position_mm=[50, 40, 6], size_mm=[8, 8, 8])
        for _ in range(3):
            self.body.step(LocomotorCommand(forward=0.0), 0.02)
        box = w.objects["paused_box"]
        gid = w._slot_ids[box.slot][1]
        frozen = (data.time, data.qpos.copy(), data.qvel.copy())
        before = data.geom_xpos[gid].copy()
        w.apply_edit(dict(schema_version=1, property_id="object.box.position_mm", target_id="paused_box",
                          expected_revision=box.revision, unit="mm", value=[80, -20, 6]))
        # Negative control: the edit alone leaves the derived pose stale.
        self.assertTrue(np.allclose(data.geom_xpos[gid], before))
        w.refresh_poses()
        self.assertTrue(np.allclose(data.geom_xpos[gid], [80, -20, 6]))
        self.assertEqual(data.time, frozen[0])
        self.assertTrue(np.array_equal(data.qpos, frozen[1]))
        self.assertTrue(np.array_equal(data.qvel, frozen[2]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
