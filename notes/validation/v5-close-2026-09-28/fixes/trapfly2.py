import sys, os, numpy as np
root=sys.argv[1]; sys.path.insert(0, os.path.join(root,"flygym_bridge")); os.chdir(root)
import mujoco
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
b=RealFlyBody(config={},show_viewer=False); b.vision_period=1e9; w=b.lab_world; idle=LocomotorCommand(forward=0)
m,d=w.model,w.data
x,y,_=b._thorax_position()
w.spawn_object(shape="trap",object_id="t",position_mm=[x,y,10])
slot=w.objects["t"].slot
solid=set(w._solid_by_slot.get(slot, []))
flyb=[i for i in range(m.nbody) if (mujoco.mj_id2name(m,mujoco.mjtObj.mjOBJ_BODY,i) or "").startswith("fly/")]
flyg=set(g for g in range(m.ngeom) if m.geom_bodyid[g] in flyb)
ev=[]; contacts=0; states=[]
for i in range(1000):
    b.step_exact(idle,1); ev+=[e["event"] for e in w.drain_events()]
    for c in d.contact[:d.ncon]:
        if (c.geom1 in solid and c.geom2 in flyg) or (c.geom2 in solid and c.geom1 in flyg): contacts+=1
    st=w.objects["t"].trap_state
    if not states or states[-1]!=st: states.append(st)
o=w.objects["t"]; S_=o.size_mm[0]; half=S_/2
p=np.array([d.xpos[i] for i in flyb]); cx,cy=o.position_mm[0],o.position_mm[1]
inner=np.max(np.maximum(abs(p[:,0]-cx),abs(p[:,1]-cy)))
print("states",states,"final z",round(o.position_mm[2],2),"events",ev)
print("trap↔fly contacts during 1000 substeps:",contacts)
print(f"fly bodies max |dx|,|dy| from trap centre {inner:.2f} mm vs wall half-extent {half:.1f} mm; lowest fly body z {p[:,2].min():.2f}")
