// PlayerController.swift — V5.5 participant input state, focus safety and key preferences.
//
// This file is intentionally UI/backend agnostic. AppKit events are reduced to
// bounded state transitions here; LabWindow owns session/tick scheduling and
// FlyGymBridge owns wire delivery.

import Cocoa

enum PlayerControlAction: String, CaseIterable, Codable {
    case forward
    case backward
    case left
    case right
    case interact

    var title: String {
        switch self {
        case .forward: return "Forward"
        case .backward: return "Backward"
        case .left: return "Left"
        case .right: return "Right"
        case .interact: return "Interact"
        }
    }
}

struct PlayerKeyChoice: Equatable {
    let title: String
    let keyCode: UInt16

    static let supported: [PlayerKeyChoice] = [
        .init(title: "W", keyCode: 13), .init(title: "A", keyCode: 0),
        .init(title: "S", keyCode: 1), .init(title: "D", keyCode: 2),
        .init(title: "Q", keyCode: 12), .init(title: "E", keyCode: 14),
        .init(title: "R", keyCode: 15), .init(title: "F", keyCode: 3),
        .init(title: "I", keyCode: 34), .init(title: "J", keyCode: 38),
        .init(title: "K", keyCode: 40), .init(title: "L", keyCode: 37),
        .init(title: "Space", keyCode: 49), .init(title: "Esc", keyCode: 53),
        .init(title: "↑", keyCode: 126), .init(title: "↓", keyCode: 125),
        .init(title: "←", keyCode: 123), .init(title: "→", keyCode: 124),
    ]

    static func title(for keyCode: UInt16) -> String {
        supported.first(where: { $0.keyCode == keyCode })?.title ?? "Key \(keyCode)"
    }

    static func contains(_ keyCode: UInt16) -> Bool {
        supported.contains(where: { $0.keyCode == keyCode })
    }

    static var remappable: [PlayerKeyChoice] {
        supported.filter { $0.keyCode != PlayerController.escapeKeyCode }
    }

    static func containsRemappable(_ keyCode: UInt16) -> Bool {
        keyCode != PlayerController.escapeKeyCode && contains(keyCode)
    }
}

struct PlayerKeyBindings: Equatable {
    static let preferencePrefix = "SiliconFly.V5.PlayerInput.Key."
    static let defaults: [PlayerControlAction: UInt16] = [
        .forward: 13, .backward: 1, .left: 0, .right: 2,
        .interact: 14,
    ]

    private(set) var keyCodes: [PlayerControlAction: UInt16]

    init(defaults store: UserDefaults = .standard) {
        var loaded = Self.defaults
        for action in PlayerControlAction.allCases {
            let key = Self.preferencePrefix + action.rawValue
            if let number = store.object(forKey: key) as? NSNumber {
                let value = number.intValue
                if value >= 0, value <= Int(UInt16.max),
                   PlayerKeyChoice.containsRemappable(UInt16(value)) {
                    loaded[action] = UInt16(value)
                }
            }
        }
        // Corrupt/old preferences must never leave two actions on one key. A
        // partial repair can itself collide with an earlier custom mapping, so
        // fail the whole map back to the known-unique shipped defaults.
        let values = PlayerControlAction.allCases.map { loaded[$0] ?? Self.defaults[$0]! }
        if Set(values).count != values.count { loaded = Self.defaults }
        keyCodes = loaded
    }

    func keyCode(for action: PlayerControlAction) -> UInt16 {
        keyCodes[action] ?? Self.defaults[action]!
    }

    func action(for keyCode: UInt16) -> PlayerControlAction? {
        PlayerControlAction.allCases.first(where: { self.keyCode(for: $0) == keyCode })
    }

    mutating func rebind(_ action: PlayerControlAction, to newKeyCode: UInt16,
                         defaults store: UserDefaults = .standard) {
        guard PlayerKeyChoice.containsRemappable(newKeyCode) else { return }
        let oldKeyCode = keyCode(for: action)
        if let conflict = self.action(for: newKeyCode), conflict != action {
            keyCodes[conflict] = oldKeyCode
        }
        keyCodes[action] = newKeyCode
        save(defaults: store)
    }

    func save(defaults store: UserDefaults = .standard) {
        for action in PlayerControlAction.allCases {
            store.set(Int(keyCode(for: action)),
                      forKey: Self.preferencePrefix + action.rawValue)
        }
    }
}

struct PlayerInputIntent: Equatable {
    var moveAxes: [Double]
    var lookDelta: [Double]
    var heldActions: [String]

    var isNeutral: Bool {
        moveAxes == [0.0, 0.0] && lookDelta == [0.0, 0.0] && heldActions.isEmpty
    }
}

enum PlayerInputFocusPolicy {
    static func prepareWindowForCapture(_ window: NSWindow) {
        // Participate look uses ordinary mouseMoved events. AppKit windows do
        // not deliver those by default, even when the view has a tracking area.
        window.acceptsMouseMovedEvents = true
    }

    static func allowsCapture(windowIsKey: Bool, firstResponder: NSResponder?,
                              viewer: NSResponder) -> Bool {
        guard windowIsKey, let firstResponder, firstResponder === viewer else { return false }
        // Explicitly fail closed if this helper is ever reused with an editable or
        // control responder instead of the WorldViewer.
        if firstResponder is NSTextView || firstResponder is NSControl { return false }
        return true
    }
}

