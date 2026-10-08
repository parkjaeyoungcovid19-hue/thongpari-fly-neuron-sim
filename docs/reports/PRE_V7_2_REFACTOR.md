# SiliconFly pre-V7.2 refactor final report

Branch: `refactor/pre-v7.2`, baseline `973945a`. P0–P4 are inherited commits; this continuation changed only P5. P0–P2 measurements below come from RESUME.md and retained phase evidence, not rerunning those phases. P3/P4 evidence also remains retained. No push, history rewrite, other-branch mutation, install, subagent, GUI launch, real-body test, loop/listener mode, snapshot command, launcher, or package signing was performed.

## Per-phase disposition

| Phase | Commit | Implemented |
|---|---|---|
| P0 | cb8c0d0 | Bulk evidence untracked and kept on disk; PNG paths preserved and downscaled; mutation-table environment fixtures in both consumers; generated large bridge state; environment-edit README count fixed. |
| P1 | df7c10c | WMO/dead stripping, dev diagnostics gate, separate stripped release compile in packaging, moved test functions, unused Swift/Python paths removed, legacy bare lab_ack decoder removed, simplified ArenaConfig. |
| P2 | e25a711 | Deterministic timer lifecycle, cached language, CSV formatting on writer queue, guarded label writes, batched/fixed-order sensory input, prebuilt sugar/MN9 GPU group buffers, linear inbound framing, encoder/input caching, connection manifest caching, single snapshot validation, cached timestep/lazy trap position, graph cleanup and view-stream geom lookup caching. |
| P3 | 4447162 | Independent brain spike consumers and scheduled stimuli; CSV column/value table including sugar GRN/MN9; event/session and ACK/generation boundaries; timeout, constraints, aim fallback and pending timeline fixes; interactive session locks; common schedule/neural recording; deterministic exception containment; input cap; log handle cleanup; CLI usage guard; fixture FAIL and actual outgoing card-click instrumentation. |
| P4 | 65361ec | Population metadata/resolution table, bit-preserving GroupSpec/rates table and reset, Lab telemetry moved out of protocol, BrainPick and stimulation separated, ACK/event dropped counters. No V7.2 observation primitive. |
| P5 | c70ab04 (plus final process-audit documentation commit) | Main/Coordinator/AppDelegate/CLI/overlay/snapshot/menu splits; Lab arena/pages/actions/toolbar/participant state/status text splits; shared session/reset/getter/parser/wire helpers; WorldEdits co-location and boundary/timeout/rejection helpers; localization folded into chrome; typed environment property moved to Bridge; node/vector/orbit helpers; diagnostic Suite/makeDiagSim; Python V4/bridge/body helpers, tool/carry/type splits and command dispatch; separated unittest unit/real/perf trees and test support; single fast unit runner; docs updated. |

### Skips, partial items and retained semantics

