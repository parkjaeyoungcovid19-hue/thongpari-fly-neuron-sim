#!/bin/zsh
# Full V5 closeout matrix, sequential. Logs next to this script.
cd "/Users/apgx/Documents/Codex Projects/초파리/siliconfly"
D=notes/validation/v5-close-2026-09-28/final
PY="/Users/apgx/Documents/Codex Projects/초파리/flygym-venv/bin/python"
SUM=$D/summary.txt; : > $SUM
run() { local name=$1; shift; local start=$(date +%s); "$@" > $D/$name.log 2>&1; local rc=$?; echo "$name exit=$rc $(( $(date +%s)-start ))s | $(grep -E 'PASS|FAIL' $D/$name.log | tail -1 | cut -c1-110)" >> $SUM; }
git status --short > $D/git-status.txt; git diff --stat > $D/git-diffstat.txt
run build ./build.sh
for t in bridgetest labtest v4test v4sessiontest v4timingtest simtest behaviortest gpucheck; do run swift-$t ./ThongpariFlyNeuronSim --$t; done
for t in test_bridge test_lab test_lab_real test_v4 test_v5 test_v5_6 test_v5_6_2 test_v5_6_2_tools test_interaction_real test_player_collision_real test_vision_real; do run py-$t "$PY" flygym_bridge/$t.py; done
loop() { # mode loop
  for p in 17841 17842; do lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null && { echo "tcp-$1-$2 BLOCKED port $p" >> $SUM; return; }; done
  if [[ $1 == mock ]]; then THONGPARI_BRIDGE_PORT=17841 "$PY" -u flygym_bridge/bridge.py --mock > $D/tcp-$1-$2-backend.log 2>&1 &
  else THONGPARI_BRIDGE_PORT=17841 THONGPARI_RENDER_PORT=17842 "$PY" -u flygym_bridge/bridge.py --flygym-headless > $D/tcp-$1-$2-backend.log 2>&1 & fi
  local bp=$!
  for i in {1..2400}; do lsof -nP -iTCP:17841 -sTCP:LISTEN >/dev/null && { [[ $1 == mock ]] || lsof -nP -iTCP:17842 -sTCP:LISTEN >/dev/null; } && break; sleep 0.1; done
  sleep 1
  run tcp-$1-$2 env THONGPARI_BRIDGE_PORT=17841 ./ThongpariFlyNeuronSim --$2
  kill $bp; wait $bp 2>/dev/null
}
for l in bridgeloop labloop interactionloop; do loop mock $l; done
for l in labloop interactionloop bridgeloop; do loop headless $l; done
run diff-check git diff --check
lsof -nP -iTCP:17841 -iTCP:17842 -sTCP:LISTEN >> $SUM 2>&1; echo "ports-after: $(lsof -nP -iTCP:17841 -iTCP:17842 -sTCP:LISTEN | wc -l) listeners" >> $SUM
echo DONE >> $SUM
