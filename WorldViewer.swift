// WorldViewer.swift — V5.1 read-only SceneKit mirror of one atomic backend
// world_render_snapshot. This view never advances or mutates MuJoCo state.

import Cocoa
import SceneKit

struct WorldViewerRay {
    let originMM: [Double]
    let direction: [Double]
}

struct WorldViewerSnapshotSource: Equatable {
    let snapshotSeq: Int
    let worldRevision: Int
    let simTick: Int
}

enum WorldViewerCameraMode: String, CaseIterable {
    case orbit
    case followFly
    case free
    case firstPerson
    case behindParticipant

    var title: String {
        switch self {
        case .orbit: return L("Orbit arena", "경기장 둘러보기")
        case .followFly: return L("Follow fly", "파리 따라가기")
        case .free: return L("Free", "자유 시점")
        case .firstPerson: return L("Participant — first person", "참여자 1인칭")
        case .behindParticipant: return L("Participant — third person", "참여자 3인칭")
        }
    }

    /// Modes whose camera is carried by the participant body.
    var ridesParticipant: Bool { self == .firstPerson || self == .behindParticipant }
}

struct WorldViewerCameraState: Equatable {
    var mode: WorldViewerCameraMode = .orbit
    var yaw: Double = Double.pi * 0.25
    var pitch: Double = 0.52
    var distance: Double = 190
    var targetScene: [Double] = [0, 0, 0]
    var freePositionScene: [Double] = [120, 110, 150]

    mutating func rotate(deltaX: Double, deltaY: Double) {
        yaw -= deltaX * 0.008
        pitch = min(1.35, max(-1.20, pitch + deltaY * 0.008))
    }

    mutating func zoom(delta: Double) {
        if mode == .free {
            let forward = forwardVector
            let scale = max(1.0, distance * 0.018)
            // Match Orbit/Follow scroll semantics: positive delta zooms/dollies
            // out, negative delta zooms/dollies in toward the look direction.
            for i in 0..<3 { freePositionScene[i] -= forward[i] * delta * scale }
        } else {
            distance = min(3000, max(2.5, distance * exp(delta * 0.035)))
        }
    }

    mutating func pan(deltaX: Double, deltaY: Double) {
        let right = [cos(yaw), 0.0, -sin(yaw)]
        let up = [0.0, 1.0, 0.0]
        let scale = max(0.01, distance * 0.0025)
        let dx = -deltaX * scale
        let dy = deltaY * scale
        if mode == .free {
            for i in 0..<3 { freePositionScene[i] += right[i] * dx + up[i] * dy }
        } else {
            for i in 0..<3 { targetScene[i] += right[i] * dx + up[i] * dy }
        }
    }

    var forwardVector: [Double] {
        let cp = cos(pitch)
        return [-sin(yaw) * cp, -sin(pitch), -cos(yaw) * cp]
    }
}

enum WorldViewerPickDisposition: Equatable {
    case ignore
    case showError
    case applySuccess
}

/// Decide whether one authoritative pick ACK belongs to the latest click and,
/// for successful hit/miss results, whether it may be applied to the current
/// semantic scene. Error ACKs deliberately do not depend on the current displayed
/// revision: otherwise a useful backend rejection can disappear just because the
/// viewer advanced to a newer pose snapshot before the ACK arrived. The backend
/// already validates the source snapshot's structural provenance before returning
/// ok=true; WorldViewer.apply then resolves the semantic target against the nodes
/// in the currently displayed authoritative snapshot.
func worldViewerPickDisposition(_ pick: RayPickResult,
                                latestRequestSeq: Int?,
                                consumedSeq: Int?,
                                expectedSource: WorldViewerSnapshotSource?) -> WorldViewerPickDisposition {
    guard let latestRequestSeq, let expectedSource,
          pick.seq == latestRequestSeq, pick.seq != consumedSeq,
          pick.sourceSnapshotSeq == expectedSource.snapshotSeq,
          pick.sourceWorldRevision == expectedSource.worldRevision,
          pick.sourceSimTick == expectedSource.simTick else {
        return .ignore
    }
    if !pick.ok {
        return .showError
    }
    return .applySuccess
}

