"""V6.3 owner geometry and real MuJoCo rotated collision; no listener/window."""
import math
import unittest
import mujoco
import numpy as np
from environment import ArenaConfig
from fly_body import RealFlyBody

class RealWorldEditorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.body=RealFlyBody(config=ArenaConfig(),show_viewer=False)
    @classmethod
    def tearDownClass(cls): cls.body.close()
    def test_owner_edits_rotated_collision_and_delete_palettes(self):
        w=self.body.lab_world; model=w.model; data=w.data
        w.spawn_object(shape="box",object_id="editor_box",position_mm=[50,50,12],size_mm=[16,2,6])
        w.spawn_object(shape="sphere",object_id="editor_probe",position_mm=[56,50,12],size_mm=2)
        box=w.objects["editor_box"]; probe=w.objects["editor_probe"]
        gid=w._slot_ids[box.slot][1]; probe_gid=w._slot_ids[probe.slot][1]
        def edit(prop,value):
            return w.apply_edit(dict(schema_version=1,property_id=prop,target_id=box.object_id,
                                        expected_revision=box.revision,value=value,unit="deg" if prop=="object.yaw_deg" else "mm"))
        def distance():
            mujoco.mj_forward(model,data)
            return mujoco.mj_geomDistance(model,data,gid,probe_gid,100,np.zeros(6))
        self.assertLess(distance(),0)
        result=edit("object.yaw_deg",450)
        self.assertEqual(result["actual_value"],90)
        self.assertGreater(distance(),3)
        w.apply_edit(dict(schema_version=1,property_id="object.sphere.position_mm",target_id=probe.object_id,expected_revision=probe.revision,unit="mm",value=[50,56,12])); self.assertLess(distance(),0)
        result=edit("object.box.size_mm",[18,4,8])
        self.assertEqual(result["actual_value"],[18,4,8])
        self.assertTrue(np.allclose(model.geom_size[gid],[9,2,4]))
        result=edit("object.box.position_mm",[60,70,15])
        self.assertEqual(result["actual_value"],[60,70,15])
        self.assertTrue(np.allclose(data.mocap_pos[w._slot_ids[box.slot][2]],[60,70,15]))
        self.assertTrue(np.allclose(data.mocap_quat[w._slot_ids[box.slot][2]],[math.sqrt(.5),0,0,math.sqrt(.5)]))
        for shape,size in (("box",[6,8,10]),("wall",[2,14,9]),("sphere",4),("food",6),("car",16),("trap",22)):
            with self.subTest(shape=shape):
                source=shape+"_source"
                w.spawn_object(shape=shape,object_id=source,position_mm=[80,70,12],size_mm=size,yaw_deg=123,variant="apple" if shape=="food" else None)
                o=w.objects[source]
                copied=w.edit_object(dict(schema_version=1,operation="duplicate",target_id=source,expected_revision=o.revision))
                clone=w.objects[copied["actual_value"]]; slot=clone.slot; base_gid=w._slot_ids[slot][1]
                mujoco.mj_forward(model,data)
                self.assertTrue(np.allclose(data.mocap_pos[w._slot_ids[slot][2]],o.position_mm))
                self.assertEqual(clone.size_mm,o.size_mm); self.assertEqual(clone.yaw_deg,o.yaw_deg)
                palettes=w._food_palettes if shape=="food" else w._toy_palettes
                gids=palettes[slot].all_gids() if slot in palettes else [base_gid]
                self.assertTrue(any(model.geom_rgba[g,3]>0 for g in gids))
                deleted=w.edit_object(dict(schema_version=1,operation="delete",target_id=clone.object_id,expected_revision=clone.revision))
                self.assertEqual(deleted["actual_value"],clone.object_id)
                self.assertTrue(all(model.geom_rgba[g,3]==0 and model.geom_contype[g]==0 and model.geom_conaffinity[g]==0 for g in gids))
                self.assertEqual(int(model.geom_contype[base_gid]),0)
                self.assertNotIn(clone.object_id,w.objects)
                if shape=="food":
                    reference=w.food_odor(fly_position_mm=[80,70,12])
                    w.remove_object(source)
                    self.assertLess(w.food_odor(fly_position_mm=[80,70,12])["odor_left"],reference["odor_left"])
                self.assertIn(slot,w._free_slots[shape])

if __name__=="__main__": unittest.main(verbosity=2)
