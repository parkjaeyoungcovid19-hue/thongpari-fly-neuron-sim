# Windows desktop

The Windows port uses the same native **PySide6/Qt** window and full
**139,255-neuron / 15,091,983-edge CPU connectome** as Linux. It starts the
current production FlyGym/MuJoCo backend on private loopback ports. See the
[Linux guide](LINUX.md#controls-and-capabilities) for shared controls and the
[platform differences](LINUX.md#simulation-contract-and-limits) for the features
that remain in the macOS interface.

## Install and launch

Use **Windows 10/11 x64**, **64-bit Python 3.12**, and a graphics driver with
OpenGL 3.3 support for MuJoCo rendering. Install Python with its `py` launcher,
then clone the repository and run in Command Prompt or PowerShell:

```powershell
git clone https://github.com/parkjaeyoungcovid19-hue/thongpari-fly-neuron-sim.git
cd thongpari-fly-neuron-sim
.\setup_windows.cmd
.\run_windows.cmd
```

Both scripts change to their own directory and handle paths containing spaces.
Installation creates `flygym-venv\Scripts\python.exe`; activation is unnecessary.
No Xcode, Swift, Metal, CUDA, WSL, Docker or external API account is required.
The app runs locally after dependencies are installed. The first launch
compiles the CPU kernels and prewarms the body; the window shows progress.

If Python is installed without the launcher, set its executable path before
running setup. In PowerShell:

```powershell
$env:THONGPARI_PYTHON = 'C:\path with spaces\Python312\python.exe'
.\setup_windows.cmd
```

Once installed, double-click `run_windows.cmd`, or pass launch options:

```powershell
.\run_windows.cmd --mock
.\run_windows.cmd --seed 0x1234
```

`--mock` keeps the full CPU brain but uses a labeled kinematic body and
top-down diagram. It is useful for testing the UI without an OpenGL driver;
it does not exercise NeuroMechFly physics or rendered-eye vision.

## Windows integration

- MuJoCo defaults to **GLFW/WGL**, and PyOpenGL uses the Windows loader.
  Linux EGL/OSMesa environment settings should not be used on Windows.
- The backend uses the venv's own interpreter and opens no extra console.
  Quit closes the socket and terminates only the backend the app created.
- Parent lifetime is watched with `OpenProcess(SYNCHRONIZE)` and
  `WaitForSingleObject`. Windows `os.kill(pid, 0)` is never used: it can
  terminate the parent instead of checking whether it exists.
- Logs live in `%LOCALAPPDATA%\ThongpariFlyNeuronSim\`. Startup errors show
  the exact log filename. Experiment CSV is UTF-8 and stores simulation
  ticks, seed, neural rates, measured body packets, commands and replies.
- The CPU brain runs exact 1 ms ticks followed by 20 ms body quanta. A slow
  computer changes wall time, not the number of neural or physics steps.
  This port has not been validated as bit-identical to Apple Metal.

If the real canvas fails to appear, check the backend log and update the GPU
vendor's driver. A remote desktop or VM may expose insufficient OpenGL even
when the mock window works. Run `--mock` to isolate UI/CPU problems from real
rendering failures.

## Validate

Run from the checkout in PowerShell:

```powershell
$env:PYTHONUTF8 = '1'
.\flygym-venv\Scripts\python.exe -m pip check
.\flygym-venv\Scripts\python.exe -m unittest desktop_lab.tests.test_brain desktop_lab.tests.test_session desktop_lab.tests.test_process_lifetime -v
.\flygym-venv\Scripts\python.exe -m unittest desktop_lab.tests.test_desktop -v
```

The desktop suite includes a real-MuJoCo workflow: rendered frames, neural/body
time, editing a ramp, duplicate/delete, temperature and eye-cover replies,
participant movement/look, pause/resume, CSV recording and backend shutdown.
It requires a working OpenGL desktop. For mock-only validation:

```powershell
.\flygym-venv\Scripts\python.exe -m unittest desktop_lab.tests.test_desktop.DesktopTests.test_mock_desktop_full_brain_pause_and_shutdown -v
```

The [CI workflow](../../.github/workflows/desktop.yml) runs the CPU, TCP,
process-lifetime, backend unit and mock Qt tests on Windows. The Linux job
also runs real MuJoCo rendering with software EGL. A native Windows real-body
GUI pass is still needed on a machine with an OpenGL driver; Linux results
do not establish Windows rendering or performance.