/// Right-handed basis conversion between MuJoCo's z-up world and SceneKit's
/// conventional y-up world. C = Rx(-90°): (x,y,z) -> (x,z,-y).
enum WorldViewerCoordinates {
    static func sceneComponents(fromMuJoCo v: [Double]) -> [Double] {
        [v[0], v[2], -v[1]]
    }

    static func mujocoComponents(fromScene v: [Double]) -> [Double] {
        [v[0], -v[2], v[1]]
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        let ax = a[0], ay = a[1], az = a[2], aw = a[3]
        let bx = b[0], by = b[1], bz = b[2], bw = b[3]
        return [
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        ]
    }

    static func sceneQuaternionXYZW(fromMuJoCo q: [Double]) -> [Double] {
        let h = sqrt(0.5)
        let c = [-h, 0.0, 0.0, h]
        let cInverse = [h, 0.0, 0.0, h]
        return multiply(multiply(c, q), cInverse)
    }

    static func sceneVector(_ values: [Double]) -> SCNVector3 {
        let s = sceneComponents(fromMuJoCo: values)
        return SCNVector3(Float(s[0]), Float(s[1]), Float(s[2]))
    }

    static func sceneQuaternion(_ values: [Double]) -> SCNQuaternion {
        let q = sceneQuaternionXYZW(fromMuJoCo: values)
        return SCNQuaternion(Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3]))
    }
}

struct WorldViewerMuJoCoCamera: Equatable {
    let positionMM: [Double]
    let forward: [Double]
    let distanceMM: Double
    let fovyDeg: Double
    /// Lets the renderer attach the camera to the live pose at render time
    /// ("fly", "participant_first", "participant_third"), so following views
    /// move at the frame rate rather than the 10 Hz snapshot rate.
    var anchor: String? = nil
    /// Camera position minus fly position (MuJoCo mm) for the "fly" anchor.
    var offsetMM: [Double]? = nil
}

final class WorldViewer: SCNView {
    var onPickRay: ((WorldViewerRay) -> Void)?
    var onPlayerKeyDown: ((UInt16, Bool) -> Void)?
    var onPlayerKeyUp: ((UInt16) -> Void)?
    var onPlayerLookDelta: ((Double, Double) -> Void)?
    var onPlayerFocusLost: (() -> Void)?
    var onPlayerCaptureRequested: (() -> Void)?
    var onCameraChanged: (() -> Void)?
    /// Set while MuJoCo's rendering covers the mirror: it shows the real
    /// NeuroMechFly body (~3 mm), so a reset frames the fly, not the arena.
    var prefersFlyCloseUp = false
    var participateModeEnabled = false
    var participateInputEnabled = false {
        didSet {
            if !participateInputEnabled { lastRightDragPoint = nil }
        }
    }
    override var acceptsFirstResponder: Bool { true }

    private let worldScene = SCNScene()
    private let cameraNode = SCNNode()
    private let groundNode = SCNNode()
    private var objectNodes: [String: SCNNode] = [:]
    private var objectRevisions: [String: Int] = [:]
    private var flyNode: SCNNode?
    private var playerNode: SCNNode?
    private(set) var currentSnapshotSource: WorldViewerSnapshotSource?
    private var selectedNode: SCNNode?
    private var selectedOriginalEmission: Any?
    private(set) var cameraState = WorldViewerCameraState()
    private var lastRightDragPoint: NSPoint?
    private var lastSceneCenter = SCNVector3Zero
    private var lastSceneExtent: CGFloat = 80
    private var lastFlyScenePosition: SCNVector3?
    /// Latest participant pose from the backend, MuJoCo coordinates (mm, z-up).
    private var lastParticipantPose: (positionMM: [Double], quatXYZW: [Double], radiusMM: Double)?
    private var leftDragStart: NSPoint?
    private var leftDragLast: NSPoint?
    private var leftDragMoved = false
    private var needsInitialCameraFrame = true
    private var playerTrackingArea: NSTrackingArea?

