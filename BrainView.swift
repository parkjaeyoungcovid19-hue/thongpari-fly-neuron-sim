// BrainView.swift — live visualization of the real FlyWire v783 brain: all
// 139,255 somas as a rotating point cloud, the escape circuit highlighted on
// top, and LIF spikes flashing at real neuron locations.

import Cocoa
import SceneKit
import simd

private func pointCloud(positions: [SIMD3<Float>], colors: [SIMD4<Float>],
                        rMin: CGFloat, rMax: CGFloat) -> SCNGeometry {
    let vData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
    let vSrc = SCNGeometrySource(data: vData, semantic: .vertex,
                                 vectorCount: positions.count, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: 4,
                                 dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
    let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
    let cSrc = SCNGeometrySource(data: cData, semantic: .color,
                                 vectorCount: colors.count, usesFloatComponents: true,
                                 componentsPerVector: 4, bytesPerComponent: 4,
                                 dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
    let idx = Array(0..<UInt32(positions.count))
    let iData = idx.withUnsafeBufferPointer { Data(buffer: $0) }
    let elem = SCNGeometryElement(data: iData, primitiveType: .point,
                                  primitiveCount: positions.count, bytesPerIndex: 4)
    elem.pointSize = 0.05
    elem.minimumPointScreenSpaceRadius = rMin
    elem.maximumPointScreenSpaceRadius = rMax
    let g = SCNGeometry(sources: [vSrc, cSrc], elements: [elem])
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.blendMode = .add
    m.writesToDepthBuffer = false
    m.readsFromDepthBuffer = false
    g.materials = [m]
    return g
}

// super_class palette (index order from etl.py)
private let CLASS_COLORS: [SIMD4<Float>] = [
    SIMD4(0.16, 0.22, 0.34, 1),   // optic — dim blue (majority, keep subtle)
    SIMD4(0.45, 0.33, 0.16, 1),   // central — amber
    SIMD4(0.14, 0.36, 0.34, 1),   // sensory — teal
    SIMD4(0.10, 0.48, 0.62, 1),   // visual_projection — cyan
    SIMD4(0.38, 0.22, 0.55, 1),   // visual_centrifugal — violet
    SIMD4(0.62, 0.28, 0.10, 1),   // descending — orange
    SIMD4(0.20, 0.45, 0.18, 1),   // ascending — green
    SIMD4(0.55, 0.14, 0.14, 1),   // motor — red
    SIMD4(0.50, 0.25, 0.40, 1),   // endocrine — pink
    SIMD4(0.17, 0.42, 0.26, 1),   // sensory_ascending — teal-green
]

struct BrainScene {
    let scene: SCNScene
    let cameraNode: SCNNode
    let brainGroup: SCNNode
    let flashPool: [SCNNode]
}

// Tuning. The cloud is 139,255 additive sprites in a 340x280 panel, 6x the
// strided cloud this window was drawn for, so the palette is dimmed and the
// sprites shrunk rather than neurons dropped. Flashes: the bus carries up to 12
// sampled spikers per simulated ms (~245 of 139k fire each ms), i.e. hundreds
// of events per rendered frame — light a spread-out slice of them so the panel
// twinkles instead of strobing. ~65 halos live at once (6 x 30 fps x 0.36 s);
// the pool is big enough that a node is never recycled mid-fade.
private let CLOUD_DIM: Float = 0.25
private let FLASHES_PER_FRAME = 6
private let FLASH_FADE = 0.36, FLASH_FADE_GF = 0.7
private let FLASH_POOL = 96
private let PICK_RADIUS: Float = 0.6   // world units; ~370 somas at median density
private let PICK_MAX = 400             // cap where the brain packs tighter

func buildBrainScene(connectome: Connectome, sim: MetalSim) -> BrainScene {
    let scene = SCNScene()
    scene.background.contents = NSColor(calibratedRed: 0.03, green: 0.035, blue: 0.06, alpha: 1)

    let group = SCNNode()
    scene.rootNode.addChildNode(group)

    // every soma in the connectome, coloured by super_class
    let cols: [SIMD4<Float>] = (0..<connectome.n).map { i in
        let ci = Int(connectome.superClass[i])
        var c = ci < CLASS_COLORS.count ? CLASS_COLORS[ci] : SIMD4<Float>(0.3, 0.3, 0.3, 1)
        c *= CLOUD_DIM
        c.w = 1
        return c
    }
    group.addChildNode(SCNNode(geometry: pointCloud(positions: connectome.positions, colors: cols,
                                                    rMin: 0.5, rMax: 1.1)))

    // circuit overlay: brighter points at the 378 role-tagged neurons
    var cpts: [SIMD3<Float>] = []
    var ccols: [SIMD4<Float>] = []
    for i in connectome.roleIndices.dropFirst().joined() {   // [0] is "other"
        cpts.append(sim.positions[i])
        switch sim.roles[i] {
        case "lc4", "lplc2":  ccols.append(SIMD4(0.15, 0.85, 1.0, 1))
        case "dna01", "dna02": ccols.append(SIMD4(1.0, 0.55, 0.10, 1))
        case "mdn":           ccols.append(SIMD4(1.0, 0.20, 0.80, 1))
        case "dnp09":         ccols.append(SIMD4(0.25, 1.0, 0.35, 1))
        case "dng11":         ccols.append(SIMD4(0.75, 0.55, 1.0, 1))
        case "escw":          ccols.append(SIMD4(1.0, 0.35, 0.25, 1))
        case "gf":            ccols.append(SIMD4(1.0, 0.95, 0.4, 1))
        default:              ccols.append(SIMD4(0.45, 0.45, 0.50, 1))   // ascend / sens
        }
    }
    group.addChildNode(SCNNode(geometry: pointCloud(positions: cpts, colors: ccols, rMin: 1.6, rMax: 2.6)))

    // the two giant fibers get actual glowing markers
    for i in connectome.roleIndices[Int(Role.gf)] {
        let s = SCNSphere(radius: 0.28)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.emission.contents = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.25, alpha: 1)
        m.blendMode = .add
        s.materials = [m]
        let node = SCNNode(geometry: s)
        node.position = SCNVector3(CGFloat(sim.positions[i].x), CGFloat(sim.positions[i].y),
                                   CGFloat(sim.positions[i].z))
        node.opacity = 0.35
        group.addChildNode(node)
    }

    // spike flash pool
    var pool: [SCNNode] = []
    let flashGeo = SCNSphere(radius: 0.16)
    let fm = SCNMaterial()
    fm.lightingModel = .constant
    fm.diffuse.contents = NSColor.black
    fm.emission.contents = NSColor(calibratedRed: 0.75, green: 0.95, blue: 1.0, alpha: 1)
    fm.blendMode = .add
    flashGeo.materials = [fm]
    for _ in 0..<FLASH_POOL {
        let node = SCNNode(geometry: flashGeo)
        node.isHidden = true
        group.addChildNode(node)
        pool.append(node)
    }

    // slow rotation about the vertical axis
    group.runAction(.repeatForever(.rotateBy(x: 0, y: 0.35, z: 0, duration: 6)))
    group.eulerAngles = SCNVector3(-0.15, 0, 0)

    let camera = SCNCamera()
    camera.fieldOfView = 46
    camera.zNear = 1
    camera.zFar = 120
    let camNode = SCNNode()
    camNode.camera = camera
    camNode.position = SCNVector3(0, 0.6, 29)
    scene.rootNode.addChildNode(camNode)

    return BrainScene(scene: scene, cameraNode: camNode, brainGroup: group, flashPool: pool)
}

// Drains the spike bus inside the brain view's own render loop.
final class BrainRenderDriver: NSObject, SCNSceneRendererDelegate {
    let sim: MetalSim
    let flashPool: [SCNNode]
    private var next = 0

    init(sim: MetalSim, flashPool: [SCNNode]) {
        self.sim = sim
        self.flashPool = flashPool
    }

    func flash(neuron: Int, isGF: Bool) {
        guard neuron < sim.n, !flashPool.isEmpty else { return }
        let node = flashPool[next]
        next = (next + 1) % flashPool.count
        let p = sim.positions[neuron]
        node.position = SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))
        node.isHidden = false
        node.removeAllActions()
        node.opacity = isGF ? 1.0 : 0.8
        node.scale = isGF ? SCNVector3(3.2, 3.2, 3.2) : SCNVector3(1, 1, 1)
        node.runAction(.sequence([.fadeOut(duration: isGF ? FLASH_FADE_GF : FLASH_FADE), .hide()]))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let bus = sim.spikeBus else { return }
        let batch = bus.popAll()
        guard !batch.isEmpty else { return }
        // Take the slice evenly across the batch so the halos land all over the
        // brain rather than all inside the last simulated millisecond, and never
        // drop a giant fiber (only ~5% of its spikes survive the GPU sampler).
        let step = max(1, batch.count / FLASHES_PER_FRAME)
        var lit = 0
        for (k, e) in batch.enumerated() where e.isGF || (k % step == 0 && lit < FLASHES_PER_FRAME) {
            if !e.isGF { lit += 1 }
            flash(neuron: e.neuron, isGF: e.isGF)
        }
    }
}

