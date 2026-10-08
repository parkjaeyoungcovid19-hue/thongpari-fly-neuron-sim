"""neural_decoder.py - the ONE place brain->locomotor engineering mapping lives.

Biology vs engineering (do not relabel):
- BIOLOGICAL READOUTS: walk/turn/backward/groom/wing/escape/sleep/arousal values
  come from FlyWire DN population rates via SignalBuilder (DNp09/DNa01/DNa02/
  MDN/DNg11/DNp02-04-11/GF). The bridge never recomputes them.
- ENGINEERING APPROXIMATIONS (this file): how those drives modulate an existing
  FlyGym locomotion controller/CPG. Forward gain, steering gain, escape urgency,
  and sleep gating are chosen for stable walking, not measured from the fly.
"""
from __future__ import annotations
from dataclasses import dataclass

@dataclass
class LocomotorCommand:
    forward: float = 0.0      # 0..1 locomotion intensity -> controller speed/amplitude
    steering: float = 0.0     # -1..1 left(+) / right(-)
    reverse: bool = False     # only if the controller cleanly supports it
    urgent: bool = False      # escape pulse -> temporary urgency
    moving: bool = True       # False when sleep gates locomotion
    groom_state: float = 0.0  # exposed state; only wired if FlyGym has grooming
    wing_state: float = 0.0   # diagnostics only; never fakes flight
    tempo: float = 1.0        # 0.2..2.0 modeled physiology / controller cadence scale

# Engineering gains (approximation, see module docstring).
ESCAPE_BOOST = 0.6

def decode(brain) -> LocomotorCommand:
    """Map a BrainPacket (or dict-like) to a LocomotorCommand."""
    g = lambda k, d=0.0: float(getattr(brain, k, brain.get(k, d)) if isinstance(brain, dict) else getattr(brain, k, d))
    b = lambda k, d=False: bool(getattr(brain, k, brain.get(k, d)) if isinstance(brain, dict) else getattr(brain, k, d))
    walk = max(0.0, min(1.3, g("walk")))
    turn = max(-1.0, min(1.0, g("turn")))
    escape = b("escape")
    backward = b("backward")
    sleep = b("sleep")
    groom = max(0.0, min(1.5, g("groom")))
    wing = max(0.0, min(1.3, g("wing")))
    tempo = max(0.2, min(2.0, g("tempo", 1.0)))
    forward = 0.0 if sleep else max(0.0, min(1.0, walk))
    if escape and not sleep:
        forward = max(forward, min(1.0, forward + ESCAPE_BOOST))
    cmd = LocomotorCommand(
        forward=forward,
        steering=0.0 if sleep else turn,
        reverse=bool(backward and not sleep),
        urgent=bool(escape and not sleep),
        moving=not sleep,
        groom_state=groom,
        wing_state=wing,
        tempo=tempo,
    )
    return cmd
