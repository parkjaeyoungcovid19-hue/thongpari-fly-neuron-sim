#!/bin/zsh
# One-script launch: venv bridge (mock or real) + Thongpari Fly Neuron Sim --flygym.
# Usage: ./run_flygym.sh [--mock|--flygym]   (default: --flygym)
cd "$(dirname "$0")"
MODE="${1:---flygym}"

# A double-click launcher must never silently run an older binary after source
# changes. Rebuild only when the executable is missing or a Swift/Metal/build
# input is newer, so normal launches stay fast.
NEEDS_BUILD=0
if [ ! -x ./ThongpariFlyNeuronSim ]; then
  NEEDS_BUILD=1
elif find . -maxdepth 1 \( -name '*.swift' -o -name '*.metal' -o -name 'build.sh' \) -newer ./ThongpariFlyNeuronSim -print -quit | grep -q .; then
  NEEDS_BUILD=1
fi
if [ "$NEEDS_BUILD" -eq 1 ]; then
    echo "🔨 최신 소스로 Virtual Fly Lab V5.5 빌드 중..."
  ./build.sh || exit 1
fi

echo "🧪 Launching Thongpari Fly Neuron Sim — Virtual Fly Lab V5.5"

if [ ! -x flygym-venv/bin/python ]; then
  echo "no flygym-venv — create it first (see flygym_bridge/README.md)" >&2
  exit 1
fi
# A previous launcher crash can leave this project's Python bridge listening on
# the fixed localhost port. Never connect a new V4 UI to an unknown/stale
# backend: replace only a bridge owned by this project, otherwise fail closed.
BRIDGE_PORT=17841
LISTENER_PIDS=("${(@f)$(lsof -tiTCP:$BRIDGE_PORT -sTCP:LISTEN 2>/dev/null)}")
for pid in $LISTENER_PIDS; do
  [ -z "$pid" ] && continue
  cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  project_parent="$(cd .. && pwd)"
  if [[ "$cmd" == *"flygym_bridge/bridge.py"* && ( "$cwd" == "$PWD" || "$cwd" == "$project_parent" ) ]]; then
    echo "♻️ 이전 Thongpari/FlyGym bridge 정리 중 (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    for _ in {1..30}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  else
    echo "❌ localhost:$BRIDGE_PORT 를 다른 프로세스가 사용 중입니다 (PID $pid)." >&2
    echo "   $cmd" >&2
    exit 1
  fi
done

if [ "$MODE" = "--flygym" ]; then
  # The venv path contains spaces, so mjpython's shebang cannot be executed
  # directly by macOS. Run the trampoline through the venv interpreter.
  ./flygym-venv/bin/python ./flygym-venv/bin/mjpython flygym_bridge/bridge.py "$MODE" &
else
  ./flygym-venv/bin/python flygym_bridge/bridge.py "$MODE" &
fi
BRIDGE_PID=$!
cleanup() {
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait "$BRIDGE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sleep 2
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  echo "❌ FlyGym bridge가 시작 직후 종료되었습니다." >&2
  wait "$BRIDGE_PID" 2>/dev/null || true
  exit 1
fi
./ThongpariFlyNeuronSim --flygym
