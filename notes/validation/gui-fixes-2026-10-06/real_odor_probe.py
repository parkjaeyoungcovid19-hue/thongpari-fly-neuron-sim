"""Real FlyGym body: body-packet odor distance must use the thorax, not the origin."""
import sys; sys.path.insert(0, ".")
from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
try:
    w = body.lab_world
    w.spawn_object(shape="food", object_id="probe_food", position_mm=[20, 12, 0.7], size_mm=2)
    pkt = None
    for _ in range(20):
        pkt = body.step(LocomotorCommand(forward=0.0), 0.01)
    thorax = [float(v) for v in body._thorax_position()]
    heading = 0.0
    from_thorax = w.food_odor(fly_position_mm=thorax)["nearest_food_distance_mm"]
    from_origin = w.food_odor(fly_position_mm=[0, 0, 0])["nearest_food_distance_mm"]
    got = pkt.nearest_food_distance_mm
    print(f"thorax {[round(v,3) for v in thorax]}  packet {got:.4f}  from_thorax {from_thorax:.4f}  from_origin {from_origin:.4f}")
    ok = abs(got - from_thorax) < 0.05 and abs(got - from_origin) > 0.2
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
finally:
    body.close()
