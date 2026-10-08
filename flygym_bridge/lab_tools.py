from __future__ import annotations
import math
import sandbox_models as sm
from lab_types import *
from interaction import CARRY_GAP_MM, CARRY_CONTACT_SKIN_MM, participant_center

class LabTools:
    def _tool_obstacles(self, obj):
        """Solid geoms from other lab objects and the active participant."""
        for other in self.objects.values():
            if other.object_id != obj.object_id:
                for gid in self._object_solid_geoms(other):
                    yield gid, "lab_object"
        if self.player.active:
            for gid in self.player.solid_geom_ids():
                yield gid, "player"

    def _tool_clearance(self, obj, margin):
        if not self._bound:
            return math.inf, None
        self._mujoco.mj_forward(self.model, self.data)
        best, kind = math.inf, None
        for own in self._object_solid_geoms(obj):
            for other, other_kind in self._tool_obstacles(obj):
                d = float(self._mujoco.mj_geomDistance(
                    self.model, self.data, own, other, margin + 2.0, None))
                gap = d - (CARRY_GAP_MM if other_kind == "player" else margin)
                if gap < best:
                    best, kind = gap, other_kind
        return best, kind

    def _try_tool_pose(self, obj, target, *, margin=CARRY_CONTACT_SKIN_MM):
        previous = list(obj.position_mm)
        if not self._bound:
            obj.position_mm = list(target)
            self._bump_revision(obj)
            return True
        baseline, _ = self._tool_clearance(obj, margin)
        obj.position_mm = list(target)
        self._sync_object(obj)
        clearance, _ = self._tool_clearance(obj, margin)
        if clearance < -1e-6 and clearance < baseline - 1e-6:
            obj.position_mm = previous
            self._sync_object(obj)
            self._mujoco.mj_forward(self.model, self.data)
            return False
        self._bump_revision(obj)
        self.interaction.previous_distances = None
        return True

    def _tool_path_clear(self, obj, target, margin):
        """Check a raised trap's entire vertical path before committing its pose."""
        if not self._bound:
            return True
        origin = list(obj.position_mm)
        previous, _ = self._tool_clearance(obj, margin)
        steps = max(1, math.ceil(math.dist(origin, target) / 0.25))
        clear = True
        try:
            for index in range(1, steps + 1):
                fraction = index / steps
                obj.position_mm = [a + (b - a) * fraction for a, b in zip(origin, target)]
                self._sync_object(obj)
                clearance, _ = self._tool_clearance(obj, margin)
                if clearance < -1e-6 and clearance < previous - 1e-6:
                    clear = False
                    break
                previous = clearance
        finally:
            obj.position_mm = origin
            self._sync_object(obj)
            self._mujoco.mj_forward(self.model, self.data)
        return clear

    def _advance_drives(self, dt):
        if not self.drives:
            return
        for object_id, motion in list(self.drives.items()):
            obj = self.objects.get(object_id)
            if obj is None or object_id == self.interaction.held_object_id:
                self.drives.pop(object_id, None)
                continue
            yaw = math.radians(obj.yaw_deg)
            direction = (math.cos(yaw), math.sin(yaw))
            travel = min(motion.remaining_mm, motion.speed_mm_s * dt)
            # Conservative rotated footprint so every body part stays on lawn.
            radius_x = 0.5 * (obj.size_mm[0] * abs(direction[0]) +
                              obj.size_mm[1] * abs(direction[1]))
            radius_y = 0.5 * (obj.size_mm[0] * abs(direction[1]) +
                              obj.size_mm[1] * abs(direction[0]))
            edge = math.inf
            for axis, radius in enumerate((radius_x, radius_y)):
                component = direction[axis]
                if abs(component) > 1e-12:
                    limit = (sm.ARENA_HALF_SIZE_MM - radius) * (1 if component > 0 else -1)
                    edge = min(edge, max(0.0, (limit - obj.position_mm[axis]) / component))
            edge_block = edge < travel - 1e-9
            travel = min(travel, edge)
            origin = list(obj.position_mm)
            def target(frac):
                return [origin[0] + direction[0] * travel * frac,
                        origin[1] + direction[1] * travel * frac, origin[2]]
            if travel > 0 and not self._try_tool_pose(obj, target(1.0)):
                low, high = 0.0, 1.0
                for _ in range(12):
                    mid = (low + high) * 0.5
                    if self._try_tool_pose(obj, target(mid)):
                        low = mid
                    else:
                        high = mid
                self.drives.pop(object_id, None)
                self._interaction_event("car_blocked", id=object_id,
                                        blocking_geom_kind="player_or_lab_object")
                continue
            motion.remaining_mm -= travel
            if edge_block or travel <= 0:
                self.drives.pop(object_id, None)
                self._interaction_event("car_blocked", id=object_id,
                                        blocking_geom_kind="lawn_edge")
            elif motion.remaining_mm <= 1e-6:
                self.drives.pop(object_id, None)
                self._interaction_event("drive_complete", id=object_id)

    def _advance_traps(self, dt):
        traps = [obj for obj in self.objects.values()
                 if obj.shape == "trap" and obj.object_id != self.interaction.held_object_id]
        if not traps:
            return
        fly = getattr(self, "fly_position_mm", None)
        for obj in traps:
            if obj.trap_state == "armed" and fly is not None:
                yaw = math.radians(obj.yaw_deg)
                dx, dy = fly[0] - obj.position_mm[0], fly[1] - obj.position_mm[1]
                local_x = math.cos(yaw) * dx + math.sin(yaw) * dy
                local_y = -math.sin(yaw) * dx + math.cos(yaw) * dy
                inner = obj.size_mm[0] * (0.5 - sm.TRAP_WALL_RATIO) - 2.0
                if abs(local_x) <= inner and abs(local_y) <= inner:
                    obj.trap_state = "dropping"
                    self._interaction_event("trap_triggered", id=obj.object_id)
            if obj.trap_state != "dropping":
                continue
            floor_z = 0.5 * obj.size_mm[2] + TRAP_FLOOR_GAP_MM
            target_z = max(floor_z, obj.position_mm[2] - TRAP_DROP_SPEED_MM_S * dt)
            if not self._try_tool_pose(obj, [*obj.position_mm[:2], target_z],
                                       margin=TRAP_FLOOR_GAP_MM):
                if obj.object_id not in self._trap_blocked:
                    self._interaction_event("trap_blocked", id=obj.object_id)
                    self._trap_blocked.add(obj.object_id)
                continue
            self._trap_blocked.discard(obj.object_id)
            if target_z <= floor_z + 1e-8:
                obj.trap_state = "closed"
                self._interaction_event("trap_closed", id=obj.object_id)

    def _park_bb(self, projectile):
        if self._bound:
            bid, gid, qadr, dadr = self._bb_ids[projectile.index]
            self.data.qpos[qadr:qadr + 3] = FAR_POS
            self.data.qpos[qadr + 3:qadr + 7] = [1, 0, 0, 0]
            self.data.qvel[dadr:dadr + 6] = 0
            self.model.body_gravcomp[bid] = 1.0
            self.model.geom_rgba[gid, 3] = 0.0
            sm.set_geom_collidable(self.model, gid, False)
            self._hide_tracer(projectile.index)
        self.projectiles.pop(projectile.id, None)

    def _park_all_bbs(self):
        for projectile in list(self.projectiles.values()):
            self._park_bb(projectile)
        if self._bound:
            for bid, gid, qadr, dadr in self._bb_ids:
                self.data.qpos[qadr:qadr + 3] = FAR_POS
                self.data.qpos[qadr + 3:qadr + 7] = [1, 0, 0, 0]
                self.data.qvel[dadr:dadr + 6] = 0
                self.model.body_gravcomp[bid] = 1.0
                self.model.geom_rgba[gid, 3] = 0.0
                sm.set_geom_collidable(self.model, gid, False)

    def _fire_bb(self, actor, direction):
        if actor != self.player.actor_id or not self.player.active or not self.player.gun_visible:
            raise LabError("active participant with equipped gun required")
        if self._sim_time_s - self._last_bb_fire_s < BB_RATE_LIMIT_S - 1e-9:
            raise LabError("BB rate limit")
        occupied = {p.index for p in self.projectiles.values()}
        index = next((i for i in range(BB_POOL_SIZE) if i not in occupied), None)
        if index is None:
            raise LabError("BB pool full")
        yaw_q = self.player._body_quat_wxyz()
        yaw = 2.0 * math.atan2(yaw_q[3], yaw_q[0])
        x, y, z = sm.BB_MUZZLE_OFFSET_MM
        position = [self.player.position_mm[0] + math.cos(yaw) * x - math.sin(yaw) * y,
                    self.player.position_mm[1] + math.sin(yaw) * x + math.cos(yaw) * y,
                    self.player.position_mm[2] + z]
        target = self._bb_aim_point(direction)
        velocity = _ballistic_velocity(position, target, BB_SPEED_MM_S, self._gravity_mm_s2())
        self._bb_counter += 1
        projectile = Projectile(f"bb_{self._bb_counter}", index, position, velocity,
                                self._sim_time_s)
        projectile.trail.append((self._sim_time_s, list(position)))
        if self._bound:
            bid, gid, qadr, dadr = self._bb_ids[index]
            self.data.qpos[qadr:qadr + 3] = position
            self.data.qpos[qadr + 3:qadr + 7] = [1, 0, 0, 0]
            self.data.qvel[dadr:dadr + 3] = projectile.velocity_mm_s
            self.data.qvel[dadr + 3:dadr + 6] = 0
            self.model.body_gravcomp[bid] = 0.0
            self.model.geom_rgba[gid] = sm.BB_RGBA
            sm.set_geom_collidable(self.model, gid, True)
        self.projectiles[projectile.id] = projectile
        self._last_bb_fire_s = self._sim_time_s
        self._interaction_event("bb_fired", id=projectile.id, actor_id=actor,
                                position_mm=list(position))
        return {"id": projectile.id, "position_mm": list(position)}

    def _gravity_mm_s2(self):
        return abs(float(self.model.opt.gravity[2])) if self._bound else 9810.0

    def _bb_aim_point(self, direction):
        """Point under the crosshair: the look ray from the eye (as the camera)."""
        center = participant_center(self.player)
        x, y, z, w = self.player.orientation_quat_xyzw
        look = [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)]
        eye = [center[i] + look[i] * self.player.radius_mm * 0.6 for i in range(3)]
        reach = BB_AIM_RANGE_MM
        if self._bound:
            import numpy as np
            hit = np.array([-1], dtype=np.int32)
            groups = np.array([1, 1, 1, 0, 0, 0], dtype=np.uint8)  # skip view-only tracers
            self._mujoco.mj_forward(self.model, self.data)
            distance = float(self._mujoco.mj_ray(
                self.model, self.data, np.array(eye), np.array(direction), groups, 1,
                self.player.body_id, hit))
            if 0.0 <= distance < reach:
                reach = distance
        return [eye[i] + direction[i] * reach for i in range(3)]

    def _hide_tracer(self, index):
        mocap, gid = self._bb_tracers[index]
        self.data.mocap_pos[mocap] = FAR_POS
        self.model.geom_rgba[gid, 3] = 0.0

    def _update_tracer(self, projectile):
        """Stretch the view-only streak over the last BB_TRACER_TRAIL_S of flight."""
        now = self._sim_time_s
        trail = projectile.trail
        if not trail or now - trail[-1][0] >= 0.002:
            trail.append((now, list(projectile.position_mm)))
        while len(trail) > 2 and now - trail[1][0] > sm.BB_TRACER_TRAIL_S:
            trail.pop(0)
        start, end = trail[0][1], projectile.position_mm
        length = math.dist(start, end)
        if length < 0.3:
            self._hide_tracer(projectile.index)
            return
        mocap, gid = self._bb_tracers[projectile.index]
        self.data.mocap_pos[mocap] = [(a + b) * 0.5 for a, b in zip(start, end)]
        self.data.mocap_quat[mocap] = sm.quat_z_to([b - a for a, b in zip(start, end)])
        self.model.geom_size[gid] = [sm.BB_TRACER_RADIUS_MM, length * 0.5, 0.0]
        self.model.geom_rgba[gid] = sm.BB_TRACER_RGBA

    def _advance_bbs(self, dt):
        if not self.projectiles:
            return
        for projectile in list(self.projectiles.values()):
            if self._bound:
                _, _, qadr, _ = self._bb_ids[projectile.index]
                projectile.position_mm = [float(v) for v in self.data.qpos[qadr:qadr + 3]]
            else:
                projectile.velocity_mm_s[2] -= 9810.0 * dt
                projectile.position_mm = [p + v * dt for p, v in zip(
                    projectile.position_mm, projectile.velocity_mm_s)]
            if self._bound:
                self._update_tracer(projectile)
            x, y, z = projectile.position_mm
            if (self._sim_time_s - projectile.fired_s >= BB_LIFETIME_S or
                    abs(x) > sm.ARENA_HALF_SIZE_MM or abs(y) > sm.ARENA_HALF_SIZE_MM or z < -5):
                self._park_bb(projectile)
                self._interaction_event("bb_expired", id=projectile.id)

    def projectile_state(self):
        if self._bound:
            return [{"id": p.id, "position_mm": [float(v) for v in
                     self.data.qpos[self._bb_ids[p.index][2]:self._bb_ids[p.index][2] + 3]]}
                    for p in self.projectiles.values()]
        return [{"id": p.id, "position_mm": list(p.position_mm)}
                for p in self.projectiles.values()]
