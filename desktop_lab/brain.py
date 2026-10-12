"""CPU implementation of LIF.metal, SimParams and MotorReadout.

The shipped CSR is used in full. Integer synaptic accumulation, PCG noise,
1 ms neural ticks and 4 ms inhibition delay are preserved. LLVM contracts
float32 multiply/add into FMA but never reassociates operations. This is a
separate CPU implementation, not a claim of bit equivalence with a Metal GPU.
"""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

import numpy as np
from numba import njit

F = np.float32
U = np.uint32
GROUP_NAMES = (
    "population",
    "loom",
    "GF",
    "DNa-left",
    "DNa-right",
    "MDN",
    "DNp09",
    "DNg11",
    "escW",
    "odor-left",
    "odor-right",
    "warm",
    "cool",
    "wind-C",
    "wind-E",
    "sugar",
)
SUGAR_IDS = (
    720575940624963786,
    720575940630233916,
    720575940637568838,
    720575940638202345,
    720575940617000768,
    720575940630797113,
    720575940632889389,
    720575940621754367,
    720575940621502051,
    720575940640649691,
    720575940639332736,
    720575940616885538,
    720575940639198653,
    720575940639259967,
    720575940617937543,
    720575940632425919,
    720575940633143833,
    720575940612670570,
    720575940628853239,
    720575940629176663,
    720575940611875570,
)


@njit(cache=True)
def pcg(value):
    state = U(U(value) * U(747796405) + U(2891336453))
    word = U(((state >> U((state >> U(28)) + U(4))) ^ state) * U(277803737))
    return U((word >> U(22)) ^ word)


@njit(cache=True)
def draw(seed, salt, index):
    return F(pcg(U(pcg(U(seed + salt)) + U(index))) >> U(8)) * F(5.9604645e-8)


@njit(cache=True)
def quantize(row, col, raw, role, nt, fx):
    out = np.empty(len(raw), dtype=np.int32)
    for i in range(len(role)):
        g = F(F(0.0032) * (F(0.5) if nt[i] >= 4 else F(1))) * F(fx)
        for k in range(row[i], row[i + 1]):
            gain = F(1)
            if role[col[k]] == 3:
                gain = (
                    F(0.5)
                    if role[i] in (1, 2)
                    else (F(1.5) if role[i] == 11 else F(0.12))
                )
            w = F(F(raw[k]) * g) * gain
            # Swift .rounded(): nearest, ties away from zero.
            out[k] = int(math.floor(w + 0.5) if w >= 0 else math.ceil(w - 0.5))
    return out


@njit(cache=True, fastmath={"contract"}, nogil=True)
def tick(
    v,
    refr,
    baseline,
    kind,
    phase,
    ext,
    exc,
    inh,
    row,
    col,
    weights,
    groups,
    sizes,
    rates,
    step,
    seed,
    inv_fx,
    probability,
    activity,
    drives,
):
    n = len(v)
    cur = (step - 1) % 5
    future = (step - 1 + 4) % 5
    h0 = pcg(U(seed + U(U(step) * U(2654435761))))
    spikes = np.empty(n, np.int32)
    count = 0
    hist = np.zeros(16, np.int32)
    for i in range(n):
        vi = v[i]
        if exc[i] != 0:
            vi = max(F(-2), F(vi + F(exc[i]) * inv_fx))
            exc[i] = 0
        if refr[i] > 0:
            refr[i] -= 1
            vi = F(vi * F(0.9512))
        else:
            vi = F(vi * F(0.9512) + F(baseline[i] * activity))
            if F(pcg(U(h0 + U(i))) >> U(8)) * F(5.9604645e-8) < probability:
                vi = F(vi + F(0.25))
        if kind[i] == 1:
            vi = F(vi + drives[0])
        elif kind[i] == 2:
            vi = F(vi + drives[1])
        elif kind[i] == 3:
            shape = F(F(0.5) + F(0.5) * F(math.sin(F(drives[3] + phase[i]))))
            vi = F(vi + drives[2] * shape)
        elif kind[i] == 4:
            vi = F(vi + drives[4])
        vi = F(vi + ext[i])
        if inh[cur, i] != 0:
            vi = max(F(-2), F(vi + F(inh[cur, i]) * inv_fx))
            inh[cur, i] = 0
        if refr[i] == 0 and vi >= F(1):
            vi = F(0)
            refr[i] = 2
            spikes[count] = i
            count += 1
            hist[groups[i]] += 1
        v[i] = vi
    for t in range(count):
        i = spikes[t]
        for k in range(row[i], row[i + 1]):
            j, w = col[k], weights[k]
            if w >= 0:
                exc[j] = np.int32(exc[j] + w)
            else:
                inh[future, j] = np.int32(inh[future, j] + w)
    hist[0] = count
    for g in range(16):
        rates[g] = F(
            rates[g] + F(F(F(hist[g]) * F(1000) / sizes[g] - rates[g]) * F(1 / 120))
        )
    return spikes[:count], hist


