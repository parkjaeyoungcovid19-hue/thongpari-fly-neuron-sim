"""V6.7 settings roundtrip, failed staging and pause/session barriers."""
import copy
import json
import subprocess
import sys
import unittest
from lab_world import LabWorld
from scene_store import SceneError, content_hash, document_text
from test_v6_6_pause_edits import PauseEditTransactionTests, stamped


def authored():
    w = LabWorld()
    for shape, pos, size in [('box',[60,40,5],[10,8,6]), ('ramp',[90,40,5],[20,14,2]),
                             ('food',[50,-30,2],3),('car',[-50,40,3],14),('trap',[-90,40,6],20),
                             ('sphere',[60,-60,4],8),('wall',[100,-80,10],[2,30,20])]:
        w.spawn_object(shape=shape, object_id=shape, position_mm=pos, size_mm=size,
                       variant='apple' if shape=='food' else None, pitch_deg=25 if shape=='ramp' else None)
    w.temperature.update(celsius=33, mode='flywire_sensory')
    w.wind.update(strength=.2, direction_deg=90, continuous=True, physical_enabled=False)
    w.eyes.update(left_mask=.6)
    return w


class SceneTests(unittest.TestCase):
    def setUp(self):
        self.w = authored()
        self.doc = self.w.export_scene()

    def test_new_process_roundtrip(self):
        script = '''import sys; from lab_world import LabWorld; from scene_store import document_text
w=LabWorld(); w.load_scene(sys.stdin.read(), fly_position_mm=[0,0,1]); print(document_text(w.export_scene()))'''
        run = subprocess.run([sys.executable,'-c',script],input=document_text(self.doc),text=True,
                             cwd=__import__('pathlib').Path(__file__).parent,capture_output=True)
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertEqual(json.loads(run.stdout),self.doc)

    def rejected(self, mutate, status=None, rehash=True):
        doc=copy.deepcopy(self.doc); mutate(doc)
        if rehash: doc['content_sha256']=content_hash(doc['scene'])
        before=copy.deepcopy(self.w.state())
        with self.assertRaises(SceneError) as ctx:
            self.w.load_scene(document_text(doc),fly_position_mm=[0,0,1])
        if status: self.assertEqual(ctx.exception.status,status)
        self.assertEqual(self.w.state(),before)

    def test_runtime_swap_failure_restores_owner(self):
        before=copy.deepcopy(self.w.state()); old=self.w._sync_object
        self.w._sync_object=lambda obj: (_ for _ in ()).throw(RuntimeError("injected swap failure"))
        try:
            with self.assertRaises(RuntimeError):self.w.load_scene(document_text(self.doc),fly_position_mm=[0,0,1])
            self.assertEqual(self.w.state(),before)
        finally:self.w._sync_object=old

    def test_duplicate_json_key(self):
        with self.assertRaises(SceneError):self.w.load_scene('{"format":"a","format":"b"}',fly_position_mm=[0,0,1])

    def test_hash_corrupt(self):
        self.rejected(lambda d:d['scene']['environment']['temperature'].update(celsius=31),'rejected_corrupt',False)
    def test_duplicate(self):
        self.rejected(lambda d:d['scene']['objects'].append(d['scene']['objects'][0]),'rejected_duplicate')
    def test_schema(self):
        self.rejected(lambda d:d.update(schema_version=99),'rejected_schema')
    def test_units(self):
        self.rejected(lambda d:d['units'].update(length='m'))
    def test_capacity(self):
        def mutate(d):
            box=next(o for o in d['scene']['objects'] if o['shape']=='box')
            d['scene']['objects']=[dict(box,id=f'x{i}') for i in range(100)]
        self.rejected(mutate,'rejected_capacity')
    def test_overlap_fly(self):
        self.rejected(lambda d:d['scene']['objects'][0].update(position_mm=[0,0,1]),'rejected_overlap')
    def test_overlap_spawn(self):
        self.rejected(lambda d:d['scene']['player_spawn'].update(position_mm=d['scene']['objects'][0]['position_mm']), 'rejected_overlap')
    def test_bad_numeric(self):
        self.rejected(lambda d:d['scene']['objects'][0].update(size_mm=[-1,8,6]))
    def test_asset_mismatch(self):
        self.rejected(lambda d:d['assets'].update(sandbox_models_sha256='0'*64),'rejected_assets')
    def test_corrupt_json(self):
        before=copy.deepcopy(self.w.state())
        for text in ['{','{"foo":NaN}',document_text(self.doc)*4000]:
            with self.assertRaises(SceneError):self.w.load_scene(text,fly_position_mm=[0,0,1])
            self.assertEqual(self.w.state(),before)
    def test_timed_wind_not_saved_as_continuous(self):
        self.w.wind.update(strength=.9,continuous=False,remaining_s=5)
        self.assertEqual(self.w.export_scene()['scene']['environment']['wind']['strength'],0)


class SceneBarrierTests(PauseEditTransactionTests):
    def test_scene_at_frozen_tick_and_stale_epoch_unchanged(self):
        b,w=self.b,self.w
        text=document_text(authored().export_scene());tick=b._current_owner_tick();t=b.body.t
        b.handle_line(stamped(101,'load_scene',scene_document=text)); b._apply_paused_edit_transaction()
        a=self.acks()[101]
        self.assertTrue(a['ok'],a);self.assertEqual(a['applied_tick'],tick)
        self.assertEqual(w.export_scene(),authored().export_scene());self.assertEqual(b.body.t,t)
        before=copy.deepcopy(w.state())
        bad=json.loads(stamped(102,'load_scene',scene_document=text));bad['epoch']=2
        b.handle_line(json.dumps(bad).encode());b._apply_paused_edit_transaction()
        self.assertFalse(self.acks()[102]['ok']);self.assertEqual(w.state(),before)
        b.handle_line(stamped(103,'export_scene'));b._apply_paused_edit_transaction()
        self.assertEqual(json.loads(self.acks()[103]['scene']['document_text']),w.export_scene())

    def test_deterministic_scene_barrier_does_not_drain_other_edits(self):
        b,w=self.b,self.w;b.session_mode='deterministic';tick=b._current_owner_tick()
        b.handle_line(stamped(105,'load_scene',scene_document=document_text(authored().export_scene())))
        b._apply_paused_edit_transaction(allowed_ops={'export_scene','load_scene'})
        self.assertTrue(self.acks()[105]['ok']);self.assertEqual(b._current_owner_tick(),tick)
        b.handle_line(stamped(106,'edit_property',edit=dict(schema_version=1,property_id='temperature.celsius',
                      expected_revision=w.environment_revision,unit='degC',value=30)))
        self.assertEqual(b._apply_paused_edit_transaction(allowed_ops={'export_scene','load_scene'}),0)
        self.assertEqual(w.temperature['celsius'],33)

    def test_running_load_refused(self):
        b,w=self.b,self.w;b.session_paused=False;before=copy.deepcopy(w.state())
        b.handle_line(stamped(104,'load_scene',scene_document=document_text(authored().export_scene())))
        b._apply_lab_commands(applied_tick=b._current_owner_tick(),applied_epoch=1)
        self.assertEqual(self.acks()[104]['status'],'rejected_busy');self.assertEqual(w.state(),before)

if __name__=='__main__':unittest.main(verbosity=2)
