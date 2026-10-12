"""Real-body native Qt workflow test. With DISPLAY it runs through X11/xcb.

Without DISPLAY use QT_QPA_PLATFORM=offscreen. Both modes still require real
MuJoCo frames, CPU brain ticks, physical state and owner process cleanup.
"""

import csv
import json
import math
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QPushButton

from desktop_lab.app import LabWindow, player_forward


class DesktopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def wait_for(self, predicate, timeout=40):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.app.processEvents()
            if predicate():
                return
            time.sleep(0.01)
        self.fail("Timed out waiting for UI/backend; " + self.window.error.text())

    def click(self, text):
        widget = next(
            w
            for w in self.window.findChildren(QPushButton)
            if w.text().startswith(text)
        )
        QTest.mouseClick(widget, Qt.MouseButton.LeftButton)

    def test_mock_desktop_full_brain_pause_and_shutdown(self):
        """Runs on Windows CI without depending on a physical OpenGL driver."""
        errors = []
        self.window = w = LabWindow(mock=True)
        w.worker.failure.connect(errors.append)
        w.show()
        try:
            self.wait_for(lambda: w.worker.initialized and w.state.get("tick", 0) > 0)
            self.assertEqual(w.worker.brain.c.n, 139255)
            self.assertEqual(w.worker.brain.c.e, 15091983)
            self.assertEqual(w.pages.count(), 5)
            w.pause.setChecked(True)
            self.wait_for(lambda: w.state.get("paused"))
            tick = w.worker.session.tick
            QTest.qWait(200)
            self.assertEqual(w.worker.session.tick, tick)
            w.pause.setChecked(False)
            self.wait_for(lambda: w.state.get("tick", 0) > tick)
            self.assertFalse(errors, errors)
        finally:
            w.close()
            self.app.processEvents()
            self.assertFalse(w.worker.isRunning())
            self.assertIsNotNone(w.worker.session.process.poll())

    def test_real_desktop_edit_input_pause_record_and_shutdown(self):
        errors = []
        slots = []
        old_hook = sys.excepthook
        sys.excepthook = lambda *e: slots.append(str(e[1]))
        self.window = w = LabWindow(mock=False)
        w.worker.failure.connect(errors.append)
        w.show()
        try:
            self.wait_for(
                lambda: (
                    w.worker.initialized
                    and not w.canvas.image.isNull()
                    and w.descriptors
                ),
                # Includes full-brain JIT plus the Session's 90 s cold-start
                # allowance. Software OpenGL startup can exceed 40 s in CI.
                timeout=120,
            )
            self.assertEqual(w.pages.count(), 5)
            self.assertTrue(w.worker.brain.c.n == 139255)
            self.assertGreater(w.state["tick"], 0)
            self.assertEqual(w.canvas.image.format().name, "Format_RGB888")
            self.assertLess(w.controls.height(), 60)
            # Add and revise a real physical ramp through actual Qt buttons.
            w.shape.setCurrentText("ramp")
            w.spawn_pos[0].setValue(80)
            w.spawn_pos[1].setValue(80)
            self.click("Add object")
            self.wait_for(
                lambda: any(
                    o["shape"] == "ramp"
                    for o in w.state.get("world", {}).get("objects", [])
                )
            )
            obj = next(o for o in w.state["world"]["objects"] if o["shape"] == "ramp")
            w.select_object(obj["id"])
            w.property_choice.setCurrentIndex(
                w.property_choice.findData("object.ramp.pitch_deg")
            )
            w.property_value.setText("25")
            self.click("Apply edit")
            self.wait_for(
                lambda: (
                    next(
                        o for o in w.state["world"]["objects"] if o["id"] == obj["id"]
                    )["pitch_deg"]
                    == 25
                )
            )
            self.click("Duplicate")
            self.wait_for(
                lambda: (
                    sum(o["shape"] == "ramp" for o in w.state["world"]["objects"]) == 2
                )
            )
            self.click("Delete")
            self.wait_for(
                lambda: (
                    sum(o["shape"] == "ramp" for o in w.state["world"]["objects"]) == 1
                )
            )
            # The property boundary and ACK are shared with the macOS backend.
            w.sidebar.setCurrentRow(1)
            w.temperature.setValue(30)
            self.click("Apply temperature")
            self.wait_for(lambda: w.state["world"]["temperature"]["celsius"] == 30)
            self.click("left cover")
            self.wait_for(lambda: w.state["world"]["eyes"]["left_mask"] == 1)
            self.click("left open")
            self.wait_for(lambda: w.state["world"]["eyes"]["left_mask"] == 0)
            # Brain page draws all neuron positions and allows individual selection.
            w.sidebar.setCurrentRow(2)
            self.wait_for(lambda: not w.brain_view.image.isNull())
            self.assertEqual(len(w.brain_view.xy), 139255)
            w.neuron_selected(int(w.worker.brain.population("GF")[0]))
            self.assertIn("FlyWire", w.neuron_label.text())
            # Actual participant movement and quaternion look on the real body.
            w.mode.setCurrentText("Participate")
            self.wait_for(lambda: bool(w.state.get("snapshot", {}).get("player")))
            before = w.state["snapshot"]["player"]["position_mm"][:]
            QTest.mouseClick(w.canvas, Qt.MouseButton.LeftButton)
            QTest.keyPress(w.canvas, Qt.Key.Key_W)
            self.wait_for(
                lambda: (
                    math.dist(before, w.state["snapshot"]["player"]["position_mm"])
                    > 0.3
                )
            )
            QTest.keyRelease(w.canvas, Qt.Key.Key_W)
            w.worker.input(look=[0.2, 0])
            self.wait_for(
                lambda: abs(player_forward(w.state["snapshot"]["player"])[1]) > 0.05
            )
            QTest.keyClick(w.canvas, Qt.Key.Key_Escape)
            self.assertFalse(w.canvas.captured)
            self.assertEqual(w.worker.axes, [0.0, 0.0])
            # Pause ACK freezes both timelines, then resume advances them.
            w.pause.setChecked(True)
            self.wait_for(lambda: w.state["paused"])
            tick = w.state["tick"]
            for _ in range(20):
                self.app.processEvents()
                time.sleep(0.01)
            self.assertEqual(w.worker.session.tick, tick)
            w.pause.setChecked(False)
            self.wait_for(lambda: w.state["tick"] > tick)
            # Recording captures actual commands, seed and measured body packets.
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "session.csv"
                w.worker.submit("record", path=str(path))
                self.wait_for(lambda: w.state["recording"])
                w.worker.submit("marker", text="desktop-native-test")
                w.worker.submit(
                    "stimulate", name="DNp09", strength=0.2, duration_ms=100
                )
                self.wait_for(lambda: path.stat().st_size > 10000)
                w.worker.submit("record", path=None)
                self.wait_for(lambda: not w.state["recording"])
                with path.open(encoding="utf-8") as recorded:
                    rows = list(csv.DictReader(recorded))
                kinds = {r["kind"] for r in rows}
                self.assertTrue(
                    {"session", "marker", "direct_neural", "telemetry"}.issubset(kinds)
                )
                for r in rows:
                    p = json.loads(r["json"])
                    if r["kind"] == "telemetry":
                        self.assertAlmostEqual(
                            p["body"]["t"] * 1000, int(r["sim_tick_ms"]), places=6
                        )
            artifact = os.environ.get("TEST_ARTIFACT_DIR")
            if artifact:
                Path(artifact).mkdir(parents=True, exist_ok=True)
                w.mode.setCurrentText("Observe")
                w.sidebar.setCurrentRow(0)
                self.app.processEvents()
                w.grab().save(str(Path(artifact) / "desktop.png"))
            self.assertFalse(errors, errors)
            self.assertFalse(slots, slots)
        finally:
            w.close()
            self.app.processEvents()
            sys.excepthook = old_hook
            self.assertFalse(w.worker.isRunning())
            self.assertIsNotNone(w.worker.session.process.poll())


if __name__ == "__main__":
    unittest.main()
