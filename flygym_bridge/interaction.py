"""V5.6 participant-owned grab/place contract and kinematic carry state."""
from __future__ import annotations

import math
from dataclasses import dataclass

INTERACTION_REACH_MM = 12.0
INTERACTION_RAY_ORIGIN_TOL_FACTOR = 2.0
CARRY_SPEED_MM_S = 40.0
CARRY_GAP_MM = 0.5
CARRY_PENETRATION_TOL_MM = 0.05
# A carried object stops this far short of another LabObject: at zero distance
# MuJoCo's witness points coincide and the surface normal is undefined.
CARRY_CONTACT_SKIN_MM = 0.005


class InteractionError(ValueError):
    """An ACK error whose first token is the contract rejection code."""


@dataclass(frozen=True)
class InteractionArgs:
    tool_id: str
    actor_id: str
    target_id: str | None
    ray_origin_mm: tuple[float, float, float] | None
    ray_direction: tuple[float, float, float] | None


def _vec3(value, name, *, nonzero=False):
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise ValueError(f"{name} must have exactly 3 numbers")
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) for v in value):
        raise ValueError(f"{name} must contain numbers")
    out = tuple(float(v) for v in value)
    if not all(math.isfinite(v) for v in out):
        raise ValueError(f"{name} must be finite")
    if nonzero and math.sqrt(sum(v * v for v in out)) < 1e-12:
        raise ValueError(f"{name} must be nonzero")
    return out


def parse_interaction_args(args):
    """Reject malformed interaction payloads before any world mutation."""
    if not isinstance(args, dict):
        raise ValueError("interaction args must be an object")
    if set(args) - {"tool_id", "actor_id", "id", "target", "ray_origin_mm", "ray_direction"}:
        raise ValueError("unknown interaction field")
    tool = args.get("tool_id")
    if not isinstance(tool, str) or tool not in ("grab", "place"):
        raise ValueError("tool_id must be grab or place")
    actor = args.get("actor_id")
    if not isinstance(actor, str) or not actor.strip() or len(actor) > 64:
        raise ValueError("actor_id must be a nonempty string")
    if "id" in args and "target" in args and args["id"] != args["target"]:
        raise ValueError("conflicting target fields")
    target = args.get("id", args.get("target"))
    if target is not None and (not isinstance(target, str) or not target.strip() or len(target) > 64):
        raise ValueError("target must be a nonempty string")
    if tool == "place":
        if "ray_origin_mm" in args or "ray_direction" in args:
            raise ValueError("place must not include a ray")
        return InteractionArgs(tool, actor, target, None, None)
    if "ray_origin_mm" not in args or "ray_direction" not in args:
        raise ValueError("grab requires ray_origin_mm and ray_direction")
    origin = _vec3(args["ray_origin_mm"], "ray_origin_mm")
    direction = _vec3(args["ray_direction"], "ray_direction", nonzero=True)
    mag = math.sqrt(sum(v * v for v in direction))
    return InteractionArgs(tool, actor, target, origin, tuple(v / mag for v in direction))


