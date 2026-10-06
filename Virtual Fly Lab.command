#!/bin/zsh
# Finder launcher: double-click to open the one-window Virtual Fly Lab.
cd "$(dirname "$0")" || exit 1
echo "🧪 Virtual Fly Lab V6.5 — 환경 패널(온도·바람·빛·먹이, 적용값/보내는 중 구분) · 경사로 · 편집 모드"
./run_flygym.sh "$@"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo
  echo "Virtual Fly Lab exited with status $STATUS. Press any key to close."
  read -k 1
fi
exit "$STATUS"