final class PlayerController {
    static let escapeKeyCode: UInt16 = 53
    private(set) var bindings: PlayerKeyBindings
    private(set) var captureEnabled = false
    private var heldKeyCodes = Set<UInt16>()
    private var blockedUntilFreshPress = Set<UInt16>()
    private(set) var freshInteractPress = false
    let lookRadiansPerPoint: Double

    init(defaults: UserDefaults = .standard, lookRadiansPerPoint: Double = 0.004) {
        bindings = PlayerKeyBindings(defaults: defaults)
        self.lookRadiansPerPoint = max(0.0001, min(0.05, lookRadiansPerPoint))
    }

    @discardableResult
    func setCaptureEnabled(_ enabled: Bool) -> PlayerInputIntent? {
        guard captureEnabled != enabled else { return nil }
        captureEnabled = enabled
        return enabled ? nil : releaseHeldInput(blockUntilFreshPress: true)
    }

    func handleKeyDown(keyCode: UInt16, isRepeat: Bool) -> PlayerInputIntent? {
        freshInteractPress = false
        guard captureEnabled else { return nil }
        if keyCode == Self.escapeKeyCode {
            if isRepeat { return nil }
            // Esc is deliberately fixed/unremappable. It is an unconditional local
            // safety barrier, not a backend held action: neutralize everything and
            // block stale key-repeat until a fresh physical press.
            blockedUntilFreshPress.formUnion(heldKeyCodes)
            heldKeyCodes.removeAll(keepingCapacity: true)
            return neutralIntent()
        }
        guard bindings.action(for: keyCode) != nil else { return nil }
        if blockedUntilFreshPress.contains(keyCode) {
            // Key-repeat after a focus/mode loss is the dangerous stale-W case.
            // A brand-new physical press (non-repeat) explicitly re-arms the key.
            if isRepeat { return nil }
            blockedUntilFreshPress.remove(keyCode)
        }
        // A repeat that begins while a text field/control owned focus must never
        // become a synthetic fresh press when the viewport regains focus.
        if isRepeat, !heldKeyCodes.contains(keyCode) { return nil }
        if heldKeyCodes.contains(keyCode) { return nil }

        heldKeyCodes.insert(keyCode)
        freshInteractPress = !isRepeat && bindings.action(for: keyCode) == .interact
        return currentIntent(extraLook: [0.0, 0.0])
    }

    func handleKeyUp(keyCode: UInt16) -> PlayerInputIntent? {
        blockedUntilFreshPress.remove(keyCode)
        guard heldKeyCodes.remove(keyCode) != nil else { return nil }
        return currentIntent(extraLook: [0.0, 0.0])
    }

    func handleLook(deltaX: Double, deltaY: Double) -> PlayerInputIntent? {
        guard captureEnabled, deltaX.isFinite, deltaY.isFinite else { return nil }
        // MuJoCo +Y is player-left, so mouse-right is negative yaw.
        let yaw = -deltaX * lookRadiansPerPoint
        let pitch = -deltaY * lookRadiansPerPoint
        guard yaw.isFinite, pitch.isFinite else { return nil }
        guard abs(yaw) > 1e-12 || abs(pitch) > 1e-12 else { return nil }
        return currentIntent(extraLook: [yaw, pitch])
    }

    func releaseHeldInput(blockUntilFreshPress: Bool) -> PlayerInputIntent? {
        freshInteractPress = false
        let hadInput = !heldKeyCodes.isEmpty
        if blockUntilFreshPress { blockedUntilFreshPress.formUnion(heldKeyCodes) }
        heldKeyCodes.removeAll(keepingCapacity: true)
        return hadInput ? neutralIntent() : nil
    }

    func rebind(_ action: PlayerControlAction, to keyCode: UInt16,
                defaults: UserDefaults = .standard) -> PlayerInputIntent? {
        let release = releaseHeldInput(blockUntilFreshPress: true)
        bindings.rebind(action, to: keyCode, defaults: defaults)
        return release
    }

    func heldIntent() -> PlayerInputIntent {
        currentIntent(extraLook: [0.0, 0.0])
    }

    private func currentIntent(extraLook: [Double]) -> PlayerInputIntent {
        let forward = axis(positive: .forward, negative: .backward)
        let right = axis(positive: .right, negative: .left)
        var actions: [String] = []
        if heldKeyCodes.contains(bindings.keyCode(for: .interact)) {
            actions.append("interact")
        }
        return PlayerInputIntent(moveAxes: [forward, right], lookDelta: extraLook,
                                 heldActions: actions)
    }

    private func axis(positive: PlayerControlAction, negative: PlayerControlAction) -> Double {
        let p = heldKeyCodes.contains(bindings.keyCode(for: positive)) ? 1.0 : 0.0
        let n = heldKeyCodes.contains(bindings.keyCode(for: negative)) ? 1.0 : 0.0
        return p - n
    }

    private func neutralIntent() -> PlayerInputIntent {
        PlayerInputIntent(moveAxes: [0.0, 0.0], lookDelta: [0.0, 0.0], heldActions: [])
    }
}
