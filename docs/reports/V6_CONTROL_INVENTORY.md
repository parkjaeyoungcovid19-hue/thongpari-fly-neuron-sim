# V6.1 current control inventory

Source inventory and read-only capability manifest, observed 2026-10-05. This is **not** V5 GUI/live-performance acceptance, scene persistence, or full V6 completion. The user-deferred V5 acceptance remains incomplete. V6.2 later added a separate strict `edit_property` path over these descriptors ([V6.2 evidence](../../notes/validation/v6-2-2026-10-05/README.md)); the legacy commands below keep their clamping unchanged.

## Contract and ownership

The existing nested `state.environment_capabilities` adds an optional ordered `{schema_version:1, descriptors:[...]}` manifest. Nominal unbound export has 39 properties. It carries backend nominal request defaults/constraints, **not** current applied values, editor authorization, or a new command/ACK path. Existing owner-thread mutations and legacy coercion/clamping remain unchanged. Existing state retains applied wind/eyes/temperature/object values; physical effects require `physical_backend=true` and resolved body targets. The manifest itself never injects neural currents.

Implementation: [registry/strict decoder](../../flygym_bridge/environment_properties.py), [additive state export](../../flygym_bridge/lab_world.py#L2041-L2082), [existing LabState serializer](../../flygym_bridge/protocol.py#L1290-L1333). All descriptor keys are required, including null/empty values. Unknown fields are ignored, while malformed known type/unit/bounds/default/enum/identity/version rejects the entire standalone decode. Optional consumers may discard a malformed manifest without discarding the enclosing state. Type names: number/vector/boolean/enum. Scene candidates describe **future** persistence policy; no save/load is implemented here.

Supported effects are PHYSICAL, SENSORY-MODEL, VISUAL (conditional by shape/mode/binding). DIRECT-NEURAL is allowed by schema but no current environment descriptor advertises it. Global scope changes singleton environment/senses; local scope refers to selected objects or transient targeted actions. All rows are live unless explicitly spawn-only. Persistence candidates exclude active timers/execution/feeding progression.

## Editable object/source configuration

Evidence: [geometry/defaults](../../flygym_bridge/lab_world.py#L642-L735), [legacy dispatch](../../flygym_bridge/lab_world.py#L1285-L1328), [Swift forms](../../LabWindow.swift#L1769-L1785).

| IDs / parameter | Type, request domain, nominal default | Existing commands / field | UI exposure and scope | Effects / persistence |
|---|---|---|---|---|
| object.shape | enum box/sphere/wall/food/car/trap; default box | spawn_object / shape | shape selector; local; **spawn-only**, existing shape immutable | shape-conditional PHYSICAL/VISUAL/SENSORY-MODEL; scene candidate |
| object.{box,sphere,wall,food,car,trap}.position_mm | float3 world XYZ mm, each −1000..1000; box/sphere [40,0,5], wall [40,0,7.5], food [20,0,1.5]; car [40,0,.205L], trap [40,0,.3L+4] are context-default null in manifest | spawn_object + shape aliases; food also spawn_food/spawn_food_marker; move_object / position_mm | XYZ editor, no UI upper/lower clamp; toy UI computes Z instead of honoring entered Z; local | VISUAL + PHYSICAL for collidable shapes; food VISUAL/SENSORY-MODEL; scene candidate |
| object.box.size_mm | full-extents float3 mm, each .2..200; [10,10,10] | spawn_object/spawn_box/resize_object / size_mm | UI scalar equal3, default5; anisotropy backend-only; local | PHYSICAL/VISUAL; scene candidate |
| object.wall.size_mm | full-extents float3 mm, each .2..200; [2,30,15] | spawn_object/spawn_wall/resize_object / size_mm | UI scalar equal3, default20; local | PHYSICAL/VISUAL; scene candidate |
| object.sphere.size_mm | scalar diameter .2..100mm; absent5 (invalid supplied numeric fallback3); applied equal3 | spawn_object/spawn_sphere/resize_object / size_mm | UI scalar5; local | PHYSICAL/VISUAL; scene candidate |
| object.food.size_mm | scalar diameter .2..100mm; 3; applied equal3 | spawn_object/spawn_food/spawn_food_marker/resize_object / size_mm | scalar3; local | VISUAL + modeled odor/contact geometry; scene candidate for authored size, not feeding progress |
| object.car.size_mm | scalar length4..60mm;14; applied [L,.44L,.41L] | spawn_object/resize_object / size_mm | scalar; spawn validates toys more strictly than legacy resize; local | PHYSICAL/VISUAL; scene candidate |
| object.trap.size_mm | scalar side8..60mm;20; applied [L,L,.6L] | spawn_object/resize_object / size_mm | scalar; local | PHYSICAL/VISUAL; scene candidate, not trap task/state |
| object.yaw_deg | scalar request −36000..36000deg;0; **clamp then modulo360**, applied [0,360) | spawn_object/primitive/food aliases + move_object / yaw_deg | Swift command/form lacks yaw; local | shape-conditional PHYSICAL/VISUAL; scene candidate |
| object.food.variant | enum apple/banana/cheese/grapes/cookie/sugar_cube; context-default null = deterministic rotation in that order | **spawn_food/spawn_food_marker only** / variant | no selector/Swift field; local; **spawn-only** | VISUAL/SENSORY-MODEL; scene candidate |

Primitive UI size minimum .1 differs from backend .2, and UI has no general maximum clamp. Position defaults are operation defaults, not UI form values (initial form [60,0,5]). Moving preserves omitted pose, resizing never adjusts floor/Z. Toy supplied spawn coordinates are strict finite/nonboolean triples; legacy primitives clamp/coerce. Generic spawn_object accepts food geometry but does **not forward variant**. Identity is unique nonempty text ≤64 or generated shape_counter; no rename/shape setter. ID is excluded from numeric/sensory environment descriptors.

Food variant sugar is derived [.55,.65,.05,.7,.8,1], not editable. Odor is exp(−surface-distance/30mm), bilateral bearing weighted, saturating union0..1; no wind plume/advection. Food palette is noncollidable. Separate mouth contact model shrinks diameter1.2mm/s and depletes below .4mm, produces modeled sugar-contact signal, not biological reward or scripted seeking. Odor sampler's taste_modeled/feeding_modeled=false describes that sampler and is ambiguous when read as a whole-world claim; separate feeding integration is present. Evidence: [variant metadata](../../flygym_bridge/sandbox_models.py#L431-L444), [feeding](../../flygym_bridge/lab_world.py#L1789-L1850), [odor sampler](../../flygym_bridge/lab_world.py#L1852-L1903).

## Singleton environment and sensory settings

Evidence: [backend setters](../../flygym_bridge/lab_world.py#L1144-L1237), [Swift UI requests](../../LabWindow.swift#L2112-L2183), [modeled transduction](../../SensoryModel.swift#L29-L89), [local temperature authority](../../main.swift#L724-L738).

| IDs / parameter | Domain / nominal default | Existing commands / field | UI / scope | Effects / persistence |
|---|---|---|---|---|
| temperature.celsius | scalar0..50°C;25 | temperature/set_temperature / celsius | UI and coordinator **10..40°C**; global | mode conditional SENSORY-MODEL; scene candidate |
| temperature.mode | environment_only (default), modeled_physiology, flywire_sensory | temperature/set_temperature / mode | three-way selector; global | see below; scene candidate |
| wind.strength | scalar0..1 dimensionless;0 (not m/s) | wind/wind_puff / strength; stop_wind action | UI form .7; global | independently gated PHYSICAL/SENSORY-MODEL; scene candidate **only continuous configuration** |
| wind.direction_deg | scalar REQUEST±36000deg;0; clamp then modulo360 APPLIED[0,360) | wind/wind_puff / direction_deg | form0; UI truncating remainder may be negative; global | same; continuous-config candidate |
| wind.continuous | bool, context-default null: wind infers absent duration, wind_puff false; applied true only strength>0; initial false | wind/wind_puff / continuous | toggle initial false; global | same; continuous-config candidate |
| wind.duration_ms | scalar1..10000ms;500 for finite puff; absent wind implies continuous | wind/wind_puff / duration_ms | UI helper permits60000ms; global | same; **transient**, not authored duration persistence |
| wind.physical / wind.sensory | booleans true/true; applied state fields physical_enabled/sensory_enabled | wind/wind_puff / physical,sensory | independent toggles; global | PHYSICAL / SENSORY-MODEL separately; continuous-config candidates |
| eyes.left_enabled / right_enabled | bool true/true | set_eye_state/eye_state / side_enabled | hidden from Swift command/form; global | SENSORY-MODEL; scene candidate |
| eyes.left_mask / right_mask | scalar0..1;0/0 | set_eye_state/eye_state / side_mask; cover_eye/restore_eyes actions | UI cover/restore0/1 only; fractional masks backend-only; global | SENSORY-MODEL; scene candidate |

Temperature environment_only records only; modeled_physiology sends controller tempo through Swift BrainPacket (1+.03*(T−25), Swift T10..40 → .55..1.45; no TRN current); flywire_sensory uses modeled warm TRN_VP2/cool TRN_VP3a+VP3b current, neutral25°C, deviation saturates at10°C, gain.060. Backend mode-derived neural_connected is intent, not proof of actual Swift target availability. Current Swift activates temperature **locally before backend ACK**, consumes local scalar, and does not reconcile backend nested temperature. This authority mismatch is documented, not silently changed by V6.1.

Wind is an engineering force, thorax mass*10000mm/s²*strength along [cosθ,sinθ,0], plus body-relative JO-C/E modeled sensory drive if sensory enabled. stop_wind zeros strength/timer/continuous but retains direction/options. Active remaining_ms is simulation time, **not** saved request duration. Eyes disabled or mask1 black actual vision frames; partial mask scales by1-mask. Observer lighting is separate from fly-eye frames.

## Transient action parameters (not scene settings)

All are local, live, persistence=transient. Their descriptors document existing command parameters only; they do not create new actions.

| IDs | Domain / default | Command / fields | UI exposure / effects |
|---|---|---|---|
| touch.target | enum nominal nine body parts + lf/lm/lh/rf/rm/rh aliases; default thorax | touch / target | UI nine choices; bound manifest selects resolved force targets, unbound nominal notes explicit. PHYSICAL + generic SENSORY-MODEL |
| touch.strength | scalar0..1;.5 | touch / strength | UI .55; force always physical (no physical:false switch), mass*16000mm/s²*strength; optional sensory |
| touch.duration_ms | scalar1..1000ms;20 | touch / duration_ms | UI150ms, helper allows60000; simulation timer |
| touch.direction_world | applied unit float3 component bounds±1;[0,1,0] | touch / direction_world | hidden; legacy arbitrary request normalizes, invalid/zero fallback; component range is **not** strict mutation request validation; PHYSICAL |
| touch.sensory | bool true | touch / sensory | hidden; generic touch channel, not selected-part neural wiring; SENSORY-MODEL |
| flash.eye / intensity / duration_ms | left/right/both(defaultboth); scalar0..1(default1); scalar1..5000ms(default100) | flash_eye / eye,intensity,duration_ms | eye selector/pulse UI; helper max60000; SENSORY-MODEL **brightness telemetry only**, no real illumination/photoreceptor neural connection; looming unchanged; intensity0 ends |
| approach.speed_mm_s / end_distance_mm | scalar.1..2000mm/s(default80); scalar.5..500mm(default8) | approach_object/approach / speed_mm_s,end_distance_mm | UI speed12/end8; snapshots flyXY and moves **object**, not fly; shape-conditional PHYSICAL/VISUAL |
| drive.speed_mm_s / distance_mm | strict scalar **0 < value ≤60mm/s**(20); **0 < value ≤300mm**(80) | drive_object / speed_mm_s,distance_mm | car-only, held car rejects; PHYSICAL/VISUAL. Manifest numeric min0 needs notes for exclusive lower bound; descriptor decode is not an edit validator |

Resolved target evidence: [body-part mapping including aliases](../../flygym_bridge/fly_body.py#L588-L613). Empty resolved target set omits touch.target rather than fabricating a nonempty supported enum. Other pulse metadata remains descriptive, not authorization.

## Excluded read-only, unsupported, and discrete state

- Compiled slot capacities are **box64/sphere64/wall64/food8/car4/trap2** by default; constructor overrides each0..256 before compilation. Actual instance capacities/free slots are existing telemetry, not live edits. Evidence: [capacity allocation](../../flygym_bridge/lab_world.py#L72-L85), [constructor](../../flygym_bridge/lab_world.py#L266-L279).
- No runtime lighting, humidity, light density, terrain/grass/ground dimensions, object material/color, tilt, odor intensity/decay, sugar/reward, fly morphology, or topology setters. Ground styling is fixed visual lawn while collision plane remains infinite; observer lights directional900/ambient450 are static. Evidence: [arena styling](../../flygym_bridge/sandbox_models.py#L254-L273), [observer lights](../../WorldViewer.swift#L303-L316).
- Discrete lifecycle/state-machine actions excluded from property descriptors: spawn/delete/remove/reset_world, restore_eyes/cover_eye, stop_wind, arm_trap (plus physical trap release/falling/closure), reset_body, interaction/pick/carry/release, participant activation/input, equip_gun/fire_bb. Their configuration-bearing spawn/pose/sensory parameters are inventoried above; live execution is not durable scene intent.
- Exclude player pose/input, gun equipped state, projectiles/BB pool/tasks/timers, approaches/drives, feeding accumulation/depletion, trap dropping state, simulation/session/epoch/ticks/revisions, events, slot IDs, neural probes/checkpoints. BB speed2000mm/s/range150mm/lifetime2s/pool8/fire interval.15s are fixed engineering constants, not editable environment descriptors. Evidence: [toy/interaction command paths](../../flygym_bridge/lab_world.py#L1240-L1284), [participant and reset commands](../../flygym_bridge/fly_body.py#L707-L723).

## Verification and cost

[Focused tests](../../flygym_bridge/test_environment_properties.py) cover strict descriptor contracts, fixture parity, isolated exports, bounded cache, changed resolved target sets, existing NDJSON, observational state invariants (objects/revisions/stimuli/events unchanged), and assertions against actual defaults/clamps/normalization/strict toy behavior. [Shared fixtures](../../fixtures/environment_capabilities/valid.json) are exact nominal unbound state; [boundary fixture](../../fixtures/environment_capabilities/valid-boundaries.json) exercises Unicode scalar lengths and structural limits. Invalid fixtures cover missing field, inverted range, unknown unit/type/version, duplicate ID, wrong vector, bad default, and blank contextual notes. Unicode parity fixtures pin code-point identity on both sides: `valid-unicode-identity` (IDs `é` vs `é`, a U+200B-prefixed label) must be accepted, `bad-unicode-choice` (enum default canonically but not code-point equal to a choice) and `bad-control-whitespace` (label ending in U+001F, which Python `strip()` removes) must be rejected. Swift compares unicode scalars and uses exactly Python's `strip()` whitespace set (checked over every scalar).

Validated registry/cache templates are private; a bounded32-entry canonical-target LRU validates only registry/cache misses, and every caller receives an isolated copy. Because every validated field is a scalar or a flat list of scalars, the export copies lists instead of calling generic `deepcopy`: unbound `LabWorld.state()` p50 **462 → 55 µs**, state+NDJSON **641 → 231 µs** (local 500-iteration microbench, identical output). The nominal manifest is ~21 KB of each lab_state (sent at 2 Hz plus one per command ACK); 128 cached command results hold ~3.9 MB of manifest copies. Swift standalone decode of the pretty-printed fixture is ~0.85 ms p50. These are **not** live acceptance or performance thresholds. Constants are deliberately not refactored: source/descriptor drift remains a maintenance risk, mitigated by focused actual-function assertions rather than new mutation authority.

**Transport bound:** a supported configured pool (256 slots per shape, 1536 objects, 64-char IDs) encodes to 516,714 B without the manifest and 538,225 B with it, which the old 512 KiB Swift line cap would drop whole (state, ACK and telemetry). The Swift cap is now 1 MiB. [Fixture generator](../../notes/validation/v6-1-2026-10-05/make_large_state_fixture.py) → [fixture](../../fixtures/bridge/v6-large-state.ndjson); `--bridgetest` feeds it through the real fragmented receive path, and a Python test keeps the same pool under 1 MiB. No installs, git mutations, listeners, GUI, real FlyGym simulation, Metal tests, or persistent processes were used.

Lightweight commands (repository root):

``sh
PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_environment_properties.py
PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_feeding_events.py
PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_lab.py
``