class InteractionState:
    def __init__(self, actor_id, *, mock=False):
        self.actor_id = actor_id
        self.mock = mock
        self.held_object_id = None
        self.carry_blocked = False
        self.blocking_geom_kind = None
        # Kind of surface that limited the last carry step before it was taken.
        self.limited_by = None
        self.last = None
        self.contacts = {}  # (object id, fly segment) -> (begin tick, peak force)
        self.previous_position = None
        # Signed distances at the last committed carry pose (clamped at the
        # small positive query horizon). Cleared when scene geometry changes.
        self.previous_distances = None
        self.distance_limit_mm = CARRY_PENETRATION_TOL_MM + 0.01
        self.carry_filter_anchor = None
        self.carry_filter_candidates = None

    def state(self):
        return {
            "held_object_id": self.held_object_id,
            "actor_id": self.actor_id,
            "carry_blocked": self.carry_blocked,
            "reach_mm": INTERACTION_REACH_MM,
            "carry_speed_mm_s": CARRY_SPEED_MM_S,
            "mode": "mock_kinematic_carry" if self.mock else "kinematic_carry",
            "last": None if self.last is None else dict(self.last),
        }

    def record(self, event_id, tool_id, ok, code=None, target_id=None, hit_distance_mm=None):
        self.last = {
            "event_id": int(event_id), "tool_id": tool_id, "ok": bool(ok),
            "code": code, "target_id": target_id,
            "hit_distance_mm": hit_distance_mm,
        }

    @staticmethod
    def hold_radius_mm(player, obj):
        """Centre distance at which the held object cannot touch the participant.

        Objects keep their own yaw while carried, so a box uses its horizontal
        half-diagonal: any look direction then leaves CARRY_GAP_MM of clearance.
        """
        if obj.shape in ("sphere", "food"):
            extent = obj.size_mm[0] * 0.5
        else:
            extent = math.hypot(obj.size_mm[0], obj.size_mm[1]) * 0.5
        return player.radius_mm + extent + CARRY_GAP_MM

    def carry_step_xy(self, player, obj, max_step_mm, constraints=()):
        """One bounded carry step toward the hold point, constrained before it is taken.

        `constraints` (or a callable returning them, evaluated only when the
        object has somewhere to go) are (nx, ny, allowance_mm, kind): a unit horizontal normal
        pointing from a nearby surface to the held object, and how far the object
        may still approach that surface. The step toward the hold point keeps
        only what every constraint allows, so the object slides along walls and
        around the participant instead of pushing into them. A straight chase
        without the participant constraint cut through it after a turn and the
        free-joint body drifted with no input (2026-09-26: 31.6 mm in 3 s).
        """
        self.limited_by = None
        center = participant_center(player)
        yaw = player.look_yaw_rad
        hold = self.hold_radius_mm(player, obj)
        dx = center[0] + math.cos(yaw) * hold - obj.position_mm[0]
        dy = center[1] + math.sin(yaw) * hold - obj.position_mm[1]
        distance = math.hypot(dx, dy)
        length = min(max(0.0, float(max_step_mm)), distance)
        if length <= 1e-12:
            return (obj.position_mm[0], obj.position_mm[1])
        if callable(constraints):
            constraints = constraints()
        sx, sy = dx / distance * length, dy / distance * length
        fx, fy, limited_by = _constrained_step(sx, sy, constraints)
        if math.hypot(fx, fy) < 0.5 * length and limited_by == "player":
            # Head-on into the participant (target behind it): go around it,
            # on the side the look is turning toward.
            vx, vy = obj.position_mm[0] - center[0], obj.position_mm[1] - center[1]
            nx, ny = next((c[0], c[1]) for c in constraints if c[3] == "player")
            side = 1.0 if vx * dy - vy * dx >= 0.0 else -1.0
            tx, ty, around_limited = _constrained_step(-ny * side * length, nx * side * length,
                                                       constraints)
            if math.hypot(tx, ty) > math.hypot(fx, fy):
                fx, fy, limited_by = tx, ty, around_limited
        if limited_by is not None and math.hypot(fx, fy) < 0.5 * length:
            self.limited_by = limited_by
        return (obj.position_mm[0] + fx, obj.position_mm[1] + fy)


def _constrained_step(sx, sy, constraints):
    """Project a horizontal step until no constraint is exceeded (zero if none fits)."""
    limited_by, removed = None, 0.0
    for _ in range(4):
        exceeded = False
        for nx, ny, allowance, kind in constraints:
            approach = -(sx * nx + sy * ny) - allowance
            if approach > 1e-12:
                sx, sy = sx + approach * nx, sy + approach * ny
                exceeded = True
                if approach > removed:
                    limited_by, removed = kind, approach
        if not exceeded:
            return sx, sy, limited_by
    for nx, ny, allowance, kind in constraints:
        if -(sx * nx + sy * ny) - allowance > 1e-9:
            return 0.0, 0.0, kind
    return sx, sy, limited_by


def participant_center(player):
    """Use immediate free-joint qpos at a same-boundary activation/pose write."""
    if player._bound:
        return [float(v) for v in player.data.qpos[player.qpos_adr:player.qpos_adr + 3]]
    return list(player.position_mm)
