#if DIAGNOSTICS
import Foundation

final class Suite {
    var failures = 0
    private(set) var count = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        print((ok ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !ok { failures += 1 }
    }
    func finish() -> Never {
        print("CHECKS \(count); FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

func makeDiagSim(connectome: Connectome, spikeBus: SpikeBus? = nil, seed: UInt32 = SIM_SEED) -> MetalSim? {
    let sim = MetalSim(connectome: connectome, spikeBus: spikeBus, seed: seed)
    sim?.perfLogIntervalMs = 0
    return sim
}
#endif
