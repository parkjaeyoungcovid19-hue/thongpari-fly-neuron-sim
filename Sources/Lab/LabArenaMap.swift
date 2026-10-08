import Cocoa

final class LabArenaPlacementView: NSView {
    var onPick: ((Double, Double) -> Void)?
    var selectedShape: String = "box" { didSet { needsDisplay = true } }
    var selectedPoint: (x: Double, y: Double)? { didSet { needsDisplay = true } }
    var worldObjects: [LabWorldObjectRemote] = [] { didSet { needsDisplay = true } }
    var flyPose: (x: Double, y: Double, heading: Double)? { didSet { needsDisplay = true } }

    private let minimumExtentMm = 100.0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 250) }

    private func visibleExtentMm() -> Double {
        var required = minimumExtentMm
        func include(_ x: Double, _ y: Double, pad: Double = 0) {
            required = max(required, abs(x) + pad, abs(y) + pad)
        }
        if let selectedPoint { include(selectedPoint.x, selectedPoint.y, pad: 8) }
        if let flyPose { include(flyPose.x, flyPose.y, pad: 8) }
        for obj in worldObjects {
            let sx = obj.sizeMM.indices.contains(0) ? abs(obj.sizeMM[0]) : 5
            let sy = obj.sizeMM.indices.contains(1) ? abs(obj.sizeMM[1]) : sx
            include(obj.positionMM.indices.contains(0) ? obj.positionMM[0] : 0,
                    obj.positionMM.indices.contains(1) ? obj.positionMM[1] : 0,
                    pad: max(sx, sy) * 0.75 + 5)
        }
        let padded = required * 1.10
        for candidate in [100.0, 150, 200, 300, 500, 750, 1000, 1500, 2000] where padded <= candidate {
            return candidate
        }
        return ceil(padded / 500.0) * 500.0
    }

    private func plotGeometry() -> (extent: Double, scale: Double, rect: NSRect) {
        let extent = visibleExtentMm()
        let side = max(1.0, min(bounds.width, bounds.height) - 16.0)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                          width: side, height: side)
        return (extent, Double(side) / (2.0 * extent), rect)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let g = plotGeometry()
        guard g.scale > 0, g.rect.contains(p) else { return }
        // Top-down lab convention: screen up = +X (forward), screen left = +Y.
        let x = max(-g.extent, min(g.extent, Double(p.y - g.rect.midY) / g.scale))
        let y = max(-g.extent, min(g.extent, Double(g.rect.midX - p.x) / g.scale))
        selectedPoint = (x, y)
        onPick?(x, y)
    }

    private func point(x: Double, y: Double, geometry g: (extent: Double, scale: Double, rect: NSRect)) -> CGPoint {
        CGPoint(x: g.rect.midX - CGFloat(y * g.scale),
                y: g.rect.midY + CGFloat(x * g.scale))
    }

    private func objectPath(_ obj: LabWorldObjectRemote,
                            geometry g: (extent: Double, scale: Double, rect: NSRect)) -> NSBezierPath {
        let x = obj.positionMM.indices.contains(0) ? obj.positionMM[0] : 0
        let y = obj.positionMM.indices.contains(1) ? obj.positionMM[1] : 0
        let sx = max(0.2, obj.sizeMM.indices.contains(0) ? abs(obj.sizeMM[0]) : 5)
        let sy = max(0.2, obj.sizeMM.indices.contains(1) ? abs(obj.sizeMM[1]) : sx)
        if obj.shape == "sphere" || obj.shape == "food" {
            let c = point(x: x, y: y, geometry: g)
            let d = max(2.0, CGFloat(sx * g.scale))
            return NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        }

        // A tilted ramp's footprint is its length times cos(tilt).
        let hx = sx * 0.5 * cos((obj.pitchDeg ?? 0) * Double.pi / 180.0)
        let hy = sy * 0.5
        let yaw = obj.yawDeg * Double.pi / 180.0
        let c = cos(yaw), sn = sin(yaw)
        let corners = [(-hx, -hy), (-hx, hy), (hx, hy), (hx, -hy)].map { local -> CGPoint in
            let wx = x + local.0 * c - local.1 * sn
            let wy = y + local.0 * sn + local.1 * c
            return point(x: wx, y: wy, geometry: g)
        }
        let path = NSBezierPath()
        if let first = corners.first {
            path.move(to: first)
            for p in corners.dropFirst() { path.line(to: p) }
            path.close()
        }
        return path
    }

    private func drawWorldObjects(geometry g: (extent: Double, scale: Double, rect: NSRect),
                                  labelAttrs: [NSAttributedString.Key: Any]) {
        for obj in worldObjects {
            let path = objectPath(obj, geometry: g)
            let color: NSColor
            switch obj.shape {
            case "food": color = .systemGreen
            case "wall": color = .systemPurple
            case "sphere": color = .systemPink
            case "car": color = .systemRed
            case "trap": color = .systemCyan
            case "ramp": color = .systemBrown
            default: color = .systemIndigo
            }
            color.withAlphaComponent(0.22).setFill()
            color.withAlphaComponent(0.95).setStroke()
            path.lineWidth = obj.shape == "wall" ? 2.0 : 1.4
            path.fill(); path.stroke()

            let x = obj.positionMM.indices.contains(0) ? obj.positionMM[0] : 0
            let y = obj.positionMM.indices.contains(1) ? obj.positionMM[1] : 0
            let c = point(x: x, y: y, geometry: g)
            let label = LabToy.objectLine(obj)
            (label as NSString).draw(at: CGPoint(x: min(bounds.maxX - 140, c.x + 5),
                                                 y: min(bounds.maxY - 15, c.y + 4)),
                                     withAttributes: labelAttrs)
        }
    }

    private func drawFly(geometry g: (extent: Double, scale: Double, rect: NSRect),
                         labelAttrs: [NSAttributedString.Key: Any]) {
        guard let flyPose else { return }
        let center = point(x: flyPose.x, y: flyPose.y, geometry: g)
        // Keep the fly legible even when the arena auto-zooms far out. Position
        // and heading are authoritative; marker pixel size is intentionally UI-sized.
        let length = max(10.0, min(18.0, CGFloat(4.0 * g.scale)))
        let worldForward = point(x: flyPose.x + cos(flyPose.heading) * 5.0,
                                 y: flyPose.y + sin(flyPose.heading) * 5.0,
                                 geometry: g)
        let dx = worldForward.x - center.x, dy = worldForward.y - center.y
        let mag = max(0.001, hypot(dx, dy))
        let ux = dx / mag, uy = dy / mag
        let px = -uy, py = ux
        let tip = CGPoint(x: center.x + ux * length * 0.65, y: center.y + uy * length * 0.65)
        let tail = CGPoint(x: center.x - ux * length * 0.45, y: center.y - uy * length * 0.45)
        let left = CGPoint(x: tail.x + px * length * 0.35, y: tail.y + py * length * 0.35)
        let right = CGPoint(x: tail.x - px * length * 0.35, y: tail.y - py * length * 0.35)
        let path = NSBezierPath()
        path.move(to: tip); path.line(to: left); path.line(to: right); path.close()
        NSColor.systemGreen.withAlphaComponent(0.90).setFill()
        NSColor.systemGreen.setStroke()
        path.lineWidth = 1.5
        path.fill(); path.stroke()
        let text = String(format: L("fly  %.1f, %.1f", "파리  %.1f, %.1f"), flyPose.x, flyPose.y)
        (text as NSString).draw(at: CGPoint(x: min(bounds.maxX - 120, center.x + 8),
                                            y: max(4, center.y - 16)),
                                withAttributes: labelAttrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let g = plotGeometry()
        NSColor.windowBackgroundColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: g.rect, xRadius: 6, yRadius: 6).fill()

        let grid = NSBezierPath()
        let step: Double = g.extent <= 100 ? 25 : (g.extent <= 200 ? 50 : (g.extent <= 500 ? 100 : (g.extent <= 1000 ? 250 : 500)))
        var v = -g.extent
        while v <= g.extent + 0.001 {
            let a = point(x: -g.extent, y: v, geometry: g)
            let b = point(x: g.extent, y: v, geometry: g)
            grid.move(to: a); grid.line(to: b)
            let c = point(x: v, y: -g.extent, geometry: g)
            let d = point(x: v, y: g.extent, geometry: g)
            grid.move(to: c); grid.line(to: d)
            v += step
        }
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        grid.lineWidth = 0.7
        grid.stroke()

        let origin = point(x: 0, y: 0, geometry: g)
        let axes = NSBezierPath()
        axes.move(to: CGPoint(x: g.rect.minX, y: origin.y)); axes.line(to: CGPoint(x: g.rect.maxX, y: origin.y))
        axes.move(to: CGPoint(x: origin.x, y: g.rect.minY)); axes.line(to: CGPoint(x: origin.x, y: g.rect.maxY))
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setStroke()
        axes.lineWidth = 1.2
        axes.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let objectAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
        ]
        (L("+X forward", "+X 앞") as NSString).draw(at: CGPoint(x: origin.x + 7, y: g.rect.maxY - 16), withAttributes: attrs)
        (L("+Y left", "+Y 왼쪽") as NSString).draw(at: CGPoint(x: g.rect.minX + 6, y: origin.y + 5), withAttributes: attrs)
        (String(format: L("±%.0f mm · %d objects", "±%.0f mm · 물체 %d개"), g.extent, worldObjects.count) as NSString)
            .draw(at: CGPoint(x: g.rect.maxX - 120, y: g.rect.minY + 5), withAttributes: attrs)

        drawWorldObjects(geometry: g, labelAttrs: objectAttrs)
        drawFly(geometry: g, labelAttrs: objectAttrs)

        guard let selectedPoint else { return }
        let p = point(x: selectedPoint.x, y: selectedPoint.y, geometry: g)
        let markerRect = NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)
        NSColor.systemOrange.setStroke()
        NSColor.systemOrange.withAlphaComponent(0.18).setFill()
        let marker: NSBezierPath
        if selectedShape == "sphere" || selectedShape == "food" {
            marker = NSBezierPath(ovalIn: markerRect)
        } else {
            marker = NSBezierPath(rect: markerRect)
        }
        marker.lineWidth = 2
        marker.fill(); marker.stroke()

        let coordinate = String(format: L("pick %.1f, %.1f mm", "고른 위치 %.1f, %.1f mm"), selectedPoint.x, selectedPoint.y)
        (coordinate as NSString).draw(at: CGPoint(x: min(bounds.maxX - 120, p.x + 10),
                                                  y: max(4, min(bounds.maxY - 16, p.y + 7))),
                                        withAttributes: attrs)
    }
}
