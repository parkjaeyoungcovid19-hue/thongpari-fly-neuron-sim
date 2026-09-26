# SiliconFly — agent notes

A 3D fruit fly on a transparent macOS overlay, behavior-driven by a 1 kHz
leaky-integrate-and-fire (LIF) simulation of the WHOLE FlyWire v783 connectome
(139,255 neurons, 15,091,983 signed edges, 54,492,922 synapses) running in a
Metal compute shader. The body is procedural SceneKit; the brain data is real.

## Fable 5 orchestration

**Protected section (owner, 2026-07-11): do not trim, rewrite, or remove — not even during doc-slimming passes. Only the owner edits it.**

When the main conversation runs on Fable 5, keep Fable lean and push heavy work to Opus subagents:

- **Fable orchestrates, Opus executes.** Fable reads context, writes specs, and makes small doc edits (TODO lines, README pointers) directly. Research, code, and verification go to Opus subagents. The point is keeping Fable token spend low while Opus does the verbose work.
- **One agent, one coherent deliverable, sequenced.** Dispatch subagents one at a time, each scoped from the previous agent's output. If a task would force the agent into extensive sub-planning, split it in the orchestrator instead. Don't forbid the agent from spawning its own subagents; scope tasks so it rarely needs to.
- **Spec checklist.** Every dispatch prompt is assembled against this list — none of it optional:
  1. Repo context (the agent starts with none) + the files it must read first. A map, not a library: enough that it can find prior notes/docs itself when stuck — don't inline or enumerate what it can look up.
  2. The user's hard rules restated: no unapproved installs, listener policy, no git actions, exactly which files/dirs it may create or modify — plus the dev-phase secrets posture above (dev tokens usable in-context, never written to tracked files).
  3. Exact tasks, in order.
  4. Verification requirements: verify against real sources / installed types, `node --check` or tests where applicable.
  5. Required report format: findings, files created (one-liners), exact user-facing commands, surprises/risks.
  6. Cleanup + confirm-no-strays step whenever processes are spawned.
     The full superpowers pipeline is not delegated — Fable's spec replaces the brainstorm/plan stages.
- **Reports carry evidence; Fable spot-checks.** Load-bearing claims quote their proof (test counts, `pgrep` output, exact errors) — assertions aren't enough. Fable spot-checks a claim or two before relaying; a failed spot-check goes back to the agent, not to the user. Anything an agent could NOT verify (e.g. no listener allowed) is declared explicitly, compensated statically, and handed to the next agent as a known risk — never silently claimed as verified.
- **Context hygiene: ~100k tokens per agent, soft target.** Agents delegate bulk reading and isolated verifications to their own Opus subagents and keep only the conclusions; stateful work (live debugging, process lifecycles) stays in one agent. Genuinely parallel work is dispatched by Fable as sibling agents, not nested.
- **Failures batch; design authority stays with Fable.** Every verification/live dispatch carries a standing failure clause: on a failure, capture the evidence and keep going — finish everything the failure doesn't block, and return ALL failures in one report, not one round-trip each. If a failure blocks the rest, apply the smallest provisional fix that unblocks and continue, flagging it prominently as provisional; come back early only when the fix is a genuine design decision that gates everything behind it. Fable's review gates every provisional fix afterward — batching reduces round-trips, it never transfers design authority.
- **Every flagged risk gets a disposition.** A risk or surprise in an agent's report is either fixed or explicitly accepted with the reason stated before the next dispatch — never silently ridden. If Fable can't write down why a risk is acceptable, it isn't.
- **Continue, don't re-spawn, for fixes.** Follow-ups on the same deliverable go to the original agent via its continuation handle (its context is already loaded). A fresh agent only for uncontaminated review or when the original's context is bloated.
- **Retire before degrading.** Continuation is for small fixes. When the next chunk of major work would land on an agent whose context has grown past roughly 100k (a judgment call, not a threshold), retire it instead: its last task is a handoff brief (state, decisions + why, open risks, gotchas), and a fresh agent boots from the brief + repo pointers — never from a full re-read, and never major work on a bloated context. Subagents can't be compacted; retire-and-handoff is the compaction.
- **Fable reviews the final code itself and owns the result.** Bar: as if Fable had written it — minimal, maintainable, elegant, not verbose. Issues become a bullet list handed back for one fix pass. Marked throwaway code gets a light sanity pass instead of a full review. Subagent output is Fable's output; "the agent got it wrong" is never the story.

