#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
THONGPARI_PYTHON="${THONGPARI_PYTHON:-python3.12}"
"$THONGPARI_PYTHON" -c 'import sys, struct; assert sys.version_info[:2] == (3, 12) and struct.calcsize("P") == 8, "Use 64-bit Python 3.12"'
"$THONGPARI_PYTHON" -m venv flygym-venv
./flygym-venv/bin/python -m pip install -r desktop_lab/requirements.txt
./flygym-venv/bin/python -m pip check
echo 'Linux desktop installed. Run ./run_linux.sh in an X11 or Wayland desktop session.'
