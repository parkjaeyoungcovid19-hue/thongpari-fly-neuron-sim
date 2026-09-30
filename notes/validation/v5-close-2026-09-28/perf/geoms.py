import sys, os, collections
root = sys.argv[1]; sys.path.insert(0, os.path.join(root, "flygym_bridge")); os.chdir(root)
import mujoco
from fly_body import RealFlyBody
b = RealFlyBody(config={}, show_viewer=False)
m=[getattr(b.sim,a) for a in dir(b.sim) if isinstance(getattr(b.sim,a,None), mujoco.MjModel)][0]
col=[g for g in range(m.ngeom) if m.geom_contype[g] or m.geom_conaffinity[g]]
bodies=collections.Counter(m.geom_bodyid[g] for g in col)
print(os.path.basename(root), "ngeom",m.ngeom,"collidable geoms",len(col),"bodies w/ collidable",len(bodies), "flags", m.opt.disableflags, "enableflags", m.opt.enableflags)
def root_name(bid):
    n=mujoco.mj_id2name(m, mujoco.mjtObj.mjOBJ_BODY, bid) or f"b{bid}"
    return n
pref=collections.Counter()
for g in col:
    n=root_name(m.geom_bodyid[g]); pref[n.split('_')[0] if n else '?']+=1
print(" collidable by body-prefix:", pref.most_common(12))
allpref=collections.Counter((root_name(m.geom_bodyid[g]) or '?').split('_')[0] for g in range(m.ngeom))
print(" all geoms by body-prefix:", allpref.most_common(12))