## Files

| file | contents |
|---|---|
| `main.swift` | overlay scene, CLI dispatch, `Coordinator` (render-loop hub), `AppDelegate` (menu, timers, display switching) |
| `MotorReadout.swift` | `SignalBuilder` (rates→`BrainSignals`) |
| `SimDiagnostics.swift` | `--simtest` / `--behaviortest` / `--v4timingtest` |
| `FlyModel.swift` | procedural fly body + `Fly` behavior (states, gait, flight, ledges, sleep) |
| `Sim.swift` | `Connectome` loader (manifest-driven, validates the CSR), `Role` ids, `BrainSignals`, `SpikeBus` |
| `MetalSim.swift` | `SimParams` (every knob + the resting-drive landmark table), `MetalShared` (pipelines, CSR buffers, load-time weight transform), `MetalSim` (per-neuron state, stim, batched `step()`) |
| `LIF.metal` | the two compute kernels; its header states the per-step order and the fma caveat |
| `BrainView.swift` | brain window: 139k-soma point cloud, 378-neuron role overlay, click-to-stimulate, spike flashes |
| `Environment.swift` | permission-free senses: `WindowSense` (ledges/looms), circadian curve, user idle, thermal tempo |
| `FlyGymBridge.swift` | optional localhost NDJSON client for FlyGym: DN commands out, proprioception + stereo-vision looming back into existing gait/LC4-LPLC2 inputs |
| `Diagnostics.swift` | `--brainstats [s]`: rest-regime rates by class/role/cell type, hotspot probe, in-weight audit, `weightScale = 0` control |
| `GPUCheck.swift` | `--gpucheck`: an independent CPU reference (`RefSim`) compared to the GPU step by step |
| `etl.py` | Codex dumps + connectivity parquet → `data/connectome.json` + `neurons.bin` + `synapses.bin` |
| `tools/verify_data.py` | re-reads the binaries from the manifest alone (knows nothing of `etl.py`); non-zero exit on any failure |
| `data/` | shipped connectome, ~95 MB (CC BY-NC 4.0 — see `data/DATA_LICENSE.md`) |
| `notes/` | the port's working reports 01–09 + `docs-runs.txt`; index in `notes/README.md` |
| `reference/`, `cache/` | local-only checkouts and raw dumps, git-excluded via `.git/info/exclude` — never commit them |

## Build, run, verify

```sh
./build.sh                      # bare swiftc, -swift-version 5, no Xcode project (never xcodebuild)
./ThongpariFlyNeuronSim                    # menu-bar 🪰; quit from there
./ThongpariFlyNeuronSim --simtest          # sim invariants + throughput bench        (~10 s)
./ThongpariFlyNeuronSim --behaviortest     # 17 end-to-end sim→body checks            (~2 s)
./ThongpariFlyNeuronSim --gpucheck         # GPU vs an independent CPU reference      (~12 s)
./ThongpariFlyNeuronSim --brainstats 4     # rest-regime diagnostics over 4 s of sim  (~2 s)
./ThongpariFlyNeuronSim --snapshot f.png   # offscreen fly render
./ThongpariFlyNeuronSim --brainshot b.png  # offscreen brain render
./ThongpariFlyNeuronSim --seed 0x1234      # pin the sim seed (decimal or 0x hex) for any mode
```

Always run `--simtest`, `--behaviortest` **and** `--gpucheck` after any sim, ETL
or shader change; they are the ground truth. Key invariants:

- GF silent over 4 s of rest; GF fires ≤ 10 ms after an **abrupt** loom (3 ms on
  the shipped seed).
- Walk-drive duty 20–50 %; siesta (`activityScale` 0.84) walk-drive > 3 %.
- Air-puff GF spikes ≤ 2 over 1 s; no per-frame scale/z snap at landing.
- Realtime: 16-step batches under the 1,000 µs budget (69–78 µs on an M4 Pro).
- `--gpucheck` bit-exact: 0 of 15,091,983 quantized weights differ, and every
  scenario reports `max|Δv| 0` (gait input is the one documented ulp exception).

