#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x flygym-venv/bin/python ]]; then
  echo 'Create flygym-venv with Python 3.12 and install desktop_lab/requirements.txt first.' >&2
  exit 1
fi
# Session selects EGL by default, or preserves an explicit GLFW/OSMesa choice.
exec flygym-venv/bin/python -m desktop_lab.app "$@"
