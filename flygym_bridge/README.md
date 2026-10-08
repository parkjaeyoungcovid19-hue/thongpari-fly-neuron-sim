# flygym_bridge — Thongpari Fly Neuron Sim brain <-> FlyGym 2.x body

Swift (`FlyGymBridge.swift`) is the TCP client, `bridge.py` is the
server on `127.0.0.1:17841`, newline-delimited JSON (see `protocol.py`).

Virtual Fly Lab V2 extends the same stream with `lab_command`, `lab_state`, and
`lab_event`. Brain/body packets keep their existing format and cadence.

## Modes

- `python bridge.py --mock` — kinematic body, no MuJoCo. Loop tests.
- `mjpython bridge.py --flygym` — real FlyGym 2.1.0 NeuroMechFly +
  HybridTurningController + MuJoCo CPU and an interactive free-camera viewer.
- `python bridge.py --flygym-headless` — same body without the viewer.

## Setup (M2 Air, Apple Silicon)

```sh
/opt/homebrew/opt/python@3.12/bin/python3.12 -m venv flygym-venv
./flygym-venv/bin/pip install "flygym[examples]"
```

No torch / TF / RL / Docker / CUDA / Warp.

The first viewer launch performs JIT/graphics prewarming before opening the TCP
listener and can take about 30 seconds on the M2 Air. Thongpari Fly Neuron Sim reconnects in
the background; normal brain simulation never waits on it.

## Mapping (engineering approximations, not measured biology)

All brain->locomotor mapping lives in `neural_decoder.py` (+ `brain_to_descending`
in `fly_body.py`). Body->brain mapping lives in Swift `FlyGymSensoryMap`.

- `walk` (DNp09) -> CPG descending-signal amplitude (cruise ~0.35 ~= 4.8 mm/s).
- `turn` (DNa L-R) -> left/right differential.
- `escape` (GF latch) -> urgency boost to cruise amplitude.
- `backward` (MDN) -> negative descending signal (controller reverses).
- `sleep` -> zero drive. `groom`/`wing` -> exposed state only, never faked.
- Body `vx`/contacts -> `gaitDrive`; CPG phase -> `gaitPhase` (proxies).
- FlyGym's actual left/right eye cameras -> `vision_decoder.py` ->
  `loom_left`/`loom_right` -> Swift `sim.loomL`/`sim.loomR` -> LC4/LPLC2.
  The legacy configured-color occupancy path is retained, and V2 also measures
  generic outward edge motion from raw frames after small whole-frame translation
  compensation. It never reads object coordinates/IDs. The generic estimator is
  an engineering approximation, **not biological retinotopy or a measured
  LC4/LPLC2 reconstruction**. Contraction, pan and full-field flash are suppressed
  as false loom cases in regression tests.
- Food geometry + actual fly pose -> bilateral modeled odor -> existing FlyWire
  `ORN_DM1`+`ORN_VA2` left/right groups. There is no taste, reward, feeding, or
  scripted food-seeking behavior. The isotropic surface-distance decay and
  left/right bearing split are sensory-model choices, not a measured odor plume,
  antennal transfer function, or chemotaxis controller.
- Lab wind sensory mode -> existing outgoing `JO-C*`/`JO-E*` groups, split by a
  modeled body-relative opponent projection using actual MuJoCo thorax heading.
  Physical wind force is independently switchable. The old generic `sens`
  (JO-A/B-like) group is not labeled or used as the V2 wind receptor path.
- `flywire_sensory` temperature -> existing `TRN_VP2` warm and
  `TRN_VP3a`+`TRN_VP3b` cool groups. Temperature scalar -> current is explicitly
  a modeling assumption; `environment_only` injects no thermosensory current.

The runtime sensory groups are selected from the shipped FlyWire v783 cell-type
labels: `ORN_DM1` + `ORN_VA2` split by side, `TRN_VP2` for warm,
`TRN_VP3a` + `TRN_VP3b` for cool, and only `JO-C*` / `JO-E*` cells with an
outgoing graph row for lab wind. The scalar-to-current gains and transduction
curves are engineering choices (currently odor `0.060`, thermal `0.060`, wind
`0.055`, followed by the Swift sensory gate), not measured receptor physiology.
`HRN_VP4`/`HRN_VP5` can be selected for direct-neural experiments in Swift, but
V2 does not implement a humidity-to-HRN sensory model.

The eye renderer uses FlyGym's real eye cameras/FOV with a 96x84 Retina at
5 Hz. Body feedback remains paced at 60 Hz; looming decays between eye samples.

## Virtual Fly Lab protocol

The Swift command is a flat, tolerant object such as:

