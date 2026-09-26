// BridgeDiagnostics.swift — bridge contract and live transport diagnostics.
import Foundation
import Cocoa
import Darwin

// MARK: - Headless self-test (--bridgetest, no sim, no sockets)

func runBridgeTest() {
    var failures = 0
    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        print((cond ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !cond { failures += 1 }
    }
    // Exercise the actual inbound dispatcher, including permissive legacy
    // telemetry and tags that cannot be classified by scanning raw JSON text.
    let dispatchBridge = FlyGymBridge()
    _ = dispatchBridge.beginConnectionForTesting()
    let escapedBody = Data(#"{"note":{"type":"hello"},"type":"bo\u0064y","vx":0.012}"#.utf8)
    check("inbound dispatch decodes escaped top-level tag",
          dispatchBridge.receiveLineForTesting(escapedBody)
          && abs((dispatchBridge.latestBody()?.vx ?? 0) - 0.012) < 1e-9)
    let invalidInbound = [
        "", "null", "[]", "{", "{}", #"{"type":null}"#, #"{"type":1}"#,
        #"{"type":"unknown"}"#, #"{"type":"brain","walk":1}"#,
        #"{"type":"hello"}"#, #"{"type":"world_render_snapshot"}"#,
        #"{"type":"ray_pick_result"}"#, #"{"type":"player_input_result"}"#,
        #"{"type":"player_input","protocol_version":4,"actor_id":"player","session_id":"s","epoch":1,"seq":1,"requested_tick":0,"move_axes":[0,0],"look_delta":[0,0],"held_actions":[]}"#,
    ]
    check("inbound rejects malformed and outbound-only packets without overwriting body",
          invalidInbound.allSatisfy { !dispatchBridge.receiveLineForTesting(Data($0.utf8)) }
          && dispatchBridge.recvCount == 1
          && abs((dispatchBridge.latestBody()?.vx ?? 0) - 0.012) < 1e-9)
    dispatchBridge.disconnectForTesting()

    // 1. BrainSignals serialization: all keys present, escape pulse preserved.
    var s = BrainSignals()
    s.escape = true; s.walkDrive = 0.52; s.turnBias = -0.18; s.sleep = false
    s.backward = true; s.groomDrive = 0.02; s.wingDrive = 0.1; s.arousal = 0.31
    let pkt = FlyGymBrainPacket(signals: s, simMs: 1234)
    let data = (try? JSONEncoder().encode(pkt)) ?? Data()
    let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    check("brain keys", (obj["type"] as? String) == "brain"
        && (obj["walk"] as? Double ?? -1) == 0.52
        && (obj["turn"] as? Double ?? 9) == -0.18
        && (obj["escape"] as? Bool) == true
        && (obj["backward"] as? Bool) == true
        && abs((obj["t"] as? Double ?? -1) - 1.234) < 1e-9)
    // 2/6. body parse of a well-formed line.
    let line = #"{"type":"body","t":1.238,"sim_dt":0.002,"wall_dt":0.020,"sim_wall_ratio":0.1,"controller_left":0.21,"controller_right":0.43,"wind_strength":0.7,"wind_direction_deg":-30,"wind_sensory":true,"touch_strength":0.55,"touch_sensory":true,"vx":0.013,"yaw_rate":-0.12,"contacts":[1,1,0,0,1,0],"left_contact":0.67,"right_contact":0.33,"loom_left":0.7,"loom_right":0.2,"brightness":0.4,"eye_sample_sim_tick":1200,"odor_left":0.75,"odor_right":0.2,"nearest_food_distance_mm":12.5,"position_x_mm":14.5,"position_y_mm":-3.25,"heading_rad":1.25,"bearing":0.5}"#
    let body = parseBodyLine(Data(line.utf8))
    check("body parse", body != nil && abs((body?.vx ?? 9) - 0.013) < 1e-9
        && abs((body?.t ?? -1) - 1.238) < 1e-9
        && abs((body?.simDt ?? -1) - 0.002) < 1e-9
        && abs((body?.wallDt ?? -1) - 0.020) < 1e-9
        && abs((body?.simWallRatio ?? -1) - 0.1) < 1e-9
        && abs((body?.controllerLeft ?? -9) - 0.21) < 1e-9
        && abs((body?.controllerRight ?? -9) - 0.43) < 1e-9
        && abs((body?.windStrength ?? -9) - 0.7) < 1e-9
        && abs((body?.windDirectionDeg ?? 9) + 30) < 1e-9
        && body?.windSensory == true
        && abs((body?.touchStrength ?? -9) - 0.55) < 1e-9
        && body?.touchSensory == true
        && (body?.contacts ?? []) == [1, 1, 0, 0, 1, 0]
        && abs((body?.leftContact ?? -1) - 0.67) < 1e-9
        && abs((body?.loomLeft ?? -1) - 0.7) < 1e-9
        && body?.eyeSampleSimTick == 1200
        && abs((body?.odorLeft ?? -1) - 0.75) < 1e-9
        && abs((body?.odorRight ?? -1) - 0.2) < 1e-9
        && abs((body?.nearestFoodDistanceMm ?? -1) - 12.5) < 1e-9
        && abs((body?.positionXmm ?? -999) - 14.5) < 1e-9
        && abs((body?.positionYmm ?? 999) + 3.25) < 1e-9
        && abs((body?.headingRad ?? -9) - 1.25) < 1e-9)
    // 7. clamping.
    let wild = #"{"type":"body","sim_dt":99,"wall_dt":-3,"sim_wall_ratio":9999,"vx":99,"yaw_rate":-99,"contacts":[9,-9,2,2,2,2,2,2],"left_contact":5,"right_contact":-5,"loom_left":9,"loom_right":-2,"brightness":7,"odor_left":9,"odor_right":-2,"nearest_food_distance_mm":-4,"heading_rad":99,"bearing":-9}"#
    let c = parseBodyLine(Data(wild.utf8))
    check("feedback clamps", c?.vx == 2.0 && c?.yawRate == -20.0
        && c?.simDt == 10.0 && c?.wallDt == 0.0 && c?.simWallRatio == 1000.0
        && (c?.contacts ?? []) == [1, 0, 1, 1, 1, 1]
        && c?.leftContact == 1.0 && c?.rightContact == 0.0
        && c?.loomLeft == 1.0 && c?.loomRight == 0.0 && c?.brightness == 1.0
        && c?.odorLeft == 1.0 && c?.odorRight == 0.0 && c?.nearestFoodDistanceMm == 0.0
        && c?.headingRad == Double.pi
        && c?.bearing == -1.0)
    // 2. malformed lines throw (recvLoop counts and skips them).
    var malformed = 0
    for bad in ["not json", "[1,2]", #"{"type":"nope"}"#, "", "{\"type\":\"body\",\"vx\":}"] {
        if parseBodyLine(Data(bad.utf8)) == nil {
            malformed += 1
        }
    }
    check("malformed rejected", malformed == 5, "\(malformed)/5")

    // V5.1 atomic render protocol. The viewport may only consume this packet;
    // malformed/mixed payloads never fall back to joining body + lab_state.
    let snapshotLine = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":2,"world_revision":3,"fly":{"id":"fly","position_mm":[1.0,2.0,0.7],"orientation_quat_xyzw":[0.0,0.0,0.0,1.0]},"objects":[{"id":"box_1","shape":"box","position_mm":[12.0,-3.0,4.0],"orientation_quat_xyzw":[0.0,0.0,0.0,1.0],"size_mm":[6.0,8.0,8.0],"revision":2,"collidable":true}]}"#
    let snapshotParsed = parseWorldRenderSnapshotLine(Data(snapshotLine.utf8))
    check("V5 atomic world snapshot strict parse",
          snapshotParsed?.snapshotID == 2 && snapshotParsed?.revision == 3
          && snapshotParsed?.simTick == 40 && snapshotParsed?.objects.first?.id == "box_1"
          && snapshotParsed?.fly?.positionMM == [1.0, 2.0, 0.7])
    let badSnapshotVector = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":2,"world_revision":3,"fly":{"id":"fly","position_mm":[1.0,2.0],"orientation_quat_xyzw":[0,0,0,1]},"objects":[]}"#
    let badSnapshotQuat = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":2,"world_revision":3,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,0]},"objects":[]}"#
    let aliasSnapshot = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_id":2,"revision":3,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[]}"#
    check("V5 snapshot rejects invalid vector/quaternion",
          parseWorldRenderSnapshotLine(Data(badSnapshotVector.utf8)) == nil
          && parseWorldRenderSnapshotLine(Data(badSnapshotQuat.utf8)) == nil)
    check("V5 snapshot wire names are canonical",
          parseWorldRenderSnapshotLine(Data(aliasSnapshot.utf8)) == nil)

    let playerSnapshotLine = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":4,"sim_tick":40,"ok":true,"snapshot_seq":4,"world_revision":6,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[],"player":{"actor_id":"player","position_mm":[24,0,2.5],"orientation_quat_xyzw":[0,0,0,1],"collision_radius_mm":2.5,"mode":"participate"}}"#
    let playerSnapshot = parseWorldRenderSnapshotLine(Data(playerSnapshotLine.utf8))
    check("V5.4 player pose preserves collision/display contract",
          playerSnapshot?.player?.id == "player"
          && playerSnapshot?.player?.positionMM == [24, 0, 2.5]
          && playerSnapshot?.player?.collisionRadiusMM == 2.5
          && playerSnapshot?.player?.mode == "participate")

    let v5Bridge = FlyGymBridge()
    let v5Generation = v5Bridge.beginConnectionForTesting()
    // Drain Swift's hello, then install a server hello that explicitly advertises
    // V5.1. A V4-only peer must leave the viewport disabled.
    _ = v5Bridge.dequeueLaneForTesting(at: Date())
    let v5Hello = #"{"type":"hello","protocol_version":4,"role":"python","capabilities":["applied_tick","deterministic_experiment","epoch","pause_barrier","world_render_snapshot","ray_pick","player_body"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#
    _ = v5Bridge.receiveLineForTesting(Data(v5Hello.utf8))
    check("V5 viewer requires explicit server capabilities", v5Bridge.worldViewerV5_1Available)
    check("V5.4 participant requires explicit player capability", v5Bridge.playerV5_4Available)
    let renderRequestSeq = v5Bridge.requestWorldRenderSnapshot()
    let renderLane = v5Bridge.dequeueLaneForTesting(at: Date().addingTimeInterval(0.02))
    check("V5 render request has bounded observation lane",
          renderRequestSeq != nil && renderLane == .worldRender)
    _ = v5Bridge.receiveLineForTesting(Data(snapshotLine.utf8))
    let acceptedSnapshot = v5Bridge.latestWorldRenderSnapshot()
    check("V5 sessionless snapshot accepted + generation stamped",
          acceptedSnapshot?.snapshotID == 2
          && acceptedSnapshot?.connectionGeneration == v5Generation)
    let olderSnapshot = snapshotLine.replacingOccurrences(of: #""snapshot_seq":2"#,
                                                           with: #""snapshot_seq":1"#)
    _ = v5Bridge.receiveLineForTesting(Data(olderSnapshot.utf8))
    check("V5 stale snapshot cannot replace newer snapshot",
          v5Bridge.latestWorldRenderSnapshot()?.snapshotID == 2)

    let pickSeq = v5Bridge.sendRayPick(rayOriginMM: [0, -20, 10], rayDirection: [0, 2, -1],
                                          sourceSnapshotSeq: 2, sourceWorldRevision: 3,
                                          sourceSimTick: 40)
    let pickLane = v5Bridge.dequeueLaneForTesting(at: Date().addingTimeInterval(0.04))
    check("V5 ray pick uses separate bounded read-only lane", pickSeq != nil && pickLane == .rayPick)
    if let pickSeq {
        let pickLine = "{\"type\":\"ray_pick_result\",\"protocol_version\":4,\"session_id\":\"\",\"epoch\":0,\"seq\":\(pickSeq),\"sim_tick\":40,\"world_revision\":3,\"source_snapshot_seq\":2,\"source_world_revision\":3,\"source_sim_tick\":40,\"ok\":true,\"hit\":true,\"target_id\":\"box_1\",\"target_kind\":\"lab_object\",\"distance_mm\":12.5,\"point_mm\":[1,2,3],\"normal_world\":[0,0,2],\"geom_id\":7}"
        _ = v5Bridge.receiveLineForTesting(Data(pickLine.utf8))
        let pick = v5Bridge.latestRayPickResult()
        check("V5 authoritative pick result echoes source + carries hit point/normal",
              pick?.seq == pickSeq && pick?.targetID == "box_1"
              && pick?.sourceSnapshotSeq == 2 && pick?.sourceWorldRevision == 3
              && pick?.sourceSimTick == 40
              && pick?.pointMM == [1, 2, 3] && pick?.normalWorld == [0, 0, 1])

        let source = WorldViewerSnapshotSource(snapshotSeq: 2, worldRevision: 3, simTick: 40)
        let poseAdvancedLine = pickLine
            .replacingOccurrences(of: #""sim_tick":40,"world_revision":3"#,
                                  with: #""sim_tick":41,"world_revision":4"#)
        let poseAdvancedPick = parseRayPickResultLine(Data(poseAdvancedLine.utf8))
        check("V5 pick UI accepts pose-advanced successful ACK after source validation",
              poseAdvancedPick.map {
                  worldViewerPickDisposition($0, latestRequestSeq: pickSeq,
                                             consumedSeq: nil, expectedSource: source) == .applySuccess
              } == true)

        let errorLine = "{\"type\":\"ray_pick_result\",\"protocol_version\":4,\"session_id\":\"\",\"epoch\":0,\"seq\":\(pickSeq),\"sim_tick\":42,\"world_revision\":5,\"source_snapshot_seq\":2,\"source_world_revision\":3,\"source_sim_tick\":40,\"ok\":false,\"hit\":false,\"error\":\"stale source world revision\"}"
        let errorPick = parseRayPickResultLine(Data(errorLine.utf8))
        check("V5 pick UI always consumes matching backend error ACK",
              errorPick.map {
                  worldViewerPickDisposition($0, latestRequestSeq: pickSeq,
                                             consumedSeq: nil, expectedSource: source) == .showError
              } == true)
        check("V5 pick UI ignores stale successful ACK from older request",
              poseAdvancedPick.map {
                  worldViewerPickDisposition($0, latestRequestSeq: pickSeq + 1,
                                             consumedSeq: nil, expectedSource: source) == .ignore
              } == true)
    } else {
        check("V5 authoritative pick result echoes source + carries hit point/normal", false)
        check("V5 pick UI accepts pose-advanced successful ACK after source validation", false)
        check("V5 pick UI always consumes matching backend error ACK", false)
        check("V5 pick UI ignores stale successful ACK from older request", false)
    }

    let missingPickSource = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"","epoch":0,"seq":9,"sim_tick":40,"world_revision":3,"ok":true,"hit":false}"#
    check("V5 pick result requires source snapshot metadata",
          parseRayPickResultLine(Data(missingPickSource.utf8)) == nil)

    // Active V4 session identity is also authoritative for V5 observation traffic.
    // Delayed old-epoch render/pick responses must never refill the cache after a
    // reset promoted the bridge to a newer epoch.
    let v5EpochFilter = FlyGymBridge()
    _ = v5EpochFilter.beginConnectionForTesting()
    _ = v5EpochFilter.dequeueLaneForTesting(at: Date()) // Swift hello
    _ = v5EpochFilter.receiveLineForTesting(Data(v5Hello.utf8))
    _ = v5EpochFilter.sendSessionControl(action: "begin", sessionID: "v5-epoch",
                                         epoch: 2, simTick: 0, mode: .deterministic)
    let oldEpochSnapshot = snapshotLine
        .replacingOccurrences(of: #""session_id":"""#, with: #""session_id":"v5-epoch""#)
        .replacingOccurrences(of: #""epoch":0"#, with: #""epoch":1"#)
    let staleV5Before = v5EpochFilter.staleSessionPacketCount
    _ = v5EpochFilter.receiveLineForTesting(Data(oldEpochSnapshot.utf8))
    let oldEpochPick = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"v5-epoch","epoch":1,"seq":77,"sim_tick":40,"world_revision":3,"source_snapshot_seq":2,"source_world_revision":3,"source_sim_tick":40,"ok":true,"hit":false}"#
    _ = v5EpochFilter.receiveLineForTesting(Data(oldEpochPick.utf8))
    check("V5 active-session old-epoch responses rejected",
          v5EpochFilter.latestWorldRenderSnapshot() == nil
          && v5EpochFilter.latestRayPickResult() == nil
          && v5EpochFilter.staleSessionPacketCount == staleV5Before + 2)

    let v4Only = FlyGymBridge()
    _ = v4Only.beginConnectionForTesting()
    _ = v4Only.receiveLineForTesting(Data(#"{"type":"hello","protocol_version":4,"role":"python","capabilities":["applied_tick","deterministic_experiment","epoch","pause_barrier"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#.utf8))
    check("V4-only peer does not silently enable V5 viewport",
          !v4Only.worldViewerV5_1Available && v4Only.requestWorldRenderSnapshot() == nil)
    let v51Only = FlyGymBridge()
    _ = v51Only.beginConnectionForTesting()
    _ = v51Only.receiveLineForTesting(Data(#"{"type":"hello","protocol_version":4,"role":"python","capabilities":["world_render_snapshot","ray_pick"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#.utf8))
    check("V5.1-only peer does not silently enable V5.4 participant",
          v51Only.worldViewerV5_1Available && !v51Only.playerV5_4Available)

    // MuJoCo z-up <-> SceneKit y-up basis must be exact or the displayed pose
    // and the authoritative backend pick ray refer to different geometry.
    let sceneAxis = WorldViewerCoordinates.sceneComponents(fromMuJoCo: [1, 2, 3])
    let axisRoundTrip = WorldViewerCoordinates.mujocoComponents(fromScene: sceneAxis)
    check("V5 viewport coordinate basis round-trip",
          sceneAxis == [1, 3, -2] && axisRoundTrip == [1, 2, 3])
    let half = Double.pi / 4
    let yaw90Scene = WorldViewerCoordinates.sceneQuaternionXYZW(
        fromMuJoCo: [0, 0, sin(half), cos(half)])
    check("V5 MuJoCo +Z yaw maps to SceneKit +Y yaw",
          abs(yaw90Scene[0]) < 1e-12 && abs(yaw90Scene[1] - sin(half)) < 1e-12
          && abs(yaw90Scene[2]) < 1e-12 && abs(yaw90Scene[3] - cos(half)) < 1e-12)
    let rayScene = WorldViewerCoordinates.sceneComponents(fromMuJoCo: [0.25, -0.5, 0.75])
    let rayBack = WorldViewerCoordinates.mujocoComponents(fromScene: rayScene)
    check("V5 pick ray uses inverse viewport basis", zip(rayBack, [0.25, -0.5, 0.75]).allSatisfy { abs($0 - $1) < 1e-12 })

    // V5.2 presentation-state ownership. LabSession remains authoritative for
    // pause/timeline; the screen state mirrors that once and every panel renders
    // from the same value instead of independently inferring phase/tick.
    var v52State = LabViewState()
    let v52Session = LabSessionSnapshot(
        mode: .deterministic, phase: .paused, sessionID: "v52-state", epoch: 3,
        simTick: 120, quantumTicks: FlyGymProtocolV4.experimentQuantumTicks,
        outstandingStepSeq: nil, pauseControlSent: true,
        lastBodyResultTick: 120, lastAppliedCommandTick: 100, lastError: nil)
    v52State.sync(session: v52Session)
    if let snapshotParsed { v52State.accept(snapshot: snapshotParsed, connectionGeneration: 9) }
    check("V5.2 common state keeps session timeline authoritative",
          v52State.timelineTick == 120 && v52State.snapshotTick == 40
          && v52State.phaseBadge == "PAUSED"
          && v52State.commonStatusLine.contains("tick 120 ms · PAUSED")
          && v52State.sessionStatusLine.contains("paused · epoch 3 · tick 120 ms"))
    var v52PendingDisplay = v52State
    v52PendingDisplay.beginModeTransition(to: .participate)
    check("V5.5 pending Participate stays visibly selected without claiming authority",
          v52PendingDisplay.mode == .observe
          && v52PendingDisplay.displayedMode == .participate)

    let v52PickLine = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"","epoch":0,"seq":90,"sim_tick":41,"world_revision":4,"source_snapshot_seq":2,"source_world_revision":3,"source_sim_tick":40,"ok":true,"hit":true,"target_id":"box_1","target_kind":"lab_object","distance_mm":1.0,"point_mm":[0,0,0],"normal_world":[0,0,1],"geom_id":1}"#
    if let v52Pick = parseRayPickResultLine(Data(v52PickLine.utf8)) {
        v52State.apply(pick: v52Pick)
    }
    check("V5.2 authoritative pick updates one shared object selection",
          v52State.selectedObjectID == "box_1" && v52State.selectionSummary.contains("object box_1"))

    let v52EmptySnapshotLine = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":2,"sim_tick":42,"ok":true,"snapshot_seq":3,"world_revision":5,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[]}"#
    if let v52Empty = parseWorldRenderSnapshotLine(Data(v52EmptySnapshotLine.utf8)) {
        v52State.accept(snapshot: v52Empty, connectionGeneration: 9)
    }
    check("V5.2 shared selection is reconciled by authoritative snapshot",
          v52State.selectedObjectID == nil && v52State.timelineTick == 120
          && v52State.snapshotSeq == 3 && v52State.worldRevision == 5)

    // V5.4 mode presentation is snapshot-authoritative. A UI request stays
    // pending until the backend world actually contains/removes the participant;
    // rejection leaves the prior mode intact.
    var v54State = LabViewState()
    v54State.setViewerAvailable(true)
    v54State.beginModeTransition(to: .participate)
    check("V5.4 participate request does not claim mode before backend snapshot",
          v54State.mode == .observe && v54State.pendingMode == .participate)
    var v54Rejected = v54State
    v54Rejected.rejectModeTransition()
    check("V5.4 rejected participate request preserves prior mode",
          v54Rejected.mode == .observe && v54Rejected.pendingMode == nil)
    if let playerSnapshot {
        v54State.accept(snapshot: playerSnapshot, connectionGeneration: 12)
    }
    check("V5.4 player snapshot confirms Participate mode",
          v54State.mode == .participate && v54State.pendingMode == nil)

    let v54PlayerPickLine = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"","epoch":0,"seq":91,"sim_tick":41,"world_revision":6,"source_snapshot_seq":4,"source_world_revision":6,"source_sim_tick":40,"ok":true,"hit":true,"target_id":"player","target_kind":"player","distance_mm":2.0,"point_mm":[24,0,5],"normal_world":[0,0,1],"geom_id":9}"#
    if let v54PlayerPick = parseRayPickResultLine(Data(v54PlayerPickLine.utf8)) {
        v54State.apply(pick: v54PlayerPick)
    }
    check("V5.4 authoritative player pick reaches common selection state",
          v54State.selectedPlayerID == "player" && v54State.selectionSummary.contains("player player"))

    v54State.beginModeTransition(to: .observe)
    if let playerSnapshot {
        v54State.accept(snapshot: playerSnapshot, connectionGeneration: 12)
    }
    check("V5.4 disable request stays Participate while player still exists",
          v54State.mode == .participate && v54State.pendingMode == .observe)
    if let v54Empty = parseWorldRenderSnapshotLine(Data(v52EmptySnapshotLine.utf8)) {
        v54State.accept(snapshot: v54Empty, connectionGeneration: 12)
    }
    check("V5.4 player-free snapshot confirms Observe mode",
          v54State.mode == .observe && v54State.pendingMode == nil
          && v54State.selectedPlayerID == nil)

    // Pending participant commands are transport-generation scoped. Losing the
    // viewer/capability must clear the command gate even when the current mode is
    // still Observe (enable pending) or still Participate (disable pending).
    var pendingEnable = ParticipantCommandPendingState()
    var pendingEnableState = LabViewState()
    pendingEnableState.setViewerAvailable(true)
    pendingEnableState.beginModeTransition(to: .participate)
    pendingEnable.begin(commandID: 701, connectionGeneration: 21)
    let enableCleared = pendingEnable.clearIfViewerLifecycleInvalid(
        playerAvailable: false, connectionGeneration: 21)
    if enableCleared { pendingEnableState.rejectModeTransition() }
    pendingEnableState.setViewerAvailable(false)
    check("V5.4 disconnect during enable clears pending participant command",
          enableCleared && !pendingEnable.isPending
          && pendingEnableState.mode == .observe
          && pendingEnableState.pendingMode == nil)

    var pendingDisable = ParticipantCommandPendingState()
    var pendingDisableState = LabViewState()
    pendingDisableState.setViewerAvailable(true)
    if let playerSnapshot {
        pendingDisableState.accept(snapshot: playerSnapshot, connectionGeneration: 31)
    }
    pendingDisableState.beginModeTransition(to: .observe)
    pendingDisable.begin(commandID: 702, connectionGeneration: 31)
    let disableCleared = pendingDisable.clearIfViewerLifecycleInvalid(
        playerAvailable: false, connectionGeneration: 31)
    if disableCleared { pendingDisableState.rejectModeTransition() }
    pendingDisableState.setViewerAvailable(false)
    check("V5.4 disconnect during disable clears pending participant command",
          disableCleared && !pendingDisable.isPending
          && pendingDisableState.mode == .observe
          && pendingDisableState.pendingMode == nil)

    var pendingGeneration = ParticipantCommandPendingState()
    pendingGeneration.begin(commandID: 703, connectionGeneration: 41)
    check("V5.4 connection-generation rollover clears stale participant command",
          pendingGeneration.clearIfViewerLifecycleInvalid(
              playerAvailable: true, connectionGeneration: 42)
          && !pendingGeneration.isPending)

    // V5.5 PlayerInput wire/capability + continuous latest-state semantics.
    let v55Hello = #"{"type":"hello","protocol_version":4,"role":"python","capabilities":["applied_tick","deterministic_experiment","epoch","pause_barrier","world_render_snapshot","ray_pick","player_body","player_input"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#
    let v55Bridge = FlyGymBridge()
    _ = v55Bridge.beginConnectionForTesting()
    _ = v55Bridge.dequeueLaneForTesting(at: Date()) // Swift hello
    _ = v55Bridge.receiveLineForTesting(Data(v55Hello.utf8))
    check("V5.5 player input requires explicit layered capability",
          v55Bridge.playerV5_4Available && v55Bridge.playerInputV5_5Available)

    let v55Seq1 = v55Bridge.sendPlayerInput(sessionID: "", epoch: 0,
                                            requestedTick: 95,
                                            moveAxes: [1, 0], lookDelta: [0.10, 0.05],
                                            heldActions: ["interact"])
    let v55Seq2 = v55Bridge.sendPlayerInput(sessionID: "", epoch: 0,
                                            requestedTick: 100,
                                            moveAxes: [0, -1], lookDelta: [-0.03, 0.02],
                                            heldActions: [])
    let coalescedSend = v55Bridge.dequeueSendForTesting(at: Date().addingTimeInterval(0.02))
    let coalescedInput = coalescedSend.flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 PlayerInput coalesces axes/held latest-wins and accumulates look once",
          v55Seq1 != nil && v55Seq2 != nil
          && coalescedSend?.0 == .playerInput
          && coalescedInput?.seq == v55Seq2
          && coalescedInput?.requestedTick == 100
          && coalescedInput?.moveAxes == [0, -1]
          && abs((coalescedInput?.lookDelta[0] ?? 9) - 0.07) < 1e-12
          && abs((coalescedInput?.lookDelta[1] ?? 9) - 0.07) < 1e-12
          && coalescedInput?.heldActions.isEmpty == true)

    let v55LargeLook = FlyGymBridge()
    _ = v55LargeLook.beginConnectionForTesting()
    _ = v55LargeLook.dequeueLaneForTesting(at: Date())
    _ = v55LargeLook.receiveLineForTesting(Data(v55Hello.utf8))
    _ = v55LargeLook.sendPlayerInput(sessionID: "", epoch: 0,
                                     requestedTick: 0, moveAxes: [0, 0],
                                     lookDelta: [0.7, -0.7], heldActions: [])
    _ = v55LargeLook.sendPlayerInput(sessionID: "", epoch: 0,
                                     requestedTick: 0, moveAxes: [0, 0],
                                     lookDelta: [0.7, -0.7], heldActions: [])
    let largeLookSend1 = v55LargeLook.dequeueSendForTesting(at: Date().addingTimeInterval(0.01))
    let largeLookSend2 = v55LargeLook.dequeueSendForTesting(at: Date().addingTimeInterval(0.02))
    let largeLook1 = largeLookSend1.flatMap { decodePlayerInputLine($0.1) }
    let largeLook2 = largeLookSend2.flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 coalesced look above per-packet bound is split without loss",
          largeLookSend1?.0 == .playerInput && largeLookSend2?.0 == .playerInput
          && largeLook1 != nil && largeLook2 != nil
          && abs((largeLook1!.lookDelta[0] + largeLook2!.lookDelta[0]) - 1.4) < 1e-12
          && abs((largeLook1!.lookDelta[1] + largeLook2!.lookDelta[1]) + 1.4) < 1e-12
          && abs(largeLook1!.lookDelta[0]) <= PlayerInputPacket.maxLookDelta
          && abs(largeLook2!.lookDelta[0]) <= PlayerInputPacket.maxLookDelta
          && largeLook2!.seq > largeLook1!.seq
          && v55LargeLook.dequeueSendForTesting(at: Date().addingTimeInterval(0.03)) == nil)

    let v55ReleaseLook = FlyGymBridge()
    _ = v55ReleaseLook.beginConnectionForTesting()
    _ = v55ReleaseLook.dequeueLaneForTesting(at: Date())
    _ = v55ReleaseLook.receiveLineForTesting(Data(v55Hello.utf8))
    _ = v55ReleaseLook.sendPlayerInput(sessionID: "", epoch: 0,
                                       requestedTick: 0, moveAxes: [0, 0],
                                       lookDelta: [0.7, -0.7], heldActions: [])
    let releaseSeq = v55ReleaseLook.sendPlayerInput(
        sessionID: "", epoch: 0, requestedTick: 0,
        moveAxes: [0, 0], lookDelta: [0, 0], heldActions: [],
        discardPendingLook: true)
    let releaseSend = v55ReleaseLook.dequeueSendForTesting(
        at: Date().addingTimeInterval(0.01))
    let releasePacket = releaseSend.flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 safety release discards pending mouse look and remainder",
          releaseSeq != nil
          && releaseSend?.0 == .playerInput
          && releasePacket?.lookDelta == [0, 0]
          && releasePacket?.moveAxes == [0, 0]
          && releasePacket?.heldActions.isEmpty == true
          && v55ReleaseLook.dequeueSendForTesting(
              at: Date().addingTimeInterval(0.02)) == nil)

    let v55AckLine = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55BadSuccess = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"ok":true,"status":"applied"}"#
    let v55BadFailure = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"ok":false,"status":"rejected"}"#
    let v55BadSuccessStatus = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"queue_full"}"#
    let v55BadFailureApplied = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":false,"status":"rejected","error":"no"}"#
    let v55BadFailureStatus = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"ok":false,"status":"applied","error":"no"}"#
    let v55BadSuccessNullError = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied","error":null}"#
    let v55BadFailureNullTick = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":null,"ok":false,"status":"rejected","error":"no"}"#
    let v55BadSeqBound = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2147483648,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55BadTickBound = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":1000000000000001,"applied_tick":1000000000000001,"ok":true,"status":"applied"}"#
    let v55BadProtocol = #"{"type":"player_input_result","protocol_version":0,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55BadBlankSession = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"   ","epoch":1,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55PaddedStatus = String(repeating: " ", count: 65) + "applied"
    let v55BadStatusBound = "{\"type\":\"player_input_result\",\"protocol_version\":4,\"actor_id\":\"player\",\"session_id\":\"\",\"epoch\":0,\"seq\":2,\"requested_tick\":100,\"applied_tick\":101,\"ok\":true,\"status\":\"\(v55PaddedStatus)\"}"
    let v55LongError = String(repeating: "x", count: 513)
    let v55BadErrorBound = "{\"type\":\"player_input_result\",\"protocol_version\":4,\"actor_id\":\"player\",\"session_id\":\"\",\"epoch\":0,\"seq\":2,\"requested_tick\":100,\"ok\":false,\"status\":\"rejected\",\"error\":\"\(v55LongError)\"}"
    let parsedV55Ack = parsePlayerInputResultLine(Data(v55AckLine.utf8))
    check("V5.5 PlayerInput result strict schema carries applied tick",
          parsedV55Ack?.ok == true && parsedV55Ack?.seq == 2
          && parsedV55Ack?.requestedTick == 100 && parsedV55Ack?.appliedTick == 101
          && parsePlayerInputResultLine(Data(v55BadSuccess.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailure.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadSuccessStatus.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailureApplied.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailureStatus.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadSuccessNullError.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailureNullTick.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadSeqBound.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadTickBound.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadProtocol.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadBlankSession.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadStatusBound.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadErrorBound.utf8)) == nil)
    _ = v55Bridge.receiveLineForTesting(Data(v55AckLine.utf8))
    check("V5.5 accepted result is generation stamped",
          v55Bridge.latestPlayerInputResult()?.appliedTick == 101
          && v55Bridge.latestPlayerInputResult()?.connectionGeneration == v55Bridge.connectionGeneration)

    let v55SeqBounds = FlyGymBridge()
    _ = v55SeqBounds.beginConnectionForTesting()
    _ = v55SeqBounds.dequeueLaneForTesting(at: Date())
    _ = v55SeqBounds.receiveLineForTesting(Data(v55Hello.utf8))
    v55SeqBounds.setNextPlayerInputSeqForTesting(PlayerInputPacket.maxSeq)
    let maxWireSeq = v55SeqBounds.sendPlayerInput(
        sessionID: "", epoch: 0, requestedTick: 0,
        moveAxes: [0, 0], lookDelta: [0, 0], heldActions: [])
    let exhaustedWireSeq = v55SeqBounds.sendPlayerInput(
        sessionID: "", epoch: 0, requestedTick: 0,
        moveAxes: [0, 0], lookDelta: [0, 0], heldActions: [])
    let maxWirePacket = v55SeqBounds.dequeueSendForTesting(
        at: Date().addingTimeInterval(0.01)).flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 outbound PlayerInput never exceeds Python seq bound",
          maxWireSeq == PlayerInputPacket.maxSeq
          && exhaustedWireSeq == nil
          && maxWirePacket?.seq == PlayerInputPacket.maxSeq)

    // Deterministic boundary ordering: queued PlayerInput must reach Python before
    // the body quantum it targets, exactly like tick-scheduled LabCommands.
    let v55Order = FlyGymBridge()
    _ = v55Order.beginConnectionForTesting()
    _ = v55Order.dequeueLaneForTesting(at: Date())
    _ = v55Order.receiveLineForTesting(Data(v55Hello.utf8))
    _ = v55Order.sendSessionControl(action: "begin", sessionID: "v55-order",
                                    epoch: 1, simTick: 0, mode: .deterministic)
    _ = v55Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.01))
    let orderedInput = v55Order.sendPlayerInput(sessionID: "v55-order", epoch: 1,
                                                requestedTick: 0, moveAxes: [1, 0],
                                                lookDelta: [0, 0], heldActions: [])
    let orderedStep = v55Order.sendExperimentStep(sessionID: "v55-order", epoch: 1,
                                                  seq: 1, simTick: 0, signals: BrainSignals())
    let firstV55Lane = v55Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.02))
    let secondV55Lane = v55Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.03))
    check("V5.5 deterministic PlayerInput cannot be overtaken by experiment step",
          orderedInput != nil && orderedStep
          && firstV55Lane == .playerInput && secondV55Lane == .experimentStep)

    // PlayerController focus safety and stale-key suppression are independent of
    // render FPS/window-server event repetition.
    let playerDefaultsName = "SiliconFly.PlayerInput.bridgetest.\(UUID().uuidString)"
    let playerDefaults = UserDefaults(suiteName: playerDefaultsName)!
    playerDefaults.removePersistentDomain(forName: playerDefaultsName)
    let controller = PlayerController(defaults: playerDefaults, lookRadiansPerPoint: 0.01)
    _ = controller.setCaptureEnabled(true)
    let forwardCode = controller.bindings.keyCode(for: .forward)
    let rightCode = controller.bindings.keyCode(for: .right)
    let interactCode = controller.bindings.keyCode(for: .interact)
    let forwardDown = controller.handleKeyDown(keyCode: forwardCode, isRepeat: false)
    let diagonalDown = controller.handleKeyDown(keyCode: rightCode, isRepeat: false)
    let interactDown = controller.handleKeyDown(keyCode: interactCode, isRepeat: false)
    let localEscNeutral = controller.handleKeyDown(keyCode: PlayerController.escapeKeyCode,
                                                   isRepeat: false)
    let staleRepeat = controller.handleKeyDown(keyCode: forwardCode, isRepeat: true)
    _ = controller.handleKeyUp(keyCode: forwardCode)
    let freshForward = controller.handleKeyDown(keyCode: forwardCode, isRepeat: false)
    check("V5.5 WASD/E state is bounded and Esc is local neutral safety release",
          forwardDown?.moveAxes == [1, 0]
          && diagonalDown?.moveAxes == [1, 1]
          && interactDown?.heldActions == ["interact"]
          && localEscNeutral?.isNeutral == true
          && localEscNeutral?.heldActions.isEmpty == true
          && staleRepeat == nil && freshForward?.moveAxes == [1, 0])

    let focusNeutral = controller.releaseHeldInput(blockUntilFreshPress: true)
    _ = controller.setCaptureEnabled(false)
    _ = controller.setCaptureEnabled(true)
    let focusStaleRepeat = controller.handleKeyDown(keyCode: forwardCode, isRepeat: true)
    _ = controller.handleKeyUp(keyCode: forwardCode)
    let focusFreshPress = controller.handleKeyDown(keyCode: forwardCode, isRepeat: false)
    check("V5.5 focus loss neutralizes held state and never revives stale repeats",
          focusNeutral?.isNeutral == true && focusStaleRepeat == nil
          && focusFreshPress?.moveAxes == [1, 0])

    let lookIntent = controller.handleLook(deltaX: 10, deltaY: -5)
    check("V5.5 mouse look follows +Y-left world basis and bounded radians",
          abs((lookIntent?.lookDelta[0] ?? 9) + 0.10) < 1e-12
          && abs((lookIntent?.lookDelta[1] ?? 9) - 0.05) < 1e-12)

    let originalForward = controller.bindings.keyCode(for: .forward)
    let originalRight = controller.bindings.keyCode(for: .right)
    _ = controller.rebind(.forward, to: originalRight, defaults: playerDefaults)
    let reloadedBindings = PlayerKeyBindings(defaults: playerDefaults)
    let swappedPersisted = reloadedBindings.keyCode(for: .forward) == originalRight
        && reloadedBindings.keyCode(for: .right) == originalForward
    _ = controller.rebind(.forward, to: PlayerController.escapeKeyCode, defaults: playerDefaults)
    check("V5.5 remap persists unique swaps while Esc stays reserved",
          swappedPersisted && controller.bindings.keyCode(for: .forward) == originalRight)
    playerDefaults.set(Int(PlayerController.escapeKeyCode),
                       forKey: PlayerKeyBindings.preferencePrefix + PlayerControlAction.forward.rawValue)
    let escapedStoredBinding = PlayerKeyBindings(defaults: playerDefaults)
    check("V5.5 corrupt persisted Esc binding fails safely to non-Esc mapping",
          escapedStoredBinding.keyCode(for: .forward) != PlayerController.escapeKeyCode)
    playerDefaults.removePersistentDomain(forName: playerDefaultsName)

    let focusViewer = WorldViewer(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let focusField = NSTextField(string: "W should type, not walk")
    let focusButton = NSButton(title: "Control", target: nil, action: nil)
    let focusWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                               styleMask: [.titled], backing: .buffered, defer: false)
    PlayerInputFocusPolicy.prepareWindowForCapture(focusWindow)
    check("V5.5 Participate window enables ordinary mouse-move delivery",
          focusWindow.acceptsMouseMovedEvents)
    check("V5.5 text/control focus suppresses capture",
          PlayerInputFocusPolicy.allowsCapture(windowIsKey: true,
                                               firstResponder: focusViewer,
                                               viewer: focusViewer)
          && !PlayerInputFocusPolicy.allowsCapture(windowIsKey: true,
                                                   firstResponder: focusField,
                                                   viewer: focusViewer)
          && !PlayerInputFocusPolicy.allowsCapture(windowIsKey: true,
                                                   firstResponder: focusButton,
                                                   viewer: focusViewer)
          && !PlayerInputFocusPolicy.allowsCapture(windowIsKey: false,
                                                   firstResponder: focusViewer,
                                                   viewer: focusViewer))

    var participateLookCallbacks = 0
    focusViewer.onPlayerLookDelta = { _, _ in participateLookCallbacks += 1 }
    focusViewer.participateModeEnabled = true
    focusViewer.participateInputEnabled = true
    let captureCameraBefore = focusViewer.cameraState
    focusViewer.routePointerDelta(deltaX: 12, deltaY: -4, shift: false)
    focusViewer.routeScroll(delta: 9)
    let captureCameraAfter = focusViewer.cameraState
    focusViewer.participateInputEnabled = false
    var pendingKeyCallbacks = 0
    focusViewer.onPlayerKeyDown = { _, _ in pendingKeyCallbacks += 1 }
    let pendingParticipateOwnsKey = focusViewer.routePlayerKeyDown(keyCode: 13, isRepeat: false)
    focusViewer.participateInputEnabled = true
    let capturedParticipateOwnsKey = focusViewer.routePlayerKeyDown(keyCode: 13, isRepeat: false)
    focusViewer.participateInputEnabled = false
    focusViewer.routePointerDelta(deltaX: 5, deltaY: 2, shift: false)
    let releasedCameraChanged = focusViewer.cameraState != captureCameraAfter
    check("V5.5 Participate capture is exclusive from pick/Observe camera gestures",
          participateLookCallbacks == 1
          && captureCameraAfter == captureCameraBefore
          && !focusViewer.pickEnabledForCurrentMode
          && pendingParticipateOwnsKey && capturedParticipateOwnsKey
          && pendingKeyCallbacks == 1
          && releasedCameraChanged)

    // Reconnect invalidates both pending input/result state and the Coordinator's
    // interactive owner identity. A fresh transport generation must begin a fresh
    // V4 interactive session before accepting new input.
    let reconnectBridge = FlyGymBridge()
    _ = reconnectBridge.beginConnectionForTesting()
    _ = reconnectBridge.dequeueLaneForTesting(at: Date())
    _ = reconnectBridge.receiveLineForTesting(Data(v55Hello.utf8))
    let reconnectCoordinator = Coordinator(bounds: CGSize(width: 100, height: 100), sim: nil)
    reconnectCoordinator.flyGym = reconnectBridge
    let firstInteractiveReady = reconnectCoordinator.ensureInteractivePlayerInputSession()
    let firstInteractiveID = reconnectCoordinator.sessionSnapshot().sessionID
    reconnectBridge.disconnectForTesting()
    let clearedAfterDisconnect = reconnectBridge.latestPlayerInputResult() == nil
        && !reconnectBridge.playerInputV5_5Available
    _ = reconnectBridge.beginConnectionForTesting()
    _ = reconnectBridge.dequeueLaneForTesting(at: Date())
    _ = reconnectBridge.receiveLineForTesting(Data(v55Hello.utf8))
    let secondInteractiveReady = reconnectCoordinator.ensureInteractivePlayerInputSession()
    let secondInteractiveID = reconnectCoordinator.sessionSnapshot().sessionID
    check("V5.5 reconnect starts fresh interactive owner session and clears stale input state",
          firstInteractiveReady && secondInteractiveReady && clearedAfterDisconnect
          && firstInteractiveID != secondInteractiveID)

    // V5.3 observation camera is strictly presentation-only. Exercise the same
    // camera APIs used by right-drag/Shift-right-drag/scroll while wiring the
    // existing pick callback to a real V5-capable bridge. Any accidental pick,
    // neural, lab, session, render, or experiment send would increase bridge
    // pendingDepth and fail this test.
    let v53Bridge = FlyGymBridge()
    _ = v53Bridge.beginConnectionForTesting()
    _ = v53Bridge.dequeueLaneForTesting(at: Date()) // drain Swift hello
    _ = v53Bridge.receiveLineForTesting(Data(v5Hello.utf8))
    let v53Viewer = WorldViewer(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var v53PickCallbacks = 0
    v53Viewer.onPickRay = { ray in
        v53PickCallbacks += 1
        guard let source = v53Viewer.currentSnapshotSource else { return }
        _ = v53Bridge.sendRayPick(rayOriginMM: ray.originMM,
                                  rayDirection: ray.direction,
                                  sourceSnapshotSeq: source.snapshotSeq,
                                  sourceWorldRevision: source.worldRevision,
                                  sourceSimTick: source.simTick)
    }
    // Reset before any backend snapshot must not consume the one-shot initial
    // authoritative framing gate.
    v53Viewer.resetObservationCamera()
    if let snapshotParsed { v53Viewer.apply(snapshot: snapshotParsed) }
    let v53SharedBefore = v52State
    let v53InitialCamera = v53Viewer.cameraState
    let expectedInitialCenter = [6.5, 2.35, 0.5]
    let initialFrameOK = zip(v53InitialCamera.targetScene, expectedInitialCenter)
        .allSatisfy { abs($0 - $1) < 1e-5 }
    let initialSnapshotSourceOK = v53Viewer.currentSnapshotSource?.snapshotSeq == 2
    v53Viewer.rotateObservationCamera(deltaX: 24, deltaY: -9)
    v53Viewer.panObservationCamera(deltaX: 12, deltaY: 6)
    v53Viewer.zoomObservationCamera(delta: -3)
    let v53OrbitChanged = v53Viewer.cameraState != v53InitialCamera
    v53Viewer.setObservationCameraMode(.followFly)
    let followCameraBeforeMove = v53Viewer.cameraScenePositionForTesting
    let movedFollowLine = snapshotLine
        .replacingOccurrences(of: #""snapshot_seq":2"#, with: #""snapshot_seq":5"#)
        .replacingOccurrences(of: #""sim_tick":40"#, with: #""sim_tick":60"#)
        .replacingOccurrences(of: #""position_mm":[1.0,2.0,0.7]"#,
                              with: #""position_mm":[11.0,7.0,0.7]"#)
    if let movedFollowSnapshot = parseWorldRenderSnapshotLine(Data(movedFollowLine.utf8)) {
        v53Viewer.apply(snapshot: movedFollowSnapshot)
    }
    let followCameraAfterMove = v53Viewer.cameraScenePositionForTesting
    let followCameraDelta = zip(followCameraAfterMove, followCameraBeforeMove).map { $0.0 - $0.1 }
    let expectedFollowDelta = [10.0, 0.0, -5.0]
    let followTracksFlyMotion = zip(followCameraDelta, expectedFollowDelta)
        .allSatisfy { abs($0.0 - $0.1) < 1e-4 }
    check("V5.3 Follow fly tracks authoritative fly motion", followTracksFlyMotion)
    let followBeforePan = v53Viewer.cameraState
    v53Viewer.panObservationCamera(deltaX: 99, deltaY: 99)
    let followPanNoOp = v53Viewer.cameraState == followBeforePan
    v53Viewer.rotateObservationCamera(deltaX: -11, deltaY: 4)
    v53Viewer.zoomObservationCamera(delta: 2)
    v53Viewer.setObservationCameraMode(.free)
    let freeStart = v53Viewer.cameraState
    let expectedFreePosition = zip(freeStart.targetScene, freeStart.forwardVector).map {
        $0.0 - $0.1 * freeStart.distance
    }
    let freeContinuity = zip(freeStart.freePositionScene, expectedFreePosition)
        .allSatisfy { abs($0 - $1) < 1e-3 }
    let freeZoomForward = freeStart.forwardVector
    v53Viewer.zoomObservationCamera(delta: 4)
    let freeAfterPositiveZoom = v53Viewer.cameraState
    let freePositiveZoomProjection = zip(zip(freeAfterPositiveZoom.freePositionScene,
                                             freeStart.freePositionScene), freeZoomForward)
        .reduce(0.0) { partial, pair in
            partial + (pair.0.0 - pair.0.1) * pair.1
        }
    var orbitZoomProbe = WorldViewerCameraState()
    let orbitDistanceBeforePositiveZoom = orbitZoomProbe.distance
    orbitZoomProbe.zoom(delta: 4)
    let scrollDirectionConsistent = orbitZoomProbe.distance > orbitDistanceBeforePositiveZoom
        && freePositiveZoomProjection < 0
    v53Viewer.rotateObservationCamera(deltaX: 7, deltaY: 3)
    v53Viewer.panObservationCamera(deltaX: 5, deltaY: -2)
    v53Viewer.resetObservationCamera()
    check("V5.3 first snapshot frames authoritative scene",
          initialFrameOK && initialSnapshotSourceOK)
    check("V5.3 orbit/follow/free camera inputs are presentation-only",
          v53OrbitChanged && followTracksFlyMotion && followPanNoOp && freeContinuity
          && scrollDirectionConsistent
          && v53PickCallbacks == 0 && v53Bridge.pendingDepth() == 0
          && v53Bridge.pendingLabDepth() == 0 && v52State == v53SharedBefore)

    // sensory map: standing contact is not gait; fresh real body is authoritative;
    // stale/missing real body falls back to the desktop procedural fly.
    var still = FlyGymBodyFeedback()
    still.contacts = [1, 1, 1, 1, 1, 1]
    still.leftContact = 1; still.rightContact = 1
    check("standing contact -> 0 gait", FlyGymSensoryMap.bodyDrive(still) == 0)
    check("fresh real ignores procedural gait",
          FlyGymSensoryMap.gaitDrive(procedural: 0.8, body: still) == 0)
    var brisk = FlyGymBodyFeedback()
    brisk.vx = 0.03; brisk.contacts = [1, 1, 1, 1, 1, 1]
    brisk.leftContact = 1; brisk.rightContact = 1
    check("brisk body -> ~1", abs(FlyGymSensoryMap.bodyDrive(brisk) - 1.0) < 1e-9)
    check("stale falls back", FlyGymSensoryMap.gaitDrive(procedural: 0.4, body: nil) == 0.4)
    var old = brisk; old.receivedAt = Date(timeIntervalSinceNow: -10)
    check("old packet falls back", FlyGymSensoryMap.gaitDrive(procedural: 0.4, body: old) == 0.4)
    if let body {
        var freshOdor = FlyGymBodyFeedback(body)
        check("body sim time/dt reach feedback",
              abs(freshOdor.simTime - 1.238) < 1e-9
              && abs(freshOdor.simDt - 0.002) < 1e-9
              && abs(freshOdor.simWallRatio - 0.1) < 1e-9
              && abs(freshOdor.controllerLeft - 0.21) < 1e-9
              && abs(freshOdor.controllerRight - 0.43) < 1e-9
              && abs(freshOdor.windStrength - 0.7) < 1e-9
              && freshOdor.windSensory
              && abs(freshOdor.touchStrength - 0.55) < 1e-9
              && freshOdor.touchSensory
              && abs(freshOdor.positionXmm - 14.5) < 1e-9
              && abs(freshOdor.positionYmm + 3.25) < 1e-9)
        freshOdor.receivedAt = Date()
        let o = FlyGymSensoryMap.foodOdor(body: freshOdor)
        check("fresh food odor maps", abs(o.l - 0.75) < 1e-6 && abs(o.r - 0.2) < 1e-6)
        freshOdor.receivedAt = Date(timeIntervalSinceNow: -10)
        let staleOdor = FlyGymSensoryMap.foodOdor(body: freshOdor)
        check("stale food odor clears", staleOdor.l == 0 && staleOdor.r == 0)
        check("fresh body heading maps", abs((FlyGymSensoryMap.heading(body: FlyGymBodyFeedback(body)) ?? -9) - 1.25) < 1e-9)
        check("stale body heading clears", FlyGymSensoryMap.heading(body: freshOdor) == nil)
    } else {
        check("food odor mapping", false, "body packet missing")
    }
    // 9. bounded queue: one normal latest slot + one protected escape slot.
    let b = FlyGymBridge()
    for _ in 0..<100 { b.sendBrain(s, simMs: 1) }
    check("bounded queue", b.pendingDepth() <= 2, "depth=\(b.pendingDepth())")
    s.escape = false
    b.sendBrain(s, simMs: 2)
    s.escape = true
    b.sendBrain(s, simMs: 3)
    check("escape pulse gets protected lane", b.pendingDepth() == 2,
          "depth=\(b.pendingDepth())")

    // Connection generation + freshness. Test hooks reuse the exact production
    // lifecycle/inbound paths but never open a socket.
    let freshBridge = FlyGymBridge()
    let gen1 = freshBridge.beginConnectionForTesting()
    let recvNow = Date()
    for i in 0..<5 {
        let at = recvNow.addingTimeInterval(Double(i - 4) * 0.02)
        _ = freshBridge.receiveLineForTesting(Data(line.utf8), at: at)
    }
    let liveBody = freshBridge.latestBody()
    let bodyFresh = freshBridge.bodyFreshness()
    check("body generation + simTime stamped",
          gen1 == 1 && liveBody?.connectionGeneration == gen1
          && abs((liveBody?.simTime ?? -1) - 1.238) < 1e-9)
    check("body freshness exposes age/generation",
          bodyFresh.connected && bodyFresh.isFresh
          && bodyFresh.packetGeneration == gen1
          && (bodyFresh.ageSeconds ?? 9) < 0.2)
    check("fresh bodyHz reports live cadence",
          freshBridge.bodyHz > 40 && freshBridge.bodyHz < 60,
          String(format: "%.1f Hz", freshBridge.bodyHz))

    let stateLine = #"{"type":"lab_state","t":1.25,"ack":7,"ok":true,"object_count":1,"last_action":"spawn_sphere"}"#
    let ackLine = #"{"type":"lab_ack","id":8,"ok":true,"action":"wind","message":"ok"}"#
    let eventLine = #"{"type":"lab_event","event":"wind_started"}"#
    _ = freshBridge.receiveLineForTesting(Data(stateLine.utf8), at: recvNow)
    _ = freshBridge.receiveLineForTesting(Data(ackLine.utf8), at: recvNow)
    _ = freshBridge.receiveLineForTesting(Data(eventLine.utf8), at: recvNow)
    let stateFresh = freshBridge.labStateFreshness()
    let ackFresh = freshBridge.labAckFreshness()
    let eventFresh = freshBridge.labEventFreshness()
    check("lab state/ack/event generation stamped",
          freshBridge.latestLabState()?.connectionGeneration == gen1
          && freshBridge.latestLabAck()?.connectionGeneration == gen1
          && freshBridge.latestLabEvent()?.connectionGeneration == gen1)
    check("lab state/ack/event freshness exposes age",
          stateFresh.isFresh && ackFresh.isFresh && eventFresh.isFresh
          && (stateFresh.ageSeconds ?? 9) < 0.2
          && (ackFresh.ageSeconds ?? 9) < 0.2
          && (eventFresh.ageSeconds ?? 9) < 0.2)

    // Large V4 world states used to be at risk of being discarded by the old
    // 64 KiB recv buffer guard. Exercise the exact production line-framing +
    // inbound arbitration path with all 224 default object slots and long IDs,
    // split into recv()-sized chunks.
    let largeStateBridge = FlyGymBridge()
    _ = largeStateBridge.beginConnectionForTesting()
    var largeObjects: [[String: Any]] = []
    let shapeCounts: [(String, Int)] = [("box", 64), ("sphere", 64), ("wall", 64), ("food", 32)]
    for (shape, count) in shapeCounts {
        for i in 0..<count {
            let longID = "\(shape)_\(i)_" + String(repeating: "object-id-padding-", count: 12)
            let size: [Double]
            switch shape {
            case "wall": size = [2.0, 30.0, 15.0]
            case "sphere", "food": size = [5.0, 5.0, 5.0]
            default: size = [10.0, 12.0, 8.0]
            }
            largeObjects.append([
                "id": longID,
                "shape": shape,
                "position_mm": [Double(i), Double(-i), size[2] * 0.5],
                "size_mm": size,
                "yaw_deg": Double(i % 36) * 10.0,
            ])
        }
    }
    let largeStateJSON: [String: Any] = [
        "type": "lab_state",
        "t": 12.5,
        "object_count": largeObjects.count,
        "state": [
            "objects": largeObjects,
            "slot_capacity": ["box": 64, "sphere": 64, "wall": 64, "food": 32],
            "slot_free": ["box": 0, "sphere": 0, "wall": 0, "food": 0],
        ] as [String: Any],
    ]
    var largeFrame = (try? JSONSerialization.data(withJSONObject: largeStateJSON)) ?? Data()
    let largePayloadBytes = largeFrame.count
    largeFrame.append(0x0A)
    var largeRecvBuffer = Data()
    var offset = 0
    while offset < largeFrame.count {
        let end = min(offset + 4096, largeFrame.count)
        largeStateBridge.receiveBytesForTesting(largeFrame.subdata(in: offset..<end),
                                                buffer: &largeRecvBuffer,
                                                at: recvNow)
        offset = end
    }
    let receivedLargeState = largeStateBridge.latestLabState()
    check("large lab_state exceeds historical 64 KiB guard",
          largePayloadBytes > 65_536 && largePayloadBytes < 512 * 1024,
          "bytes=\(largePayloadBytes)")
    check("224-object lab_state survives recv framing",
          largeRecvBuffer.isEmpty
          && receivedLargeState?.authoritativeObjects?.count == 224
          && receivedLargeState?.authoritativeSlotCapacity?["food"] == 32
          && receivedLargeState?.authoritativeSlotFree?["box"] == 0,
          "bytes=\(largePayloadBytes) objects=\(receivedLargeState?.authoritativeObjects?.count ?? -1)")

    // The larger legitimate limit must still be a real bound. An unterminated
    // line over 512 KiB is discarded and counted instead of growing forever.
    let malformedBeforeFlood = largeStateBridge.malformedCount
    var floodOffset = 0
    let flood = Data(repeating: 0x78, count: 512 * 1024 + 1)
    while floodOffset < flood.count {
        let end = min(floodOffset + 4096, flood.count)
        largeStateBridge.receiveBytesForTesting(flood.subdata(in: floodOffset..<end),
                                                buffer: &largeRecvBuffer,
                                                at: recvNow)
        floodOffset = end
    }
    check("recv flood guard remains bounded",
          largeRecvBuffer.isEmpty && largeStateBridge.malformedCount == malformedBeforeFlood + 1,
          "buffer=\(largeRecvBuffer.count) malformed=\(largeStateBridge.malformedCount - malformedBeforeFlood)")

    freshBridge.disconnectForTesting()
    check("disconnect clears remote state",
          !freshBridge.connected && freshBridge.latestBody() == nil
          && freshBridge.latestLabState() == nil && freshBridge.latestLabAck() == nil
          && freshBridge.latestLabEvent() == nil && freshBridge.bodyHz == 0)
    let gen2 = freshBridge.beginConnectionForTesting()
    check("reconnect advances generation and stays empty",
          gen2 == gen1 + 1 && freshBridge.latestBody() == nil
          && freshBridge.latestLabState() == nil)

    let oldAt = Date(timeIntervalSinceNow: -2)
    for i in 0..<5 {
        let at = oldAt.addingTimeInterval(Double(i) * 0.02)
        _ = freshBridge.receiveLineForTesting(Data(line.utf8), at: at)
    }
    _ = freshBridge.receiveLineForTesting(Data(stateLine.utf8), at: oldAt)
    _ = freshBridge.receiveLineForTesting(Data(ackLine.utf8), at: oldAt)
    _ = freshBridge.receiveLineForTesting(Data(eventLine.utf8), at: oldAt)
    check("stale bodyHz drops to zero",
          freshBridge.bodyHz == 0 && !freshBridge.bodyFreshness().isFresh
          && freshBridge.latestBody() == nil)
    check("stale lab age is queryable",
          !freshBridge.labStateFreshness(maxAge: 1).isFresh
          && !freshBridge.labAckFreshness(maxAge: 1).isFresh
          && !freshBridge.labEventFreshness(maxAge: 1).isFresh
          && (freshBridge.labStateFreshness(maxAge: 1).ageSeconds ?? 0) > 1.5
          && freshBridge.latestLabState(maxAge: 1) == nil
          && freshBridge.latestLabAck(maxAge: 1) == nil
          && freshBridge.latestLabEvent(maxAge: 1) == nil)

    // V4 deterministic session identity is mandatory on state/ACK packets. A
    // legacy untagged ACK or delayed old-epoch ACK must never replace the current
    // authoritative result merely because it arrived on the current TCP socket.
    let v4Filter = FlyGymBridge()
    let v4Gen1 = v4Filter.beginConnectionForTesting()
    _ = v4Filter.sendSessionControl(action: "begin", sessionID: "strict-v4",
                                    epoch: 2, simTick: 0, mode: .deterministic)
    let staleBefore = v4Filter.staleSessionPacketCount
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":31,"ok":true,"action":"touch","message":"legacy"}"#.utf8))
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":32,"ok":true,"action":"touch","message":"old","session_id":"strict-v4","epoch":1,"applied_epoch":1,"applied_tick":0}"#.utf8))
    check("deterministic ACK requires current session + epoch",
          v4Filter.latestLabAck() == nil
          && v4Filter.staleSessionPacketCount == staleBefore + 2)
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":33,"ok":true,"action":"touch","message":"ok","status":"applied","session_id":"strict-v4","epoch":2,"applied_epoch":2,"applied_tick":0,"sim_tick":0}"#.utf8))
    check("current-epoch deterministic ACK accepted",
          v4Filter.latestLabAck()?.id == 33 && v4Filter.latestLabAck()?.appliedEpoch == 2)
    _ = v4Filter.sendSessionControl(action: "reset", sessionID: "strict-v4",
                                    epoch: 3, simTick: 0, mode: .deterministic,
                                    resetScope: ["body"])
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"session_state","protocol_version":4,"session_id":"strict-v4","epoch":3,"seq":4,"sim_tick":0,"mode":"deterministic","state":"paused","ok":true}"#.utf8))
    check("reset promotes expected epoch before confirmation",
          v4Filter.latestSessionState()?.epoch == 3
          && v4Filter.latestSessionState()?.state == "paused")
    let staleAfterReset = v4Filter.staleSessionPacketCount
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":35,"ok":true,"action":"touch","message":"late epoch 2","session_id":"strict-v4","epoch":2,"applied_epoch":2,"applied_tick":20}"#.utf8))
    check("old epoch ACK rejected after reset epoch promotion",
          v4Filter.latestLabAck() == nil
          && v4Filter.staleSessionPacketCount == staleAfterReset + 1)
    v4Filter.disconnectForTesting()
    let v4Gen2 = v4Filter.beginConnectionForTesting()
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":34,"ok":true,"action":"touch","message":"after reconnect","status":"applied","session_id":"strict-v4","epoch":3,"applied_epoch":3,"applied_tick":0,"sim_tick":0}"#.utf8))
    check("reconnect generation does not become simulation epoch",
          v4Gen2 == v4Gen1 + 1 && v4Filter.latestLabAck()?.id == 34
          && v4Filter.latestLabAck()?.epoch == 3)

    let v4Overflow = FlyGymBridge()
    _ = v4Overflow.beginConnectionForTesting()
    for i in 0..<32 {
        _ = v4Overflow.sendLab(action: "spawn_sphere", target: "v4q_\(i)",
                               protocolVersion: FlyGymProtocolV4.version,
                               sessionID: "queue-v4", epoch: 1, requestedTick: 0)
    }
    let rejectedID = v4Overflow.sendLab(action: "spawn_sphere", target: "v4q_overflow",
                                        protocolVersion: FlyGymProtocolV4.version,
                                        sessionID: "queue-v4", epoch: 1, requestedTick: 0)
    check("V4 discrete queue overflow fails closed visibly",
          v4Overflow.pendingLabDepth() == 32 && v4Overflow.labDropped == 1
          && v4Overflow.latestLabAck()?.id == rejectedID
          && v4Overflow.latestLabAck()?.ok == false
          && v4Overflow.latestLabAck()?.status == "queue_full")

    let v4Order = FlyGymBridge()
    _ = v4Order.beginConnectionForTesting()
    _ = v4Order.sendSessionControl(action: "begin", sessionID: "order-v4",
                                   epoch: 1, simTick: 0, mode: .deterministic)
    // Remove hello + begin control packets from the synthetic sender lane.
    _ = v4Order.dequeueLaneForTesting(at: Date())
    _ = v4Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.02))
    _ = v4Order.sendLab(action: "touch", target: "thorax", strength: 0.3,
                        durationMs: 50,
                        protocolVersion: FlyGymProtocolV4.version,
                        sessionID: "order-v4", epoch: 1, requestedTick: 0)
    var orderSignals = BrainSignals(); orderSignals.walkDrive = 0.2
    let orderStepQueued = v4Order.sendExperimentStep(sessionID: "order-v4", epoch: 1,
                                                     seq: 1, simTick: 0,
                                                     signals: orderSignals)
    let firstBoundaryLane = v4Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.04))
    let secondBoundaryLane = v4Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.06))
    check("V4 command wire order cannot be overtaken by boundary step",
          orderStepQueued && firstBoundaryLane == .lab && secondBoundaryLane == .experimentStep)

    // Fair sender arbitration: a full 32-command lab burst must drain while a
    // normal latest-state brain packet gets the wire at least every ~75 ms.
    let fair = FlyGymBridge()
    fair.maxNormalBrainGap = 0.075
    var normal = BrainSignals()
    normal.escape = false
    fair.sendBrain(normal, simMs: 0)
    for i in 0..<32 { _ = fair.sendLab(action: "move_object", target: "fair_\(i)", x: Double(i)) }
    let fairStart = Date()
    var fairNow = fairStart
    var lastBrain = fairStart
    var maxBrainGap = 0.0
    var normalBrainSends = 0
    var labSends = 0
    var fairnessSteps = 0
    while fair.pendingLabDepth() > 0 && fairnessSteps < 100 {
        if let lane = fair.dequeueLaneForTesting(at: fairNow) {
            switch lane {
            case .brain:
                if normalBrainSends > 0 {
                    maxBrainGap = max(maxBrainGap, fairNow.timeIntervalSince(lastBrain))
                }
                lastBrain = fairNow
                normalBrainSends += 1
                fair.sendBrain(normal, simMs: fairnessSteps + 1)
            case .lab:
                labSends += 1
            case .escape:
                break
            case .control, .experimentStep, .worldRender, .rayPick, .playerInput:
                break
            }
        }
        fairNow = fairNow.addingTimeInterval(fair.minSendInterval)
        fairnessSteps += 1
    }
    maxBrainGap = max(maxBrainGap, fairNow.timeIntervalSince(lastBrain))
    check("32-lab burst preserves <=100ms brain gap",
          labSends == 32 && fair.pendingLabDepth() == 0
          && normalBrainSends > 1 && maxBrainGap <= 0.100,
          String(format: "lab=%d brain=%d maxGap=%.1fms", labSends, normalBrainSends, maxBrainGap * 1000))
    print(failures == 0 ? "ALL BRIDGE TESTS PASS" : "\(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Headless loop test (--bridgeloop, needs bridge.py --mock running)

/// Sends synthetic BrainSignals at ~60 Hz through the real TCP client and
/// counts body packets coming back. Verifies the full Swift<->Python loop.
func runBridgeLoopTest() {
    let fg = FlyGymBridge()
    fg.start()
    var waited = 0
    while !fg.connected && waited < 50 {
        Thread.sleep(forTimeInterval: 0.1); waited += 1
    }
    guard fg.connected else {
        print("FAIL  bridgeloop: no connection (is bridge.py --mock running?)")
        exit(1)
    }
    print("bridgeloop: connected, sending 200 packets @ ~75 Hz")
    let t0 = Date()
    var peakBodySpeed = 0.0
    for i in 0..<200 {
        var s = BrainSignals()
        s.walkDrive = 0.6; s.turnBias = 0.2
        s.arousal = 0.3; s.sleep = false
        fg.sendBrain(s, simMs: i * 13)
        if let b = fg.latestBody() { peakBodySpeed = max(peakBodySpeed, abs(b.vx)) }
        Thread.sleep(forTimeInterval: 1.0 / 75.0)
    }
    Thread.sleep(forTimeInterval: 1.0)   // let stragglers arrive
    if let b = fg.latestBody() { peakBodySpeed = max(peakBodySpeed, abs(b.vx)) }
    let dt = Date().timeIntervalSince(t0)
    let sent = fg.sentCount
    let recv = fg.recvCount
    let hz = fg.bodyHz
    let maxGap = fg.maxRecentBodyGap
    let finalBody = fg.latestBody()
    let simWall = finalBody?.simWallRatio ?? 0
    let brainHz = dt > 0 ? Double(sent) / dt : 0
    fg.stop()
    print(String(format: "bridgeloop: sent %d brain, recv %d body in %.1f s (brain %.1f Hz, body %.1f Hz, max body gap %.0f ms, sim/wall %.3f, peak |vx| %.2f mm/s)",
                 sent, recv, dt, brainHz, hz, maxGap * 1000, simWall, peakBodySpeed * 1000))
    // This synthetic packet intentionally asks the body to walk.  The loop is
    // not healthy if packets flow but the real body remains effectively static.
    let pass = sent >= 180 && recv >= 50 && hz >= 30
        && maxGap <= 0.250 && simWall > 0.25 && peakBodySpeed > 0.0005
    print(pass ? "BRIDGELOOP PASS" : "BRIDGELOOP FAIL")
    exit(pass ? 0 : 1)
}

// MARK: - V4 live lockstep test (--v4loop, needs bridge.py running)

/// Exercises the actual TCP V4 lifecycle without AppKit. This is intentionally
/// backend-agnostic: run it once against --mock and once against real headless
/// FlyGym to prove capability negotiation, exact 20 ms stepping, pause barriers,
/// command applied ticks, epoch reset, and true interactive body pause.
func runV4LoopTest() {
    let fg = FlyGymBridge()
    fg.start()
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !ok { failures += 1 }
    }
    func waitUntil(_ seconds: Double, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }
    func waitSession(_ sessionID: String, epoch: Int, state: String,
                     seconds: Double = 8.0) -> FlyGymSessionStatePacket? {
        var found: FlyGymSessionStatePacket?
        _ = waitUntil(seconds) {
            guard let s = fg.latestSessionState(), s.sessionID == sessionID,
                  s.epoch == epoch, s.state == state else { return false }
            found = s; return true
        }
        return found
    }
    func waitStep(_ seq: Int, seconds: Double = 12.0) -> FlyGymExperimentStepResultPacket? {
        var found: FlyGymExperimentStepResultPacket?
        _ = waitUntil(seconds) {
            guard let r = fg.latestExperimentStepResult(), r.seq == seq else { return false }
            found = r; return true
        }
        return found
    }
    func waitAck(_ id: Int, seconds: Double = 8.0) -> LabAck? {
        var found: LabAck?
        _ = waitUntil(seconds) {
            guard let a = fg.latestLabAck(), a.id == id else { return false }
            found = a; return true
        }
        return found
    }

    let connected = waitUntil(10) { fg.connected && fg.serverHello() != nil }
    check("V4 live bridge connects and receives hello", connected)
    guard connected, let hello = fg.serverHello() else {
        fg.stop(); print("V4LOOP FAIL (\(max(1, failures)))"); exit(1)
    }
    check("backend advertises deterministic V4 + exact 20ms quantum",
          hello.supportsDeterministicV4,
          String(format: "protocol=%d physics=%.6fms quanta=%@",
                 hello.protocolVersion, (hello.physicsTimestepS ?? 0) * 1000,
                 String(describing: hello.supportedQuantumTicks)))

    let session = "v4loop-\(UUID().uuidString)"
    let beginQueued = fg.sendSessionControl(action: "begin", sessionID: session,
                                            epoch: 1, simTick: 0,
                                            mode: .deterministic) != nil
    let began = waitSession(session, epoch: 1, state: "running")
    check("deterministic session begins at epoch1 tick0",
          beginQueued && began?.ok == true && began?.simTick == 0)

    let commandID = fg.sendLab(action: "wind", strength: 0.35, durationMs: 80,
                               directionDeg: 45, physical: true, sensory: true,
                               continuous: false,
                               protocolVersion: FlyGymProtocolV4.version,
                               sessionID: session, epoch: 1, requestedTick: 0)
    var signals = BrainSignals(); signals.walkDrive = 0.25; signals.turnBias = 0.05
    let step0Queued = fg.sendExperimentStep(sessionID: session, epoch: 1, seq: 1,
                                            simTick: 0, signals: signals)
    let result0 = waitStep(1)
    let commandAck = waitAck(commandID)
    check("live lockstep advances exactly 20ms",
          step0Queued && result0?.ok == true && result0?.simTick == 0
          && result0?.endSimTick == 20
          && abs((result0?.body.t ?? -1) - 0.020) < 1e-8,
          "end=\(result0?.endSimTick ?? -1) body_t=\(result0?.body.t ?? -1)")
    check("live command applies at requested boundary before step",
          commandAck?.ok == true && commandAck?.appliedEpoch == 1
          && commandAck?.appliedTick == 0 && commandAck?.status == "applied",
          "ack_tick=\(commandAck?.appliedTick ?? -1) status=\(commandAck?.status ?? "nil")")

    let pauseQueued = fg.sendSessionControl(action: "pause", sessionID: session,
                                            epoch: 1, simTick: 20,
                                            mode: .deterministic) != nil
    let paused = waitSession(session, epoch: 1, state: "paused")
    let resultCountBeforeWall = fg.experimentStepRecvCount
    let bodyTimeBeforeWall = result0?.body.t ?? -1
    let pausedCommandID = fg.sendLab(action: "touch", target: "thorax",
                                     strength: 0.25, durationMs: 100,
                                     protocolVersion: FlyGymProtocolV4.version,
                                     sessionID: session, epoch: 1, requestedTick: 20)
    Thread.sleep(forTimeInterval: 1.05)
    let resultAfterWall = fg.latestExperimentStepResult()
    let pauseFrozen = pauseQueued && paused?.ok == true
        && fg.experimentStepRecvCount == resultCountBeforeWall
        && abs((resultAfterWall?.body.t ?? bodyTimeBeforeWall) - bodyTimeBeforeWall) < 1e-12
        && fg.latestLabAck()?.id != pausedCommandID
    check("live deterministic pause freezes for >1 wall second", pauseFrozen,
          "step_results=\(resultCountBeforeWall)->\(fg.experimentStepRecvCount)")

    let resumeQueued = fg.sendSessionControl(action: "resume", sessionID: session,
                                             epoch: 1, simTick: 20,
                                             mode: .deterministic) != nil
    let resumed = waitSession(session, epoch: 1, state: "running")
    let step1Queued = fg.sendExperimentStep(sessionID: session, epoch: 1, seq: 2,
                                            simTick: 20, signals: signals)
    let result1 = waitStep(2)
    let pausedAck = waitAck(pausedCommandID)
    check("resume advances one quantum without wall catch-up",
          resumeQueued && resumed?.ok == true && step1Queued
          && result1?.ok == true && result1?.endSimTick == 40
          && abs((result1?.body.t ?? -1) - 0.040) < 1e-8)
    check("paused command applies at first resumed boundary",
          pausedAck?.ok == true && pausedAck?.appliedTick == 20
          && pausedAck?.appliedEpoch == 1)

    _ = fg.sendSessionControl(action: "pause", sessionID: session,
                              epoch: 1, simTick: 40, mode: .deterministic)
    let pausedForReset = waitSession(session, epoch: 1, state: "paused")
    let resetQueued = fg.sendSessionControl(action: "reset", sessionID: session,
                                            epoch: 2, simTick: 0,
                                            mode: .deterministic,
                                            resetScope: ["body", "world"]) != nil
    let resetState = waitSession(session, epoch: 2, state: "paused")
    check("live logical reset advances epoch exactly once",
          pausedForReset?.ok == true && resetQueued && resetState?.ok == true
          && resetState?.epoch == 2 && resetState?.simTick == 0)

    // Start a fresh interactive session and prove its autonomous body loop also
    // stops at a real pause barrier. Interactive mode remains wall-paced, but
    // pause is no longer a SceneKit-only display state.
    let interactive = "v4loop-interactive-\(UUID().uuidString)"
    let interactiveBegin = fg.sendSessionControl(action: "begin", sessionID: interactive,
                                                  epoch: 1, simTick: 0,
                                                  mode: .interactive) != nil
    let interactiveRunning = waitSession(interactive, epoch: 1, state: "running")
    let gotInteractiveBody = waitUntil(12) { (fg.latestBody(maxAge: 2.0)?.simTime ?? 0) > 0 }
    let bodyBeforePauseRequest = fg.latestBody(maxAge: 2.0)?.simTime ?? -1
    let interactivePause = fg.sendSessionControl(action: "pause", sessionID: interactive,
                                                  epoch: 1, simTick: 0,
                                                  mode: .interactive) != nil
    let interactivePaused = waitSession(interactive, epoch: 1, state: "paused")
    // The backend may already be inside one autonomous physics chunk when the
    // control packet arrives. The pause barrier is the confirmed boundary after
    // that in-flight chunk, not the earlier wall instant when Swift queued it.
    let bodyAtPauseBarrier = fg.latestBody(maxAge: 2.0)?.simTime ?? -1
    Thread.sleep(forTimeInterval: 1.05)
    let bodyDuringPause = fg.latestBody(maxAge: 5.0)?.simTime ?? -2
    check("interactive V4 pause stops autonomous body physics",
          interactiveBegin && interactiveRunning?.ok == true && gotInteractiveBody
          && interactivePause && interactivePaused?.ok == true
          && bodyAtPauseBarrier >= bodyBeforePauseRequest
          && abs(bodyDuringPause - bodyAtPauseBarrier) < 1e-12,
          String(format: "request_t %.6f barrier_t %.6f -> %.6f",
                 bodyBeforePauseRequest, bodyAtPauseBarrier, bodyDuringPause))
    _ = fg.sendSessionControl(action: "resume", sessionID: interactive,
                              epoch: 1, simTick: 0, mode: .interactive)
    _ = waitSession(interactive, epoch: 1, state: "running")
    let interactiveAdvanced = waitUntil(12) {
        (fg.latestBody(maxAge: 2.0)?.simTime ?? bodyAtPauseBarrier) > bodyAtPauseBarrier + 1e-6
    }
    check("interactive resume advances again without paused-wall catch-up", interactiveAdvanced)

    // Same-machine repeatability: begin a fresh deterministic session, which
    // resets body/controller state, then replay the identical first-boundary
    // wind command and neural command used above. Protocol/controller fields are
    // exact; real MuJoCo observables use a tight numeric tolerance rather than a
    // cross-hardware bit-identity claim.
    let repeatSession = "v4loop-repeat-\(UUID().uuidString)"
    _ = fg.sendSessionControl(action: "begin", sessionID: repeatSession,
                              epoch: 1, simTick: 0, mode: .deterministic)
    let repeatBegan = waitSession(repeatSession, epoch: 1, state: "running")
    let repeatCommandID = fg.sendLab(action: "wind", strength: 0.35, durationMs: 80,
                                     directionDeg: 45, physical: true, sensory: true,
                                     continuous: false,
                                     protocolVersion: FlyGymProtocolV4.version,
                                     sessionID: repeatSession, epoch: 1, requestedTick: 0)
    let repeatQueued = fg.sendExperimentStep(sessionID: repeatSession, epoch: 1,
                                             seq: 1, simTick: 0, signals: signals)
    let repeatResult = waitStep(1)
    let repeatAck = waitAck(repeatCommandID)
    let reference = result0?.body
    let repeated = repeatResult?.body
    let exactRepeat = repeatBegan?.ok == true && repeatQueued
        && repeatResult?.ok == true && repeatResult?.endSimTick == result0?.endSimTick
        && repeatAck?.appliedTick == commandAck?.appliedTick
        && repeated?.t == reference?.t && repeated?.simDt == reference?.simDt
        && repeated?.controllerLeft == reference?.controllerLeft
        && repeated?.controllerRight == reference?.controllerRight
        && repeated?.contacts == reference?.contacts
    let physicalTolerance = 1e-9
    let numericRepeat = abs((repeated?.vx ?? .infinity) - (reference?.vx ?? 0)) <= physicalTolerance
        && abs((repeated?.yawRate ?? .infinity) - (reference?.yawRate ?? 0)) <= physicalTolerance
        && abs((repeated?.headingRad ?? .infinity) - (reference?.headingRad ?? 0)) <= physicalTolerance
    check("same-machine repeated deterministic real/mock quantum is reproducible",
          exactRepeat && numericRepeat,
          String(format: "Δvx=%.3g Δyaw=%.3g Δheading=%.3g",
                 abs((repeated?.vx ?? .infinity) - (reference?.vx ?? 0)),
                 abs((repeated?.yawRate ?? .infinity) - (reference?.yawRate ?? 0)),
                 abs((repeated?.headingRad ?? .infinity) - (reference?.headingRad ?? 0))))

    fg.stop()
    print(failures == 0 ? "V4LOOP PASS" : "V4LOOP FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Live lab protocol test (--labloop, needs bridge.py running)

/// Exercises the actual TCP lab lane and acknowledgement/state/event path.
/// Works against both `bridge.py --mock` and real FlyGym.
func runLabLoopTest() {
    let fg = FlyGymBridge()
    fg.start()
    var waited = 0
    while !fg.connected && waited < 80 {
        Thread.sleep(forTimeInterval: 0.1); waited += 1
    }
    guard fg.connected else {
        print("FAIL  labloop: no connection (start bridge.py --mock or --flygym-headless)")
        exit(1)
    }

    func waitAck(_ id: Int, seconds: Double = 3.0) -> LabAck? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let ack = fg.latestLabAck(), ack.id == id { return ack }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    var failures = 0
    func command(_ name: String, _ id: Int) {
        let ack = waitAck(id)
        let ok = ack?.ok == true
        let fresh = fg.labAckFreshness()
        let ageMs = fresh.ageSeconds.map { String(format: "%.0f", $0 * 1000) } ?? "n/a"
        print("\(ok ? "PASS" : "FAIL")  labloop \(name) ack=\(ack?.id ?? -1) \(ack?.message ?? "timeout")"
              + " gen=\(fresh.packetGeneration.map(String.init) ?? "n/a")/\(fresh.currentGeneration) age=\(ageMs)ms")
        if !ok { failures += 1 }
    }

    func bodyDiagnostic(_ body: FlyGymBodyFeedback?) -> String {
        let fresh = fg.bodyFreshness()
        let ageMs = fresh.ageSeconds.map { String(format: "%.0f", $0 * 1000) } ?? "n/a"
        guard let body else {
            return "body=nil gen=\(fresh.packetGeneration.map(String.init) ?? "n/a")/\(fresh.currentGeneration) age=\(ageMs)ms fresh=\(fresh.isFresh)"
        }
        return String(format: "t=%.4fs dt=%.4fs wind=%.3f touch=%.3f gen=%@/%llu age=%@ms fresh=%@",
                      body.simTime, body.simDt, body.windStrength, body.touchStrength,
                      fresh.packetGeneration.map(String.init) ?? "n/a", fresh.currentGeneration,
                      ageMs, fresh.isFresh ? "yes" : "no")
    }

    let objectID = "labloop_ball_\(ProcessInfo.processInfo.processIdentifier)"
    let spawn = fg.sendLab(action: "spawn_sphere", target: objectID,
                           x: 20, y: 5, z: 3, size: 4)
    command("spawn", spawn)
    if (fg.latestLabState()?.objectCount ?? 0) < 1 {
        Thread.sleep(forTimeInterval: 0.15)
    }
    let stateOK = (fg.latestLabState()?.objectCount ?? 0) >= 1
    print("\(stateOK ? "PASS" : "FAIL")  labloop state object_count=\(fg.latestLabState()?.objectCount ?? -1)")
    if !stateOK { failures += 1 }

    let wind = fg.sendLab(action: "wind", strength: 0.2, durationMs: 300,
                          directionDeg: 90, physical: true, sensory: true, continuous: false)
    command("wind", wind)
    let flash = fg.sendLab(action: "flash_eye", target: "left", strength: 0.8, durationMs: 80)
    command("flash", flash)
    let touch = fg.sendLab(action: "touch", target: "thorax", strength: 0.2, durationMs: 300)
    command("touch", touch)
    let sourceDeadline = Date().addingTimeInterval(0.25)
    var sourceOK = false
    var sourceBody: FlyGymBodyFeedback?
    while Date() < sourceDeadline {
        if let body = fg.latestBody(), body.windStrength > 0.19, body.windSensory,
           body.touchStrength > 0.19, body.touchSensory {
            sourceOK = true
            sourceBody = body
            break
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    print("\(sourceOK ? "PASS" : "FAIL")  labloop body packet is wind/touch source-of-truth — \(bodyDiagnostic(sourceBody ?? fg.latestBody()))")
    if !sourceOK { failures += 1 }

    // The backend timer is expressed in MuJoCo simulation time, not wall time.
    // A slow real backend may need much more than 300 ms of wall time to advance
    // 300 ms of simulation. Accept only a bounded simulation-time expiry window:
    // too-early clear, frozen timers and excessively late clear are all failures.
    // The tolerance covers one observed body packet plus a few physics/telemetry
    // steps; wall time remains only a hang guard.
    let sourceSimTime = sourceBody?.simTime ?? fg.latestBody()?.simTime ?? 0
    let requestedDurationS = 0.300
    let sourceDt = max(0.001, sourceBody?.simDt ?? fg.latestBody()?.simDt ?? 0.001)
    let expiryToleranceS = max(0.060, min(0.120, sourceDt * 4 + 0.020))
    let expiryTargetSimTime = sourceSimTime + requestedDurationS
    let expiryEarliestSimTime = expiryTargetSimTime - expiryToleranceS
    let expiryLatestSimTime = expiryTargetSimTime + expiryToleranceS
    let expiryWallDeadline = Date().addingTimeInterval(12.0)
    var expired: FlyGymBodyFeedback?
    var expiredTooEarly = false
    var expiredTooLate = false
    var expiredInWindow = false
    while Date() < expiryWallDeadline {
        if let body = fg.latestBody() {
            expired = body
            let cleared = body.windStrength == 0 && body.touchStrength == 0
            if cleared {
                if body.simTime < expiryEarliestSimTime {
                    expiredTooEarly = true
                } else if body.simTime <= expiryLatestSimTime {
                    expiredInWindow = true
                } else {
                    expiredTooLate = true
                }
                break
            }
            if body.simTime > expiryLatestSimTime {
                expiredTooLate = true
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let expiredOK = expiredInWindow && !expiredTooEarly && !expiredTooLate
    print("\(expiredOK ? "PASS" : "FAIL")  labloop body source clears on simulation-time timer expiry"
          + " target_t=\(String(format: "%.4f", expiryTargetSimTime))s"
          + " window=[\(String(format: "%.4f", expiryEarliestSimTime)),\(String(format: "%.4f", expiryLatestSimTime))]s"
          + " — \(bodyDiagnostic(expired))")
    if !expiredOK { failures += 1 }
    if let event = fg.latestLabEvent() {
        print("PASS  labloop event \(event.event)")
    } else {
        print("FAIL  labloop event missing"); failures += 1
    }
    // Clean up only the object this test created. Never reset an already-running
    // user's body/world merely because --labloop connected to that listener.
    let cleanup = fg.sendLab(action: "delete_object", target: objectID)
    command("delete_object", cleanup)

    fg.stop()
    print(failures == 0 ? "LABLOOP PASS" : "LABLOOP FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - V5.6 live participant interaction (--interactionloop)

/// Uses only the bridge methods used by LabWindow. Each invocation needs a fresh
/// test-owned backend, because beginning a session changes the backend world.
func runInteractionLoopTest() {
    let fg = FlyGymBridge()
    fg.start()
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  interactionloop \(name) \(detail)")
        if !ok { failures += 1 }
    }
    func wait<T>(_ seconds: Double, _ read: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let value = read() { return value }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return read()
    }
    func snapshot(after tick: Int = -1, containing id: String? = nil,
                  seconds: Double = 25) -> WorldRenderSnapshot? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let seq = fg.requestWorldRenderSnapshot(),
               let s: WorldRenderSnapshot = wait(2.0, {
                   guard let s = fg.latestWorldRenderSnapshot(maxAge: 5),
                         s.requestSeq == seq, s.ok, s.simTick > tick,
                         s.player != nil,
                         id == nil || s.objects.contains(where: { $0.id == id }) else { return nil }
                   return s
               }) { return s }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }
    var ackCursor: UInt64 = 0
    func commandAck(_ id: Int, seconds: Double = 25) -> LabAck? {
        wait(seconds) {
            let batch = fg.labAcks(after: ackCursor)
            ackCursor = batch.serial
            return batch.acks.first(where: { $0.id == id })
        }
    }
    var eventCursor: UInt64 = 0
    var eventNames: [String] = []
    var events: [LabEventNotice] = []
    func collectEvents() {
        let batch = fg.labEvents(after: eventCursor)
        eventCursor = batch.serial
        eventNames += batch.events.map(\.event)
        events += batch.events
    }
    let connected: Bool = wait(12) { fg.connected && fg.serverHello() != nil ? true : nil } ?? false
    check("connected", connected)
    guard connected, let hello = fg.serverHello() else {
        fg.stop(); print("INTERACTIONLOOP FAIL (\(failures))"); exit(1)
    }
    check("hello player_body/player_input", hello.supportsPlayerInputV5_5,
          "capabilities=\(hello.capabilities)")
    let session = "interactionloop-\(UUID().uuidString)"
    let began = fg.sendSessionControl(action: "begin", sessionID: session,
                                      epoch: 1, simTick: 0, mode: .interactive) != nil
    let running: FlyGymSessionStatePacket? = wait(30) {
        guard let s = fg.latestSessionState(), s.sessionID == session,
              s.epoch == 1, s.state == "running" else { return nil }
        return s
    }
    check("interactive session", began && running?.ok == true,
          "session=\(session) state=\(running?.state ?? "timeout")")
    func lab(_ action: String, target: String? = nil,
             x: Double? = nil, y: Double? = nil, z: Double? = nil,
             size: Double? = nil, value: Double? = nil, tick: Int = 0) -> LabAck? {
        let id = fg.sendLab(action: action, target: target, x: x, y: y, z: z,
                            size: size, value: value,
                            protocolVersion: FlyGymProtocolV4.version,
                            sessionID: session, epoch: 1, requestedTick: tick)
        return commandAck(id)
    }
    func interaction(_ tool: String, ray: WorldViewerRay? = nil,
                     target: String? = nil, tick: Int) -> LabAck? {
        guard let id = fg.sendInteraction(toolID: tool, actorID: "player", target: target,
                                          rayOriginMM: ray?.originMM,
                                          rayDirection: ray?.direction,
                                          protocolVersion: FlyGymProtocolV4.version,
                                          sessionID: session, epoch: 1,
                                          requestedTick: tick) else { return nil }
        return commandAck(id)
    }
    let activate = lab("set_player_active", value: 1)
    check("activate participant", activate?.ok == true,
          "ack=\(activate?.id ?? -1) \(activate?.message ?? "timeout")")
    var base = snapshot()
    check("authoritative participant snapshot", base != nil,
          "tick=\(base?.simTick ?? -1)")
    let id = "interactionloop_box_\(ProcessInfo.processInfo.processIdentifier)"
    var created = false
    if let s = base, let player = s.player,
       let ray = WorldViewer.participantAimRay(player: player) {
        // One small box on the same participant ray, about 7 mm from its eye.
        let p = (0..<3).map { ray.originMM[$0] + ray.direction[$0] * 7 }
        let spawn = lab("spawn_box", target: id, x: p[0], y: p[1], z: p[2],
                        size: 2, tick: s.simTick)
        created = spawn?.ok == true
        check("legacy spawn ACK", created && spawn?.action == "spawn_box"
              && spawn?.status == "applied",
              "ack=\(spawn?.id ?? -1) action=\(spawn?.action ?? "nil") status=\(spawn?.status ?? "nil") tick=\(spawn?.appliedTick ?? -1)")
        base = snapshot(after: s.simTick, containing: id)
        check("spawn visible in new snapshot", base != nil,
              "tick=\(base?.simTick ?? -1)")
    } else { check("aim ray from snapshot", false) }

    if let s = base, let player = s.player,
       let ray = WorldViewer.participantAimRay(player: player), created {
        let grab = interaction("grab", ray: ray, target: id, tick: s.simTick)
        let held = fg.latestLabState()?.interaction?.heldObjectID
        collectEvents()
        check("grab ACK and held state", grab?.ok == true && held == id,
              "ack=\(grab?.id ?? -1) error=\(grab?.message ?? "timeout") held=\(held ?? "nil")")
        check("object_grabbed event", eventNames.contains("object_grabbed"),
              "events=\(eventNames)")

        let before = snapshot(containing: id)
        let moveTick = before?.simTick ?? s.simTick
        let inputSeq = fg.sendPlayerInput(sessionID: session, epoch: 1,
                                          requestedTick: moveTick,
                                          moveAxes: [0, 1], lookDelta: [0, 0],
                                          heldActions: [])
        let inputResult: PlayerInputResult? = wait(20) {
            guard let r = fg.latestPlayerInputResult(), r.seq == inputSeq else { return nil }
            return r
        }
        check("lateral PlayerInput ACK", inputSeq != nil && inputResult?.ok == true,
              "seq=\(inputSeq ?? -1) status=\(inputResult?.status ?? "timeout")")
        var samples: [WorldRenderSnapshot] = []
        if let before { samples.append(before) }
        let targetTick = moveTick + 400
        let moveDeadline = Date().addingTimeInterval(40)
        while Date() < moveDeadline && (samples.last?.simTick ?? moveTick) < targetTick {
            if let next = snapshot(after: samples.last?.simTick ?? moveTick,
                                   containing: id, seconds: 3) { samples.append(next) }
        }
        let releaseTick = samples.last?.simTick ?? moveTick
        let releaseSeq = fg.sendPlayerInput(sessionID: session, epoch: 1,
                                            requestedTick: releaseTick,
                                            moveAxes: [0, 0], lookDelta: [0, 0],
                                            heldActions: [], discardPendingLook: true)
        let releaseResult: PlayerInputResult? = wait(20) {
            guard let r = fg.latestPlayerInputResult(), r.seq == releaseSeq else { return nil }
            return r
        }
        check("release PlayerInput ACK", releaseSeq != nil && releaseResult?.ok == true)
        func object(_ s: WorldRenderSnapshot) -> WorldRenderObject? {
            s.objects.first(where: { $0.id == id })
        }
        // Adjacent snapshots can be a few ms apart, where integer-ms tick
        // provenance inflates the apparent speed; only >=100 ms windows count.
        var maxSpeed = 0.0
        for (i, first) in samples.enumerated() {
            for second in samples[(i + 1)...] {
                let dt = Double(second.simTick - first.simTick) / 1000
                guard dt >= 0.1, let a = object(first), let b = object(second) else { continue }
                maxSpeed = max(maxSpeed, hypot(b.positionMM[0] - a.positionMM[0],
                                               b.positionMM[1] - a.positionMM[1]) / dt)
            }
        }
        let start = samples.first.flatMap(object)?.positionMM
        let end = samples.last.flatMap(object)?.positionMM
        let distance = start != nil && end != nil
            ? hypot(end![0] - start![0], end![1] - start![1]) : 0
        let simMs = (samples.last?.simTick ?? moveTick) - (samples.first?.simTick ?? moveTick)
        check("carry moves box", distance > 0.5 && simMs >= 300,
              String(format: "distance=%.4fmm sim=%dms max_sample_speed=%.4fmm/s samples=%d",
                     distance, simMs, maxSpeed, samples.count))
        // Compare against the live backend bound, not a copied constant; the
        // 2 mm/s margin covers snapshot spacing and integer-ms tick quantization.
        let liveSpeed = fg.latestLabState()?.interaction?.carrySpeedMMs
        check("carry_speed_mm_s observable from public state",
              liveSpeed.map { $0.isFinite && $0 > 0 } == true,
              "carry_speed_mm_s=\(liveSpeed.map { String($0) } ?? "nil")")
        check("carry speed <= live backend bound + sampling margin 2mm/s",
              liveSpeed != nil && maxSpeed <= liveSpeed! + 2.0 && samples.count >= 2,
              String(format: "max_sample_speed=%.4fmm/s bound=%@", maxSpeed,
                     liveSpeed.map { String($0) } ?? "nil"))

        let placeSnapshot = snapshot(containing: id)
        let place = interaction("place", target: id,
                                tick: placeSnapshot?.simTick ?? releaseTick)
        collectEvents()
        check("place ACK and released state", place?.ok == true
              && fg.latestLabState()?.interaction != nil
              && fg.latestLabState()?.interaction?.heldObjectID == nil,
              "ack=\(place?.id ?? -1) error=\(place?.message ?? "timeout")")
        check("object_placed event", eventNames.contains("object_placed"),
              "events=\(eventNames)")
        let stillStart = snapshot(containing: id)
        let stillEnd = snapshot(after: (stillStart?.simTick ?? releaseTick) + 60,
                                containing: id)
        let stillA = stillStart.flatMap(object)?.positionMM
        let stillB = stillEnd.flatMap(object)?.positionMM
        let stillDistance = stillA != nil && stillB != nil
            ? hypot(stillB![0] - stillA![0], stillB![1] - stillA![1]) : .infinity
        check("placed box stays still", stillDistance < 0.01,
              String(format: "distance=%.6fmm ticks=%d..%d", stillDistance,
                     stillStart?.simTick ?? -1, stillEnd?.simTick ?? -1))

        let noHold = interaction("place", tick: stillEnd?.simTick ?? releaseTick)
        let afterNoHold = snapshot(containing: id)
        let noHoldPosition = afterNoHold.flatMap(object)?.positionMM
        check("reject place without held object", noHold?.ok == false
              && noHold?.message.hasPrefix("not_holding") == true
              && fg.latestLabState()?.interaction?.heldObjectID == nil
              && noHoldPosition == stillB,
              "error=\(noHold?.message ?? "timeout")")
        if let fresh = snapshot(containing: id), let p = fresh.player,
           let freshRay = WorldViewer.participantAimRay(player: p) {
            let sky = WorldViewerRay(originMM: freshRay.originMM,
                                     direction: [0, 0, 1])
            let miss = interaction("grab", ray: sky, tick: fresh.simTick)
            let afterMiss = snapshot(containing: id)
            check("reject sky grab", miss?.ok == false
                  && miss?.message.hasPrefix("ray_miss") == true
                  && fg.latestLabState()?.interaction?.heldObjectID == nil
                  && afterMiss.flatMap(object)?.positionMM == object(fresh)?.positionMM,
                  "error=\(miss?.message ?? "timeout")")
            let far = (0..<3).map { freshRay.originMM[$0] + freshRay.direction[$0] * 25 }
            let move = lab("move_object", target: id, x: far[0], y: far[1], z: far[2],
                           tick: fresh.simTick)
            check("legacy move ACK", move?.ok == true && move?.action == "move_object"
                  && move?.status == "applied",
                  "ack=\(move?.id ?? -1) action=\(move?.action ?? "nil") tick=\(move?.appliedTick ?? -1)")
            if let distant = snapshot(after: fresh.simTick, containing: id),
               let aim = distant.player.flatMap({ WorldViewer.participantAimRay(player: $0) }) {
                let farGrab = interaction("grab", ray: aim, target: id,
                                          tick: distant.simTick)
                let afterFarGrab = snapshot(containing: id)
                check("reject out-of-reach grab", farGrab?.ok == false
                      && farGrab?.message.hasPrefix("out_of_reach") == true
                      && fg.latestLabState()?.interaction?.heldObjectID == nil
                      && afterFarGrab.flatMap(object)?.positionMM == object(distant)?.positionMM,
                      "error=\(farGrab?.message ?? "timeout")")
            } else { check("distant snapshot", false) }
        } else { check("rejection snapshot", false) }
    }

    collectEvents()
    let grabbed = events.first { $0.event == "object_grabbed" }?.detail
    let placed = events.first { $0.event == "object_placed" && $0.detail?.reason == "place" }?.detail
    check("event id/reason/integer sim_tick_ms observable",
          grabbed?.id == id && grabbed?.simTickMS != nil
          && placed?.id == id && placed?.simTickMS != nil
          && placed!.simTickMS! >= grabbed!.simTickMS!,
          "grabbed=\(grabbed.map(\.summary) ?? "nil") placed=\(placed.map(\.summary) ?? "nil")")
    if created {
        let cleanup = lab("delete_object", target: id)
        check("legacy delete ACK", cleanup?.ok == true
              && cleanup?.action == "delete_object" && cleanup?.status == "applied",
              "ack=\(cleanup?.id ?? -1) action=\(cleanup?.action ?? "nil") tick=\(cleanup?.appliedTick ?? -1)")
    }
    let inactive = lab("set_player_active", value: 0)
    check("deactivate participant", inactive?.ok == true)
    fg.stop()
    print(failures == 0 ? "INTERACTIONLOOP PASS" : "INTERACTIONLOOP FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}