- P0: optional consolidation of 40 environment-edit fixtures was not done; independent tiny cases were retained rather than introducing another fixture schema.
- P1: `actor_id` fallback was retained because Python PlayerBody actually emits it. `gaitPhasePublic` remains read by production gait feedback, so it is not dead. The optional MetalSim debug hooks remain gated for diagnostics. `LabInteractionPresentation.canSend` remains diagnostic coverage while production uses explicit gates; its deletion/use was not completed in the inherited phase. Legacy brainless flies, presets and the independent GPU oracle were retained as required.
- P2 inherited omissions: lazy 10 Hz telemetry creation, restricting signal/metrics/toy text work to the selected section, moving ambient queries to the 0.7 s timer, off-main window enumeration and reusable MuJoCo pixel buffers remain unimplemented. Paused graph samples still append. The saved handoff does not establish a risk/design disposition for these omissions; this continuation honored the instruction not to redo P0–P4. Refresh passes a captured session to the view/workspace rendering paths, but a blanket single-snapshot cleanup was not completed. Folded wing nodes/flash actions and covered SceneKit rendering are cached/paused in the final tree. Overlay FPS, MSAA and shadow quality are unchanged.
- P3: untagged deterministic body input was a real boundary risk; it is rejected in deterministic mode, with matching experiment-step-result body as the authoritative input. Real clicks, language/restart/thread interleavings and offscreen commands could not be executed under the user's restrictions; feasible in-process regression coverage passed. No P3 bug was deliberately left unfixed.
- P4: no required structural item deferred. GPU oracle remains independent and EMA expression is exactly `r += (Float(count) * 1000 / n - r) * a`.
- P5.1: participant state is owned by a real `LabParticipantController`; window extensions still adapt AppKit callbacks and use forwarding properties. Status extraction covers signal-path and remote-state pure text; backend/service/command status assembly remains in refresh because live service/bridge observations must be captured together before a larger pure input structure is designed. The complete requested pure-text extraction is deferred.
- P5.3: neural reset, sensory readout zeroing and nine session-control envelopes share helpers. Modeled reset paths retain their distinct scope/seed/pause actions; wholesale merging needs an explicit transaction policy to avoid changing reset order.
- P5.4: send builds LabCommand and one schedule rule; preset/marker selectors, key popups and graph inventory are unified. Two UI recording variables travel in one presentation value. Full merging of writer lifecycle, asynchronous stop outcome and UI recording enums is deferred: they express different queue/flush/error boundaries, and forcing a common state would require a recording lifecycle design change. Two nested bilingual interpolations remain in view-specific status text.
- P5.5: sendLab's compatibility argument wrapper delegates to sendLabCommand; it remains for existing diagnostic callers. Triple body-field collapse is deferred because tolerant wire decoding, feedback freshness and telemetry defaults/provenance differ; collapsing them without a new public observation contract risks losing fields. Named parser wrappers remain thin type-specific aliases over generic parseLine.
- P5.6: the three edit lifecycles live together and share timeout, connection/session ACK checks and common rejection detail. They retain specialized pending shapes/queue/history policies (especially missing-schedule behavior, transient undo rejection and current revisions); a single state machine requires a design decision. Exact history labels are table-driven; value extraction and environment/editor property switches remain specialized, so the requested universal property table is only partially completed. Label strings remain exact and 117 editor checks pass.
- P5.8: common Suite and makeDiagSim cover normal diagnostic checks/setup/summary exit. Simtest's aggregate pass, behavior scenario harness and specialized live-loop checks keep their custom formats/flow; GPUCheck's independent oracle is untouched. Loop changes were compiled but not run.
- P5.12: script checks are unittest assertions/subtests and the scene-store triple pause-suite import/run is removed. Tests have feature names. Existing feature-specific food/capacity/future-tick/replay checks remain when their setup/public boundary differs; broad deletion of overlapping cases is deferred because it would reduce independent boundary coverage. Script feature groups still use one test_contract with named subtests rather than one method per assertion. Real and perf files were relocated and statically parsed, not executed.
- P5.13: HybridTurningController JointDOF precomputation was skipped. The required upstream real-body bit-equality experiment was prohibited; controller math remains unchanged.

## Before/after measurements

Measurements use retained baseline evidence and the final tree; timings are load-dependent, not a controlled speedup claim.

| Metric | Before | Final |
|---|---:|---:|
| Tracked working-tree allocated size (`git ls-files -z | xargs -0 du -ck | tail -1`) | 171124 KiB | 104216 KiB |
| Dev binary (`wc -c`) | 4304232 B | 3620792 B |
| Release binary, stripped | no original release baseline; P1 1702408 B | 1752888 B |
| Saved pre-P0 simtest, 16-step | 123 µs/step | 131 µs/step |
| Saved pre-P0 simtest, 1-step | 638 µs/step | 320 µs/step |
| Python mock suite external wall | 5.766 s, 14 scripts | 2.110 s, unittest discover |
| Swift LOC (`wc -l`) | 23338 | 23579 |
| Metal LOC (`wc -l`) | 163 | 163 |
| Python LOC (`wc -l`, including separated real/perf tests) | 15987 | 16464 |

