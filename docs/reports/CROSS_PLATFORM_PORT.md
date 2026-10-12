# Linux and Windows desktop port — 2026-10-12

The Qt/CPU client in `desktop_lab/` runs the whole shipped FlyWire graph and
uses the current FlyGym/MuJoCo world backend. Platform launchers and guides
are linked from the README. This source port does not produce standalone
`.exe`/AppImage packages.

The initial uncommitted Linux client was brought forward from `7cea100` onto
the current macOS V7.5 source (`1f35b76`) before adding Windows support. No
older Swift or Python backend was published over the newer repository.

## Verified in the Linux cloud environment

- `python -m unittest discover -s desktop_lab/tests -v`: **19 tests passed**.
  This includes the full graph, independent scalar/RNG/weight oracles,
  taste/odor separation, stimulation expiry, exact 20 ms TCP quanta,
  stale-revision rejection, native Qt mock and real-body workflows, graphics
  defaults and owned-process cleanup after both normal quit and app crash.
- Backend mock discovery (`flygym_bridge/tests/unit`): **95 tests passed**.
- Real-body `test_lab_real.py` and `test_vision_real.py`: both passed,
  including actual MuJoCo physics and stereo-eye rendering.
- `tools/verify_data.py --no-parquet`: all shipped-data checks passed. The
  upstream parquet reconciliation was explicitly skipped.
- `pip check`, Python compilation, launcher help/invalid-seed checks,
  shell syntax and `git diff --check` passed.

The final desktop run took 53.712 s. A concurrent software-rendered Lab run
had exceeded the desktop test's original 40 s startup gate. Cold-start testing
now allows full-brain compilation plus the backend's existing 90 s startup
allowance; the final desktop suite ran without concurrent real-body tests.

## Windows coverage and limits

The Actions matrix installs from `setup_windows.cmd` and runs full CPU brain,
protocol, native process-lifetime, backend unit and mock Qt tests on Windows.
Windows uses GLFW/WGL rather than Linux EGL, `%LOCALAPPDATA%` rather than
POSIX cache paths, and handle-based parent monitoring rather than
`os.kill(pid, 0)`. CSV and launchers use UTF-8. Actual Windows MuJoCo rendering
requires a native desktop/GPU validation pass; the hosted Windows CI job does
not establish real-body rendering or performance.

The shared Qt UI includes the world, environment, brain, data and experiment
pages. The macOS overlay, editor drag handles, undo/scene-file UI and V7 exact
observation/group/event-window panels are not in this client. CPU float32
simulation is not claimed bit-identical to Metal. See [Linux](../guides/LINUX.md)
and [Windows](../guides/WINDOWS.md) for the full capability and validation scope.
