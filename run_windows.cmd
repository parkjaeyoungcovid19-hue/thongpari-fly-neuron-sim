@echo off
setlocal
set "PYTHONUTF8=1"
cd /d "%~dp0"
if not exist "flygym-venv\Scripts\python.exe" (
    echo Run setup_windows.cmd first. 1>&2
    exit /b 1
)
flygym-venv\Scripts\python.exe -m desktop_lab.app %*
exit /b %errorlevel%
