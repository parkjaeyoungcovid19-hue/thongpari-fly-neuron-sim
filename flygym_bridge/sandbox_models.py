"""V5.6.2 sandbox geometry: arena look, stick-figure participant, food models, toys.

Every model here is built from MuJoCo primitives that are compiled before the
Simulation exists. Runtime topology is fixed, so each model is a *palette* of
pre-compiled geoms that `fill_parts` poses, sizes and colours at runtime; unused
palette geoms get alpha 0, which MuJoCo 3.9 skips in both `mjv_updateScene`
and `mj_ray` (measured 2026-09-27). The same geoms are rendered, ray-picked and
seen by the fly's eye cameras.

Collision: a part is collidable only where the owning object is (the stick
figure and toy bodies are; food is not). Purely decorative parts are marked
`collide=False`; each one sits on or inside a collidable surface so the visible
silhouette and the collision silhouette differ by at most a few tenths of a mm.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import mujoco
import numpy as np

SPHERE = mujoco.mjtGeom.mjGEOM_SPHERE
ELLIPSOID = mujoco.mjtGeom.mjGEOM_ELLIPSOID
CAPSULE = mujoco.mjtGeom.mjGEOM_CAPSULE
CYLINDER = mujoco.mjtGeom.mjGEOM_CYLINDER
BOX = mujoco.mjtGeom.mjGEOM_BOX


# ----------------------------------------------------------------------------
# Part description and runtime palette filling
# ----------------------------------------------------------------------------
@dataclass(frozen=True)
class Part:
    """One primitive in model-local coordinates (MuJoCo size convention)."""
    type: int
    pos: tuple
    size: tuple
    rgba: tuple
    quat: tuple = (1.0, 0.0, 0.0, 0.0)  # wxyz
    collide: bool = True


def set_geom_collidable(model, gid, on):
    """Toggle a geom's 1/1 collision mask and keep its body's mask in step.

    The compiler sets body_contype/conaffinity to the OR of the body's geoms, and
    the broadphase skips a body only when both are 0. Hidden lab slots are
    compiled collidable, so without this every parked slot (all at FAR_POS) stays
    in the sweep-and-prune and pairs with every other one: 214 mocap bodies cost
    about a third of each 0.1 ms step (measured 2026-09-29). Contacts are
    unchanged: geom masks still decide every pair.
    """
    v = 1 if on else 0
    model.geom_contype[gid] = v
    model.geom_conaffinity[gid] = v
    sync_body_collision_mask(model, int(model.geom_bodyid[gid]))


def sync_body_collision_mask(model, bid):
    start = int(model.body_geomadr[bid])
    if start < 0:
        return
    stop = start + int(model.body_geomnum[bid])
    model.body_contype[bid] = int(np.bitwise_or.reduce(model.geom_contype[start:stop]))
    model.body_conaffinity[bid] = int(np.bitwise_or.reduce(model.geom_conaffinity[start:stop]))


def _norm(v):
    n = math.sqrt(sum(c * c for c in v))
    return [c / n for c in v] if n > 1e-12 else [0.0, 0.0, 1.0]


def quat_z_to(direction):
    """wxyz quaternion rotating local +Z onto `direction`."""
    x, y, z = _norm(direction)
    if z < -1.0 + 1e-9:
        return (0.0, 1.0, 0.0, 0.0)
    w = 1.0 + z
    q = [w, -y, x, 0.0]
    n = math.sqrt(sum(c * c for c in q))
    return tuple(c / n for c in q)


def quat_axis(axis, angle_rad):
    x, y, z = _norm(axis)
    s = math.sin(angle_rad * 0.5)
    return (math.cos(angle_rad * 0.5), x * s, y * s, z * s)


def quat_mul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (aw * bw - ax * bx - ay * by - az * bz,
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw)


def ball(pos, r, rgba, collide=True):
    return Part(ELLIPSOID, tuple(pos), (r, r, r), rgba, collide=collide)


def ell(pos, radii, rgba, quat=(1.0, 0.0, 0.0, 0.0), collide=True):
    return Part(ELLIPSOID, tuple(pos), tuple(radii), rgba, quat, collide)


def stick(p0, p1, r, rgba, collide=True):
    """Capsule between two points."""
    mid = tuple((a + b) * 0.5 for a, b in zip(p0, p1))
    half = math.dist(p0, p1) * 0.5
    return Part(CAPSULE, mid, (r, half, 0.0), rgba,
                quat_z_to([b - a for a, b in zip(p0, p1)]), collide)


def disc(pos, r, half_h, rgba, quat=(1.0, 0.0, 0.0, 0.0), collide=True):
    return Part(CYLINDER, tuple(pos), (r, half_h, 0.0), rgba, quat, collide)


def block(pos, half, rgba, quat=(1.0, 0.0, 0.0, 0.0), collide=True):
    return Part(BOX, tuple(pos), tuple(half), rgba, quat, collide)


class Palette:
    """Pre-compiled geoms of fixed types on one body, filled at runtime."""

    def __init__(self, counts):
        self.counts = dict(counts)          # geom type -> how many
        self.names = {t: [] for t in counts}
        self.gids = {t: [] for t in counts}
        self._collide_masks = {}

    def install(self, body, prefix, *, max_extent_mm, collidable):
        """Add hidden palette geoms to an MjSpec body.

        Sizes are compiled at `max_extent_mm` so MuJoCo's constant bounding
        volumes (geom_rbound/aabb) stay conservative for any runtime size.
        """
        e = float(max_extent_mm)
        size = {ELLIPSOID: [e, e, e], CAPSULE: [e, e, 0.0],
                CYLINDER: [e, e, 0.0], BOX: [e, e, e], SPHERE: [e, 0.0, 0.0]}
        for gtype, count in self.counts.items():
            for i in range(count):
                name = f"{prefix}_{_TYPE_TAG[gtype]}{i}"
                body.add_geom(name=name, type=gtype, size=size[gtype],
                              rgba=[1.0, 1.0, 1.0, 0.0], mass=1e-9,
                              contype=1 if collidable else 0,
                              conaffinity=1 if collidable else 0)
                self.names[gtype].append(name)
        return self

    def bind(self, model):
        for gtype, names in self.names.items():
            self.gids[gtype] = [int(mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_GEOM, n))
                                for n in names]
            if any(g < 0 for g in self.gids[gtype]):
                raise RuntimeError(f"compiled palette geom missing: {names}")
            # Compiled at the body origin, MuJoCo marks these geoms "same frame
            # as the body" and mj_kinematics would ignore runtime geom_pos/quat.
            for gid in self.gids[gtype]:
                model.geom_sameframe[gid] = 0
        return self

    def all_gids(self):
        return [g for gids in self.gids.values() for g in gids]

    def fill(self, model, parts, *, scale=1.0, collidable=True, visible=True):
        """Pose the palette as `parts` (scaled); hide and disable the rest.

        Returns the geom ids now showing a collidable part.
        """
        used = {t: 0 for t in self.gids}
        solid = []
        for part in parts if visible else ():
            gtype = part.type
            index = used.get(gtype)
            if index is None or index >= len(self.gids[gtype]):
                raise RuntimeError(f"palette too small for {_TYPE_TAG[gtype]}")
            used[gtype] = index + 1
            gid = self.gids[gtype][index]
            model.geom_pos[gid] = [c * scale for c in part.pos]
            model.geom_quat[gid] = part.quat
            size = [c * scale for c in part.size]
            model.geom_size[gid] = (size + [0.0, 0.0, 0.0])[:3]
            model.geom_rgba[gid] = part.rgba
            on = bool(collidable and part.collide)
            set_geom_collidable(model, gid, on)
            if on:
                solid.append(gid)
        for gtype, gids in self.gids.items():
            for gid in gids[used.get(gtype, 0):]:
                model.geom_rgba[gid, 3] = 0.0
                set_geom_collidable(model, gid, False)
        return solid


_TYPE_TAG = {SPHERE: "s", ELLIPSOID: "e", CAPSULE: "c", CYLINDER: "y", BOX: "b"}


def palette_counts(*models):
    """Smallest palette that can show every model in `models`."""
    counts = {}
    for parts in models:
        need = {}
        for part in parts:
            need[part.type] = need.get(part.type, 0) + 1
        for gtype, n in need.items():
            counts[gtype] = max(counts.get(gtype, 0), n)
    return counts


# ----------------------------------------------------------------------------
# Arena: square lawn
# ----------------------------------------------------------------------------
ARENA_HALF_SIZE_MM = 150.0
GRASS_TILE_MM = 12.0
GRASS_TEXTURE_PX = 96


def _grass_texture_bytes(px=GRASS_TEXTURE_PX, seed=7):
    """Tileable lawn: soft mottling plus short blade strokes, low contrast.

    Mean luminance (~0.36) is kept close to FlyGym's grey checker (0.30/0.40)
    so the eye cameras' overall brightness baseline barely moves.
    """
    rng = np.random.default_rng(seed)
    base = np.array([0.23, 0.46, 0.14])
    img = np.ones((px, px, 3)) * base
    # Tileable low-frequency mottling from a few wrapped sinusoids.
    yy, xx = np.mgrid[0:px, 0:px] / px * 2.0 * math.pi
    mottle = np.zeros((px, px))
    for _ in range(6):
        kx, ky = rng.integers(1, 4, size=2)
        phase = rng.uniform(0, 2 * math.pi)
        mottle += np.sin(kx * xx + ky * yy + phase)
    mottle /= 6.0
    img *= (1.0 + 0.18 * mottle)[..., None]
    # Short blade strokes (wrapped so the tile repeats seamlessly).
    blade_colors = [np.array([0.30, 0.58, 0.18]), np.array([0.18, 0.38, 0.11]),
                    np.array([0.36, 0.62, 0.22])]
    for _ in range(px * 3):
        x0, y0 = rng.uniform(0, px, size=2)
        length = rng.uniform(2.0, 5.0)
        angle = rng.uniform(-0.6, 0.6) + math.pi / 2 * rng.integers(0, 2)
        color = blade_colors[rng.integers(0, len(blade_colors))]
        for t in np.linspace(0.0, length, int(length * 2) + 1):
            x = int(x0 + math.cos(angle) * t) % px
            y = int(y0 + math.sin(angle) * t) % px
            img[y, x] = img[y, x] * 0.4 + color * 0.6
    img = np.clip(img, 0.0, 1.0)
    return (img * 255.0 + 0.5).astype(np.uint8).tobytes()


def style_arena(world, half_size_mm=ARENA_HALF_SIZE_MM):
    """Turn FlyGym's grey checker plane into a square lawn.

    MuJoCo planes collide as infinite planes whatever their size, so this only
    changes what is drawn (and what the eye cameras see): contacts, the fly's
    footing and every existing experiment coordinate are unchanged.
    """
    spec = world.mjcf_root
    tex = spec.add_texture(name="v562_grass", type=mujoco.mjtTexture.mjTEXTURE_2D,
                           width=GRASS_TEXTURE_PX, height=GRASS_TEXTURE_PX, nchannel=3)
    tex.data = _grass_texture_bytes()
    material = spec.add_material(name="v562_lawn", reflectance=0.0, specular=0.05,
                                 shininess=0.05)
    material.textures[int(mujoco.mjtTextureRole.mjTEXROLE_RGB)] = "v562_grass"
    repeat = 2.0 * half_size_mm / GRASS_TILE_MM
    material.texrepeat = [repeat, repeat]
    ground = world.ground_geom
    ground.material = "v562_lawn"
    ground.size = [half_size_mm, half_size_mm, 1.0]
    return ground


# ----------------------------------------------------------------------------
# Participant: stick figure ("쫄라맨")
# ----------------------------------------------------------------------------
# Frame: origin = head centre (the participant's pose and collision radius),
# +X forward, +Y left, +Z up; the body frame only yaws (look pitch stays in the
# camera), so the figure never tips over when the user looks up or down.
INK = (0.08, 0.08, 0.09, 1.0)
FACE = (0.97, 0.95, 0.90, 1.0)
LIMB_R = 0.32
FIGURE_FOOT_Z = -9.9               # foot capsule centre below the head centre
FIGURE_CLEARANCE_MM = 0.08
FIGURE_HEAD_HEIGHT_MM = -FIGURE_FOOT_Z + LIMB_R + FIGURE_CLEARANCE_MM  # 10.3 mm
SHOULDER = (0.0, 0.0, -3.4)
HIP = (0.0, 0.0, -6.6)
LEFT_HAND = (0.35, 2.55, -6.1)
RIGHT_HAND = (0.35, -2.55, -6.1)
# With the toy gun out, the right arm points forward at shoulder height.
RIGHT_HAND_AIM = (2.35, -0.95, -3.7)


def figure_body_parts(*, aiming=False):
    """Collidable stick-figure limbs (the head sphere is the participant geom)."""
    hand = RIGHT_HAND_AIM if aiming else RIGHT_HAND
    return [
        stick((0.0, 0.0, -2.35), HIP, LIMB_R, INK),                  # neck + torso
        stick(SHOULDER, LEFT_HAND, 0.28, INK),                        # left arm
        stick(SHOULDER, hand, 0.28, INK),                             # right arm
        stick(HIP, (0.15, 1.5, FIGURE_FOOT_Z), LIMB_R, INK),          # left leg
        stick(HIP, (0.15, -1.5, FIGURE_FOOT_Z), LIMB_R, INK),         # right leg
    ]


def figure_face_parts(radius_mm):
    """Two dot eyes and a smile drawn on the head surface (decorative).

    They stick out of the head sphere by <= 0.06 mm; the first-person camera
    sits inside the head and hides these along with the head sphere.
    """
    r = radius_mm
    eye_x = r * math.cos(math.radians(22)) * math.cos(math.radians(18))
    eye_y = r * math.sin(math.radians(22)) * math.cos(math.radians(18))
    eye_z = r * math.sin(math.radians(18))
    tilt_l = quat_z_to((eye_x, eye_y, eye_z))
    tilt_r = quat_z_to((eye_x, -eye_y, eye_z))
    eyes = [ell((eye_x * 0.995, eye_y * 0.995, eye_z * 0.995), (0.22, 0.30, 0.06), INK, tilt_l, False),
            ell((eye_x * 0.995, -eye_y * 0.995, eye_z * 0.995), (0.22, 0.30, 0.06), INK, tilt_r, False)]
    # Smile: short capsules hugging the sphere on an arc below the eyes.
    smile = []
    points = []
    for deg in (-26, -13, 0, 13, 26):
        yaw = math.radians(deg)
        pitch = math.radians(-14 - 7 * math.cos(math.radians(deg * 3.4)))
        points.append((r * math.cos(pitch) * math.cos(yaw) * 1.0,
                       r * math.cos(pitch) * math.sin(yaw) * 1.0,
                       r * math.sin(pitch)))
    for a, b in zip(points, points[1:]):
        smile.append(stick(a, b, 0.07, INK, collide=False))
    return eyes + smile


def gun_parts():
    """Toy BB pistol held in the aiming right hand (decorative, non-colliding).

    Orange muzzle tip marks it as a toy. Barrel axis is +X from the hand.
    """
    hx, hy, hz = RIGHT_HAND_AIM
    body = (0.30, 0.30, 0.32, 1.0)
    dark = (0.14, 0.14, 0.15, 1.0)
    orange = (1.0, 0.45, 0.05, 1.0)
    grip_q = quat_axis((0.0, 1.0, 0.0), math.radians(-18))
    return [
        block((hx + 0.85, hy, hz + 0.42), (1.05, 0.22, 0.26), body, collide=False),       # slide
        block((hx + 0.05, hy, hz - 0.18), (0.26, 0.19, 0.55), dark, grip_q, collide=False),  # grip
        disc((hx + 2.0, hy, hz + 0.47), 0.13, 0.1, orange,
             quat_z_to((1.0, 0.0, 0.0)), collide=False),                                   # muzzle
        stick((hx + 0.35, hy, hz + 0.02), (hx + 0.75, hy, hz - 0.02), 0.07, dark, False),  # trigger guard
    ]


def figure_parts(radius_mm, *, aiming=False, gun=False):
    parts = figure_body_parts(aiming=aiming or gun) + figure_face_parts(radius_mm)
    if gun:
        parts += gun_parts()
    return parts


FIGURE_PALETTE = palette_counts(figure_parts(2.5, gun=True))
BB_MUZZLE_OFFSET_MM = (RIGHT_HAND_AIM[0] + 2.15, RIGHT_HAND_AIM[1], RIGHT_HAND_AIM[2] + 0.47)


# ----------------------------------------------------------------------------
# Food models (unit bounding diameter 1, bottom at z = -0.5)
# ----------------------------------------------------------------------------
# No food colour is near the magenta configured-loom target (chroma distance
# > 0.15 for every part), so food never enters the legacy colour-occupancy path.
def _apple():
    red = (0.78, 0.09, 0.07, 1.0)
    return [
        ball((0.0, 0.0, -0.05), 0.45, red),
        ell((0.0, 0.0, 0.33), (0.2, 0.2, 0.08), (0.62, 0.06, 0.05, 1.0)),       # dimple rim
        stick((0.0, 0.0, 0.3), (0.05, 0.0, 0.5), 0.03, (0.33, 0.2, 0.09, 1.0)),  # stem
        ell((0.13, 0.0, 0.47), (0.13, 0.055, 0.018), (0.22, 0.58, 0.14, 1.0),
            quat_axis((0.0, 1.0, 0.0), math.radians(-25))),                      # leaf
    ]


def _banana():
    yellow = (0.96, 0.80, 0.16, 1.0)
    pts = [(0.6 * math.cos(math.radians(a)), 0.6 * math.sin(math.radians(a)) - 0.35, -0.39)
           for a in (38, 64, 90, 116, 142)]
    parts = [stick(a, b, 0.11 if i in (1, 2) else 0.095, yellow) for i, (a, b) in enumerate(zip(pts, pts[1:]))]
    parts += [ball(pts[0], 0.05, (0.3, 0.2, 0.08, 1.0)),
              stick(pts[-1], (pts[-1][0] - 0.07, pts[-1][1] - 0.05, pts[-1][2]), 0.045,
                    (0.45, 0.4, 0.12, 1.0))]
    return parts


def _cheese():
    body = (0.98, 0.76, 0.22, 1.0)
    hole = (0.86, 0.58, 0.12, 1.0)
    return [
        block((0.0, 0.0, -0.32), (0.42, 0.3, 0.18), body),
        ell((0.2, -0.301, -0.28), (0.07, 0.012, 0.06), hole),
        ell((-0.15, -0.301, -0.36), (0.05, 0.012, 0.045), hole),
        ell((0.05, 0.0, -0.141), (0.08, 0.07, 0.012), hole),
        ell((-0.26, 0.12, -0.141), (0.05, 0.05, 0.012), hole),
    ]


def _grapes():
    berry = (0.40, 0.08, 0.16, 1.0)
    shine = (0.50, 0.12, 0.20, 1.0)
    r = 0.15
    layout = [(-0.14, -0.14, -0.35), (0.14, -0.14, -0.35), (-0.14, 0.14, -0.35), (0.14, 0.14, -0.35),
              (0.0, 0.0, -0.33), (0.0, -0.14, -0.1), (0.13, 0.08, -0.1), (-0.13, 0.08, -0.1),
              (0.0, 0.0, 0.14)]
    parts = [ball(p, r, berry if i % 3 else shine) for i, p in enumerate(layout)]
    parts.append(stick((0.0, 0.0, 0.26), (0.06, 0.0, 0.45), 0.03, (0.35, 0.25, 0.1, 1.0)))
    return parts


def _cookie():
    dough = (0.83, 0.61, 0.33, 1.0)
    chip = (0.24, 0.12, 0.05, 1.0)
    parts = [disc((0.0, 0.0, -0.42), 0.48, 0.08, dough)]
    for x, y in ((0.18, 0.1), (-0.15, 0.2), (-0.2, -0.14), (0.1, -0.22), (0.0, 0.02)):
        parts.append(ell((x, y, -0.34), (0.055, 0.055, 0.03), chip))
    return parts


def _sugar_cube():
    return [block((0.0, 0.0, -0.21), (0.29, 0.29, 0.29), (0.97, 0.97, 0.95, 1.0),
                  quat_axis((0.0, 0.0, 1.0), math.radians(12)))]


FOOD_VARIANTS = {
    "apple": _apple(),
    "banana": _banana(),
    "cheese": _cheese(),
    "grapes": _grapes(),
    "cookie": _cookie(),
    "sugar_cube": _sugar_cube(),
}
FOOD_VARIANT_ORDER = tuple(FOOD_VARIANTS)
# Relative sugar content 0..1 used as the modeled sugar-contact signal while the
# fly's mouth touches the food. A coarse modelling assumption (ranked by typical
# sugar fraction), not measured chemistry; cheese is near zero.
FOOD_SUGAR = {"apple": 0.55, "banana": 0.65, "cheese": 0.05,
              "grapes": 0.7, "cookie": 0.8, "sugar_cube": 1.0}
FOOD_PALETTE = palette_counts(*FOOD_VARIANTS.values())


# ----------------------------------------------------------------------------
# Toy car (unit length 1 along +X; bounding box centred on the origin)
# ----------------------------------------------------------------------------
CAR_WIDTH_RATIO = 0.44
CAR_HEIGHT_RATIO = 0.41


def car_parts():
    paint = (0.84, 0.13, 0.10, 1.0)
    glass = (0.55, 0.74, 0.90, 0.85)
    tyre = (0.07, 0.07, 0.08, 1.0)
    hub = (0.72, 0.72, 0.75, 1.0)
    axle_y = quat_z_to((0.0, 1.0, 0.0))
    parts = [
        block((0.0, 0.0, -0.035), (0.5, 0.22, 0.075), paint),           # chassis
        block((-0.06, 0.0, 0.095), (0.23, 0.185, 0.055), glass),         # cabin glass
        block((-0.06, 0.0, 0.1875), (0.25, 0.2, 0.0175), paint),         # roof
        block((0.502, 0.0, -0.045), (0.006, 0.09, 0.03), (0.18, 0.18, 0.2, 1.0), collide=False),  # grille
        block((0.505, 0.0, -0.1), (0.012, 0.21, 0.018), (0.25, 0.25, 0.27, 1.0), collide=False),  # bumper
        block((-0.505, 0.0, -0.1), (0.012, 0.21, 0.018), (0.25, 0.25, 0.27, 1.0), collide=False),
    ]
    for x in (0.3, -0.3):
        for y in (0.2, -0.2):
            parts.append(disc((x, y, -0.115), 0.095, 0.035, tyre, axle_y))
            parts.append(disc((x, y * 1.2, -0.115), 0.045, 0.006, hub, axle_y, collide=False))
    for y in (0.14, -0.14):
        parts.append(ell((0.5, y, -0.01), (0.014, 0.042, 0.028), (1.0, 0.96, 0.7, 1.0), collide=False))
        parts.append(ell((-0.5, y, -0.01), (0.014, 0.036, 0.024), (0.9, 0.08, 0.05, 1.0), collide=False))
    return parts


CAR_PARTS = car_parts()
CAR_PALETTE = palette_counts(CAR_PARTS)


# ----------------------------------------------------------------------------
# Cage trap (unit footprint side 1; height 0.6; centred on the origin)
# ----------------------------------------------------------------------------
TRAP_HEIGHT_RATIO = 0.6
TRAP_WALL_RATIO = 0.02


def trap_parts():
    glass = (0.78, 0.88, 0.96, 0.32)
    frame = (0.22, 0.24, 0.27, 1.0)
    h = TRAP_HEIGHT_RATIO * 0.5
    t = TRAP_WALL_RATIO * 0.5
    parts = [
        block((0.5 - t, 0.0, 0.0), (t, 0.5, h), glass),
        block((-0.5 + t, 0.0, 0.0), (t, 0.5, h), glass),
        block((0.0, 0.5 - t, 0.0), (0.5 - 2 * t, t, h), glass),
        block((0.0, -0.5 + t, 0.0), (0.5 - 2 * t, t, h), glass),
        block((0.0, 0.0, h - t), (0.5 - 2 * t, 0.5 - 2 * t, t), glass),  # lid
    ]
    e = 0.5 - t
    corners = [(e, e), (-e, e), (-e, -e), (e, -e)]
    for (x0, y0), (x1, y1) in zip(corners, corners[1:] + corners[:1]):
        parts.append(stick((x0, y0, h - t), (x1, y1, h - t), 0.014, frame, collide=False))
        parts.append(stick((x0, y0, -h + t), (x1, y1, -h + t), 0.014, frame, collide=False))
    for x, y in corners:
        parts.append(stick((x, y, -h + t), (x, y, h - t), 0.014, frame, collide=False))
    parts.append(stick((0.0, -0.12, h + 0.01), (0.0, 0.12, h + 0.01), 0.03, frame, collide=False))  # handle
    return parts


TRAP_PARTS = trap_parts()
TRAP_PALETTE = palette_counts(TRAP_PARTS)


# ----------------------------------------------------------------------------
# BB pellet
# ----------------------------------------------------------------------------
BB_RADIUS_MM = 0.6
BB_RGBA = (0.97, 0.93, 0.62, 1.0)
# Tracer: a thin glowing streak over the pellet's last BB_TRACER_TRAIL_S, drawn
# only for the user. Geom group 3 is off in FlyGym's eye renderer (it shows
# group 0 only), so the fly never sees this effect; it never collides.
# ~15 ms of flight: about one app frame at the backend's usual 0.4x realtime.
BB_TRACER_RGBA = (1.0, 0.86, 0.4, 0.45)
BB_TRACER_RADIUS_MM = 0.12
BB_TRACER_TRAIL_S = 0.015
VIEW_ONLY_GROUP = 3
