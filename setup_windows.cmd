@echo off
setlocal
set "PYTHONUTF8=1"
cd /d "%~dp0"
if defined THONGPARI_PYTHON (
    set "THONGPARI_PYTHON_ARGS="
) else (
    set "THONGPARI_PYTHON=py"
    set "THONGPARI_PYTHON_ARGS=-3.12"
)
"%THONGPARI_PYTHON%" %THONGPARI_PYTHON_ARGS% -c "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8, 'Use 64-bit Python 3.12'"
if errorlevel 1 goto failed
"%THONGPARI_PYTHON%" %THONGPARI_PYTHON_ARGS% -m venv flygym-venv
if errorlevel 1 goto failed
flygym-venv\Scripts\python.exe -m pip install -r desktop_lab\requirements.txt
if errorlevel 1 goto failed
flygym-venv\Scripts\python.exe -m pip check
if errorlevel 1 goto failed
echo Windows desktop installed. Run run_windows.cmd.
exit /b 0
:failed
echo Installation failed. Install 64-bit Python 3.12 with the Python launcher, or set THONGPARI_PYTHON to its executable path. 1>&2
exit /b 1
