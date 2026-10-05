# A/B control only: run the real bridge with environment_capabilities removed from state().
import runpy, sys
root = sys.argv.pop(1)
sys.path.insert(0, root + "/flygym_bridge")
import lab_world
_orig = lab_world.LabWorld.state
def state(self):
    s = _orig(self); s.pop("environment_capabilities", None); return s
lab_world.LabWorld.state = state
sys.argv[0] = root + "/flygym_bridge/bridge.py"
runpy.run_path(sys.argv[0], run_name="__main__")