`--simtest`'s pass line asserts the GF silence, the loom response, a fluctuating
walk drive, the click-stim path, the siesta floor, GPU state consistency and
realtime; the loom latency and the walk duty are printed, not asserted — read them.

`--behaviortest` carries a pre-existing ~1-in-8 flake, `ledge attach + follow
window edge`. It is a `bodyCheck` with no sim in it — re-run before investigating.

**SourceKit note**: the IDE reports "Cannot find type ..." across files —
false positives. The eight .swift files compile as one module via build.sh;
trust the compiler, not single-file diagnostics.

## Threading model

- SceneKit render thread: `Coordinator.renderer(_:updateAtTime:)` steps the
  sim and updates flies. All cross-thread mutation goes through
  `Coordinator.enqueue {}` (lock + pending-actions queue, drained per frame).
- Main thread: timers (mouse 30 Hz, windows 0.7 s), menu actions, global
  click monitor — these only call enqueue/setters.
- Brain window has its own render delegate; spikes cross via `SpikeBus` (locked).
- `MetalSim.step()` is **synchronous on the render thread**: one command buffer
  per ≤64-step batch (`maxBatch`), sub-batched again at stim expiries so
  `extInput` is exact for every step, then `commit()` + `waitUntilCompleted()`.
- `MetalShared` (device, queue, pipelines, CSR buffers) is shared and immutable;
  a second sim reuses it unless the weight knobs changed.
- `MetalSim.stimulate()` is the only cross-thread method (lock + pending list
  merged at the top of `step()`).

## Neuron → behavior mapping

| role slug | FlyWire types (count) | drives | consumed in |
|---|---|---|---|
| `lc4`, `lplc2` | LC4 (104), LPLC2 (210) | looming input (per eye) → nervous darting; excite GF | `BrainSignals.nervous` |
| `gf` | DNp01 (2) | escape takeoff (spike = takeoff) | `BrainSignals.escape` |
| `dna01`, `dna02` | DNa01 (2), DNa02 (2) | steering: L−R rate → turn bias (slow-adapted, tau ~8 s) | `BrainSignals.turnBias` |
| `dnp09` | DNp09 (2) | walk/rest hysteresis + walking speed | `BrainSignals.walkDrive` |
| `dng11` | DNg11 (6) | grooming hysteresis | `BrainSignals.groomDrive` |
| `mdn` | MDN (4) | backward walking burst | `BrainSignals.backward` |
| `escw` | DNp02/DNp04/DNp11 (6) | wing-beat effort in flight, threat wing-raise | `BrainSignals.wingDrive` |
| `ascend` | 24 strongest ascending partners | body→brain gait proprioception (input target, `inputKind` 3) | `sim.gaitDrive` / `gaitPhase` |
| `sens` | 16 strongest sensory partners | wind/tap input (`inputKind` 4); electrically boosted onto GF | `sim.airPuff`, taps |
| `other` | 138,877 | the network everything above sits in; its rate is arousal | `BrainSignals.arousal` |

`SignalBuilder.make` is the whole mapping (rest values from `--brainstats`):

| signal | formula | at rest | driven |
|---|---|---|---|
| `escape` | `sim.consumeGF()` | false | true ≤3 ms after an abrupt loom |
| `nervous` | `clamp(rateLoom / 115, 0, 1)` | 0 (LC 0.0 Hz) | 1.0 at LC 172 Hz; 0.27 on a gentle loom |
| `turnBias` | `clamp((diff − dnaBaseline) × 0.04, ±1)` | wander | −0.26…−1.0 rad/s on a left loom |
| `backward` | `rateMDN > 60` | false (MDN 18.8 Hz, p95 31) | true on MDN stim (~200 Hz) |
| `walkDrive` | `clamp((rateFwd − 10) / 33, 0, 1.3)` — **rectified-linear** | 0.12 (DNp09 p50 14 Hz) | 1.3 on stim |
| `groomDrive` | `clamp(rateGroom / 5, 0, 1.5)` | 0.09–0.43 by seed | 1.5 on DNg11 stim |
| `wingDrive` | `clamp(rateEscW / 10, 0, 1.3)` | 0.00 | 1.3 under escape |
| `arousal` | `clamp(ratePop / 10, 0, 1)` | 0.175 (1.75 Hz/neuron) | 0.55 inside an arousal burst |

