"""In-process regressions for pre-V7.2 fixes; no sockets or real body."""
import unittest
from bridge import Bridge
from protocol import LabEventPacket, encode
from view_stream import ViewStream


class RefactorRegressionTests(unittest.TestCase):
    def test_paused_transaction_failure_is_contained(self):
        bridge = Bridge(mode="mock")
        def fail(allowed_ops=None):
            raise RuntimeError("fixture failure")
        bridge._apply_paused_edit_transaction = fail
        self.assertFalse(bridge._try_paused_edit_transaction({"load_scene", "export_scene"}))
        self.assertFalse(bridge._try_paused_edit_transaction())

    def test_event_identity_survives_encoding(self):
        event = LabEventPacket(event="wind_complete", session_id="s", epoch=2, sim_tick=40)
        import json
        data = json.loads(encode(event))
        self.assertEqual((data["session_id"], data["epoch"], data["sim_tick"]), ("s", 2, 40))

    def test_buffered_event_keeps_old_epoch_before_reset(self):
        from protocol import HelloPacket, SessionControlPacket
        bridge = Bridge(mode="mock")
        bridge.handle_line(encode(HelloPacket(role="swift")))
        bridge.handle_line(encode(SessionControlPacket(session_id="s", seq=1, action="begin", mode="interactive")))
        bridge._process_session_controls(); bridge._drain_lab_responses()
        bridge.body.lab_world.events.append({"event": "old"})
        bridge.handle_line(encode(SessionControlPacket(session_id="s", epoch=2, seq=2, action="reset", reset_scope=[])))
        bridge._process_session_controls()
        events = [p for p in bridge._drain_lab_responses() if isinstance(p, LabEventPacket)]
        self.assertEqual([(p.event, p.epoch) for p in events], [("old", 1)])

    def test_view_input_is_bounded(self):
        # Exercise the production reader with an in-memory peer.
        class Peer:
            reads = 0
            def recv(self, size):
                self.reads += 1
                return b"x" * 4096
        stream = ViewStream.__new__(ViewStream)
        stream._running = True
        dropped = []
        stream._drop = dropped.append
        peer = Peer()
        stream._read_loop(peer)
        self.assertEqual(peer.reads, 513)
        self.assertEqual(dropped, [peer])


if __name__ == "__main__":
    unittest.main()
