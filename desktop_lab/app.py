"""Native Linux/Windows desktop window; reuses the production MuJoCo world renderer."""

from __future__ import annotations

import argparse
import math
import platform
import sys
from pathlib import Path

import numpy as np
from PySide6.QtCore import QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QCursor, QImage, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QPushButton,
    QScrollArea,
    QSpinBox,
    QSplitter,
    QStackedWidget,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .brain import GROUP_NAMES
from .brain_view import BrainView
from .worker import LabWorker

ROOT = Path(__file__).resolve().parents[1]


def player_forward(player):
    """Rotate the participant's +X look axis by its authoritative quaternion."""
    x, y, z, w = player.get("orientation_quat_xyzw", [0, 0, 0, 1])
    return [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)]


def number(lo, hi, value, decimals=2):
    widget = QDoubleSpinBox()
    widget.setDecimals(decimals)
    widget.setRange(lo, hi)
    widget.setValue(value)
    return widget


def button(text, callback):
    widget = QPushButton(text)
    widget.clicked.connect(lambda checked=False: callback())
    return widget


class Canvas(QWidget):
    camera_changed = Signal(dict)
    input_changed = Signal(list, list)
    interact = Signal()
    shoot = Signal()
    equip = Signal()
    pick = Signal(list, list)

    def __init__(self):
        super().__init__()
        self.setMinimumSize(480, 360)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMouseTracking(True)
        self.image, self.state = QImage(), {}
        self.mode = "Observe"
        self.captured = False
        self.keys = set()
        self.yaw, self.pitch, self.distance = -0.9, 0.45, 65.0
        self.last = None
        self.setToolTip(
            "Observe: right-drag to orbit, wheel to zoom. Participate: click, WASD, mouse, E grab/place, G equip, F fire, Esc release."
        )

    def set_frame(self, image):
        self.image = image
        self.update()

    def release(self):
        self.keys.clear()
        self.input_changed.emit([0.0, 0.0], [0.0, 0.0])
        if self.captured:
            self.releaseMouse()
            self.unsetCursor()
        self.captured = False

    def set_mode(self, mode):
        self.release()
        self.mode = mode
        self.update_camera()

    def camera(self):
        offset = [
            self.distance * math.cos(self.pitch) * math.cos(self.yaw),
            self.distance * math.cos(self.pitch) * math.sin(self.yaw),
            self.distance * math.sin(self.pitch),
        ]
        forward = [-v / self.distance for v in offset]
        player = (
            self.state.get("snapshot", {}).get("player")
            or self.state.get("world", {}).get("player")
            or {}
        )
        anchor = "participant_first" if self.mode == "Participate" else "fly"
        fly = self.state.get("snapshot", {}).get("fly") or {}
        position = fly.get(
            "position_mm",
            [
                self.state.get("body", {}).get("position_x_mm", 0),
                self.state.get("body", {}).get("position_y_mm", 0),
                1,
            ],
        )
        if anchor == "participant_first":
            position = player.get("position_mm", [24, 0, 3])
            forward = player_forward(player)
        else:
            position = [a + b for a, b in zip(position, offset)]
        width = max(64, min(1000, self.width()))
        height = max(64, min(750, round(width * self.height() / max(1, self.width()))))
        return {
            "type": "view",
            "width": width,
            "height": height,
            "position_mm": position,
            "forward": forward,
            "distance_mm": self.distance,
            "fovy_deg": 45,
            "anchor": anchor,
            "offset_mm": offset,
        }

    def update_camera(self):
        self.camera_changed.emit(self.camera())

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("#18211e"))
        if not self.image.isNull():
            painter.drawImage(self.rect(), self.image)
        else:
            painter.setPen(QColor("#e0e9df"))
            painter.drawText(
                18,
                28,
                "MOCK · top-down diagram / 모의 월드 평면도"
                if self.state
                else "Starting / 시작 중…",
            )
            if self.state:
                objects = self.state.get("world", {}).get("objects", [])
                scale = min(self.width(), self.height()) / 180
                for obj in objects:
                    x, y, _ = obj.get("position_mm", [0, 0, 0])
                    size = obj.get("size_mm", [5, 5, 5])
                    painter.setBrush(
                        QColor("#dbb85a" if obj.get("shape") == "food" else "#789aac")
                    )
                    painter.drawRect(
                        QRectF(
                            self.width() / 2 + x * scale - size[0] * scale / 2,
                            self.height() / 2 - y * scale - size[1] * scale / 2,
                            size[0] * scale,
                            size[1] * scale,
                        )
                    )
                body = self.state.get("body", {})
                painter.setBrush(QColor("#f46a61"))
                painter.drawEllipse(
                    QRectF(
                        self.width() / 2 + body.get("position_x_mm", 0) * scale - 4,
                        self.height() / 2 - body.get("position_y_mm", 0) * scale - 4,
                        8,
                        8,
                    )
                )
        if self.mode == "Participate":
            painter.setPen(QPen(QColor("white"), 2))
            x, y = self.width() // 2, self.height() // 2
            painter.drawLine(x - 8, y, x + 8, y)
            painter.drawLine(x, y - 8, x, y + 8)

    def mousePressEvent(self, event):
        self.setFocus()
        if self.mode == "Participate" and event.button() == Qt.MouseButton.LeftButton:
            self.captured = True
            self.grabMouse()
            self.setCursor(Qt.CursorShape.BlankCursor)
            QCursor.setPos(self.mapToGlobal(self.rect().center()))
        elif self.mode == "Edit" and event.button() == Qt.MouseButton.LeftButton:
            camera = self.camera()
            forward = np.array(camera["forward"], dtype=float)
            forward /= np.linalg.norm(forward)
            right = np.cross(forward, [0, 0, 1])
            right /= np.linalg.norm(right)
            up = np.cross(right, forward)
            nx, ny = (
                2 * event.position().x() / self.width() - 1,
                1 - 2 * event.position().y() / self.height(),
            )
            ray = forward + math.tan(math.pi / 8) * (
                nx * self.width() / self.height() * right + ny * up
            )
            ray /= np.linalg.norm(ray)
            self.pick.emit(camera["position_mm"], ray.tolist())
        self.last = event.position()

    def mouseMoveEvent(self, event):
        if self.captured:
            delta = event.position() - self.rect().center()
            if delta.manhattanLength() > 0:
                self.input_changed.emit(
                    self.axes(), [-delta.x() * 0.0015, -delta.y() * 0.0015]
                )
                QCursor.setPos(self.mapToGlobal(self.rect().center()))
        elif event.buttons() & Qt.MouseButton.RightButton and self.last is not None:
            delta = event.position() - self.last
            self.yaw -= delta.x() * 0.008
            self.pitch = min(1.4, max(0.05, self.pitch + delta.y() * 0.008))
            self.update_camera()
        self.last = event.position()

    def wheelEvent(self, event):
        self.distance = max(
            8, min(300, self.distance * math.exp(-event.angleDelta().y() / 1200))
        )
        self.update_camera()

    def axes(self):
        return [
            float((Qt.Key.Key_W in self.keys) - (Qt.Key.Key_S in self.keys)),
            float((Qt.Key.Key_D in self.keys) - (Qt.Key.Key_A in self.keys)),
        ]

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape:
            self.release()
            return
        if self.mode != "Participate" or not self.captured or event.isAutoRepeat():
            return
        self.keys.add(event.key())
        self.input_changed.emit(self.axes(), [0.0, 0.0])
        if event.key() == Qt.Key.Key_E:
            self.interact.emit()
        if event.key() == Qt.Key.Key_G:
            self.equip.emit()
        if event.key() == Qt.Key.Key_F:
            self.shoot.emit()

    def keyReleaseEvent(self, event):
        if not event.isAutoRepeat():
            self.keys.discard(event.key())
            self.input_changed.emit(self.axes(), [0.0, 0.0])

    def focusOutEvent(self, event):
        self.release()
        super().focusOutEvent(event)

    def resizeEvent(self, event):
        self.update_camera()
        super().resizeEvent(event)