```json
{"type":"lab_command","id":42,"action":"move_object","target":"stimulus","x":20,"y":0,"z":5}
```

Python also accepts the equivalent nested form
`{"type":"lab_command","seq":42,"op":"move_object","args":{...}}`.
Discrete commands use a bounded FIFO (128 entries). Continuous state updates
(`move_object`, `resize_object`, `wind`, eye state, temperature) use bounded
per-control latest-wins slots, so slider traffic cannot grow without limit.
MuJoCo changes are dequeued only by the simulation-owner loop.

Supported V2 operations include:

- `spawn_object` (box), `spawn_box`, `spawn_sphere`, `spawn_wall`, `spawn_food`;
  `target` is the object ID. Runtime geometry uses a fixed precompiled pool of
  8 box, 8 sphere, 8 wall, and 4 food-marker slots.
- `move_object`, `resize_object`, `delete_object`, `reset_world` and
  `approach_object`. Approach animates the physical object toward the fly; it
  never scripts the fly's response.
- `wind` applies an actual external force to the thorax. The nested form can set
  `direction_deg`, `physical`, `sensory`, `continuous`, and `duration_ms`.
- `touch` applies a short physical force to thorax/head/abdomen or a named leg.
- `set_eye_state`/`cover_eye`/`restore_eyes` mask the rendered eye input. This is
  a **SENSORY-MODEL** intervention.
- `flash_eye` (`left`, `right`, or `both`) adds a temporary full-field brightness
  signal to telemetry only. It deliberately leaves `loom_left/right` unchanged,
  because the current lab has no full photoreceptor pathway to LC4/GF.
- `temperature` supports `environment_only`, `modeled_physiology`, and
  `flywire_sensory`. Only the last drives identified TRN groups; the scalar
  transduction remains a **SENSORY-MODEL** rather than measured physiology.
- `reset_body` resets the FlyGym body/controller pose while preserving LabWorld.

Food is a green non-colliding odor-source marker. `LabWorld.food_odor()` computes
bounded bilateral concentration from source surface distance and relative heading;
the body packet carries `odor_left`, `odor_right`, `nearest_food_distance_mm`, and
separate `heading_rad` telemetry. Swift injects the fresh odor values into the real
ORN groups. Removing the source or receiving stale body feedback clears the drive.
There is no scripted seeking, taste, reward, or feeding behavior.

Every command is acknowledged with `lab_state` (`ack`, `ok`, optional `error`)
and the bridge sends a full state heartbeat at 2 Hz. (10 Hz full-state traffic
measurably reduced the Swift/Python closed-loop rate; commands still receive an
immediate ack.) The nested state exposes
objects, active approaches, wind/touch/flash, eye state, temperature, queue
depth/drop counters, and command counters. Completion markers such as
`approach_complete`, `wind_complete`, `touch_complete`, and `flash_complete` are
sent as bounded `lab_event` packets.

## Tests

```sh
python3 flygym_bridge/test_bridge.py   # protocol + decoder + mock (no deps)
python3 flygym_bridge/test_lab.py      # lab protocol/queues/world/mock integration
./flygym-venv/bin/python flygym_bridge/test_lab_real.py  # real MuJoCo smoke
./flygym-venv/bin/python flygym_bridge/test_vision_real.py # real rendered generic loom
./ThongpariFlyNeuronSim --bridgetest   # Swift serialization/mapping/bounds
./ThongpariFlyNeuronSim --bridgeloop   # live TCP loop (needs bridge.py --mock)
```

## Launch

For normal user-facing Virtual Fly Lab work, the recommended launcher is the
repository-root **`Thongpari Fly Neuron Sim 실험실.command`**. Double-click it in Finder; it
starts the real FlyGym/MuJoCo bridge and `ThongpariFlyNeuronSim --flygym`, which opens the
Lab window automatically.

CLI equivalents / diagnostics:

```sh
./run_flygym.sh --flygym   # real body
./run_flygym.sh --mock     # mock body
```

Use `--flygym-headless` in place of `--flygym` to run the real body without a
viewer. Measured details are in `../docs/reports/PERFORMANCE_FLYGYM.md`; installed API evidence
is in `../docs/reference/FLYGYM_API_INSPECTION.md`.

Environment manifest transport: `lab_state.state.environment_capabilities` is sent
on the first state carrying a manifest on each connection, then only when its
canonical JSON content changes. Reconnect starts a fresh cache. Omission means
"retain the last validated manifest on this connection", never deletion. A
present manifest still receives strict Swift validation; malformed optional
manifests do not replace the cache. Session/epoch filtering precedes caching.
ACKs and other state fields keep their existing cadence and meaning.
