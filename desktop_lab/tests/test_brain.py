import ctypes
import ctypes.util
import math
import sys
import unittest
from pathlib import Path

import numpy as np

from desktop_lab.brain import Brain, Connectome, F, U, pcg, quantize, tick

ROOT = Path(__file__).resolve().parents[2]


def hash_reference(value):
    state = (value * 747796405 + 2891336453) & 0xFFFFFFFF
    word = (((state >> ((state >> 28) + 4)) ^ state) * 277803737) & 0xFFFFFFFF
    return ((word >> 22) ^ word) & 0xFFFFFFFF


class KernelTests(unittest.TestCase):
    def test_pcg_wrap_matches_independent_integer_oracle(self):
        for value in [0, 1, 0xFFFFFFFF, 0x5EED1F1F] + list(range(0, 1000000, 7919)):
            self.assertEqual(int(pcg(U(value))), hash_reference(value))

    def test_scalar_reference_spikes_membranes_and_delays(self):
        """Independent scalar oracle, including pre-decrement refractory and FMA."""
        libm = ctypes.CDLL("ucrtbase.dll" if sys.platform == "win32" else ctypes.util.find_library("m"))
        fma = libm.fmaf
        fma.argtypes = [ctypes.c_float] * 3
        fma.restype = ctypes.c_float
        n = 6
        row = np.array([0, 2, 3, 4, 4, 4, 4], np.uint32)
        col = np.array([1, 2, 3, 4], np.uint32)
        weights = np.array([32768, -32768, 16384, -16384], np.int32)
        v = np.array([1.1, 0, 0.8, 0, 0.2, 0], np.float32)
        baseline = np.array([0, 0.051, 0.04, 0.05, 0.02, 0.03], np.float32)
        refr = np.array([0, 0, 0, 1, 0, 2], np.uint8)
        exc = np.zeros(n, np.int32)
        inh = np.zeros((5, n), np.int32)
        rv, rr, rx, ri = v.copy(), refr.copy(), exc.copy(), inh.copy()
        kind = np.zeros(n, np.uint8)
        phase = np.zeros(n, np.float32)
        ext = np.array([0, 0, 0, 0, 0.005, 0], np.float32)
        groups = np.arange(n, dtype=np.uint8)
        rates = np.zeros(16, np.float32)
        sizes = np.ones(16, np.float32)
        sizes[0] = n
        seed = 0x5EED1F1F
        for step in range(1, 81):
            expected = []
            cur = (step - 1) % 5
            future = (step + 3) % 5
            for i in range(n):
                vi = rv[i]
                if rx[i]:
                    vi = F(max(-2, F(vi + F(rx[i]) * F(1 / 65536))))
                    rx[i] = 0
                if rr[i]:
                    rr[i] -= 1
                    vi = F(vi * F(0.9512))
                else:
                    vi = F(fma(vi, F(0.9512), baseline[i]))
                    h = hash_reference(
                        (hash_reference((seed + step * 2654435761) & 0xFFFFFFFF) + i)
                        & 0xFFFFFFFF
                    )
                    if F(h >> 8) * F(5.9604645e-8) < F(0.005):
                        vi = F(vi + F(0.25))
                vi = F(vi + ext[i])
                if ri[cur, i]:
                    vi = F(max(-2, F(vi + F(ri[cur, i]) * F(1 / 65536))))
                    ri[cur, i] = 0
                if rr[i] == 0 and vi >= 1:
                    vi = F(0)
                    rr[i] = 2
                    expected.append(i)
                rv[i] = vi
            for i in expected:
                for k in range(row[i], row[i + 1]):
                    if weights[k] >= 0:
                        rx[col[k]] += weights[k]
                    else:
                        ri[future, col[k]] += weights[k]
            spikes, _ = tick(
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
                U(seed),
                F(1 / 65536),
                F(0.005),
                F(1),
                np.zeros(5, np.float32),
            )
            self.assertEqual(spikes.tolist(), expected, f"spikes at tick {step}")
            np.testing.assert_array_equal(refr, rr)
            np.testing.assert_allclose(v, rv, rtol=0, atol=2e-7)
            np.testing.assert_array_equal(exc, rx)
            np.testing.assert_array_equal(inh, ri)

    def test_quantization_routes_and_rounding(self):
        row = np.array([0, 2, 4, 6, 8], np.uint32)
        col = np.array([2, 3] * 4, np.uint32)
        raw = np.array([50, -50] * 4, np.int16)
        role = np.array([1, 11, 3, 0], np.uint8)
        nt = np.array([1, 1, 1, 4], np.uint8)
        actual = quantize(row, col, raw, role, nt, 65536)
        expected = []
        for pre in range(4):
            for k in range(row[pre], row[pre + 1]):
                gain = (
                    F(0.5 if pre == 0 else 1.5 if pre == 1 else 0.12)
                    if col[k] == 2
                    else F(1)
                )
                weight = (
                    F(
                        F(raw[k])
                        * F(F(F(0.0032) * F(0.5 if nt[pre] >= 4 else 1)) * F(65536))
                    )
                    * gain
                )
                expected.append(
                    int(math.copysign(math.floor(abs(float(weight)) + 0.5), weight))
                )
        np.testing.assert_array_equal(actual, expected)


class FullConnectomeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.brain = Brain(Connectome(ROOT / "data"))

    def setUp(self):
        self.brain.reset()

    def test_full_graph_and_identified_taste(self):
        b = self.brain
        self.assertEqual((b.c.n, b.c.e), (139255, 15091983))
        self.assertEqual(len(b.weights), b.c.e)
        self.assertEqual(len(b.sugar), 21)
        self.assertEqual(b.fx, 65536)
        self.assertTrue(np.all(b.c.rowStart[b.sugar + 1] > b.c.rowStart[b.sugar]))

    def test_seed_reset_is_reproducible(self):
        b = self.brain
        first = b.step(120)
        v = b.v.copy()
        rates = b.rates.copy()
        b.reset()
        self.assertEqual(b.step(120), first)
        np.testing.assert_array_equal(b.v, v)
        np.testing.assert_array_equal(b.rates, rates)

    def test_rest_and_abrupt_loom_use_connectome_giant_fiber(self):
        b = self.brain
        rest = b.step(4000)
        self.assertFalse(rest["escape"])
        self.assertGreater(float(b.rates[6]), 1)
        self.assertTrue(np.all(np.isfinite(b.v)))
        self.assertGreater(b.total_spikes, 10000)
        escaped = False
        for _ in range(10):
            if b.step(1, {"loom_left": 1, "loom_right": 1})["escape"]:
                escaped = True
                break
        self.assertTrue(
            escaped,
            "abrupt loom must propagate through actual GF connectivity within 10ms",
        )

    def test_sensory_paths_distinguish_taste_from_odor_and_heading(self):
        b = self.brain
        ext, _ = b.sensory({"odor_left": 1}, {})
        self.assertEqual(float(ext[b.sugar].max()), 0)
        self.assertAlmostEqual(float(ext[b.groups == 9].max()), 0.06, places=6)
        ext, _ = b.sensory(
            {
                "taste_sugar": 1,
                "wind_sensory": True,
                "wind_strength": 1,
                "heading_rad": 0,
            },
            {},
        )
        self.assertAlmostEqual(float(ext[b.sugar].min()), 0.12, places=6)
        self.assertAlmostEqual(float(ext[b.groups == 13].max()), 0.055, places=6)
        self.assertEqual(float(ext[b.groups == 14].max()), 0)

    def test_direct_stimulation_has_exact_expiry_and_reset_clears_it(self):
        b = self.brain
        b.stimulate("GF", strength=0.5, duration_ms=40)
        self.assertTrue(b.step(20)["escape"])
        b.step(20)
        self.assertEqual(b.stimuli, [])
        b.reset()
        self.assertEqual(b.stimuli, [])
        self.assertEqual(b.total_spikes, 0)


if __name__ == "__main__":
    unittest.main()