class LabWindow(QMainWindow):
    def __init__(self, mock=False, seed=0x5EED1F1F, start=True):
        super().__init__()
        self.setWindowTitle(f"Thongpari · Virtual Fly Lab — {platform.system()}")
        self.resize(1320, 830)
        self.mock, self.state, self.descriptors = mock, {}, []
        self.worker = LabWorker(ROOT, mock=mock, seed=seed)
        self.worker.telemetry.connect(self.update_state)
        self.worker.frame.connect(self.receive_frame)
        self.worker.status.connect(self.statusBar().showMessage)
        self.worker.failure.connect(self.show_error)
        self.worker.acknowledged.connect(self.acknowledge)
        self.worker.ready.connect(self.on_ready)
        self.worker.picked.connect(self.select_object)
        self.controls = QWidget()
        self.controls.setFixedHeight(48)
        self.controls.setEnabled(False)
        root = QWidget()
        layout = QVBoxLayout(root)
        toolbar = QHBoxLayout()
        title = QLabel(
            "<b>Virtual Fly Lab</b> · " + platform.system() + " · "
            + ("MOCK" if mock else "FlyGym / MuJoCo")
        )
        toolbar.addWidget(title)
        toolbar.addStretch()
        self.mode = QComboBox()
        self.mode.addItems(["Observe", "Participate", "Edit"])
        self.mode.currentTextChanged.connect(self.change_mode)
        toolbar.addWidget(self.mode)
        self.pause = QCheckBox("Pause / 일시정지")
        self.pause.toggled.connect(self.pause_changed)
        toolbar.addWidget(self.pause)
        self.record_button = button("Record CSV / 기록", self.toggle_record)
        toolbar.addWidget(self.record_button)
        toolbar.addWidget(
            button("Reset brain + body / 초기화", lambda: self.worker.submit("reset"))
        )
        top = QVBoxLayout(self.controls)
        top.setContentsMargins(0, 0, 0, 0)
        top.addLayout(toolbar)
        layout.addWidget(self.controls)
        split = QSplitter()
        self.sidebar = QListWidget()
        self.sidebar.addItems(
            [
                "World / 월드",
                "Stimuli / 자극",
                "Brain / 뇌",
                "Data / 데이터",
                "Experiment / 실험",
            ]
        )
        self.sidebar.setMaximumWidth(170)
        split.addWidget(self.sidebar)
        center = QWidget()
        cl = QVBoxLayout(center)
        cl.setContentsMargins(0, 0, 0, 0)
        self.canvas = Canvas()
        cl.addWidget(self.canvas, 1)
        self.summary = QLabel("Loading / 로딩 중…")
        self.summary.setWordWrap(True)
        self.summary.setMaximumHeight(48)
        cl.addWidget(self.summary)
        self.error = QLabel()
        self.error.setWordWrap(True)
        self.error.setMaximumHeight(72)
        self.error.setStyleSheet("color: #b22")
        cl.addWidget(self.error)
        split.addWidget(center)
        self.pages = QStackedWidget()
        self.pages.setMinimumWidth(335)
        self.pages.setMaximumWidth(470)
        for page in [
            self.world_page(),
            self.stimuli_page(),
            self.brain_page(),
            self.data_page(),
            self.experiment_page(),
        ]:
            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setWidget(page)
            self.pages.addWidget(scroll)
        self.pages.setEnabled(False)
        split.addWidget(self.pages)
        split.setSizes([155, 800, 365])
        layout.addWidget(split)
        self.sidebar.currentRowChanged.connect(self.pages.setCurrentIndex)
        self.sidebar.setCurrentRow(0)
        self.canvas.camera_changed.connect(self.set_camera)
        self.canvas.input_changed.connect(self.worker.input)
        self.canvas.interact.connect(self.interact)
        self.canvas.equip.connect(
            lambda: self.command("equip_gun", actor_id="player", equipped=True)
        )
        self.canvas.shoot.connect(self.shoot)
        self.canvas.pick.connect(
            lambda origin, direction: self.worker.submit(
                "pick", origin=origin, direction=direction
            )
        )
        self.setCentralWidget(root)
        if start:
            self.worker.start()

    def command(self, op, **args):
        self.worker.submit("command", op=op, args=args)

    def show_error(self, error):
        self.error.setText(error)

    def on_ready(self):
        self.controls.setEnabled(True)
        self.pages.setEnabled(True)
        self.canvas.update_camera()
        self.brain_view.bind(self.worker.brain.c)

    def receive_frame(self, image):
        self.canvas.set_frame(image)

    def set_camera(self, camera):
        if self.worker.initialized:
            self.worker.submit("camera", **camera)

    def change_mode(self, mode):
        self.canvas.set_mode(mode)
        self.worker.submit("participate", active=mode == "Participate")

    def pause_changed(self, paused):
        self.canvas.release()
        self.worker.submit("pause", paused=paused)

    def acknowledge(self, ack):
        if not ack.get("ok"):
            self.show_error(ack.get("error", "Command rejected / 명령 거부"))
        else:
            self.applied.setText(
                "Applied / 적용 완료: "
                + str((ack.get("edit") or {}).get("actual_value", "✓"))
            )

    def world_page(self):
        page = QWidget()
        l = QVBoxLayout(page)
        l.addWidget(QLabel("<b>Physical world / 물리 월드</b>"))
        self.objects = QListWidget()
        self.objects.setMinimumHeight(150)
        self.objects.currentRowChanged.connect(self.refresh_properties)
        l.addWidget(self.objects)
        self.shape = QComboBox()
        self.shape.addItems(["box", "sphere", "wall", "ramp", "food", "car", "trap"])
        l.addWidget(self.shape)
        form = QFormLayout()
        self.spawn_pos = [number(-500, 500, v) for v in [30, 0, 5]]
        for label, w in zip(["X (mm)", "Y (mm)", "Z (mm)"], self.spawn_pos):
            form.addRow(label, w)
        self.spawn_size = number(1, 60, 10)
        form.addRow("Size / 크기 (mm)", self.spawn_size)
        l.addLayout(form)
        l.addWidget(button("Add object / 추가", self.spawn))
        row = QHBoxLayout()
        row.addWidget(
            button("Duplicate / 복제", lambda: self.object_operation("duplicate"))
        )
        row.addWidget(button("Delete / 삭제", lambda: self.object_operation("delete")))
        l.addLayout(row)
        self.property_choice = QComboBox()
        self.property_choice.currentIndexChanged.connect(self.property_changed)
        l.addWidget(self.property_choice)
        self.property_value = QLineEdit()
        self.property_value.setPlaceholderText("Value / 값 (vector: x, y, z)")
        l.addWidget(self.property_value)
        self.property_note = QLabel()
        self.property_note.setWordWrap(True)
        l.addWidget(self.property_note)
        l.addWidget(button("Apply edit / 편집 적용", self.edit_object_property))
        self.applied = QLabel(
            "Edits apply at the next running tick / 편집은 재개 후 다음 틱에 적용됩니다"
        )
        self.applied.setWordWrap(True)
        l.addWidget(self.applied)
        l.addWidget(
            button(
                "Drive selected car / 자동차 출발",
                lambda: self.selected_command(
                    "drive_object", speed_mm_s=20, distance_mm=80
                ),
            )
        )
        l.addWidget(
            button(
                "Re-arm selected trap / 덫 재설정",
                lambda: self.selected_command("arm_trap"),
            )
        )
        l.addWidget(
            button("Reset world / 월드 초기화", lambda: self.command("reset_world"))
        )
        hint = QLabel(
            "Observe: right-drag orbit · wheel zoom\nParticipate: click canvas · WASD · mouse · E grab/place · G equip · F fire · Esc release\nEdit: click an object or select it above; edit values, duplicate or delete."
        )
        hint.setWordWrap(True)
        l.addWidget(hint)
        l.addStretch()
        return page

    def selected(self):
        item = self.objects.currentItem()
        if item:
            return next(
                (
                    o
                    for o in self.state.get("world", {}).get("objects", [])
                    if o["id"] == item.data(Qt.ItemDataRole.UserRole)
                ),
                None,
            )
        return None

    def select_object(self, target):
        for i in range(self.objects.count()):
            if self.objects.item(i).data(Qt.ItemDataRole.UserRole) == target:
                self.objects.setCurrentRow(i)
                break

    def spawn(self):
        shape = self.shape.currentText()
        size = self.spawn_size.value()
        self.command(
            "spawn_object",
            shape=shape,
            position_mm=[w.value() for w in self.spawn_pos],
            size_mm=size if shape in ("car", "trap") else [size, size, size],
        )

    def selected_command(self, op, **args):
        obj = self.selected()
        if obj:
            self.command(op, id=obj["id"], **args)

    def object_operation(self, operation):
        obj = self.selected()
        if obj:
            self.command(
                "edit_object",
                object_edit={
                    "schema_version": 1,
                    "operation": operation,
                    "target_id": obj["id"],
                    "expected_revision": obj["revision"],
                },
            )

    def refresh_properties(self):
        obj = self.selected()
        prior = self.property_choice.currentData()
        self.property_choice.blockSignals(True)
        self.property_choice.clear()
        if obj:
            for d in self.descriptors:
                pid = d["property_id"]
                if d["apply_mode"] != "spawn_only" and pid.startswith("object.") and (
                    pid.count(".") == 1 or pid.split(".")[1] == obj["shape"]
                ):
                    self.property_choice.addItem(
                        d["label"] + " (" + d["unit"] + ")", pid
                    )
        index = self.property_choice.findData(prior)
        self.property_choice.setCurrentIndex(max(0, index))
        self.property_choice.blockSignals(False)
        self.property_changed()

    def property_changed(self):
        obj = self.selected()
        pid = self.property_choice.currentData()
        d = next((d for d in self.descriptors if d["property_id"] == pid), None)
        if d and obj:
            value = obj.get(d["legacy_field"], d["default"])
            if d["value_type"] == "number" and isinstance(value, list):
                value = value[0]
            self.property_value.setText(
                ", ".join(str(v) for v in value)
                if isinstance(value, list)
                else str(value)
            )
            self.property_note.setText(
                f"{' · '.join(d['supported_effects'])}\nRange / 범위: {d['min']} … {d['max']}"
            )

    def edit_object_property(self):
        obj = self.selected()
        pid = self.property_choice.currentData()
        d = next((d for d in self.descriptors if d["property_id"] == pid), None)
        if not obj or not d:
            return
        try:
            text = self.property_value.text()
            value = (
                [float(v.strip()) for v in text.split(",")]
                if d["value_type"] == "vector"
                else float(text)
            )
            if not np.all(np.isfinite(value)):
                raise ValueError("Value must be finite / 유한한 값이 필요합니다")
            self.edit(pid, value, obj)
        except ValueError as exc:
            self.show_error(str(exc))

    def edit(self, pid, value, obj=None):
        d = next((d for d in self.descriptors if d["property_id"] == pid), None)
        if d:
            self.applied.setText("Pending / 적용 대기 중…")
            self.command(
                "edit_property",
                edit={
                    "schema_version": 1,
                    "property_id": pid,
                    "unit": d["unit"],
                    "target_id": obj["id"] if obj else None,
                    "value": value,
                    "expected_revision": obj["revision"]
                    if obj
                    else self.state.get("world", {}).get("environment_revision", 0),
                },
            )

    def stimuli_page(self):
        page = QWidget()
        l = QVBoxLayout(page)
        l.addWidget(QLabel("<b>Environment / 환경</b>"))
        self.at_fly = QLabel()
        self.at_fly.setWordWrap(True)
        l.addWidget(self.at_fly)
        form = QFormLayout()
        self.temperature = number(10, 40, 25)
        self.temp_mode = QComboBox()
        self.temp_mode.addItems(
            ["environment_only", "modeled_physiology", "flywire_sensory"]
        )
        form.addRow("Temperature / 온도 °C", self.temperature)
        form.addRow("Model / 모델", self.temp_mode)
        l.addLayout(form)
        # Separate revision-checked edits avoid silently rewriting other settings.
        l.addWidget(
            button(
                "Apply temperature / 온도 적용",
                lambda: self.edit("temperature.celsius", self.temperature.value()),
            )
        )
        l.addWidget(
            button(
                "Apply model / 모델 적용",
                lambda: self.edit("temperature.mode", self.temp_mode.currentText()),
            )
        )
        self.wind = number(0, 1, 0)
        self.direction = number(0, 360, 0)
        self.wind_physical = QCheckBox("Physical force / 물리력")
        self.wind_physical.setChecked(True)
        self.wind_sensory = QCheckBox("Sensory model / 감각 모델")
        self.wind_sensory.setChecked(True)
        f = QFormLayout()
        f.addRow("Wind / 바람", self.wind)
        f.addRow("Direction / 방향 °", self.direction)
        l.addLayout(f)
        l.addWidget(self.wind_physical)
        l.addWidget(self.wind_sensory)
        l.addWidget(
            button(
                "Apply continuous wind / 지속 바람",
                lambda: self.command(
                    "wind",
                    strength=self.wind.value(),
                    direction_deg=self.direction.value(),
                    continuous=True,
                    physical=self.wind_physical.isChecked(),
                    sensory=self.wind_sensory.isChecked(),
                ),
            )
        )
        l.addWidget(button("Stop wind / 바람 중지", lambda: self.command("stop_wind")))
        for eye in ["left", "right"]:
            row = QHBoxLayout()
            row.addWidget(
                button(
                    eye + " cover / 가리기",
                    lambda eye=eye: self.command(
                        "set_eye_state", **{eye + "_mask": 1.0}
                    ),
                )
            )
            row.addWidget(
                button(
                    eye + " open / 열기",
                    lambda eye=eye: self.command(
                        "set_eye_state", **{eye + "_mask": 0.0}
                    ),
                )
            )
            l.addLayout(row)
        l.addWidget(
            button(
                "Flash both eyes / 양쪽 눈 섬광",
                lambda: self.command(
                    "flash_eye", eye="both", strength=1.0, duration_ms=200
                ),
            )
        )
        self.touch_target = QComboBox()
        self.touch_target.addItems(
            ["thorax", "head", "abdomen", "lf", "lm", "lh", "rf", "rm", "rh"]
        )
        l.addWidget(self.touch_target)
        l.addWidget(
            button(
                "Physical touch / 물리 접촉",
                lambda: self.command(
                    "touch",
                    target=self.touch_target.currentText(),
                    strength=0.55,
                    duration_ms=150,
                    sensory=True,
                ),
            )
        )
        l.addStretch()
        return page

    def brain_page(self):
        page = QWidget()
        l = QVBoxLayout(page)
        text = QLabel(
            "<b>Full FlyWire v783 / 전체 뇌</b><br>139,255 neurons · 15,091,983 edges<br>CPU float32 · 1 ms ticks<br>DIRECT-NEURAL / 직접 신경 자극"
        )
        text.setWordWrap(True)
        l.addWidget(text)
        self.brain_view = BrainView()
        self.brain_view.selected.connect(self.neuron_selected)
        l.addWidget(self.brain_view)
        self.neuron_label = QLabel(
            "Drag to rotate · click to select / 드래그 회전 · 클릭 선택"
        )
        self.neuron_label.setWordWrap(True)
        l.addWidget(self.neuron_label)
        self.population = QComboBox()
        self.population.addItems(list(GROUP_NAMES[1:]) + ["ascend", "sens"])
        l.addWidget(self.population)
        self.strength = number(0, 1, 0.15, 3)
        self.duration = QSpinBox()
        self.duration.setRange(1, 10000)
        self.duration.setValue(200)
        form = QFormLayout()
        form.addRow("Current / 전류", self.strength)
        form.addRow("Duration / 지속 ms", self.duration)
        l.addLayout(form)
        l.addWidget(
            button(
                "Stimulate / 자극",
                lambda: self.worker.submit(
                    "stimulate",
                    name=self.population.currentText(),
                    strength=self.strength.value(),
                    duration_ms=self.duration.value(),
                ),
            )
        )
        l.addWidget(
            button("Stimulate selected neuron / 선택 뉴런 자극", self.stimulate_neuron)
        )
        self.rate_table = QTableWidget(len(GROUP_NAMES), 2)
        self.rate_table.setHorizontalHeaderLabels(["Population / 집단", "Hz"])
        self.rate_table.horizontalHeader().setSectionResizeMode(
            QHeaderView.ResizeMode.Stretch
        )
        self.rate_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        for i, name in enumerate(GROUP_NAMES):
            self.rate_table.setItem(i, 0, QTableWidgetItem(name))
        l.addWidget(self.rate_table)
        return page

    def neuron_selected(self, index):
        c = self.worker.brain.c
        self.neuron_label.setText(
            f"FlyWire {int(c.rootId[index])}\n{c.tables['cellTypes'][c.cellType[index]]} · {c.tables['roles'][c.role[index]]}"
        )

    def stimulate_neuron(self):
        if self.brain_view.index is not None:
            self.worker.submit(
                "stimulate_neuron",
                index=self.brain_view.index,
                strength=self.strength.value(),
                duration_ms=self.duration.value(),
            )

    def data_page(self):
        page = QWidget()
        l = QVBoxLayout(page)
        l.addWidget(QLabel("<b>Measured simulated body / 시뮬레이션 측정값</b>"))
        self.body_table = QTableWidget(0, 2)
        self.body_table.setHorizontalHeaderLabels(["Signal / 신호", "Value / 값"])
        self.body_table.horizontalHeader().setSectionResizeMode(
            QHeaderView.ResizeMode.Stretch
        )
        self.body_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        l.addWidget(self.body_table)
        label = QLabel(
            "Receptor currents and motor readouts are engineering models. Hunger is unsupported.\n감각 전류와 운동 출력은 공학 모델입니다. 배고픔은 지원하지 않습니다."
        )
        label.setWordWrap(True)
        l.addWidget(label)
        return page

    def experiment_page(self):
        page = QWidget()
        l = QVBoxLayout(page)
        text = QLabel(
            "<b>Deterministic experiment / 결정론적 실험</b><br>Brain 20 × 1 ms → body exact 20 ms.<br>Pause stops both timelines. CPU speed changes wall time, not simulated time."
        )
        text.setWordWrap(True)
        l.addWidget(text)
        self.marker = QLineEdit()
        self.marker.setPlaceholderText("Trial marker / 실험 마커")
        l.addWidget(self.marker)
        l.addWidget(
            button(
                "Mark / 마커 기록",
                lambda: self.worker.submit("marker", text=self.marker.text()),
            )
        )
        for name, pop, strength, ms in [
            ("GF", "GF", 0.5, 40),
            ("DNa-left", "DNa-left", 0.3, 900),
            ("DNa-right", "DNa-right", 0.3, 900),
            ("MDN", "MDN", 0.3, 900),
            ("DNp09", "DNp09", 0.2, 900),
        ]:
            l.addWidget(
                button(
                    "DIRECT-NEURAL · " + name,
                    lambda pop=pop, strength=strength, ms=ms: self.worker.submit(
                        "stimulate", name=pop, strength=strength, duration_ms=ms
                    ),
                )
            )
        l.addWidget(
            button(
                "PHYSICAL · wind puff / 바람 펄스",
                lambda: self.command(
                    "wind",
                    strength=0.7,
                    duration_ms=500,
                    direction_deg=0.0,
                    physical=True,
                    sensory=True,
                    continuous=False,
                ),
            )
        )
        l.addWidget(button("PHYSICAL · frontal loom / 정면 접근", self.frontal_loom))
        l.addWidget(
            QLabel(
                "CSV stores seed, commands, neural rates, body packets and ACKs.\n기록: 시드·명령·발화율·몸 상태·응답"
            )
        )
        l.addStretch()
        return page

    def frontal_loom(self):
        self.command(
            "spawn_box", id="desktop_loom", position_mm=[60, 0, 5], size_mm=[10, 10, 10]
        )
        self.command(
            "approach_object", id="desktop_loom", speed_mm_s=80, end_distance_mm=8
        )

    def toggle_record(self):
        if self.state.get("recording"):
            self.worker.submit("record", path=None)
            return
        path, _ = QFileDialog.getSaveFileName(
            self,
            "Record CSV / CSV 기록",
            str(Path.home() / "fly-lab.csv"),
            "CSV (*.csv)",
        )
        if path:
            self.worker.submit("record", path=path)

    def player_ray(self):
        player = (
            self.state.get("snapshot", {}).get("player")
            or self.state.get("world", {}).get("player")
            or {}
        )
        return player.get("position_mm", [24, 0, 3]), player_forward(player)

    def interact(self):
        held = self.state.get("world", {}).get("interaction", {}).get("held_object_id")
        if held:
            self.command(
                "interaction", tool_id="place", actor_id="player", target_id=held
            )
        else:
            origin, direction = self.player_ray()
            self.command(
                "interaction",
                tool_id="grab",
                actor_id="player",
                ray_origin_mm=origin,
                ray_direction=direction,
            )

    def shoot(self):
        _, direction = self.player_ray()
        self.command("fire_bb", actor_id="player", direction=direction)

    def update_state(self, state):
        self.state = state
        self.canvas.state = state
        self.canvas.update()
        world = state.get("world", {})
        body = state.get("body", {})
        self.summary.setText(
            f"Time / 시간 {state['tick'] / 1000:.3f} s · CPU brain / {'mock' if self.mock else 'real MuJoCo'} · sim/wall {state['ratio']:.2f}× · "
            + ("PAUSED / 정지" if state["paused"] else "RUNNING / 실행 중")
        )
        if state.get("render_error"):
            self.show_error("MuJoCo rendering: " + state["render_error"])
        self.record_button.setText(
            "Stop recording / 기록 중지"
            if state.get("recording")
            else "Record CSV / 기록"
        )
        old = self.selected()
        old_id = old["id"] if old else None
        objects = world.get("objects", [])
        ids = [o["id"] for o in objects]
        existing = [
            self.objects.item(i).data(Qt.ItemDataRole.UserRole)
            for i in range(self.objects.count())
        ]
        if ids != existing:
            self.objects.blockSignals(True)
            self.objects.clear()
            for o in objects:
                self.objects.addItem(o["id"] + " · " + o["shape"])
                self.objects.item(self.objects.count() - 1).setData(
                    Qt.ItemDataRole.UserRole, o["id"]
                )
            self.objects.blockSignals(False)
            if old_id:
                self.select_object(old_id)
            if self.objects.currentRow() < 0 and self.objects.count():
                self.objects.setCurrentRow(0)
        descriptors = world.get("environment_capabilities", {}).get("descriptors", [])
        if descriptors and descriptors != self.descriptors:
            self.descriptors = descriptors
            self.refresh_properties()
        self.at_fly.setText(
            f"Applied / 적용 상태: {world.get('temperature', {}).get('celsius', 25)} °C\nWind / 바람 {body.get('wind_strength', 0):.2f} · heading / 방향 {body.get('heading_rad', 0):.2f}\nOdor / 냄새 {body.get('odor_left', 0):.3f}, {body.get('odor_right', 0):.3f}\nSugar contact / 설탕 접촉 {body.get('taste_sugar', 0):.3f}"
        )
        for i, rate in enumerate(state.get("rates", [])):
            self.rate_table.setItem(i, 1, QTableWidgetItem(f"{rate:.3f}"))
        if self.pages.currentIndex() == 2:
            self.brain_view.set_spikes(state.get("spikes", []))
        self.body_table.setRowCount(len(body))
        for row, (key, value) in enumerate(sorted(body.items())):
            self.body_table.setItem(row, 0, QTableWidgetItem(key))
            self.body_table.setItem(
                row,
                1,
                QTableWidgetItem(
                    f"{value:.6g}" if isinstance(value, float) else str(value)
                ),
            )

    def closeEvent(self, event):
        self.canvas.release()
        self.worker.stop()
        if not self.worker.wait(30000):
            self.show_error("Waiting for backend shutdown / 백엔드 종료 대기 중…")
            event.ignore()
            QTimer.singleShot(1000, self.close)
        else:
            event.accept()


def main():
    parser = argparse.ArgumentParser(
        description="Virtual Fly Lab — Linux/Windows native Qt desktop"
    )
    parser.add_argument(
        "--mock",
        action="store_true",
        help="kinematic mock body; brain still uses full connectome",
    )
    parser.add_argument("--seed", type=lambda x: int(x, 0), default=0x5EED1F1F)
    args = parser.parse_args()
    if not 0 <= args.seed <= 0xFFFFFFFF:
        parser.error("seed must fit uint32")
    app = QApplication(sys.argv[:1])
    window = LabWindow(args.mock, args.seed)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
