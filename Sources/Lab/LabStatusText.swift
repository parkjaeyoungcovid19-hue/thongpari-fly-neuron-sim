import Foundation

enum LabStatusText {
    static func signalPath(_ t: LabTelemetry) -> String {
        let nearest = t.bodyNearestFoodDistanceMm >= 0
            ? String(format: "%.1f mm", t.bodyNearestFoodDistanceMm)
            : L("none", "없음")
        // The body packet is the same fresh backend snapshot that drives the
        // neural model, so source diagnostics cannot disagree with actual
        // LabWorld timer expiry merely because lab_state arrived at another rate.
        let windSource = t.bodyPacketAgeS >= 0
            ? String(format: "%.2f%@", t.bodyWindStrength,
                     (t.bodyWindStrength > 0 && t.bodyWindSensory) ? L(" sensory", " 감각") : "")
            : L("unavailable", "없음")
        let touchSource = t.bodyPacketAgeS >= 0
            ? String(format: "%.2f%@", t.bodyTouchStrength,
                     (t.bodyTouchStrength > 0 && t.bodyTouchSensory) ? L(" sensory", " 감각") : "")
            : L("unavailable", "없음")
        let sourceLine = String(format: L("1  Source → sensor     food %@ → odor %.3f/%.3f  |  vision expansion %.3f/%.3f → loom %.3f/%.3f  |  wind %@  |  touch %@  |  temp %.1f°C", "1  바깥 자극 → 감각기관    먹이 %@ → 냄새 %.3f/%.3f  |  눈에 보이는 커짐 %.3f/%.3f → 다가옴 %.3f/%.3f  |  바람 %@  |  닿음 %@  |  온도 %.1f°C"),
            nearest, t.bodyOdorL, t.bodyOdorR,
            t.bodyOpticExpansionL, t.bodyOpticExpansionR, t.loomL, t.loomR,
            windSource, touchSource, t.temperatureC)
        let currentLine = String(format: L("2  Sensor → current    ORN food %.3f/%.3f  |  TRN warm/cool %.3f/%.3f  |  JO-C/E wind %.3f/%.3f  (simulation current units)", "2  감각기관 → 신호 세기    먹이 냄새 %.3f/%.3f  |  따뜻함/차가움 %.3f/%.3f  |  더듬이 바람 C/E %.3f/%.3f  (시뮬레이션 단위)"),
            t.odorDriveL, t.odorDriveR, t.thermoWarmDrive, t.thermoCoolDrive,
            t.windCDrive, t.windEDrive)
        let neuralLine = String(format: L("3  Receptor → brain    ORN L/R %.1f/%.1f Hz  |  TRN warm/cool %.1f/%.1f  |  JO-C/E %.1f/%.1f  |  loom %.1f  |  DNa L/R %.1f/%.1f  |  DNp09 %.1f", "3  감각 뉴런 → 뇌    후각 L/R %.1f/%.1f Hz  |  따뜻함/차가움 %.1f/%.1f  |  바람 C/E %.1f/%.1f  |  다가옴 감지 %.1f  |  왼쪽/오른쪽 돌기 %.1f/%.1f  |  앞으로 걷기 %.1f"),
            t.rateFoodOdorL, t.rateFoodOdorR, t.rateThermoWarm, t.rateThermoCool,
            t.rateWindC, t.rateWindE, t.rateLoom, t.rateDNaL, t.rateDNaR, t.rateFwd)
        let commandLine: String
        if t.brainSignalsAvailable {
            commandLine = String(format: L("4  BrainSignals → FlyGym controller    walk %.2f  |  turn %.2f  |  escape %@  |  back %@  |  groom %.2f  |  wing %.2f  |  arousal %.2f  |  nervous %.2f  |  tempo %.2f  |  sleep %@  |  controller L/R %.3f/%.3f", "4  뇌 → 몸에 내린 명령    걷기 %.2f  |  돌기 %.2f  |  도망 %@  |  뒤로 %@  |  손질 %.2f  |  날개 %.2f  |  흥분도 %.2f  |  긴장 %.2f  |  활동 속도 %.2f  |  잠 %@  |  왼쪽/오른쪽 출력 %.3f/%.3f"),
                t.brainWalkDrive, t.brainTurnBias, onOff(t.brainEscape),
                onOff(t.brainBackward), t.brainGroomDrive, t.brainWingDrive,
                t.brainArousal, t.brainNervous, t.brainTempo, onOff(t.brainSleep),
                t.bodyControllerLeft, t.bodyControllerRight)
        } else {
            commandLine = String(format: L("4  BrainSignals → FlyGym controller    no decoded BrainSignals this frame  |  controller L/R %.3f/%.3f", "4  뇌 → 몸에 내린 명령    이번 순간에는 해석된 명령 없음  |  왼쪽/오른쪽 출력 %.3f/%.3f"),
                t.bodyControllerLeft, t.bodyControllerRight)
        }
        let bodyPacketDetail = t.bodyPacketAgeS >= 0
            ? String(format: L("body packet %.0f ms old · MuJoCo t %.3f s · sim/wall %.2fx",
                               "몸 데이터 %.0f ms 전 · 물리 시각 %.3f s · 실시간 대비 %.2f배"),
                     t.bodyPacketAgeS * 1000, t.bodySimTime, t.bodySimWallRatio)
            : L("no fresh body packet used", "새 몸 데이터 없음")
        let motionLine = String(format: L("5  Measured motion     forward %.4f m/s  |  yaw %.2f rad/s  |  contact %.2f  |  %@", "5  실제로 측정한 움직임    앞으로 %.4f m/s  |  회전 %.2f rad/s  |  발 닿음 %.2f  |  %@"),
            t.bodyVX, t.bodyYawRate, t.bodyContactMean, bodyPacketDetail)
        return [sourceLine, currentLine, neuralLine, commandLine, motionLine]
            .joined(separator: "\n")
    }
    static func remoteState(_ state: LabRemoteState?, event: String?) -> String {
        guard let s = state else {
            return L("Environment — waiting for FlyGym state…", "환경 — 시뮬레이터 상태를 기다리는 중…")
        }
                var bits = [String(format: "%.1f s", s.t)]
                if let n = s.objectCount { bits.append(L("\(n) object\(n == 1 ? "" : "s")", "물체 \(n)개")) }
                if let w = s.wind { bits.append(String(format: L("wind %.2f", "바람 %.2f"), w)) }
                if let c = s.temperature { bits.append(String(format: "%.1f°C", c)) }
                let eyeState = { (covered: Bool) in covered ? L("covered", "가림") : L("open", "뜸") }
                if let l = s.leftEyeCovered { bits.append(L("left eye ", "왼눈 ") + eyeState(l)) }
                if let r = s.rightEyeCovered { bits.append(L("right eye ", "오른눈 ") + eyeState(r)) }
                if let e = s.error, !e.isEmpty { bits.append(L("error: ", "오류: ") + e) }
                if let event, !event.isEmpty { bits.append(L("last event: ", "최근 알림: ") + event) }
        return L("Environment — ", "환경 — ") + bits.joined(separator: " · ")
    }
    private static func onOff(_ value: Bool) -> String { value ? L("ON", "켬") : L("OFF", "끔") }
}