    var cameraScenePositionForTesting: [Double] {
        [Double(cameraNode.position.x), Double(cameraNode.position.y), Double(cameraNode.position.z)]
    }

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        configureScene()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureScene()
    }

    private func configureScene() {
        scene = worldScene
        backgroundColor = NSColor.windowBackgroundColor
        allowsCameraControl = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 30

        let ground = SCNBox(width: 2000, height: 0.2, length: 2000, chamferRadius: 0)
        let groundMaterial = SCNMaterial()
        groundMaterial.diffuse.contents = NSColor(calibratedWhite: 0.40, alpha: 1)
        groundMaterial.roughness.contents = 0.9
        ground.materials = [groundMaterial]
        groundNode.geometry = ground
        groundNode.position = SCNVector3(0, -0.12, 0)
        groundNode.name = "__ground__"
        worldScene.rootNode.addChildNode(groundNode)

        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.zNear = 0.2
        camera.zFar = 5000
        cameraNode.camera = camera
        worldScene.rootNode.addChildNode(cameraNode)
        resetObservationCamera()
        // The static shell has no authoritative extent yet. The first backend
        // snapshot must still frame the actual fly/world rather than preserving
        // this placeholder origin camera.
        needsInitialCameraFrame = true
        pointOfView = cameraNode

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.8, 0.2, -0.5)
        worldScene.rootNode.addChildNode(keyNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 450
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        worldScene.rootNode.addChildNode(ambientNode)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let playerTrackingArea { removeTrackingArea(playerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        playerTrackingArea = area
    }

    private func cameraTargetForCurrentMode() -> SCNVector3 {
        if cameraState.mode == .followFly, let lastFlyScenePosition {
            return lastFlyScenePosition
        }
        return SCNVector3(Float(cameraState.targetScene[0]),
                          Float(cameraState.targetScene[1]),
                          Float(cameraState.targetScene[2]))
    }

    private func applyCameraState() {
        defer { onCameraChanged?() }
        if cameraState.mode.ridesParticipant, let pose = participantCameraPose() {
            cameraNode.position = WorldViewerCoordinates.sceneVector(pose.eye)
            cameraNode.look(at: WorldViewerCoordinates.sceneVector(pose.target),
                            up: SCNVector3(0, 1, 0),
                            localFront: SCNVector3(0, 0, -1))
            return
        }
        let target = cameraTargetForCurrentMode()
        if cameraState.mode == .free {
            let p = cameraState.freePositionScene
            cameraNode.position = SCNVector3(Float(p[0]), Float(p[1]), Float(p[2]))
            let f = cameraState.forwardVector
            let fx = CGFloat(f[0])
            let fy = CGFloat(f[1])
            let fz = CGFloat(f[2])
            let look = SCNVector3(cameraNode.position.x + fx,
                                  cameraNode.position.y + fy,
                                  cameraNode.position.z + fz)
            cameraNode.look(at: look,
                            up: SCNVector3(0, 1, 0),
                            localFront: SCNVector3(0, 0, -1))
            return
        }

        let distance = cameraState.distance
        let forward = cameraState.forwardVector
        cameraNode.position = SCNVector3(Float(Double(target.x) - forward[0] * distance),
                                         Float(Double(target.y) - forward[1] * distance),
                                         Float(Double(target.z) - forward[2] * distance))
        cameraNode.look(at: target,
                        up: SCNVector3(0, 1, 0),
                        localFront: SCNVector3(0, 0, -1))
    }

    /// Eye and look target for the participant-carried views, in MuJoCo
    /// coordinates. The participant's look quaternion is yaw(Z)·pitch(Y) with
    /// +X forward, exactly as the backend integrates the captured mouse.
    private func participantCameraPose() -> (eye: [Double], target: [Double])? {
        guard let pose = lastParticipantPose else { return nil }
        let q = pose.quatXYZW
        let (x, y, z, w) = (q[0], q[1], q[2], q[3])
        let forward = [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)]
        let p = pose.positionMM
        let r = pose.radiusMM
        if cameraState.mode == .firstPerson {
            // Just in front of the body's surface, so the body never fills the view.
            let eye = (0..<3).map { p[$0] + forward[$0] * r * 1.05 }
            return (eye, (0..<3).map { eye[$0] + forward[$0] * 10 })
        }
        let h = hypot(forward[0], forward[1])
        let flat = h > 1e-6 ? [forward[0] / h, forward[1] / h, 0] : [1, 0, 0]
        let eye = [p[0] - flat[0] * r * 5, p[1] - flat[1] * r * 5, p[2] + r * 2.2]
        return (eye, (0..<3).map { p[$0] + forward[$0] * r * 3 })
    }

    /// The observation camera in MuJoCo world coordinates (mm, z-up), so the
    /// backend's free camera can render exactly the view this canvas picks from.
    var mujocoCamera: WorldViewerMuJoCoCamera {
        let p = cameraNode.position
        let f = cameraNode.worldFront
        let distance: Double
        switch cameraState.mode {
        case .orbit, .followFly: distance = cameraState.distance
        case .free: distance = 100
        case .firstPerson, .behindParticipant: distance = 10
        }
        let positionMM = WorldViewerCoordinates.mujocoComponents(
            fromScene: [Double(p.x), Double(p.y), Double(p.z)])
        var camera = WorldViewerMuJoCoCamera(
            positionMM: positionMM,
            forward: WorldViewerCoordinates.mujocoComponents(
                fromScene: [Double(f.x), Double(f.y), Double(f.z)]),
            distanceMM: distance,
            fovyDeg: Double(cameraNode.camera?.fieldOfView ?? 42))
        switch cameraState.mode {
        case .followFly:
            if let fly = lastFlyScenePosition {
                let flyMM = WorldViewerCoordinates.mujocoComponents(
                    fromScene: [Double(fly.x), Double(fly.y), Double(fly.z)])
                camera.anchor = "fly"
                // Rounded so the fly's own motion never looks like a new request.
                camera.offsetMM = (0..<3).map { ((positionMM[$0] - flyMM[$0]) * 1e4).rounded() / 1e4 }
            }
        case .firstPerson where lastParticipantPose != nil:
            camera.anchor = "participant_first"
        case .behindParticipant where lastParticipantPose != nil:
            camera.anchor = "participant_third"
        default:
            break
        }
        return camera
    }

    func setObservationCameraMode(_ mode: WorldViewerCameraMode) {
        if mode == cameraState.mode { return }
        if cameraState.mode.ridesParticipant {
            // Leave the participant's eyes looking where they looked.
            let f = cameraNode.worldFront
            cameraState.pitch = min(1.35, max(-1.20, asin(-Double(f.y))))
            cameraState.yaw = atan2(-Double(f.x), -Double(f.z))
        }
        if mode == .orbit {
            // Orbit circles the whole arena: fly, participant and objects.
            cameraState.targetScene = [Double(lastSceneCenter.x),
                                       Double(lastSceneCenter.y),
                                       Double(lastSceneCenter.z)]
            cameraState.distance = max(45, Double(lastSceneExtent) * 2.4)
        } else if mode == .followFly && prefersFlyCloseUp {
            cameraState.distance = 14
        } else if mode == .free {
            let target = cameraTargetForCurrentMode()
            cameraState.targetScene = [Double(target.x), Double(target.y), Double(target.z)]
            cameraState.freePositionScene = [Double(cameraNode.position.x),
                                             Double(cameraNode.position.y),
                                             Double(cameraNode.position.z)]
        } else if cameraState.mode == .free {
            cameraState.targetScene = [Double(lastSceneCenter.x),
                                       Double(lastSceneCenter.y),
                                       Double(lastSceneCenter.z)]
        }
        cameraState.mode = mode
        applyCameraState()
    }

    func resetObservationCamera() {
        cameraState.yaw = Double.pi * 0.25
        cameraState.pitch = 0.52
        let flyCloseUp = prefersFlyCloseUp ? lastFlyScenePosition : nil
        let center = flyCloseUp ?? lastSceneCenter
        cameraState.distance = flyCloseUp != nil ? 14 : max(45, Double(lastSceneExtent) * 2.4)
        cameraState.targetScene = [Double(center.x), Double(center.y), Double(center.z)]
        let target = cameraTargetForCurrentMode()
        let forward = cameraState.forwardVector
        cameraState.freePositionScene = [Double(target.x) - forward[0] * cameraState.distance,
                                         Double(target.y) - forward[1] * cameraState.distance,
                                         Double(target.z) - forward[2] * cameraState.distance]
        applyCameraState()
        // A user may press Reset before the first backend snapshot or while a
        // session identity transition has cleared the scene. Keep the initial
        // authoritative reframe armed until a real snapshot is being applied.
        needsInitialCameraFrame = (currentSnapshotSource == nil)
    }

    func rotateObservationCamera(deltaX: Double, deltaY: Double) {
        // The participant's own look (captured mouse) steers these views.
        guard !cameraState.mode.ridesParticipant else { return }
        cameraState.rotate(deltaX: deltaX, deltaY: deltaY)
        applyCameraState()
    }

    func panObservationCamera(deltaX: Double, deltaY: Double) {
        // Follow mode's target is the authoritative fly pose; allowing a hidden
        // presentation offset here would make "follow" ambiguous. Switch to
        // Orbit or Free when a panned target is desired.
        guard cameraState.mode != .followFly, !cameraState.mode.ridesParticipant else { return }
        cameraState.pan(deltaX: deltaX, deltaY: deltaY)
        applyCameraState()
    }

    func zoomObservationCamera(delta: Double) {
        cameraState.zoom(delta: delta)
        applyCameraState()
    }

    private func material(for shape: String, collidable: Bool = true) -> SCNMaterial {
        let material = SCNMaterial()
        switch shape {
        case "food": material.diffuse.contents = NSColor.systemGreen
        case "sphere": material.diffuse.contents = NSColor.systemBlue
        case "wall": material.diffuse.contents = NSColor.systemGray
        case "fly": material.diffuse.contents = NSColor.systemOrange
        case "player": material.diffuse.contents = NSColor.systemPurple
        default: material.diffuse.contents = NSColor.systemTeal
        }
        material.roughness.contents = 0.65
        if !collidable { material.transparency = 0.72 }
        return material
    }

    private func geometry(for object: WorldRenderObject) -> SCNGeometry {
        let sx = CGFloat(object.sizeMM[0])
        let sy = CGFloat(object.sizeMM[1])
        let sz = CGFloat(object.sizeMM[2])
        let geometry: SCNGeometry
        if object.shape == "sphere" || object.shape == "food" {
            // Backend sphere/food slots use diameter in size_mm[0].
            geometry = SCNSphere(radius: max(0.05, sx * 0.5))
        } else {
            // MuJoCo xyz extents -> SceneKit width/height/length = x/z/y.
            geometry = SCNBox(width: max(0.1, sx), height: max(0.1, sz),
                              length: max(0.1, sy), chamferRadius: 0)
        }
        geometry.materials = [material(for: object.shape, collidable: object.collidable)]
        return geometry
    }

    private func ensureFlyNode() -> SCNNode {
        if let flyNode { return flyNode }
        let geometry = SCNSphere(radius: 1.0)
        geometry.materials = [material(for: "fly")]
        let node = SCNNode(geometry: geometry)
        node.scale = SCNVector3(2.5, 1.35, 1.0)
        node.name = "fly"
        worldScene.rootNode.addChildNode(node)
        flyNode = node
        return node
    }

    private func ensurePlayerNode() -> SCNNode {
        if let playerNode { return playerNode }
        let geometry = SCNSphere(radius: 1.0)
        geometry.materials = [material(for: "player")]
        let node = SCNNode(geometry: geometry)
        node.name = "player"
        worldScene.rootNode.addChildNode(node)
        playerNode = node
        return node
    }

    /// Apply exactly one owner-produced snapshot. No body/lab_state data is
    /// accepted here, which prevents accidentally inventing a mixed-time world.
    func apply(snapshot: WorldRenderSnapshot) {
        guard snapshot.ok, let snapshotID = snapshot.snapshotID,
              let revision = snapshot.revision, let fly = snapshot.fly else { return }
        let source = WorldViewerSnapshotSource(snapshotSeq: snapshotID,
                                               worldRevision: revision,
                                               simTick: snapshot.simTick)
        guard source != currentSnapshotSource else { return }
        currentSnapshotSource = source

        let activeIDs = Set(snapshot.objects.map(\.id))
        for id in Array(objectNodes.keys) where !activeIDs.contains(id) {
            objectNodes[id]?.removeFromParentNode()
            objectNodes.removeValue(forKey: id)
            objectRevisions.removeValue(forKey: id)
        }

        for object in snapshot.objects {
            let node: SCNNode
            if let existing = objectNodes[object.id] {
                node = existing
                if objectRevisions[object.id] != object.revision {
                    node.geometry = geometry(for: object)
                }
            } else {
                node = SCNNode(geometry: geometry(for: object))
                node.name = object.id
                worldScene.rootNode.addChildNode(node)
                objectNodes[object.id] = node
            }
            objectRevisions[object.id] = object.revision
            node.position = WorldViewerCoordinates.sceneVector(object.positionMM)
            node.orientation = WorldViewerCoordinates.sceneQuaternion(object.orientationQuatXYZW)
        }

        let f = ensureFlyNode()
        f.name = fly.id
        f.position = WorldViewerCoordinates.sceneVector(fly.positionMM)
        f.orientation = WorldViewerCoordinates.sceneQuaternion(fly.orientationQuatXYZW)
        lastFlyScenePosition = f.position

        if let player = snapshot.player {
            let p = ensurePlayerNode()
            p.name = player.id
            p.position = WorldViewerCoordinates.sceneVector(player.positionMM)
            p.orientation = WorldViewerCoordinates.sceneQuaternion(player.orientationQuatXYZW)
            if let radius = player.collisionRadiusMM, radius > 0 {
                p.scale = SCNVector3(Float(radius), Float(radius), Float(radius))
            }
            p.isHidden = false
            lastParticipantPose = (player.positionMM, player.orientationQuatXYZW,
                                   max(0.2, player.collisionRadiusMM ?? 2.5))
        } else {
            playerNode?.isHidden = true
            lastParticipantPose = nil
        }

        // Presentation-only framing. It cannot feed back into simulation state.
        var center = WorldViewerCoordinates.sceneVector(fly.positionMM)
        var maxExtent: CGFloat = 30
        var count: CGFloat = 1
        for object in snapshot.objects {
            let p = WorldViewerCoordinates.sceneVector(object.positionMM)
            center.x += p.x; center.y += p.y; center.z += p.z; count += 1
        }
        center.x /= count; center.y /= count; center.z /= count
        let flyScene = WorldViewerCoordinates.sceneVector(fly.positionMM)
        maxExtent = max(maxExtent, max(abs(flyScene.x - center.x), abs(flyScene.z - center.z)))
        for object in snapshot.objects {
            let p = WorldViewerCoordinates.sceneVector(object.positionMM)
            let size = CGFloat(object.sizeMM.max() ?? 1)
            let xExtent = abs(p.x - center.x) + size
            let zExtent = abs(p.z - center.z) + size
            let yExtent = abs(p.y - center.y) + size
            maxExtent = max(maxExtent, max(xExtent, max(zExtent, yExtent)))
        }
        lastSceneCenter = center
        lastSceneExtent = maxExtent
        if needsInitialCameraFrame {
            resetObservationCamera()
        } else if cameraState.mode == .followFly || cameraState.mode.ridesParticipant {
            applyCameraState()
        }
    }

    private func clearSelection() {
        if let old = selectedNode, let material = old.geometry?.firstMaterial {
            material.emission.contents = selectedOriginalEmission
        }
        selectedNode = nil
        selectedOriginalEmission = nil
    }

    /// Drop all backend-derived presentation state while preserving only the
    /// static camera/lights/ground shell. Identity transitions must never leave
    /// geometry or a pick highlight from the previous world visible.
    func clearSnapshot() {
        clearSelection()
        for node in objectNodes.values { node.removeFromParentNode() }
        objectNodes.removeAll(keepingCapacity: true)
        objectRevisions.removeAll(keepingCapacity: true)
        flyNode?.removeFromParentNode()
        flyNode = nil
        playerNode?.removeFromParentNode()
        playerNode = nil
        currentSnapshotSource = nil
        lastFlyScenePosition = nil
        lastParticipantPose = nil
        lastSceneCenter = SCNVector3Zero
        lastSceneExtent = 80
        needsInitialCameraFrame = true
    }

    func apply(pickResult: RayPickResult) {
        clearSelection()
        guard pickResult.ok, pickResult.hit, let id = pickResult.targetID else { return }
        let node = objectNodes[id] ?? (flyNode?.name == id ? flyNode : nil)
            ?? (playerNode?.name == id ? playerNode : nil)
        guard let node, let material = node.geometry?.firstMaterial else { return }
        selectedOriginalEmission = material.emission.contents
        material.emission.contents = NSColor.systemYellow
        selectedNode = node
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        leftDragStart = nil
        if participateModeEnabled {
            if !participateInputEnabled { onPlayerCaptureRequested?() }
            // V5.6 owns world interaction. A Participate click is only an input
            // capture gesture in V5.5, never an authoritative pick/grab command.
            return
        }
        // A press that turns into a drag moves the camera (the usual trackpad
        // gesture); a press released in place is a pick, sent on mouse-up.
        let point = convert(event.locationInWindow, from: nil)
        leftDragStart = point
        leftDragLast = point
        leftDragMoved = false
    }

    override func mouseDragged(with event: NSEvent) {
        if participateInputEnabled {
            routePointerDelta(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY), shift: false)
            return
        }
        guard let start = leftDragStart, let last = leftDragLast else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !leftDragMoved && hypot(p.x - start.x, p.y - start.y) < 3 { return }
        leftDragMoved = true
        leftDragLast = p
        let pan = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
        routePointerDelta(deltaX: Double(p.x - last.x), deltaY: Double(p.y - last.y), shift: pan)
    }

    override func mouseUp(with event: NSEvent) {
        defer { leftDragStart = nil; leftDragLast = nil; leftDragMoved = false }
        guard leftDragStart != nil, !leftDragMoved, !participateModeEnabled else { return }
        pick(at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        routeScroll(delta: -Double(event.magnification) * 60)
    }

    private func pick(at point: NSPoint) {
        guard currentSnapshotSource != nil else { return }
        let near = unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let far = unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let dx = Double(far.x - near.x), dy = Double(far.y - near.y), dz = Double(far.z - near.z)
        let norm = sqrt(dx * dx + dy * dy + dz * dz)
        guard norm >= 1e-12 else { return }
        let sceneOrigin = [Double(near.x), Double(near.y), Double(near.z)]
        let sceneDirection = [dx / norm, dy / norm, dz / norm]
        onPickRay?(WorldViewerRay(
            originMM: WorldViewerCoordinates.mujocoComponents(fromScene: sceneOrigin),
            direction: WorldViewerCoordinates.mujocoComponents(fromScene: sceneDirection)))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastRightDragPoint = participateInputEnabled ? nil : convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if participateInputEnabled {
            routePointerDelta(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY), shift: false)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        guard let last = lastRightDragPoint else {
            lastRightDragPoint = p
            return
        }
        let dx = Double(p.x - last.x)
        let dy = Double(p.y - last.y)
        lastRightDragPoint = p
        if event.modifierFlags.contains(.shift) {
            panObservationCamera(deltaX: dx, deltaY: dy)
        } else {
            rotateObservationCamera(deltaX: dx, deltaY: dy)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        lastRightDragPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        routeScroll(delta: Double(event.scrollingDeltaY))
    }

    override func mouseMoved(with event: NSEvent) {
        guard participateInputEnabled, window?.firstResponder === self else {
            super.mouseMoved(with: event)
            return
        }
        routePointerDelta(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY), shift: false)
    }

    override func keyDown(with event: NSEvent) {
        if routePlayerKeyDown(keyCode: event.keyCode, isRepeat: event.isARepeat) {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if routePlayerKeyUp(keyCode: event.keyCode) {
            return
        }
        super.keyUp(with: event)
    }

    @discardableResult
    func routePlayerKeyDown(keyCode: UInt16, isRepeat: Bool) -> Bool {
        if participateInputEnabled {
            onPlayerKeyDown?(keyCode, isRepeat)
            return true
        }
        return participateModeEnabled
    }

    @discardableResult
    func routePlayerKeyUp(keyCode: UInt16) -> Bool {
        if participateInputEnabled {
            onPlayerKeyUp?(keyCode)
            return true
        }
        return participateModeEnabled
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, participateInputEnabled { onPlayerFocusLost?() }
        return resigned
    }

    /// Shared by AppKit handlers and --bridgetest so Participate pointer routing
    /// is regression-testable without synthesizing window-server NSEvents.
    func routePointerDelta(deltaX: Double, deltaY: Double, shift: Bool) {
        if participateInputEnabled {
            onPlayerLookDelta?(deltaX, deltaY)
        } else if shift {
            panObservationCamera(deltaX: deltaX, deltaY: deltaY)
        } else {
            rotateObservationCamera(deltaX: deltaX, deltaY: deltaY)
        }
    }

    func routeScroll(delta: Double) {
        guard !participateInputEnabled else { return }
        zoomObservationCamera(delta: delta)
    }

    var pickEnabledForCurrentMode: Bool { !participateModeEnabled }
}
