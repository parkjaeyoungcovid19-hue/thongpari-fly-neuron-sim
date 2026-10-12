"""OS-specific defaults for the shared Qt client and its private backend."""

import os
import sys
import tempfile
from pathlib import Path


def cache_directory():
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir()))
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    return base / "ThongpariFlyNeuronSim"


def backend_environment():
    env = os.environ.copy()
    if sys.platform == "win32":
        env.setdefault("MUJOCO_GL", "glfw")
        # EGL/OSMesa are Linux backends; Windows uses its native WGL loader.
        env.setdefault("PYOPENGL_PLATFORM", "win32")
    else:
        env.setdefault("MUJOCO_GL", "egl")
        if env["MUJOCO_GL"] in ("egl", "osmesa"):
            env.setdefault("PYOPENGL_PLATFORM", env["MUJOCO_GL"])
    # Qt wheels sometimes inject plugin paths that conflict with another Qt
    # bundled by OpenCV in the body process. The backend doesn't need Qt.
    env.pop("QT_PLUGIN_PATH", None)
    env.pop("QT_QPA_PLATFORM_PLUGIN_PATH", None)
    return env