RESUME.md additionally records an earlier 99 µs sample, simultaneous original 138–143 vs refactor 105–141 µs samples, and rounded dev 4.30→3.52 MB/release 1.70 MB. The final 16-step sample does not demonstrate a reliable runtime speedup. The formerly advertised 178 s Python run included about 162 s of real physics; it is not comparable to this mock-only runner. unittest's internal time was 1.928 s for 95 methods, versus 2.110 s external process wall. New regression/table/adapter/test wrapper code makes total source LOC slightly larger even though the largest files and tracked repository shrink: main 17 lines, LabWindow 1806 lines, lab_world 1740 lines. Evidence untracking does not shrink existing git history or delete local evidence.

`size -m` segment bytes (PAGEZERO excluded from meaningful file comparison):

| Segment | Baseline dev | Final dev | Final release |
|---|---:|---:|---:|
| __TEXT | 2359296 | 2326528 | 1523712 |
| __DATA_CONST | 81920 | 81920 | 65536 |
| __DATA | 147456 | 131072 | 131072 |
| __LINKEDIT | 1785856 | 1130496 | 98304 |

`git diff --stat 973945a` including this report: 513 files changed, 12479 insertions(+), 53716 deletions(-). LOC baseline is counted from git blobs at 973945a; final LOC is wc -l over the source trees.

## Final P5 verification

All final commands ran sequentially through the phase checker after ./build.sh. EOF/trailing whitespace-only cleanup followed, with both working and staged diff checks clean. No semantic Swift changes followed the full test pass. A final Body protocol cleanup removed an unimplemented, unused observe requirement (RealFlyBody does not expose it); the Python suite was rerun afterward: 95 tests, 1.989 s, OK, exit 0.

| Check | PASS count / terminal evidence | Exit |
|---|---|---:|
| ./build.sh | Built ./ThongpariFlyNeuronSim | 0 |
| --simtest | 8 PASS lines; final sim invariant PASS | 0 |
| --behaviortest | 17 PASS; ALL BEHAVIOR TESTS PASS (no retry needed) | 0 |
| --gpucheck | 0/15091983 differing weights; GPUCHECK PASS (see every delta below) | 0 |
| --labtest | CHECKS 191; FAILURES 0 | 0 |
| --bridgetest | CHECKS 100; FAILURES 0 | 0 |
| --v4test | CHECKS 18; FAILURES 0 | 0 |
| --v4sessiontest | CHECKS 18; FAILURES 0 | 0 |
| --v4timingtest | CHECKS 5; FAILURES 0 | 0 |
| --worldeditortest | CHECKS 117; FAILURES 0 | 0 |
| --observationaudittest | CHECKS 23; FAILURES 0; all 16 EMA rates preserve Float bits | 0 |
| ../flygym-venv/bin/python -m unittest discover -s tests/unit | Ran 95 tests in 1.928s; OK; external 2.110s | 0 |
| git diff --check; git diff --cached --check | no errors | 0 |
| standalone release compile / strip | 1752888 B | 0 |
| release --simtest | diagnostics not compiled in | 2 (expected) |
| Python AST parse of source/unit/real/perf | all files parse; no real test imported/executed | 0 |

All other in-process *test flags are included (v4sessiontest is the additional alias). Live *loop, inputprobe and GUI/snapshot commands are deliberately excluded.

### GPU equality: inherited spec discrepancy

Hard-rule prose says every scenario must report zero. The preserved baseline already prints two intentionally failing FMA candidates, overlapping CPU stimulus summation and gait ULP exceptions. Final checker lines match it; no oracle/math was changed to manufacture zeros. A/B/C/D/E'/H are zero, 0 weights differ, and suite exit is 0. Thus the literal all-delta-lines-zero condition is NOT achieved and was not true before this work.

