#!/bin/zsh
# Finder launcher: double-click to open the one-window Virtual Fly Lab.
cd "$(dirname "$0")" || exit 1
echo "🧪 Virtual Fly Lab V6.3 — 편집 모드: 물체 선택 · 이동 · Z 회전 · 크기 · 복제 · 삭제"
./run_flygym.sh "$@"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo
  echo "Virtual Fly Lab exited with status $STATUS. Press any key to close."
  read -k 1
fi
exit "$STATUS"
