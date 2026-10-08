// LabGraphView.swift — compact bounded telemetry plots for Virtual Fly Lab.

import Cocoa

final class LabGraphView: NSView {
    struct Series {
        var name: String
        var values: [Double] = []
    }

    private let maxSamples: Int
    private var series: [Series]
    var fixedRange: ClosedRange<Double>? { didSet { needsDisplay = true } }
    var valueDecimals: Int? { didSet { needsDisplay = true } }
    var unitLabel: String? { didSet { needsDisplay = true } }

    init(frame frameRect: NSRect, names: [String], maxSamples: Int = 240) {
        self.maxSamples = max(20, maxSamples)
        self.series = names.map { Series(name: $0) }
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func append(_ values: [Double]) {
        for i in 0..<min(values.count, series.count) {
            series[i].values.append(values[i].isFinite ? values[i] : 0)
            if series[i].values.count > maxSamples {
                series[i].values.removeFirst(series[i].values.count - maxSamples)
            }
        }
        needsDisplay = true
    }

    func clear() {
        for i in series.indices { series[i].values.removeAll(keepingCapacity: true) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        background.fill()

        let all = series.flatMap(\.values)
        let range: ClosedRange<Double>
        if let fixedRange {
            range = fixedRange
        } else if let lo = all.min(), let hi = all.max() {
            let pad = max(1e-6, (hi - lo) * 0.08)
            range = (lo - pad)...(hi + pad)
        } else {
            range = 0...1
        }
        let span = max(1e-9, range.upperBound - range.lowerBound)
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPink,
                                 .systemPurple, .systemTeal, .systemRed, .systemYellow]

        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let legendLineHeight: CGFloat = 14
        let legendRows: CGFloat = series.count > 5 ? 2 : 1
        let legendHeight = legendRows * legendLineHeight + 4
        let plot = NSRect(x: 44, y: legendHeight + 6,
                          width: max(10, bounds.width - 54),
                          height: max(20, bounds.height - legendHeight - 16))

        func formatted(_ value: Double) -> String {
            let decimals = valueDecimals ?? (span > 20 ? 0 : (span <= 0.1 ? 3 : 2))
            return String(format: "%.*f", decimals, value)
        }

        for step in 0...2 {
            let f = Double(step) / 2.0
            let y = plot.minY + CGFloat(f) * plot.height
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            NSColor.separatorColor.withAlphaComponent(step == 0 || step == 2 ? 0.55 : 0.28).setStroke()
            grid.lineWidth = 0.75
            grid.stroke()

            let value = range.lowerBound + f * span
            let text = formatted(value)
            NSAttributedString(string: text, attributes: axisAttrs)
                .draw(at: NSPoint(x: 4, y: y - 5))
        }

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: plot)
        border.lineWidth = 0.75
        border.stroke()

        if let unitLabel, !unitLabel.isEmpty {
            let unitAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let unit = NSAttributedString(string: unitLabel, attributes: unitAttrs)
            unit.draw(at: NSPoint(x: max(plot.minX + 4, plot.maxX - unit.size().width - 5),
                                  y: plot.maxY - 13))
        }

        for (si, s) in series.enumerated() where s.values.count > 1 {
            let p = NSBezierPath()
            for (i, v) in s.values.enumerated() {
                let x = plot.minX + CGFloat(i) / CGFloat(max(1, maxSamples - 1)) * plot.width
                let y0 = (v - range.lowerBound) / span
                let y = plot.minY + CGFloat(max(0, min(1, y0))) * plot.height
                if i == 0 { p.move(to: NSPoint(x: x, y: y)) }
                else { p.line(to: NSPoint(x: x, y: y)) }
            }
            colors[si % colors.count].setStroke()
            p.lineWidth = 1.7
            p.stroke()
        }

        let legendFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        var x = plot.minX
        var y: CGFloat = 3
        for (i, s) in series.enumerated() {
            let latest = s.values.last ?? 0
            let valueText = formatted(latest)
            let text = "● \(s.name) \(valueText)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: legendFont,
                .foregroundColor: colors[i % colors.count]
            ]
            let a = NSAttributedString(string: text, attributes: attrs)
            let width = a.size().width
            if x + width > bounds.maxX - 8, x > plot.minX {
                x = plot.minX
                y += legendLineHeight
            }
            a.draw(at: NSPoint(x: x, y: y))
            x += width + 12
        }
    }
}
