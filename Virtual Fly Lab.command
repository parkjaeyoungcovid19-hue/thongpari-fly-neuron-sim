#!/bin/zsh
# Finder launcher: double-click to open the one-window Virtual Fly Lab.
cd "$(dirname "$0")" || exit 1
echo "🧪 Virtual Fly Lab V7.1 — 장면 저장/불러오기 · Undo/Redo · 표본 발화/측정값 출처 구분"
./run_flygym.sh "$@"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo
  echo "Virtual Fly Lab exited with status $STATUS. Press any key to close."
  read -k 1
fi
exit "$STATUS"
