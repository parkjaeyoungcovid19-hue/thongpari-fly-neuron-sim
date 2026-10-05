# V6.3 world object editor verification

## Scope and ownership

Backend-owned applied geometry/revisions. Move (XYZ), Z yaw, size, duplicate, delete; keyboard/numeric equivalents. Edit toolbar is reachable; leaving Participate requests confirmed participant removal before entering Edit. No optimistic owner geometry, no undo. No sim/shader/data changes. No listeners, installs, git actions, live desktop actions, or shared-process kills.

## Contracts

- Strict session/generation/epoch/requested-tick envelope, matching ACK/result/boundary/revision and bounded actual-value validation. New commands carry the displayed/captured identity, not a recaptured session.
- Optional manifest object_operations advertises duplicate/delete; omission preserves older manifest normalization. Validation rejects unknown, non-string, duplicate operations.
- Duplicate uses backend pool allocation and exact authored shape/size/pose/yaw/food variant, fresh dynamic activity; delete deactivates all palette rendering/collision and clears bookkeeping.
- Clean/unfocused numeric geometry tracks each owner poll including unchanged authored revision with dynamic pose. Beginning field editing freezes geometry+revision. Dirty/focused polling never rebases; authored revision, identity, selection, mode, availability, tool switch, Escape invalidate draft including the active shared NSTextView.
- Selection completion is limited to original target, original selection serial, Edit mode, and the current live selection; delete survives snapshot-before-ACK; duplicate survives ACK-before-snapshot briefly.
- Parse errors name X/Y/Z/S/yaw; descriptor errors name property. Unsupported capabilities, held target, stale/unavailable workspace, Observe/Participate disable editing.

## Collected evidence

- bash-105: existing Python environment descriptor/edit suites, 32 tests, exit 0.
- bash-104: initial compiled --worldeditortest, 26 focused ACK/projection/numeric/draft assertions, 0 failures, exit 0 (before expanded real field-editor fixture).
- bash-113: flygym-venv real RealFlyBody + MuJoCo fixture, 1 test with six shape subtests, exit 0, 4.016 s. Actual mj_geomDistance overlapping yaw0 box/probe <0; authoritative 450° input normalizes to90° and distance >3; moving probe to rotated long axis restores <0. Owner position/size/mocap quaternion verified. Exact duplicate pose/size/yaw verified for box/wall/sphere/food/car/trap; all palette alpha, contype and conaffinity become0 on deletion; slots returned; modeled odor falls after food source removal.

## Limitations

Overlay projects the latest owner snapshot over the JPEG: no frame stamps/depth occlusion; delayed images can briefly lag owner overlay. Local handle drafts are previews only; pending/error text is the authoritative status. Parent owns fresh live GUI acceptance.

## Final build and required sequential gates

- `./build.sh`: bash-112, exit0. Original bare-swiftc verification binary. Subsequently reviewer found and required the minimal explicit-schedule precedence repair below; original logs retained.
- `./ThongpariFlyNeuronSim --worldeditortest && ./ThongpariFlyNeuronSim --labtest`: bash-115 and captured repeat, exit0; 38 V6.3 assertions plus168 lab assertions (206 total),0 failures. [Full output](<swift-tests.txt>). Genuine offscreen in-process NSWindow shared NSTextView exercised revision7→8+Return, dirty source freeze, Escape→Return, dynamic clean source, delete/duplicate ordering and newer selection race.
- `./ThongpariFlyNeuronSim --simtest`: bash-117 first stage exit0; 16-step batches102 µs/step (1000 budget), one-step batches306 µs/step; taste readout dynamics bit-identical. [Output](<simtest.txt>).
- `./ThongpariFlyNeuronSim --behaviortest`: initial16/17 PASS, exit1: thermal-tempo speed cool46→hot53 pt/s. Preserved [initial output](<behaviortest.txt>). Required isolated rerun17/17 PASS exit0, thermal cool46→hot70. [Rerun](<behaviortest-retry.txt>). No production changes between runs. Cause unproven; this thermal check is NOT the documented ledge-attach flake. Residual nondeterminism risk explicitly retained; parent accepts the scope-limited discrepancy with both logs rather than unrelated sim/body tuning.
- `./ThongpariFlyNeuronSim --gpucheck`: final stage exit0, GPUCHECK PASS; all15,091,983 quantized weights identical. Independent reference arithmetic-selected fma-leak calibration, all final cases pass. Calibration intentionally reports rejected nonmatching arithmetic candidates as FAIL; those are not final gate failures. [Output](<gpucheck.txt>).
- `PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_world_editor.py && ...test_lab.py && ...test_v4.py`: bash-114, exit0, all3 scripts.