```text
weights: 15091983 quantized edges, 0 differ from the GPU buffer (max 0 Q18 units, independent factor order)
  0 plain a*b+c  120 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 7.15e-07 (n69919 @step 55) | FAIL
  1 fma leak  120 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 0 | ok
  2 fma synaptic  120 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 7.15e-07 (n69919 @step 55) | FAIL
  3 fma leak+syn  120 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 0 | ok
A rest  300 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 0 | ok
B loom+puff  300 steps | spikes+gf = (gf 122) | refr = | groups = | rates = | max|Δv| 0 | ok
C stim 200x0.5/7ms   16 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 0 | ok
D scale .84 gate .6  150 steps | spikes+gf = (gf 12) | refr = | groups = | rates = | max|Δv| 0 | ok
E 2 overlapping stims   20 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 5.96e-08 (n155 @step 1) | ok
E' same, GPU summing   20 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 0 | ok
  gaitFma 0  200 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 1.19e-07 (n103594 @step 47) | ok
  gaitFma 1  200 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 1.19e-07 (n103594 @step 47) | ok
  gaitFma 2  200 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 5.96e-08 (n113373 @step 21) | ok
  gaitFma 3  200 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 5.96e-08 (n113373 @step 21) | ok
H 12.2 s + burst  538 steps | spikes+gf = (gf 0) | refr = | groups = | rates = | max|Δv| 0 | ok
GPUCHECK PASS
```

## Protocol changes

P2: Python considers `lab_state.state.environment_capabilities` at actual transmission, sends the first manifest on each connection, then sends it again only when canonical JSON content changes. Reconnect resets the sent-manifest key. ACK/state fields retain their cadence. Swift caches the last strictly validated manifest per connection; omission retains it, malformed optional manifests do not replace it, reconnect clears it, and session/epoch filtering happens before caching. Panel/window capability readers use the cache. This is not an ACK negotiation or a deletion sentinel.

P3: lab_event includes session_id, epoch and sim_tick; stale/missing identity is filtered once a session is requested. Begin/reset drains old events before promoting identity. ACK history is generation-filtered. Bare untagged body is rejected in deterministic mode; matching experiment_step_result supplies the body. CSV appends sugar_grn_hz and mn9_hz; header/value order comes from one table. Requested tick is not mislabeled as appliedTick for neural marks.

## Orchestrator-only acceptance

- GUI: both brain windows see spikes; clicks retain visible stimulus behavior; participant controls recover after lost ACK; language changes do not grow constraints; aim fallback/mark stays aligned; pending timeline rows survive; pages/toolbar/presets/markers/key bindings and recording/quit-flush behavior remain correct after splits.
- Actual threading/service: pause/resume/reset boundaries and concurrent interactive start; backend restarts close old log descriptors; covered SceneKit stops rendering; recorded columns/rate text remain correct.
- Actual transport: first/changed/reconnect manifest, omission cache and rejection ACKs; stale event/epoch/body boundaries; frame input limits and loop regression modes.
- `flygym_bridge/tests/real/*_real.py`, including moved V5.6.2 real feeding/contact/controller-observation checks; optional tests/perf idle-toy gate separately. Unit speed does not establish real physics performance.
- `package_app.sh`: independent release bundle compile, resource assembly, codesign verification and Finder launch. Only standalone release compile/strip/diagnostic rejection were verified here.

## Surprises and risks

P5's initial Python failures came from extraction/import boundaries, including overlapping _vec3 helper names, mock max_physics_substeps defaults, fixture paths, bidirectional test decoding and duplicate unittest class imports; they were fixed without controller/physics/math edits. Swift split failures were access-control boundaries and a stored property in an extension, fixed by moving ownership and only widening required declarations. Migrated real files needed their original check helper/cleanup restored, found statically; runtime remains unverified. Existing packaging Selector warnings remain nonfatal. No new observation primitive was implemented. The full refactor is not evidence of every requested lightweighting subitem being completed; partial/deferred items above are explicit.

## Process confirmation

Before the implementation commit, both `pgrep -fl ThongpariFlyNeuronSim` and `pgrep -fl bridge.py` returned no output, exit 1; all processes started by this continuation had ended.

The final post-commit audit found a separately started external validation build: `pgrep -fl ThongpariFlyNeuronSim` returned exit 0 because shell PID 27279, swift-driver PID 27284 and swift-frontend PID 27285 included the binary name in command arguments. `ps` executable-name filtering found no running ThongpariFlyNeuronSim executable at that instant. `pgrep -fl bridge.py` still returned no output, exit 1. These external processes were not started or terminated by this continuation; no claim is made that the separate validator has finished.
