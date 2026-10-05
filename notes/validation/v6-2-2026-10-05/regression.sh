#!/bin/zsh
# From repo root. Sequential: heavy suites never overlap.
D=notes/validation/v6-2-2026-10-05
export PYTHONDONTWRITEBYTECODE=1
run() { local name=$1; shift; "$@" > $D/$name-final.log 2>&1; echo "$name exit=$?" | tee -a $D/regression-summary.txt; }
: > $D/regression-summary.txt
run build ./build.sh
for t in labtest bridgetest v4test v4timingtest simtest behaviortest gpucheck; do run $t ./ThongpariFlyNeuronSim --$t; done
for t in environment_edits environment_properties feeding_events bridge lab v4 v5 v5_6 lab_real v5_6_2 interaction_real player_collision_real vision_real v5_6_2_tools; do
  run test_$t flygym-venv/bin/python flygym_bridge/test_$t.py
done
