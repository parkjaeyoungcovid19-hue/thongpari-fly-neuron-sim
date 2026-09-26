#!/bin/zsh
# Finder launcher: double-click to open the one-window Virtual Fly Lab.
cd "$(dirname "$0")" || exit 1
./run_flygym.sh "$@"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo
  echo "Virtual Fly Lab exited with status $STATUS. Press any key to close."
  read -k 1
fi
exit "$STATUS"