### Earlier iteration failures (resolved before final build)

- bash-102: descriptor/fixture operations preservation mismatch, fixed optional validator key; bash-10532 tests pass.
- bash-103/106/108/110/111 real fixture API/schema mistakes: nonexistent edit_property/set_pose, missing unit, non-shape position property ID, nonexistent odor_sources state key. Corrected fixture to actual apply_edit descriptor contract + modeled food_odor; bash-113 passes.
- bash-107: diagnostics accessed private duplicate/delete buttons, fixed to discover actual child buttons by selector.
- bash-109: diagnostic source changed mid-build, no output accepted; final immutable-source bash-112 succeeds.

## Remaining baseline regressions (bash-118, serial, all exit0)

| Command | Result | Log |
|---|---:|---|
| `PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_v5_6_2.py` | 37 PASS,0FAIL; real included | [Model log](<model-tests.txt>) |
| `PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_v5_6_2_tools.py` | 50 PASS,0FAIL; median idle ratio0.9589 | [Tools log](<model-tools-tests.txt>) |
| `PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_v5.py` | 31 PASS,0FAIL | [Render/snapshot log](<render-tests.txt>) |
| `PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python -m unittest discover -s flygym_bridge -p "test_environment*.py"` | 32tests,OK,0.173s | [Property log](<property-tests.txt>) |

## Final reviewer schedule-boundary repair

Reviewer found `sendCommand` preferred a newly derived coordinator schedule over the explicitly captured editor boundary. Minimal repair: production `LabCommandSchedule.choose(explicit:fallback:)` preserves the supplied envelope and lazily avoids fallback derivation; editor dispatch immediately checks chosen sessionID/epoch against captured identity before send. If reset races afterward, packet retains old epoch for owner rejection rather than silently retagging the draft. Regression uses the same production chooser with a simulated new epoch; normal unsupplied commands still derive a current schedule. No sim/body/shader edits.

- `./build.sh`: final bash-120 exit0. [Build output](<build-schedule-fix.txt>). Original build/performance logs retained.
- `./ThongpariFlyNeuronSim --worldeditortest`: final bash-12140 PASS,0FAIL. [Final editor output](<world-editor-final.txt>).
- `./ThongpariFlyNeuronSim --labtest`: final168 PASS,0FAIL. [Final lab output](<lab-final.txt>).
- `./ThongpariFlyNeuronSim --v4test`: final18 PASS,0FAIL. [V4 session output](<v4-final.txt>).
- `./ThongpariFlyNeuronSim --bridgetest`: final97 PASS,0FAIL. [Bridge output](<bridge-final.txt>).
- `PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python -m unittest discover -s flygym_bridge -p "test_world_editor.py"`: final4 tests,OK,0.011s. [Strict backend editor output](<editor-python-final.txt>).

Final collection: all relevant jobs completed, no running/stopping harness jobs. Explicit GPU-IDLE notice sent parent before live GUI handoff. Parent owns actual toolbar/handle dispatch acceptance; hidden fixtures are not claimed as live GUI evidence. No orphan tests/listeners or shared-process kills.

