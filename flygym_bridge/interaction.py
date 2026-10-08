"""V5.6 participant-owned grab/place contract and kinematic carry state."""
from __future__ import annotations

import math
from dataclasses import dataclass

# 16 mm since V5.6.2: the stick figure's eye is 10.3 mm up, so a floor item
# 9 mm ahead is already ~12.6 mm from the head centre.
INTERACTION_REACH_MM = 16.0
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


from lab_types import (PHYSICAL)
import sandbox_models as sm

class WorldInteraction:
    def _interaction_event(self, name, **fields):
        self.events.append({"event": name, "classification": PHYSICAL,
                            "sim_tick_ms": int(self._interaction_tick_ms), **fields})

    def _append_event(self, event):
        event["sim_tick_ms"] = int(self._interaction_tick_ms)
        self.events.append(event)

    def release_interaction(self, reason):
        held = self.interaction.held_object_id
        if held is None:
            return
        obj = self.objects.get(held)
        self.interaction.held_object_id = None
        self.interaction.previous_position = None
        self.interaction.previous_distances = None
        self.interaction.carry_blocked = False
        self.interaction.blocking_geom_kind = None
        self.interaction.limited_by = None
        self._interaction_event("object_placed", id=held, actor_id=self.player.actor_id,
                                position_mm=(list(obj.position_mm) if obj else None), reason=reason)

    def apply_interaction(self, command, *, ray_pick=None):
        tool = command.args.get("tool_id") if isinstance(command.args, dict) else None
        try:
            try:
                args = parse_interaction_args(command.args)
            except ValueError as exc:
                raise InteractionError(f"invalid_interaction: {exc}") from exc
            if not self.player.active:
                raise InteractionError("not_participating")
            if args.actor_id != self.player.actor_id:
                raise InteractionError("wrong_actor")
            held = self.interaction.held_object_id
            if args.tool_id == "place":
                if held is None:
                    raise InteractionError("not_holding")
                if args.target_id is not None and args.target_id != held:
                    raise InteractionError("target_mismatch")
                self.release_interaction("place")
                self.interaction.record(command.seq, args.tool_id, True, target_id=held)
                return self.interaction.state()
            if held is not None:
                raise InteractionError("already_holding")
            center = participant_center(self.player)
            if math.dist(center, args.ray_origin_mm) > (
                    INTERACTION_RAY_ORIGIN_TOL_FACTOR * self.player.radius_mm):
                raise InteractionError("ray_origin_not_at_participant")
            if ray_pick is None:
                raise RuntimeError("interaction ray picker unavailable")
            hit = ray_pick(args.ray_origin_mm, args.ray_direction)
            if not hit.get("hit"):
                raise InteractionError("ray_miss")
            if hit.get("target_kind") != "lab_object":
                raise InteractionError(f"unsupported_target: {hit.get('target_kind', 'unknown')}")
            distance = math.dist(center, hit["point_mm"])
            if distance > INTERACTION_REACH_MM:
                raise InteractionError(f"out_of_reach: {distance:.3f}mm")
            object_id = hit["target_id"]
            if args.target_id is not None and args.target_id != object_id:
                raise InteractionError("target_mismatch")
            if object_id not in self.objects:
                raise InteractionError("ray_miss")
            if self.objects[object_id].shape == "ramp":
                raise InteractionError("fixed_terrain")
            self.approaches.pop(object_id, None)
            self.drives.pop(object_id, None)
            self.interaction.held_object_id = object_id
            self.interaction.previous_distances = None
            self.interaction.carry_blocked = False
            self.interaction.limited_by = None
            self.interaction.record(command.seq, args.tool_id, True,
                                    target_id=object_id, hit_distance_mm=distance)
            self._interaction_event("object_grabbed", id=object_id,
                                    actor_id=self.player.actor_id, hit_distance_mm=distance)
            return self.interaction.state()
        except InteractionError as exc:
            self.interaction.record(command.seq, tool, False, str(exc).split(":", 1)[0])
            raise

    def interaction_pre_step(self, dt):
        held = self.interaction.held_object_id
        if held is None:
            return
        obj = self.objects.get(held)
        if obj is None:
            self.release_interaction("object_removed")
            return
        if not self.player.active:
            self.release_interaction("participant_inactive")
            return
        # Contract §1 compares the post-step signed distance with the last
        # committed pose. An external resize/move invalidates that baseline.
        self.interaction.distance_limit_mm = (CARRY_PENETRATION_TOL_MM +
                                               CARRY_SPEED_MM_S * dt + 0.01)
        if self._bound and self.interaction.previous_distances is None:
            self._mujoco.mj_forward(self.model, self.data)
            held_gid, candidates = self._carry_candidates()
            self.interaction.previous_distances = self._carry_distances(held_gid, candidates)
        constraints = self._carry_constraints if self._bound else ()
        x, y = self.interaction.carry_step_xy(self.player, obj, CARRY_SPEED_MM_S * dt, constraints)
        self.interaction.previous_position = list(obj.position_mm)
        if math.hypot(x - obj.position_mm[0], y - obj.position_mm[1]) > 1e-12:
            obj.position_mm[0] = x
            obj.position_mm[1] = y
            self._bump_revision(obj)
            self._sync_object(obj)

    def _carry_candidates(self):
        held = self.interaction.held_object_id
        held_gids = (self._object_solid_geoms(self.objects[held])
                     if held is not None and held in self.objects else [])
        if not held_gids:
            return [], []
        obj = self.objects[held]
        anchor = self.interaction.carry_filter_anchor
        if (self.interaction.previous_distances is None or anchor is None or
                math.dist(anchor, obj.position_mm) > 0.5):
            # A candidate excluded at this anchor is farther than the sum of
            # both bounding spheres plus 0.5 mm travel and the query horizon.
            # The filter is rebuilt before the held center travels 0.5 mm;
            # external object edits and approach motion invalidate the cache.
            held_radius = (obj.size_mm[0] * 0.5 if obj.shape == "sphere" else
                           math.sqrt(sum((v * 0.5) ** 2 for v in obj.size_mm)))
            near = []
            for other in self.objects.values():
                if other.object_id == held or other.shape == "food":
                    continue
                radius = (other.size_mm[0] * 0.5 if other.shape == "sphere" else
                          math.sqrt(sum((v * 0.5) ** 2 for v in other.size_mm)))
                reach = held_radius + radius + 0.5 + self.interaction.distance_limit_mm
                if math.dist(obj.position_mm, other.position_mm) <= reach:
                    near.extend((gid, "lab_object", other)
                                for gid in self._object_solid_geoms(other))
            self.interaction.carry_filter_anchor = tuple(obj.position_mm)
            self.interaction.carry_filter_candidates = near
        candidates = ([(gid, "ground", None) for gid in self._ground_geom_ids] +
                      self.interaction.carry_filter_candidates +
                      ([(gid, "player", None) for gid in self.player.solid_geom_ids()]
                       if self.player.active else []))
        return held_gids, candidates

    def _object_solid_geoms(self, obj):
        if obj.shape == "food" or not self._bound:
            return []
        if obj.shape in ("car", "trap"):
            return self._solid_by_slot.get(obj.slot, [])
        return [self._slot_ids[obj.slot][1]]

    def _carry_constraints(self):
        """Surfaces near the held object at its committed pose, as carry_step_xy constraints.

        The participant keeps CARRY_GAP_MM of clearance; other LabObjects are
        approached to CARRY_CONTACT_SKIN_MM. Floors are skipped: a horizontal
        step does not deepen a plane contact (the post-step guard still checks).
        """
        held_gids, candidates = self._carry_candidates()
        if not held_gids:
            return ()
        fromto = self._fromto
        constraints = []
        for gid, kind, _ in candidates:
            if kind == "ground":
                continue
            margin = CARRY_GAP_MM if kind == "player" else CARRY_CONTACT_SKIN_MM
            horizon = margin + self.interaction.distance_limit_mm
            for held_gid in held_gids:
                distance = float(self._mujoco.mj_geomDistance(
                    self.model, self.data, held_gid, gid, horizon, fromto))
                if distance >= horizon or abs(distance) < 1e-9:
                    continue
            # With the held geom first, (from - to) / distance points from the
            # other surface to the held object whether or not they overlap.
                nx = float(fromto[0] - fromto[3]) / distance
                ny = float(fromto[1] - fromto[4]) / distance
                horizontal = math.hypot(nx, ny)
                if horizontal < 0.1:
                    continue
                constraints.append((nx / horizontal, ny / horizontal,
                                    max(0.0, distance - margin) / horizontal, kind))
        return constraints

    def _carry_distances(self, held_gids, candidates):
        # MuJoCo 3.9.0 returns distmax for separated geoms beyond this limit,
        # while penetrating pairs still return their full negative distance.
        limit = self.interaction.distance_limit_mm
        return {(held_gid, gid): float(self._mujoco.mj_geomDistance(
                self.model, self.data, held_gid, gid, limit, None))
                for held_gid in held_gids for gid, _, _ in candidates}

    def interaction_post_step(self):
        """Read real fly contacts and apply the contract §1 geometry guard."""
        if not self._bound or (not self.objects and not self.interaction.contacts and not self.projectiles):
            return
        import numpy as np
        mujoco = self._mujoco
        contact_now = {}
        car_hits = {}
        bb_fly_hits = {}
        bb_object_hits = {}
        held = self.interaction.held_object_id
        blocked_kind = None
        moved = (held is not None and held in self.objects and
                 self.interaction.previous_position is not None and
                 math.dist(self.interaction.previous_position,
                           self.objects[held].position_mm) > 1e-12)
        held_gids, candidates = self._carry_candidates() if moved else ([], [])
        # Both branches below need a penetrating contact on a fly-segment or BB
        # geom. Selecting those in numpy skips building a Python contact object
        # for every leg/floor contact on every 0.1 ms substep.
        contacts = self.data.contact              # sized to ncon
        hit = self._post_step_watch[contacts.geom]
        watched = (np.flatnonzero((contacts.dist <= 0.0) & hit.any(axis=1)).tolist()
                   if hit.any() else [])
        if watched:
            bb_by_geom = {self._bb_ids[p.index][1]: p for p in self.projectiles.values()}
            object_by_geom = {gid: obj.object_id for obj in self.objects.values()
                              for gid in self._object_solid_geoms(obj)}
        for index in watched:
            contact = contacts[index]
            g1, g2 = int(contact.geom1), int(contact.geom2)
            if float(contact.dist) <= 0.0:
                for bb_gid, other_gid in ((g1, g2), (g2, g1)):
                    pellet = bb_by_geom.get(bb_gid)
                    if pellet is None:
                        continue
                    segment = self._fly_contact_geoms.get(other_gid)
                    object_id = object_by_geom.get(other_gid)
                    if segment is not None and not pellet.hit_fly:
                        import numpy as np
                        force = np.zeros(6, dtype=float)
                        mujoco.mj_contactForce(self.model, self.data, index, force)
                        peak = max(0.0, float(force[0]))
                        if pellet.id not in bb_fly_hits or peak > bb_fly_hits[pellet.id][2]:
                            bb_fly_hits[pellet.id] = (pellet, segment, peak)
                    elif object_id is not None and not pellet.hit_object:
                        bb_object_hits[pellet.id] = (pellet, object_id)
            for object_gid, fly_gid in ((g1, g2), (g2, g1)):
                object_id = object_by_geom.get(object_gid)
                segment = self._fly_contact_geoms.get(fly_gid)
                if object_id is not None and segment is not None and float(contact.dist) <= 0.0:
                    import numpy as np
                    force = np.zeros(6, dtype=float)
                    mujoco.mj_contactForce(self.model, self.data, index, force)
                    key = (object_id, segment)
                    contact_now[key] = max(contact_now.get(key, 0.0), max(0.0, float(force[0])))
                    if object_id in self.drives:
                        car_hits[object_id] = max(car_hits.get(object_id, 0.0),
                                                  max(0.0, float(force[0])))
        for object_id, force in car_hits.items():
            self.drives.pop(object_id, None)
            self._interaction_event("car_hit_fly", id=object_id,
                                    peak_normal_force=force, force_units="mujoco_model")
        for pellet, segment, peak in bb_fly_hits.values():
            pellet.hit_fly = True
            self._interaction_event("bb_hit_fly", id=pellet.id, fly_segment=segment,
                                    peak_normal_force=peak, force_units="mujoco_model")
        for pellet, object_id in bb_object_hits.values():
            pellet.hit_object = True
            self._interaction_event("bb_hit_object", id=pellet.id, object_id=object_id)
        # Contract §1: mocap pairs and mocap/fixed-plane pairs need explicit
        # mj_geomDistance checks. Only a *deeper* penetration beyond tolerance
        # blocks carry; an initial overlap may move sideways or out of contact.
        if held_gids and self.interaction.previous_position is not None:
            previous = self.interaction.previous_distances or {}
            distances = self._carry_distances(held_gids, candidates)
            for (held_gid, other_gid), distance in distances.items():
                kind = next(k for gid, k, _ in candidates if gid == other_gid)
                if (distance < -CARRY_PENETRATION_TOL_MM and
                        distance < previous.get((held_gid, other_gid), distance) - 1e-9):
                    blocked_kind = kind
                    break
            self.interaction.previous_distances = distances
        if blocked_kind is not None:
            # Safety net behind the pre-step constraints: undo a deepening step.
            obj = self.objects.get(held)
            if obj is not None:
                obj.position_mm = self.interaction.previous_position
                self._bump_revision(obj)
                self._sync_object(obj)
                mujoco.mj_forward(self.model, self.data)
                # The next comparison must use the restored pose, not the
                # rejected pose from the just-completed physics substep.
                self.interaction.previous_distances = self._carry_distances(held_gids, candidates)
        elif held is not None:
            # A step the pre-step constraints cut to under half is blocked too.
            blocked_kind = self.interaction.limited_by
        if blocked_kind is not None:
            if not self.interaction.carry_blocked:
                self._interaction_event("carry_blocked", id=held, blocking_geom_kind=blocked_kind)
            self.interaction.carry_blocked = True
            self.interaction.blocking_geom_kind = blocked_kind
        elif self.interaction.carry_blocked:
            self._interaction_event("carry_unblocked", id=held,
                                    blocking_geom_kind=self.interaction.blocking_geom_kind)
            self.interaction.carry_blocked = False
            self.interaction.blocking_geom_kind = None
        old = self.interaction.contacts
        for key, force in contact_now.items():
            if key not in old:
                old[key] = (self._interaction_tick_ms, force)
                self._interaction_event("object_contact_begin", id=key[0], fly_segment=key[1],
                                        normal_force=force, force_units="mujoco_model")
            else:
                begin, peak = old[key]
                old[key] = (begin, max(peak, force))
        for key in list(old):
            if key not in contact_now:
                begin, peak = old.pop(key)
                self._interaction_event("object_contact_end", id=key[0], fly_segment=key[1],
                                        peak_normal_force=peak,
                                        duration_ms=max(0, self._interaction_tick_ms - begin),
                                        force_units="mujoco_model")
