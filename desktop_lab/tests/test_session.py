import socket
import time
import unittest
from pathlib import Path

from desktop_lab.session import Session

ROOT = Path(__file__).resolve().parents[2]


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.session = Session(ROOT, mock=True, render=False).start()

    def tearDown(self):
        self.session.close()

    def test_exact_quantum_and_pause_barrier(self):
        s = self.session
        for _ in range(3):
            s.step({"walk": 0.35})
        self.assertEqual(s.tick, 60)
        self.assertAlmostEqual(s.body["t"], 0.06)
        s.control("pause")
        with self.assertRaises(RuntimeError):
            s.step({"walk": 0.35})
        self.assertEqual(s.tick, 60)
        s.control("resume")
        s.step({"walk": 0.35})
        self.assertEqual(s.tick, 80)

    def test_command_ack_and_authoritative_snapshot(self):
        s = self.session
        seq = s.command(
            "spawn_box",
            {"id": "linux-test", "position_mm": [40, 0, 5], "size_mm": [5, 5, 5]},
        )
        s.step({"walk": 0})
        ack = next(a for a in s.acks if a["ack"] == seq)
        self.assertTrue(ack["ok"])
        self.assertEqual(ack["applied_tick"], 0)
        snapshot = s.view_snapshot()
        self.assertEqual(snapshot["sim_tick"], 20)
        self.assertTrue(any(o["id"] == "linux-test" for o in snapshot["objects"]))

    def test_revision_conflict_is_reported_without_mutation(self):
        s = self.session
        s.command(
            "spawn_box",
            {"id": "revision-box", "position_mm": [40, 0, 5], "size_mm": [5, 5, 5]},
        )
        s.step({})
        obj = next(o for o in s.world["objects"] if o["id"] == "revision-box")
        edit = {
            "schema_version": 1,
            "property_id": "object.yaw_deg",
            "unit": "deg",
            "target_id": obj["id"],
            "expected_revision": obj["revision"],
            "value": 25,
        }
        seq = s.command("edit_property", {"edit": edit})
        s.step({})
        self.assertTrue(next(a for a in s.acks if a["ack"] == seq)["ok"])
        edit["value"] = 90
        seq = s.command("edit_property", {"edit": edit})
        s.step({})
        self.assertFalse(next(a for a in s.acks if a["ack"] == seq)["ok"])
        self.assertEqual(
            next(o for o in s.world["objects"] if o["id"] == obj["id"])["yaw_deg"], 25
        )

    def test_owned_process_stops_and_private_port_closes(self):
        s = self.session
        pid = s.process.pid
        port = s.port
        s.close()
        self.assertIsNotNone(s.process.poll())
        self.assertGreater(pid, 0)
        # Windows may finish socket teardown just after the process handle is
        # signaled. Require the port to close within a bounded interval, and
        # close every successful probe rather than leaking sockets on failure.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    pass
            except OSError:
                break
            time.sleep(0.05)
        else:
            self.fail("owned backend port remained open after process exit")


if __name__ == "__main__":
    unittest.main()
