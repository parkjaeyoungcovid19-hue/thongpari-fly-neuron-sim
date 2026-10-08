import Cocoa
import SceneKit

#if DIAGNOSTICS
// MARK: - Offscreen render modes

func offscreenRender(_ scene: SCNScene, camNode: SCNNode, size: CGSize, path: String) {
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    renderer.pointOfView = camNode
    let img = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    savePNG(img, to: path)
    print("snapshot written to \(path)")
}

func runSnapshot(path: String) {
    let scene = SCNScene()
    scene.background.contents = NSColor(calibratedWhite: 0.94, alpha: 1)
    let fly = Fly(at: .zero)
    fly.heading = .pi / 2
    for (i, leg) in fly.model.legs.enumerated() {
        leg.angle = [0.25, -0.2, -0.22, 0.28, 0.2, -0.25][i]
        leg.lift = [0.35, 0, 0, 0.3, 0, 0.35][i]
        leg.apply()
    }
    fly.syncNode()
    scene.rootNode.addChildNode(fly.node)
    let camera = SCNCamera()
    camera.fieldOfView = 42
    let camNode = SCNNode()
    camNode.camera = camera
    camNode.position = SCNVector3(30, -58, 42)
    let lookAt = SCNLookAtConstraint(target: fly.node)
    lookAt.isGimbalLockEnabled = true
    camNode.constraints = [lookAt]
    scene.rootNode.addChildNode(camNode)
    let key = SCNLight(); key.type = .directional; key.intensity = 1100
    let keyNode = SCNNode(); keyNode.light = key
    keyNode.eulerAngles = SCNVector3(-0.9, 0.5, 0)
    scene.rootNode.addChildNode(keyNode)
    let amb = SCNLight(); amb.type = .ambient; amb.intensity = 500
    let ambNode = SCNNode(); ambNode.light = amb
    scene.rootNode.addChildNode(ambNode)
    offscreenRender(scene, camNode: camNode, size: CGSize(width: 720, height: 720), path: path)
}

func runBrainshot(path: String) {
    guard let c = loadConnectome(),
          let sim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) else {
        fputs("no data/ — run etl.py first\n", stderr); exit(1)
    }
    let bs = buildBrainScene(connectome: c, sim: sim)
    bs.brainGroup.removeAllActions()
    bs.brainGroup.eulerAngles = SCNVector3(-0.15, 0.5, 0)
    // decorate with a burst of fake spikes so the preview shows the live look
    let driver = BrainRenderDriver(sim: sim, flashPool: bs.flashPool)
    for _ in 0..<40 { driver.flash(neuron: Int.random(in: 0..<sim.n), isGF: false) }
    if let gfIdx = sim.gf.first { driver.flash(neuron: gfIdx, isGF: true) }
    for node in bs.flashPool { node.removeAllActions() }   // freeze mid-flash
    offscreenRender(bs.scene, camNode: bs.cameraNode, size: CGSize(width: 720, height: 560), path: path)
}

#endif
