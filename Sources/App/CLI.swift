import Cocoa
import SceneKit

// Sim seed. `--seed N` pins every sim in this process. Without it the CLI
// diagnostic modes use the shipped default, so --simtest/--behaviortest/
// --gpucheck/--brainstats/--brainshot stay reproducible, and the live app draws
// a fresh seed per launch (two launches are not the same fly).
let seedOverride: UInt32? = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--seed"), i + 1 < a.count else { return nil }
    let t = a[i + 1]
    let hex = t.hasPrefix("0x") || t.hasPrefix("0X")
    return UInt32(hex ? String(t.dropFirst(2)) : t, radix: hex ? 16 : 10)
}()
let SIM_SEED: UInt32 = seedOverride ?? 0x5EED_1F1F
func launchSeed() -> UInt32 { seedOverride ?? .random(in: 1...UInt32.max) }

let args = CommandLine.arguments

func dispatchCLI() {
    #if DIAGNOSTICS
    if args.contains(where: { $0.hasSuffix("test") || $0.hasSuffix("loop") }) { LabLanguage.pinForTests(.english) }
    let flags: [(String, (Int) -> Void)] = [
        ("--snapshot", { i in runSnapshot(path: args.count > i + 1 ? args[i + 1] : "preview.png"); exit(0) }),
        ("--brainshot", { i in runBrainshot(path: args.count > i + 1 ? args[i + 1] : "brain.png"); exit(0) }),
        ("--observationaudittest", { _ in runObservationAuditTest() }),
        ("--observetest", { _ in runObservationTest() }),
        ("--registrytest", { _ in runRegistryTest() }),
        ("--eventwindowtest", { _ in runEventWindowTest() }),
        ("--timelinetest", { _ in runTimelineTest() }),
        ("--gpucheck", { _ in runGPUCheck() }),
        ("--bridgetest", { _ in runBridgeTest() }),
        ("--worldeditortest", { _ in runWorldEditorTest() }),
        ("--envpanelshot", { i in
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                fputs("usage: --envpanelshot DIRECTORY\n", stderr); exit(2)
            }
            runEnvironmentPanelShot(directory: args[i + 1])
        }),
        ("--labtest", { _ in runLabTest() }),
        ("--v4test", { _ in runV4SessionTest() }),
        ("--v4sessiontest", { _ in runV4SessionTest() }),
        ("--v4loop", { _ in runV4LoopTest() }),
        ("--v4timingtest", { _ in runV4TimingTest() }),
        ("--bridgeloop", { _ in runBridgeLoopTest() }),
        ("--sceneloop", { _ in runSceneLoopTest() }),
        ("--labloop", { _ in runLabLoopTest() }),
        ("--inputprobe", { _ in runInputProbe() }),
        ("--interactionloop", { _ in runInteractionLoopTest() }),
        ("--simtest", { _ in runSimtest() }),
        ("--behaviortest", { _ in runBehaviorTest() }),
        ("--brainstats", { i in runBrainStats(seconds: args.count > i + 1 ? Int(args[i + 1]) ?? 5 : 5) })
    ]
    for (flag, run) in flags { if let i = args.firstIndex(of: flag) { run(i) } }
    #else
    if args.contains(where: { $0.hasPrefix("--") && ($0.hasSuffix("test") || $0.hasSuffix("loop") ||
        ["--gpucheck", "--simtest", "--brainstats", "--snapshot", "--brainshot", "--envpanelshot", "--inputprobe"].contains($0)) }) {
        fputs("diagnostics not compiled in\n", stderr); exit(2)
    }
    #endif
}
