// MuJoCoCanvas.swift — shows MuJoCo's own rendering of the live FlyGym scene
// (NeuroMechFly meshes, arena, lab objects) inside the Lab canvas.
//
// The headless backend renders offscreen with the same MjModel/MjData its
// passive viewer used and streams raw RGB frames on a private loopback port
// (flygym_bridge/view_stream.py). The view sits on top of WorldViewer's SceneKit
// mirror and passes every event through, so WorldViewer keeps owning the
// observation camera, backend ray picks and Participate input; the backend is
// told that camera, so the picture and the picks share one viewpoint.

import Cocoa

/// Background-thread client for view_stream.py. Frames arrive on the main queue.
final class MuJoCoFrameStream {
    private let port: UInt16
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var pendingView: Data?
    private var lastSentView: Data?
    private let writeQueue = DispatchQueue(label: "mujoco-view-writer")
    // Latest-wins hand-off to the main thread. Queuing one main-thread block per
    // frame let a briefly busy main thread replay seconds of stale frames, so the
    // participant appeared to keep moving after input stopped (2026-09-26).
    private var latestFrame: CGImage?
    private var frameDeliveryScheduled = false
    private(set) var framesReplaced = 0
    var onFrame: ((CGImage) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    init(port: UInt16) { self.port = port }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "mujoco-frame-reader"
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        let socket = fd
        fd = -1
        lock.unlock()
        if socket >= 0 { Darwin.shutdown(socket, SHUT_RDWR); Darwin.close(socket) }
    }

    /// Latest camera wins; identical requests are not resent.
    func sendView(camera: WorldViewerMuJoCoCamera, pixelWidth: Int, pixelHeight: Int) {
        var message: [String: Any] = [
            "type": "view", "width": pixelWidth, "height": pixelHeight,
            "position_mm": camera.positionMM, "forward": camera.forward,
            "distance_mm": camera.distanceMM, "fovy_deg": camera.fovyDeg,
        ]
        if let anchor = camera.anchor { message["anchor"] = anchor }
        if let offset = camera.offsetMM { message["offset_mm"] = offset }
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        lock.lock()
        if line == lastSentView && fd >= 0 { lock.unlock(); return }
        pendingView = line
        lock.unlock()
        writeQueue.async { [weak self] in self?.flushView() }
    }

    private func flushView() {
        lock.lock()
        let socket = fd
        guard socket >= 0, let line = pendingView else { lock.unlock(); return }
        pendingView = nil
        lastSentView = line
        lock.unlock()
        let ok = line.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(socket, raw.baseAddress! + sent, raw.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        if !ok {
            lock.lock(); if lastSentView == line { lastSentView = nil }; lock.unlock()
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func run() {
        while isRunning {
            guard let socket = connect() else { Thread.sleep(forTimeInterval: 0.5); continue }
            lock.lock()
            fd = socket
            // Resend the current camera to a fresh backend.
            if pendingView == nil { pendingView = lastSentView }
            lastSentView = nil
            lock.unlock()
            DispatchQueue.main.async { self.onConnectionChange?(true) }
            writeQueue.async { [weak self] in self?.flushView() }
            readFrames(socket)
            lock.lock()
            if fd == socket { fd = -1; Darwin.close(socket) }
            lock.unlock()
            DispatchQueue.main.async { self.onConnectionChange?(false) }
            if isRunning { Thread.sleep(forTimeInterval: 0.5) }
        }
    }

    private func connect() -> Int32? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !ok { Darwin.close(socket); return nil }
        return socket
    }

    private func readExactly(_ socket: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while got < count {
                let n = Darwin.recv(socket, raw.baseAddress! + got, count - got, 0)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? data : nil
    }

    private func readFrames(_ socket: Int32) {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        while isRunning {
            // b"MJF1", u32 width, u32 height, u64 seq, u32 payload length (little-endian)
            guard let header = readExactly(socket, 24),
                  header.prefix(4) == Data("MJF1".utf8) else { return }
            func u32(_ at: Int) -> Int {
                header[at..<at + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            }
            let width = u32(4), height = u32(8), length = u32(20)
            guard width > 0, height > 0, length == width * height * 3,
                  length <= 16 << 20,
                  let payload = readExactly(socket, length),
                  let provider = CGDataProvider(data: payload as CFData),
                  let image = CGImage(width: width, height: height,
                                      bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else { return }
            deliver(image)
        }
    }
}

extension MuJoCoFrameStream {
    /// Keeps only the newest frame; at most one main-thread delivery is pending.
    func deliver(_ image: CGImage, on queue: DispatchQueue = .main) {
        lock.lock()
        if latestFrame != nil { framesReplaced += 1 }
        latestFrame = image
        let schedule = !frameDeliveryScheduled
        frameDeliveryScheduled = true
        lock.unlock()
        guard schedule else { return }
        queue.async { [weak self] in self?.drainLatestFrame() }
    }

    private func drainLatestFrame() {
        lock.lock()
        let image = latestFrame
        latestFrame = nil
        frameDeliveryScheduled = false
        lock.unlock()
        if let image { onFrame?(image) }
    }
}

/// Transparent to events: WorldViewer underneath handles camera, picking and
/// Participate capture exactly as before.
final class MuJoCoFrameView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}
