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
    box_obstacle: BoxObstacle = field(default_factory=BoxObstacle)
