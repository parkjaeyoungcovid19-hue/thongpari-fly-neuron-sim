# pre-V7.2 refactor verification

Branch `refactor/pre-v7.2`, base `973945a`. P0–P2 were inherited as committed,
verified work; they were not repeated. No GUI, listener, real-body test, launcher,
package signing, installation, push, history rewrite, or subagent was used.

Phase logs stay local beside this README (ignored by the P0 evidence policy).
The phase result files include each command's exit code and wall time. Swift
suite logs preserve all individual PASS/FAIL lines and GPU delta lines.

P3 fixes independent bounded display consumers, scheduled clicks, CSV schema
(including sugar GRN/MN9), session-tagged events, ACK generation filtering,
8-second participant timeout, one-time aim setup, idempotent constraints,
2.5 mm aim fallback, pending timeline retention, interactive-start serialization,
render-thread pause mutation, command schedule selection, unified neural marks,
paused-transaction exception containment, 2 MiB view-input bound, service log
handle closure, CLI usage guard, fixture FAIL handling, and real card-send probing.
Untagged standalone body packets are rejected during deterministic sessions;
matching experiment-step results supply the body. Buffer scan offsets are local
to their receive loop, preventing connection teardown from racing that cursor.

Regression coverage: `--labtest`, `--bridgetest`, Python refactor regressions,
and existing V4/timing/editor/audit suites. Actual mouse clicks, language-change
layout, restart descriptor counts, and concurrent UI scheduling still require
the orchestrator's allowed live checks. Neural marks record `appliedTick` as
unknown until an owner application boundary is known; a requested tick is not
claimed to be an observed application.

The inherited GPU checker has deliberate FMA candidate failures and tolerated
CPU accumulation/gait ulp differences. They match the saved baseline. The
production-equal scenarios A/B/C/D/E'/H stay exactly zero, weights differ by zero,
and the suite reports GPUCHECK PASS. See the final report for every delta line.

P4 makes NeuronGuide the population/cluster/color/resolver table, moves telemetry
into Lab, folds rate EMA/denominators/reset through GroupSpec while retaining
caller getters, resolves receptor types once, and separates BrainPick from the
explicit stimulus action. ACK/event overflow now has diagnostic counters. The
observation audit compares every rate's Float bits against the original EMA
expression for 130 steps across sugar/MN9 windows. No V7.2 exact primitive added.
