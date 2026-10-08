// FlyMood.swift — a small, rule-based "mood" readout for the Lab canvas.
//
// This is a presentation aid for non-specialists, not a measurement of what the
// fly feels. Each mood is a fixed rule over signals the simulator actually
// exposes (food odour at the antennae, temperature, touch impulses, the escape
// and looming readouts, sleep state), and the reason line always names the
// signal that produced it.

import Foundation

struct FlyMoodInputs {
    var foodOdor: Double = 0           // max of left/right antenna odour, 0…1
    var nearestFoodMM: Double = -1     // < 0 when there is no food
    var temperatureC: Double = 25
    var escape = false                 // giant-fiber escape readout
    var nervous: Double = 0            // looming-driven nervousness, 0…1
    var sleep = false
    var grooming: Double = 0
}

enum FlyMood: Equatable {
    case calm, happy, cold, hot, hurt, angry, scared, sleepy, grooming

    var emoji: String {
        switch self {
        case .calm: return "🙂"
        case .happy: return "😊"
        case .cold: return "🥶"
        case .hot: return "🥵"
        case .hurt: return "😣"
        case .angry: return "😠"
        case .scared: return "😨"
        case .sleepy: return "😴"
        case .grooming: return "😌"
        }
    }

    var title: String {
        switch self {
        case .calm: return L("Calm", "평온")
        case .happy: return L("Happy", "행복")
        case .cold: return L("Sad — cold", "슬픔 — 추워요")
        case .hot: return L("Sad — too hot", "슬픔 — 더워요")
        case .hurt: return L("Sad — hurt", "슬픔 — 아파요")
        case .angry: return L("Angry", "화남")
        case .scared: return L("Scared", "겁남")
        case .sleepy: return L("Sleepy", "졸림")
        case .grooming: return L("Relaxed — grooming", "느긋함 — 몸 손질 중")
        }
    }
}

struct FlyMoodReading: Equatable {
    let mood: FlyMood
    let reason: String
}

/// Keeps short-lived memories of being hit so a single tap reads as anger for a
/// few seconds and fades, while repeated or hard hits last longer.
final class FlyMoodEstimator {
    static let coldBelowC = 18.0
    static let hotAboveC = 30.0
    static let hurtStrength = 0.8
    private static let halfLifeS = 4.0

    private var anger = 0.0
    private var pain = 0.0
    private var lastUpdate: Date?

    func registerHit(strength: Double, at now: Date = Date()) {
        decay(to: now)
        let s = max(0, min(1, strength))
        anger = min(2, anger + s)
        if s >= Self.hurtStrength { pain = min(2, pain + s) }
    }

    func reset() {
        anger = 0
        pain = 0
        lastUpdate = nil
    }

    private func decay(to now: Date) {
        if let lastUpdate {
            let dt = max(0, now.timeIntervalSince(lastUpdate))
            let k = pow(0.5, dt / Self.halfLifeS)
            anger *= k
            pain *= k
        }
        lastUpdate = now
    }

    func update(_ i: FlyMoodInputs, now: Date = Date()) -> FlyMoodReading {
        decay(to: now)
        if i.escape || i.nervous >= 0.5 {
            return .init(mood: .scared, reason: i.escape
                ? L("escape neuron (GF) fired", "비상 탈출 뉴런(GF)이 켜졌어요")
                : L("something is looming toward it", "무언가 빠르게 다가오고 있어요"))
        }
        if pain >= 0.3 {
            return .init(mood: .hurt, reason: L("it was hit hard", "세게 맞았어요"))
        }
        if anger >= 0.25 {
            return .init(mood: .angry, reason: anger >= 1
                ? L("it keeps getting hit", "계속 맞고 있어요")
                : L("it was just hit", "방금 맞았어요"))
        }
        if i.temperatureC < Self.coldBelowC {
            return .init(mood: .cold, reason: String(format: L("%.0f °C is too cold", "%.0f °C는 너무 추워요"), i.temperatureC))
        }
        if i.temperatureC > Self.hotAboveC {
            return .init(mood: .hot, reason: String(format: L("%.0f °C is too hot", "%.0f °C는 너무 더워요"), i.temperatureC))
        }
        if i.foodOdor >= 0.1 || (i.nearestFoodMM >= 0 && i.nearestFoodMM < 15) {
            return .init(mood: .happy, reason: i.nearestFoodMM >= 0 && i.nearestFoodMM < 15
                ? String(format: L("food %.0f mm away", "먹이가 %.0f mm 앞에 있어요"), i.nearestFoodMM)
                : L("it smells food", "먹이 냄새가 나요"))
        }
        if i.sleep {
            return .init(mood: .sleepy, reason: L("sleep state is on", "잠든 상태예요"))
        }
        if i.grooming >= 0.8 {
            return .init(mood: .grooming, reason: L("grooming drive is high", "몸 손질하고 싶어 해요"))
        }
        return .init(mood: .calm, reason: L("nothing unusual", "특별한 일 없어요"))
    }
}
