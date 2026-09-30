import sys, os, collections, re
root = sys.argv[1]; sys.path.insert(0, os.path.join(root, "flygym_bridge")); os.chdir(root)
import mujoco
from fly_body import RealFlyBody
b = RealFlyBody(config={}, show_viewer=False)
m=[getattr(b.sim,a) for a in dir(b.sim) if isinstance(getattr(b.sim,a,None), mujoco.MjModel)][0]
def cls(g):
    n=mujoco.mj_id2name(m, mujoco.mjtObj.mjOBJ_GEOM, g) or ''
    bn=mujoco.mj_id2name(m, mujoco.mjtObj.mjOBJ_BODY, m.geom_bodyid[g]) or ''
    s=(bn+'|'+n)
    s=re.sub(r'\d+','#',s)
    return s[:40]
c=collections.Counter()
for i in range(m.npair):
    a,bb=sorted([cls(m.pair_geom1[i]), cls(m.pair_geom2[i])]); c[(re.sub(r'\|.*','',a), re.sub(r'\|.*','',bb))]+=1
print(os.path.basename(root), "npair", m.npair)
for k,v in c.most_common(25): print(f"  {v:4d}  {k}")
