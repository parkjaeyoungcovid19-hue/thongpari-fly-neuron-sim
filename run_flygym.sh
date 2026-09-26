#!/bin/zsh
# Open the one-window Virtual Fly Lab. The app starts and owns its FlyGym
# backend on a private loopback port (same lifecycle as the packaged .app) and
# stops it on quit; it never touches another process's 17841 listener.
#
# Usage: ./run_flygym.sh [--mock | --viewer | --bridge-only]
#   (default)      real FlyGym, headless — the only window is the Lab
#   --mock         kinematic mock body (no MuJoCo), for quick UI checks
#   --viewer       development only: also opens MuJoCo's own viewer window
#   --bridge-only  run just a real headless bridge on 127.0.0.1:17841 for
#                  diagnostics (--labloop/--v4loop) or `./ThongpariFlyNeuronSim --flygym`
cd "$(dirname "$0")"
LAB_FLAGS=()
BRIDGE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --mock|--viewer) LAB_FLAGS+=("$arg") ;;
    --bridge-only) BRIDGE_ONLY=1 ;;
    --flygym|--flygym-headless) ;;   # older launchers: the default is already real FlyGym
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ ! -x flygym-venv/bin/python ]; then
  echo "no flygym-venv — create it first (see flygym_bridge/README.md)" >&2
  exit 1
fi

if [ "$BRIDGE_ONLY" -eq 1 ]; then
  BRIDGE_PORT=17841
  if lsof -tiTCP:$BRIDGE_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "❌ localhost:$BRIDGE_PORT is already in use (PID $(lsof -tiTCP:$BRIDGE_PORT -sTCP:LISTEN | tr '\n' ' '))." >&2
    exit 1
  fi
  # The venv path contains spaces, so mjpython's shebang cannot be executed
  # directly by macOS. Run the trampoline through the venv interpreter.
  exec ./flygym-venv/bin/python ./flygym-venv/bin/mjpython flygym_bridge/bridge.py --flygym-headless
fi

# A double-click launcher must never silently run an older binary after source
# changes. Rebuild only when the executable is missing or a Swift/Metal/build
# input is newer, so normal launches stay fast.
if [ ! -x ./ThongpariFlyNeuronSim ] || \
   find . -maxdepth 1 \( -name '*.swift' -o -name '*.metal' -o -name 'build.sh' \) -newer ./ThongpariFlyNeuronSim -print -quit | grep -q .; then
  echo "🔨 최신 소스로 Virtual Fly Lab 빌드 중..."
  ./build.sh || exit 1
fi

echo "🧪 Virtual Fly Lab — one window"
exec ./ThongpariFlyNeuronSim --lab "${LAB_FLAGS[@]}"
