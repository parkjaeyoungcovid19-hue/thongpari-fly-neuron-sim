#!/bin/zsh
# usage: hl.sh <root> <loop> <tag>
ROOT="$1"; LOOP="$2"; TAG="$3"; OUT=/private/tmp/claude-501/-Users-apgx-Documents-Codex-Projects----/20e28e84-c7e7-4000-b91c-1a7148f59901/scratchpad/own
PY="/Users/apgx/Documents/Codex Projects/초파리/flygym-venv/bin/python"
for p in 17841 17842; do lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null && { echo "port $p busy"; exit 3; }; done
cd "$ROOT"
THONGPARI_BRIDGE_PORT=17841 THONGPARI_RENDER_PORT=17842 "$PY" -u flygym_bridge/bridge.py --flygym-headless > $OUT/$TAG-backend.log 2>&1 &
BP=$!
for i in {1..2400}; do lsof -nP -iTCP:17841 -sTCP:LISTEN >/dev/null && lsof -nP -iTCP:17842 -sTCP:LISTEN >/dev/null && break; sleep 0.1; done
sleep 1
THONGPARI_BRIDGE_PORT=17841 ./ThongpariFlyNeuronSim --$LOOP > $OUT/$TAG-test.log 2>&1; RC=$?
kill $BP; wait $BP 2>/dev/null
echo "$TAG rc=$RC"; grep -E "bridgeloop:|PASS|FAIL" $OUT/$TAG-test.log | tail -3