`walkDrive` is rectified-linear because DNp09 does not rest near zero: a bare
divisor put FlyModel's whole 0.08…0.22 hysteresis band below the resting swing
and measured **duty 100 %**. `--simtest`'s duty probes call the same static
`SignalBuilder.walkDrive`/`groomDrive`, so the mapping can only be changed in one
place. Only fly #1 has the brain; extra flies use the legacy distance-based
behavior (`signals: nil` path).

## Adding a new neuron population (recipe)

1. **Check the type exists** in v783:
   `gzcat cache/flywire783/consolidated_cell_types.csv.gz | grep -c ',TYPE,'`
   (raw dumps: see README "Regenerating the data"; never commit them).
2. **`etl.py`**: add `"TYPE": "roleslug"` to `CORE_TYPES`, append the slug to
   `ROLES` (order is a contract — `Role.names` in `Sim.swift` is asserted equal
   to `stringTables.roles` at load), and to `COMMAND_ROLES` if it is a command DN
   so the in-degree report covers it.
3. **Rerun the ETL + `tools/verify_data.py`** and read `in-degree onto each
   command population`. Below a few hundred synapses the population will be
   noise-driven rather than network-driven — that bug shipped once for DNg11
   (6 synapses in the old 668-neuron subset; it gets 3,535 from the full graph).
4. **`Sim.swift`**: add the id to `Role` and bump `Role.count` / `Role.names`.
5. **`MetalSim.swift`**: a `private(set) var xyz: [Int]` group, a `Group` id
   (histogram slot, ids 1–15), `inputKind` if it takes external drive, membership
   in `init`'s role switch, resting drive in `applySeed` (command DNs use
   `baselineCommand` 0.022 — deliberately below the one-kick line; DNp09 has its
   own `baselineFwd` 0.032; never randomize per side for a bilateral pair,
   asymmetry must come from wiring), plus an `nXyz` EMA denominator and a
   `rateXyz` fold in `runBatch`.
6. **`SignalBuilder`** (MotorReadout.swift): normalize `rateXyz` into a new
   `BrainSignals` field — **always clamp** (an unclamped walkDrive once sent the
   fly to 1,100 pt/s). Read the resting distribution out of `--brainstats` first:
   the mapping has to straddle it, not sit under it.
7. **`FlyModel.brainBehavior`**: consume the signal. Hysteresis + the `stateAge`
   dwell guard (≥0.4 s) for state changes, cooldown timers for one-shot actions;
   make sure the action works from every grounded state (MDN was once dead from
   idle).
8. **`BrainView.swift`**: role color in the overlay + a `regionName` label
   (clicking that region should demo the behavior).
9. **Tests**: `tools/verify_data.py` checks the role counts against the manifest;
   add a `--behaviortest` scenario (stimulate → assert body reaction) and, if
   sim-level, a `--simtest` probe. Re-run `--gpucheck` too if the weight
   transform or the step semantics changed.

## Tuning gotchas (learned the hard way)

- **The operating point is a table, not a number.** `v_rest = baseline × 20.49`
  plus the noise offset (`pNoise × noiseKick × 20.49` = 0.026 at shipped values)
  against threshold 1. At `noiseKick` 0.25 the landmarks are: **0.0354** one kick
  fires it · **0.0424** still one-kick after the siesta's ×0.84 · **0.0475**
  self-fires on the mean noise drive · **0.0488** self-fires with no noise at all.
  Baselines live per super class in `SimParams.baselineByClass`; every range
  straddles 0.0354 (below it the wiring decides the spike) and every top clears
  0.0424 (so the class survives the siesta).
- **Noise granularity, not weight scale, decides whether the wiring matters.**
  `pNoise × noiseKick` is the mean drive; `noiseKick` is the event size. At kick
  0.42 one noise event was ~17× a synaptic one and the network contribution was
  **1.01×** — the connectome was inert. At 0.25 with the same mean drive it is
  **1.31×**. Smaller kicks kill the siesta: `(kick − 0.144)/kick` of the firing
  population survives `activityScale` 0.84 (42 % at 0.25, 4 % at 0.15). Never move
  it without re-running the siesta probe on ≥3 seeds.
