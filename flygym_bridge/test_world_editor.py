"""V6.3 strict duplicate/delete and existing edit lifecycle; no listeners."""
from copy import deepcopy
import json
import unittest
from bridge import Bridge
from environment_properties import EditError
from lab_world import LabWorld
from protocol import (LabCommand, HelloPacket, SessionControlPacket,
                      ExperimentStepPacket, BrainPacket, encode)


def command(seq, operation, target, revision, **stamps):
    return LabCommand.from_dict(dict(type="lab_command", id=seq, action="edit_object",
        object_edit=dict(schema_version=1, operation=operation, target_id=target,
                         expected_revision=revision), **stamps))


class WorldEditorTests(unittest.TestCase):
    def rejected_untouched(self, w, payload, path, status="rejected_invalid"):
        before, events = deepcopy(w.state()), deepcopy(list(w.events))
        with self.assertRaises(EditError) as caught:
            w.edit_object(payload)
        self.assertEqual((caught.exception.path, caught.exception.status), (path, status))
        self.assertEqual(w.state(), before)
        self.assertEqual(list(w.events), events)

    def test_six_shape_duplicate_exact_and_source_unchanged(self):
        for shape, size in (("box", [6,8,10]), ("wall", [2,14,9]), ("sphere",4),
                            ("food",6), ("car",16), ("trap",22)):
            with self.subTest(shape=shape):
                w=LabWorld()
                w.spawn_object(shape=shape, object_id="source", position_mm=[40,30,10],
                               size_mm=size, yaw_deg=123, variant="apple" if shape=="food" else None)
                o=w.objects["source"]
                if shape=="trap": o.trap_state="closed"
                w.drives["source"]={"test":True}; w.feeding["source"]=1.3
                old=deepcopy(o.state()); old_world=w.revision
                result=w.apply_command(command(1,"duplicate","source",o.revision))
                clone=w.objects[result["actual_value"]]
                self.assertNotEqual(clone.object_id,o.object_id)
                self.assertEqual(result["property_id"],"object.duplicate")
                self.assertGreater(result["revision"],old_world)
                self.assertEqual(o.state(),old)
                self.assertEqual((clone.shape,clone.position_mm,clone.size_mm,clone.yaw_deg,clone.variant),
                                 (o.shape,o.position_mm,o.size_mm,o.yaw_deg,o.variant))
                self.assertNotIn(clone.object_id,w.drives)
                self.assertNotIn(clone.object_id,w.feeding)
                if shape=="trap": self.assertEqual(clone.trap_state,"armed")

    def test_validation_no_mutation(self):
        w=LabWorld(); w.spawn_object(shape="box",object_id="source")
        base=dict(schema_version=1,operation="duplicate",target_id="source",expected_revision=w.objects["source"].revision)
        for key, values in (("schema_version",[True,2,None]),("operation",[True,"move",""]),
                            ("target_id",[True," source","x"*65,"missing"]),
                            ("expected_revision",[True,-1,1.5,float("inf"),10**400])):
            for value in values:
                with self.subTest(key=key,value=str(value)[:30]):
                    status="rejected_target" if key=="target_id" and value=="missing" else "rejected_invalid"
                    self.rejected_untouched(w,dict(base,**{key:value}),"object_edit."+key,status)
        self.rejected_untouched(w,dict(base,extra=1),"object_edit.extra")
        self.rejected_untouched(w,{k:v for k,v in base.items() if k!="operation"},"object_edit.operation")
        self.rejected_untouched(w,dict(base,expected_revision=0),"object_edit.expected_revision","rejected_revision")
        w.interaction.held_object_id="source"
        for op in ("duplicate","delete"):
            self.rejected_untouched(w,dict(base,operation=op),"object_edit.target_id","rejected_target")

    def test_pool_full_and_delete_slot_bookkeeping(self):
        w=LabWorld()
        for i in range(w.state()["slot_capacity"]["trap"]): w.spawn_object(shape="trap",object_id="trap"+str(i))
        o=w.objects["trap0"]
        self.rejected_untouched(w,dict(schema_version=1,operation="duplicate",target_id=o.object_id,
                               expected_revision=o.revision),"object_edit.operation","rejected_capacity")
        w=LabWorld(); w.spawn_object(shape="food",object_id="apple",variant="apple")
        o=w.objects["apple"]; slot=o.slot
        w.feeding[o.object_id]=.4; w._eating_id=o.object_id
        w.approaches[o.object_id]={}; w.drives[o.object_id]={}; w._trap_blocked.add(o.object_id)
        result=w.apply_command(command(1,"delete",o.object_id,o.revision))
        self.assertEqual(result["actual_value"],"apple")
        for mapping in (w.objects,w.feeding,w.approaches,w.drives): self.assertNotIn("apple",mapping)
        self.assertIsNone(w._eating_id); self.assertNotIn("apple",w._trap_blocked)
        self.assertTrue(any(e["event"]=="feeding_end" for e in w.events))
        self.assertEqual(w.state()["slot_free"]["food"],w.state()["slot_capacity"]["food"])
        w.spawn_object(shape="food",object_id="reuse")
        self.assertIn(slot,w._free_slots["food"])
        for i in range(w.state()["slot_free"]["food"]): w.spawn_object(shape="food",object_id="reuse"+str(i))
        self.assertTrue(any(o.slot==slot for o in w.objects.values()))

    def test_session_epoch_future_and_replay_once(self):
        b=Bridge(mode="mock")
        b.handle_line(encode(HelloPacket(role="swift",physics_timestep_s=None)))
        b.handle_line(encode(SessionControlPacket(session_id="editor",epoch=1,seq=1,sim_tick=0,action="begin",mode="deterministic")))
        b._process_session_controls(); b._drain_lab_responses()
        w=b.body.lab_world; w.spawn_object(shape="box",object_id="source")
        rev=w.objects["source"].revision; count=len(w.objects)
        def stamped(seq,session="editor",epoch=1,tick=0):
            return command(seq,"duplicate","source",rev,session_id=session,epoch=epoch,requested_tick=tick,protocol_version=4)
        for c in (stamped(2,"wrong"),stamped(3,epoch=2),stamped(4,tick=40)):
            b.handle_line(encode(c))
        b._apply_lab_commands(applied_tick=0); responses=b._drain_lab_responses()
        self.assertEqual(len(w.objects),count)
        self.assertEqual(len([a for a in responses if not a.ok]),2)
        # Future edit remains queued until owner tick 40. A repeated command ID
        # is replayed from the ACK cache, never duplicated as a new world action.
        for i in range(3):
            b.handle_line(encode(ExperimentStepPacket(session_id="editor",epoch=1,seq=10+i,sim_tick=20*i,
                                  quantum_ticks=20,brain=BrainPacket(t=.02*i,walk=0))))
            b._process_experiment_step(b._pop_experiment_step()); b._drain_lab_responses()
        self.assertEqual(len(w.objects),count+1)
        b.handle_line(encode(stamped(4,tick=40))); b._apply_lab_commands(); b._drain_lab_responses()
        self.assertEqual(len(w.objects),count+1)

    def test_interactive_serve_loop_ack_carries_owner_boundary(self):
        # The Swift editor accepts an applied V4 ACK only with applied_tick and
        # applied_epoch. The interactive serve loop once ACKed without them, so
        # every real GUI edit applied but was reported "not confirmed".
        b=Bridge(mode="mock")
        b.handle_line(encode(HelloPacket(role="swift",physics_timestep_s=None)))
        b.handle_line(encode(SessionControlPacket(session_id="live",epoch=1,seq=1,sim_tick=0,action="begin",mode="interactive")))
        b._process_session_controls(); b._drain_lab_responses()
        w=b.body.lab_world; w.spawn_object(shape="box",object_id="box",position_mm=[60,0,5],size_mm=[10,10,10])
        tick=b._current_owner_tick()
        edit=dict(schema_version=1,property_id="object.box.position_mm",target_id="box",
                  expected_revision=w.objects["box"].revision,unit="mm",value=[70,0,5])
        b.handle_line(json.dumps({"type":"lab_command","id":7,"action":"edit_property","edit":edit,
                                  "protocol_version":4,"session_id":"live","epoch":1,
                                  "requested_tick":tick}).encode()+b"\n")
        b._apply_interactive_owner_inputs()
        ack=next(json.loads(encode(p)) for p in b._drain_lab_responses() if getattr(p,"ack",None)==7)
        self.assertTrue(ack["ok"]); self.assertEqual(ack["status"],"applied")
        self.assertEqual(ack["applied_epoch"],1)
        self.assertGreaterEqual(ack["applied_tick"],tick)
        self.assertEqual(ack["edit"]["actual_value"],[70.0,0.0,5.0])

if __name__=="__main__": unittest.main(verbosity=2)
