import os
import unittest
from pathlib import Path
from unittest.mock import patch

from desktop_lab.platform_support import backend_environment, cache_directory


class PlatformSupportTests(unittest.TestCase):
    def test_windows_uses_native_gl_and_local_app_data(self):
        with patch("desktop_lab.platform_support.sys.platform", "win32"), patch.dict(
            os.environ, {"LOCALAPPDATA": "C:/Users/Test User/AppData/Local"}, clear=True
        ):
            env = backend_environment()
            self.assertEqual(env["MUJOCO_GL"], "glfw")
            self.assertEqual(env["PYOPENGL_PLATFORM"], "win32")
            self.assertEqual(cache_directory(), Path(os.environ["LOCALAPPDATA"]) / "ThongpariFlyNeuronSim")

    def test_linux_respects_gl_override_without_forcing_egl_loader(self):
        with patch("desktop_lab.platform_support.sys.platform", "linux"), patch.dict(
            os.environ, {"MUJOCO_GL": "glfw", "XDG_CACHE_HOME": "/tmp/custom-cache"}, clear=True
        ):
            env = backend_environment()
            self.assertEqual(env["MUJOCO_GL"], "glfw")
            self.assertNotIn("PYOPENGL_PLATFORM", env)
            self.assertEqual(cache_directory(), Path("/tmp/custom-cache/ThongpariFlyNeuronSim"))

    def test_linux_egl_and_osmesa_loaders(self):
        for gl in ("egl", "osmesa"):
            with self.subTest(gl=gl), patch("desktop_lab.platform_support.sys.platform", "linux"), patch.dict(
                os.environ, {"MUJOCO_GL": gl, "QT_PLUGIN_PATH": "conflicting-qt"}, clear=True
            ):
                self.assertEqual(backend_environment()["PYOPENGL_PLATFORM"], gl)
                self.assertNotIn("QT_PLUGIN_PATH", backend_environment())


if __name__ == "__main__":
    unittest.main()
