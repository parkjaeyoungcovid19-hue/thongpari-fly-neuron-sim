import Cocoa

let controller = PlayerController()
controller.setCaptureEnabled(true)
let one = controller.handleLook(deltaX: 100, deltaY: 0)!.lookDelta[0]
let split = (0..<10).reduce(0.0) { total, _ in
    total + controller.handleLook(deltaX: 10, deltaY: 0)!.lookDelta[0]
}
print("same 100pt movement: one event=\(one) ten events=\(split) expected=-0.4")
print("event partition invariant: \(abs(one - split) < 1e-12)")
_ = controller.handleKeyDown(keyCode: 13, isRepeat: false)
let release = controller.handleKeyUp(keyCode: 13)!
print("keyUp local neutral=\(release.isNeutral); held=\(controller.heldIntent().moveAxes)")
print("second keyUp yields retry=\(controller.handleKeyUp(keyCode: 13) != nil)")
