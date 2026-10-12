"""Rotatable whole-connectome point cloud; every neuron is projected on CPU."""

import math

import numpy as np
from PySide6.QtCore import Signal
from PySide6.QtGui import QColor, QImage, QPainter
from PySide6.QtWidgets import QWidget


class BrainView(QWidget):
    selected = Signal(int)

    def __init__(self):
        super().__init__()
        self.setMinimumSize(260, 220)
        self.connectome = None
        self.yaw, self.pitch = 0.3, -0.2
        self.zoom = 1.0
        self.last = None
        self.xy = None
        self.image = QImage()
        self.spikes = np.empty(0, np.int32)
        self.index = None

    def bind(self, connectome):
        self.connectome = connectome
        self.positions = np.asarray(connectome.positions, dtype=float)
        self.positions -= self.positions.mean(axis=0)
        palette = np.array(
            [
                [80, 123, 142],
                [238, 152, 50],
                [223, 180, 60],
                [250, 70, 66],
                [87, 204, 158],
                [79, 181, 204],
                [116, 196, 91],
                [220, 144, 200],
                [177, 130, 231],
                [229, 119, 83],
                [102, 189, 229],
                [211, 200, 110],
            ],
            np.uint8,
        )
        self.colors = palette[np.asarray(connectome.role)]
        self.project()

    def project(self):
        if self.connectome is None:
            return
        yaw, pitch = self.yaw, self.pitch
        rz = np.array(
            [
                [math.cos(yaw), -math.sin(yaw), 0],
                [math.sin(yaw), math.cos(yaw), 0],
                [0, 0, 1],
            ]
        )
        rx = np.array(
            [
                [1, 0, 0],
                [0, math.cos(pitch), -math.sin(pitch)],
                [0, math.sin(pitch), math.cos(pitch)],
            ]
        )
        xyz = self.positions @ (rx @ rz).T
        scale = min(self.width(), self.height()) * 0.043 * self.zoom
        self.xy = np.column_stack(
            [
                xyz[:, 0] * scale + self.width() / 2,
                -xyz[:, 1] * scale + self.height() / 2,
            ]
        ).astype(int)
        pixels = np.empty((self.height(), self.width(), 3), np.uint8)
        pixels[:] = [14, 23, 34]
        valid = (
            (self.xy[:, 0] >= 0)
            & (self.xy[:, 0] < self.width())
            & (self.xy[:, 1] >= 0)
            & (self.xy[:, 1] < self.height())
        )
        indices = np.argsort(xyz[:, 2], kind="stable")
        indices = indices[valid[indices]]
        points = self.xy[indices]
        pixels[points[:, 1], points[:, 0]] = self.colors[indices]
        for indices, color in [
            (self.spikes, [255, 255, 255]),
            ([self.index] if self.index is not None else [], [255, 55, 55]),
        ]:
            indices = np.asarray(indices, dtype=int)
            indices = indices[valid[indices]]
            points = self.xy[indices]
            pixels[points[:, 1], points[:, 0]] = color
        self.image = QImage(
            pixels.data,
            self.width(),
            self.height(),
            self.width() * 3,
            QImage.Format.Format_RGB888,
        ).copy()
        self.update()

    def set_spikes(self, spikes):
        self.spikes = np.asarray(spikes, np.int32)
        self.project()

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0e1722"))
        if not self.image.isNull():
            p.drawImage(0, 0, self.image)
        p.setPen(QColor("white"))
        p.drawText(
            8,
            18,
            "FlyWire v783 · 139,255 neurons"
            if self.connectome
            else "Loading / 로딩 중…",
        )

    def mousePressEvent(self, event):
        self.last = event.position()

    def mouseMoveEvent(self, event):
        if event.buttons() and self.last is not None:
            delta = event.position() - self.last
            self.yaw += delta.x() * 0.01
            self.pitch += delta.y() * 0.01
            self.last = event.position()
            self.project()

    def mouseReleaseEvent(self, event):
        if self.xy is not None:
            distance = np.sum(
                (self.xy - [event.position().x(), event.position().y()]) ** 2, axis=1
            )
            index = int(np.argmin(distance))
            if distance[index] < 100:
                self.index = index
                self.selected.emit(index)
                self.project()
        self.last = None

    def wheelEvent(self, event):
        self.zoom = max(
            0.25, min(8, self.zoom * math.exp(event.angleDelta().y() / 1200))
        )
        self.project()

    def resizeEvent(self, event):
        self.project()
        super().resizeEvent(event)
