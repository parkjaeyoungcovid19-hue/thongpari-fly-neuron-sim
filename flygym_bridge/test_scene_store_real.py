import copy
import unittest
import numpy as np
from environment import ArenaConfig
from fly_body import RealFlyBody
from scene_store import document_text, SceneError
from test_scene_store import authored

class RealSceneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.body=RealFlyBody(config=ArenaConfig(),show_viewer=False)
    @classmethod
    def tearDownClass(cls):cls.body.close()

    def test_roundtrip_collision_render_and_no_time_advance(self):
        w=self.body.lab_world
        t=w.data.time;qpos=w.data.qpos.copy();qvel=w.data.qvel.copy()
        w.load_scene(document_text(authored().export_scene()),fly_position_mm=self.body._thorax_position())
        for obj in w.objects.values():
            gid=w._slot_ids[obj.slot][1]
            self.assertTrue(np.allclose(w.data.geom_xpos[gid],obj.position_mm))
            if obj.shape in ('box','wall','ramp'):
                self.assertTrue(np.allclose(w.model.geom_size[gid],np.array(obj.size_mm)/2))
                self.assertEqual(w.model.geom_contype[gid],1)
        self.assertEqual(w.export_scene(),authored().export_scene())
        self.assertEqual(w.data.time,t)
        # BB parking intentionally clears projectile qpos only; fly DOFs stay fixed.
        for _,_,adr,dadr in w._bb_ids:
            qpos[adr:adr+7]=w.data.qpos[adr:adr+7];qvel[dadr:dadr+6]=w.data.qvel[dadr:dadr+6]
        self.assertTrue(np.array_equal(w.data.qpos,qpos));self.assertTrue(np.array_equal(w.data.qvel,qvel))

    def test_failed_sync_rolls_back_compiled_collision_and_owner(self):
        w=self.body.lab_world
        before=copy.deepcopy(w.state()); arrays=[a.copy() for a in (w.model.geom_size,w.model.geom_rgba,w.model.body_contype,w.data.mocap_pos,w.data.qpos)]
        old=w._sync_object;count=0
        def fail(obj):
            nonlocal count
            old(obj);count+=1
            if count==2:raise RuntimeError('injected MuJoCo swap failure')
        w._sync_object=fail
        try:
            with self.assertRaises(RuntimeError):w.load_scene(document_text(authored().export_scene()),fly_position_mm=self.body._thorax_position())
        finally:w._sync_object=old
        self.assertEqual(w.state(),before)
        for live,saved in zip((w.model.geom_size,w.model.geom_rgba,w.model.body_contype,w.data.mocap_pos,w.data.qpos),arrays):self.assertTrue(np.array_equal(live,saved))

if __name__=='__main__':unittest.main(verbosity=2)