class Connectome:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.manifest = json.loads((self.directory / "connectome.json").read_text(encoding="utf-8"))
        for name, info in self.manifest["files"].items():
            path = self.directory / name
            if (
                path.stat().st_size != info["bytes"]
                or hashlib.sha256(path.read_bytes()).hexdigest() != info["sha256"]
            ):
                raise ValueError(f"connectome integrity check failed: {name}")
        for name, rec in self.manifest["arrays"].items():
            array = np.memmap(
                self.directory / rec["file"],
                dtype=np.dtype(rec["dtype"]).newbyteorder("<"),
                mode="r",
                offset=rec["byteOffset"],
                shape=(rec["count"],),
            )
            setattr(self, name, array)
        self.n = self.manifest["neuronCount"]
        self.e = self.manifest["edgeCount"]
        if (
            len(self.rowStart) != self.n + 1
            or self.rowStart[0] != 0
            or self.rowStart[-1] != self.e
            or np.any(self.rowStart[1:] < self.rowStart[:-1])
            or np.any(self.colIdx >= self.n)
        ):
            raise ValueError("invalid connectome CSR")
        self.positions = self.pos.reshape(self.n, 3)
        self.tables = self.manifest["stringTables"]


class Brain:
    def __init__(self, connectome: Connectome, seed=0x5EED1F1F):
        self.c = connectome
        self.seed = U(seed)
        n = connectome.n
        self.baseline = np.zeros(n, np.float32)
        self.groups = np.zeros(n, np.uint8)
        self.kind = np.zeros(n, np.uint8)
        self.phase = np.zeros(n, np.float32)
        ranges = {
            "optic": (0.021, 0.043),
            "central": (0.023, 0.047),
            "visual_projection": (0.021, 0.043),
            "sensory": (0, 0.004),
            "sensory_ascending": (0, 0.006),
        }
        for i in range(n):
            lo, hi = ranges.get(
                connectome.tables["superClasses"][connectome.superClass[i]],
                (0.019, 0.043),
            )
            r, left = connectome.role[i], connectome.side[i] == 1
            if r in (1, 2):
                lo, hi = 0.008, 0.028
                self.groups[i], self.kind[i] = 1, 1 if left else 2
            elif r == 3:
                lo = hi = 0.002
                self.groups[i] = 2
            elif r in (4, 5):
                lo = hi = 0.022
                self.groups[i] = 3 if left else 4
            elif r in (6, 7, 8, 9):
                lo = hi = 0.032 if r == 6 else 0.022
                self.groups[i] = {6: 6, 7: 7, 8: 5, 9: 8}[r]
            elif r == 10:
                self.kind[i] = 3
                self.phase[i] = F(F(2) * F(np.pi)) * draw(self.seed, U(0x2F1B3C4D), i)
            elif r == 11:
                self.kind[i] = 4
            self.baseline[i] = F(lo) + F(F(hi) - F(lo)) * draw(
                self.seed, U(0x51ED2701), i
            )
            if not self.groups[i]:
                name = connectome.tables["cellTypes"][connectome.cellType[i]]
                if name in ("ORN_DM1", "ORN_VA2") and connectome.side[i] in (1, 2):
                    self.groups[i] = 9 if left else 10
                elif name == "TRN_VP2":
                    self.groups[i] = 11
                elif name in ("TRN_VP3a", "TRN_VP3b"):
                    self.groups[i] = 12
                elif connectome.rowStart[i + 1] > connectome.rowStart[i]:
                    if name.startswith("JO-C"):
                        self.groups[i] = 13
                    elif name.startswith("JO-E"):
                        self.groups[i] = 14
        self.sugar = np.flatnonzero(np.isin(connectome.rootId, SUGAR_IDS))
        self.groups[self.sugar] = 15
        self.sizes = np.maximum(1, np.bincount(self.groups, minlength=16)).astype(
            np.float32
        )
        self.sizes[0] = n
        # Match MetalShared's adaptive fixed-point scale and overflow bound.
        row_gain = F(0.0032) * np.where(connectome.nt >= 4, F(0.5), F(1)).astype(
            np.float32
        )
        maximum = F(0)
        for start in range(0, n, 8192):
            end = min(n, start + 8192)
            a, b = int(connectome.rowStart[start]), int(connectome.rowStart[end])
            pre = np.repeat(
                np.arange(start, end),
                np.diff(connectome.rowStart[start : end + 1]).astype(int),
            )
            gain = np.ones(b - a, np.float32)
            gf = connectome.role[connectome.colIdx[a:b]] == 3
            gain[gf] = np.where(
                np.isin(connectome.role[pre[gf]], [1, 2]),
                F(0.5),
                np.where(connectome.role[pre[gf]] == 11, F(1.5), F(0.12)),
            )
            maximum = max(
                maximum,
                np.max(
                    np.abs(connectome.weight[a:b].astype(np.float32))
                    * row_gain[pre]
                    * gain,
                    initial=0,
                ),
            )
        self.fx = 1048576
        while (
            self.fx > 65536 and float(maximum) * self.fx * 4096 > np.iinfo(np.int32).max
        ):
            self.fx //= 2
        if float(maximum) * self.fx * 4096 > np.iinfo(np.int32).max:
            raise ValueError("fixed-point weight overflow")
        self.weights = quantize(
            connectome.rowStart,
            connectome.colIdx,
            connectome.weight,
            connectome.role,
            connectome.nt,
            self.fx,
        )
        self.reset()

    def reset(self):
        n = self.c.n
        self.v = np.zeros(n, np.float32)
        self.refr = np.zeros(n, np.uint8)
        self.exc = np.zeros(n, np.int32)
        self.inh = np.zeros((5, n), np.int32)
        self.rates = np.zeros(16, np.float32)
        self.ms = 0
        self.total_spikes = 0
        self.spikes = np.empty(0, np.int32)
        self.gf = False
        self.dna_baseline = 0.0
        self.stimuli = []
        self.burst_next, self.burst_until, self.burst_counter = 12000, 0, 0

    def population(self, name):
        if name in GROUP_NAMES[1:]:
            return np.flatnonzero(self.groups == GROUP_NAMES.index(name))
        if name == "ascend":
            return np.flatnonzero(self.c.role == 10)
        if name == "sens":
            return np.flatnonzero(self.c.role == 11)
        raise ValueError(f"unknown neural population: {name}")

    def stimulate(self, name, strength=0.15, duration_ms=200):
        self.stimulate_indices(self.population(name), strength, duration_ms)

    def stimulate_indices(self, indices, strength=0.15, duration_ms=200):
        if (
            not math.isfinite(strength)
            or not 0 <= strength <= 1
            or not 1 <= duration_ms <= 10000
        ):
            raise ValueError("invalid stimulation")
        indices = np.asarray(indices, dtype=np.int32)
        if np.any(indices < 0) or np.any(indices >= self.c.n):
            raise ValueError("neuron index out of range")
        self.stimuli.append((indices, F(strength), self.ms + int(duration_ms)))
        self.stimuli = self.stimuli[-8:]

    def sensory(self, body, world):
        ext = np.zeros(self.c.n, np.float32)
        body = body or {}
        for g, key in ((9, "odor_left"), (10, "odor_right"), (15, "taste_sugar")):
            value = min(1, max(0, body.get(key, 0)))
            ext[self.groups == g] = F(
                (0.12 if g == 15 else 0.06) * math.sqrt(math.sqrt(value))
            )
        temperature = world.get("temperature", {})
        if temperature.get("mode") == "flywire_sensory":
            t = temperature.get("celsius", 25)
            ext[self.groups == 11] = F(0.06 * min(1, max(0, (t - 25) / 10)))
            ext[self.groups == 12] = F(0.06 * min(1, max(0, (25 - t) / 10)))
        if body.get("wind_sensory"):
            strength = min(1, max(0, body.get("wind_strength", 0)))
            opponent = math.cos(
                math.radians(body.get("wind_direction_deg", 0))
                - body.get("heading_rad", 0)
            )
            ext[self.groups == 13] = F(0.055 * strength * (0.5 + 0.5 * opponent))
            ext[self.groups == 14] = F(0.055 * strength * (0.5 - 0.5 * opponent))
        touch = min(1, max(0, body.get("touch_strength", 0)))
        if body.get("touch_sensory") and touch > 0:
            ext[self.c.role == 11] = F(0.02 + 0.18 * touch)
        gait = max(
            min(1, abs(body.get("vx", 0)) / 0.03),
            min(1, abs(body.get("yaw_rate", 0)) / 4),
        )
        drives = np.array(
            [
                body.get("loom_left", 0) * 0.32,
                body.get("loom_right", 0) * 0.32,
                gait * 0.09,
                body.get("gait_phase", 0) or 0,
                0,
            ],
            np.float32,
        )
        drives[3] *= F(2) * F(np.pi)
        return ext, drives

    def step(self, milliseconds=20, body=None, world=None):
        ext, drives = self.sensory(body, world or {})
        self.gf = False
        for _ in range(milliseconds):
            self.ms += 1
            if self.ms >= self.burst_next:
                self.burst_until = self.ms + 400
                self.burst_counter += 1
                self.burst_next = (
                    self.ms
                    + 15000
                    + int(draw(self.seed, U(0x7A3B9F11), self.burst_counter) * F(25001))
                )
            current = ext.copy() if self.stimuli else ext
            self.stimuli = [s for s in self.stimuli if self.ms < s[2]]
            for indices, strength, _ in self.stimuli:
                current[indices] += strength
            probability = F(0.03 if self.ms < self.burst_until else 0.005)
            self.spikes, hist = tick(
                self.v,
                self.refr,
                self.baseline,
                self.kind,
                self.phase,
                current,
                self.exc,
                self.inh,
                self.c.rowStart,
                self.c.colIdx,
                self.weights,
                self.groups,
                self.sizes,
                self.rates,
                self.ms,
                self.seed,
                F(1 / self.fx),
                probability,
                F(1),
                drives,
            )
            self.total_spikes += len(self.spikes)
            self.gf = self.gf or bool(hist[2])
        diff = float(self.rates[3] - self.rates[4])
        self.dna_baseline += (diff - self.dna_baseline) * min(1, milliseconds / 8000)
        return {
            "walk": float(np.clip((self.rates[6] - 10) / 33, 0, 1.3)),
            "turn": float(np.clip((diff - self.dna_baseline) * 0.04, -1, 1)),
            "escape": self.gf,
            "backward": bool(self.rates[5] > 60),
            "groom": float(np.clip(self.rates[7] / 5, 0, 1.5)),
            "wing": float(np.clip(self.rates[8] / 10, 0, 1.3)),
            "nervous": float(np.clip(self.rates[1] / 115, 0, 1)),
            "arousal": float(np.clip(self.rates[0] / 10, 0, 1)),
            "t": self.ms / 1000,
            "tempo": 1,
            "sleep": False,
        }