- **Never scale baselines linearly** by a mood/time factor — compress toward 1
  (`1 − (1−a) × 0.35`), or populations go silent (the "siesta coma" bug). Same
  failure mode as the kick rule, one level up.
- **`weightScale` 0.0032 has ~4 % of headroom.** 0.0048 refuses to build:
  `MetalShared.init` throws `fixed-point overflow: max|w| 11.5440 x scale 65536 x
  4096 exceeds Int32`. Going higher means revisiting the 4096 accumulation
  headroom — a shader-adjacent change, not a knob.
- **The GF has three independent input gains**, all stated *relative* to
  `weightScale`: `gapJunctionBoost` 0.5 (LC4/LPLC2→GF), `sensGFBoost` 1.5
  (wind/tap→GF), `gfInputScale` 0.12 (its ~3,800 ordinary chemical synapses per
  cell). Without the third, the GF's in-degree makes it fire spontaneously long
  before the rest of the brain is network-driven, and no `baselineGF` fixes it
  (hyperpolarized onto the −2 floor it still fires ~5 Hz). Changing `weightScale`
  means re-deriving all three.
- **Escape is a race**: one synchronous LC onset volley (+1.78 threshold units on
  the electrical path, `--brainstats` in-weight audit) against 4 ms-delayed
  feedforward inhibition. Slow ramps lose to inhibition **by design** — test
  escapes with **abrupt** loom steps, never ramps. The ≤10 ms invariant is what
  pins `loomGain` (0.32).
- **Audit the data before tuning against it.** 94 `nt_type`-less antennal-lobe
  local interneurons were fallback-signed excitatory, formed a mutual-excitation
  loop pinned at the refractory ceiling, and secretly carried the entire measured
  "network contribution"; `etl.py` now forces `^(lLN|il3LN|v2LN)` inhibitory and
  the whole operating point had to be re-derived (`notes/05` → `notes/06`).
- **`--brainstats` is the tuning instrument**, not `--simtest`'s pass line: it
  prints the population rate, the silent/<1/1–5/5–20/>20 Hz histogram, per-class
  and per-role rates, the hottest cell type with its neurotransmitter provenance,
  the in-weight audit, and the same run with `weightScale = 0` beside it.
- **Seeds**: `--seed N` pins the whole process. Diagnostics use `0x5EED1F1F`; the
  live app draws a fresh one per launch. Tightest margins today: walk duty 40 %
  against the 50 % ceiling, air-puff GF 1 against ≤2, groom duty 8–41 % across
  seeds, and the siesta's *direction* is seed-dependent (the invariant holds, the
  intent is carried by FlyModel's `tempo`).
- **Live modifiers must never weaken takeoff**: flight effort =
  `max(baseEffort, live formula)` (a regression once halved escape altitude).
- **Landing must go through the flare** (alt decays below 0.035) — never snap
  scale/z in `land()`.

## Repo conventions

- Public repo: `dawsonamf/siliconfly` (master). Upstream, which this began as a
  port of, is `DenisSergeevitch/desktop-fly`. Code MIT (both copyright lines
  stay in `LICENSE`); `data/` is CC BY-NC 4.0 (FlyWire terms) — keep the
  license split intact.
- `data/` is three files, ~95 MB: `connectome.json` (122 kB manifest — the
  loader's contract), `neurons.bin` (4.2 MB), `synapses.bin` (90.6 MB). Locate
  every array through the manifest; never hardcode a byte offset.
- README numeric claims (neuron/edge/synapse counts, rates, latencies, µs/step)
  must match `data/connectome.json` and the suite's own output — reviewers
  falsify them against the data. `notes/docs-runs.txt` is the capture the current
  README numbers came from.
- `notes/` holds the port's working reports (01 recon → 09 docs) and the brain
  screenshots; `notes/README.md` indexes them. They are working notes, not docs.
- `.gitignore` covers the binary, logs, and root-level PNGs (diagnostics
  outputs); intentional images live in `assets/`. `reference/` and `cache/` are
  excluded through `.git/info/exclude` and stay local.