// SCNView that reports clicks and hover state without needing key focus.
final class BrainSCNView: SCNView {
    var onClick: ((NSPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

final class BrainWindowController {
    let panel: NSPanel
    let driver: BrainRenderDriver
    private let sim: MetalSim
    private let conn: Connectome
    private let brainGroup: SCNNode
    private let view: BrainSCNView
    var embeddedView: BrainSCNView { view }
    /// Called after a click stimulates a cluster (indices, cluster name,
    /// strength, duration ms) so a host such as the Lab can record the direct
    /// neural intervention. The stimulation itself happens here either way.
    var onClickStimulus: (([Int], String, Float, Int) -> Void)?
    private let stimRing: SCNNode
    private let label = NSTextField(labelWithString: "")
    private var labelHider: DispatchWorkItem?

    init(connectome: Connectome, sim: MetalSim, screen: NSScreen) {
        self.sim = sim
        self.conn = connectome
        let size = NSSize(width: 340, height: 280)
        let vis = screen.visibleFrame
        let origin = NSPoint(x: vis.maxX - size.width - 18, y: vis.minY + 18)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Fly Brain — FlyWire v783 (click = stimulate)"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces]

        let bs = buildBrainScene(connectome: connectome, sim: sim)
        brainGroup = bs.brainGroup
        driver = BrainRenderDriver(sim: sim, flashPool: bs.flashPool)

        // reusable stimulation ring
        let ringGeo = SCNSphere(radius: 0.9)
        let rm = SCNMaterial()
        rm.lightingModel = .constant
        rm.diffuse.contents = NSColor.black
        rm.emission.contents = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.5, alpha: 1)
        rm.blendMode = .add
        rm.transparency = 0.18
        rm.isDoubleSided = true
        ringGeo.materials = [rm]
        stimRing = SCNNode(geometry: ringGeo)
        stimRing.isHidden = true
        bs.brainGroup.addChildNode(stimRing)

        view = BrainSCNView(frame: NSRect(origin: .zero, size: size))
        view.scene = bs.scene
        view.pointOfView = bs.cameraNode
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.delegate = driver
        view.isPlaying = true
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        label.layer?.cornerRadius = 6
        label.isHidden = true
        view.addSubview(label)

        view.onHover = { [weak self] hovering in
            self?.brainGroup.isPaused = hovering   // hold the rotation while aiming
        }
        view.onClick = { [weak self] p in self?.handleClick(at: p) }
    }

    private func handleClick(at p: NSPoint) {
        let near = view.unprojectPoint(SCNVector3(p.x, p.y, 0))
        let far = view.unprojectPoint(SCNVector3(p.x, p.y, 1))
        let group = brainGroup.presentation
        let a = group.simdConvertPosition(SIMD3<Float>(Float(near.x), Float(near.y), Float(near.z)), from: nil)
        let b = group.simdConvertPosition(SIMD3<Float>(Float(far.x), Float(far.y), Float(far.z)), from: nil)
        let d = simd_normalize(b - a)

        // Nearest neuron to the click ray. A ray through the slab grazes hundreds
        // of somas, so break the near-tie towards the camera: 0.002 x depth is
        // worth about a 0.2-unit miss, i.e. a few pixels.
        var best = -1
        var bestScore = Float.greatestFiniteMagnitude
        for i in 0..<sim.n {
            let ap = sim.positions[i] - a
            let t = simd_dot(ap, d)
            let score = simd_length_squared(ap - t * d) + t * 0.002
            if score < bestScore { bestScore = score; best = i }
        }
        guard best >= 0 else { return }
        let anchor = sim.positions[best]

        // its neighbourhood: 139k neurons, so measure once and sort the shortlist
        var neigh: [(d: Float, i: Int)] = []
        for i in 0..<sim.n {
            let dd = simd_distance_squared(sim.positions[i], anchor)
            if dd < PICK_RADIUS * PICK_RADIUS { neigh.append((dd, i)) }
        }
        neigh.sort { $0.d < $1.d }
        let picked = neigh.prefix(PICK_MAX).map { $0.i }   // never empty: the anchor is in it

        let strength: Float = 0.25, durationMs = 400
        sim.stimulate(picked, strength: strength, durationMs: durationMs)
        for k in stride(from: 0, to: picked.count, by: max(1, picked.count / 24)) {
            driver.flash(neuron: picked[k], isGF: false)   // light the whole ball, not its core
        }
        flashRing(at: anchor)
        let name = regionName(for: picked)
        showLabel(name)
        onClickStimulus?(picked, name, strength, durationMs)
    }

    /// A role population is 2-210 neurons out of 139k, so it never wins a plain
    /// majority of a cluster: name the role if the click reached one at all
    /// (the giant fiber first), otherwise the cluster's dominant cell types.
    private func regionName(for picked: [Int]) -> String {
        var counts: [String: Int] = [:]
        for i in picked where conn.role[i] != Role.other { counts[conn.roleName[i], default: 0] += 1 }
        let major = counts["gf"] != nil ? "gf" : (counts.max { $0.value < $1.value }?.key ?? "other")
        let sideSuffix: (String) -> String = { role in
            let l = picked.filter { self.conn.roleName[$0] == role && self.sim.positions[$0].x < 0 }.count
            let r = picked.filter { self.conn.roleName[$0] == role }.count - l
            return l == r ? "" : (l > r ? L(" · left", " · 왼쪽") : L(" · right", " · 오른쪽"))
        }
        if major != "other", let name = NeuronGuide.clusterLabel(role: major) {
            let sided = ["lc4", "lplc2", "dna01", "dna02"].contains(major)
            return "⚡ \(name)\(sided ? sideSuffix(major) : "")"
        }
        switch major {
        default:
            var types: [String: Int] = [:], classes: [String: Int] = [:]
            for i in picked {
                types[conn.typeName[i], default: 0] += 1
                classes[conn.superClassNames[Int(conn.superClass[i])], default: 0] += 1
            }
            let region = classes.max { $0.value < $1.value }?.key ?? "brain"
            let top = types.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                           .prefix(2).map(\.key).filter { $0 != region && $0 != "?" }
            return top.isEmpty ? L("⚡ \(picked.count) \(region) neurons", "⚡ \(region) 뉴런 \(picked.count)개")
                               : "⚡ \(top.joined(separator: " + ")) · \(region) (\(picked.count))"
        }
    }

    private func flashRing(at pos: SIMD3<Float>) {
        stimRing.position = SCNVector3(CGFloat(pos.x), CGFloat(pos.y), CGFloat(pos.z))
        stimRing.removeAllActions()
        stimRing.isHidden = false
        stimRing.opacity = 1
        stimRing.scale = SCNVector3(0.5, 0.5, 0.5)
        stimRing.runAction(.group([.scale(to: 1.4, duration: 0.55),
                                   .sequence([.fadeOut(duration: 0.55), .hide()])]))
    }

    private func showLabel(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        let w = label.frame.width + 16
        label.frame = NSRect(x: (view.bounds.width - w) / 2, y: 10, width: w, height: label.frame.height + 6)
        label.isHidden = false
        labelHider?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.label.isHidden = true }
        labelHider = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    var isVisible: Bool { panel.isVisible }
    func show() { panel.orderFront(nil) }
    func hide() { panel.orderOut(nil) }

    func move(to screen: NSScreen) {
        let size = panel.frame.size
        let vis = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vis.maxX - size.width - 18, y: vis.minY + 18))
    }
}
