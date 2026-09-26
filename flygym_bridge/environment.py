"""environment.py - small ArenaConfig for the first MuJoCo/FlyGym world.

Units are FlyGym/MuJoCo millimeters (fly spawns at z=0.7 mm).
"""
from __future__ import annotations
from dataclasses import dataclass, field

@dataclass
class BoxObstacle:
    # 10 mm cube sitting on the floor, 60 mm ahead of spawn.
    pos: list = field(default_factory=lambda: [60.0, 0.0, 5.0])
    size: list = field(default_factory=lambda: [5.0, 5.0, 5.0])

@dataclass
class ArenaConfig:
    floor_friction: float = 1.0
    gravity: list = field(default_factory=lambda: [0.0, 0.0, -9.81])
    sim_speed: float = 1.0
    box_obstacle: BoxObstacle = field(default_factory=BoxObstacle)
    render_width: int = 480
    render_height: int = 360
    render_fps: int = 20
