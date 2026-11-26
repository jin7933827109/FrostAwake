import AppKit

final class WakeStatusIndicator {
    enum State {
        case off, waiting, autoFrost, awakeOnly, privacy

        var shortTitle: String {
            switch self {
            case .off: return "Off"
            case .waiting, .autoFrost: return "Auto"
            case .awakeOnly: return "Clear"
            case .privacy: return "Frost"
            }
        }

        var modeTitle: String {
            self == .off ? shortTitle : shortTitle + " Mode"
        }

        var symbol: String {
            switch self {
            case .off: return "cup.and.saucer"
            case .waiting, .autoFrost: return "laptopcomputer"
            case .awakeOnly: return "cup.and.saucer.fill"
            case .privacy: return "snowflake"
            }
        }
    }

    private weak var button: NSStatusBarButton?
    private var appName = ""
    var title: String { state.shortTitle }
    private var timer: Timer?
    private var index = 0
    private lazy var frames = (0..<16).map(Self.coffeeFrame)
    private(set) var state: State = .off
    var isAnimating: Bool { timer != nil }

    func attach(button: NSStatusBarButton?, appName: String) {
        self.button = button
        self.appName = appName
        button?.imagePosition = .imageLeading
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        render()
    }

    func setState(_ next: State) {
        guard next != state else { return }
        state = next
        render()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func displayOptionsChanged() { render() }

    private func render() {
        stop()
        guard let button else { return }
        button.title = title
        button.toolTip = "\(appName) · \(title)"
        button.setAccessibilityLabel("\(appName) · \(title)")
        guard state == .awakeOnly, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            let image = Self.statusIcon(state)
            image?.isTemplate = true
            button.image = image
            return
        }

        index = 0
        button.image = frames[index]
        let animation = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.index = (self.index + 1) % self.frames.count
            self.button?.image = self.frames[self.index]
        }
        animation.tolerance = 0.025
        timer = animation
        RunLoop.main.add(animation, forMode: .common)
    }

    static func statusIcon(_ state: State) -> NSImage? {
        if state == .awakeOnly { return coffeeFrame(4) }
        let icon = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        let decorated = NSImage(size: NSSize(width: 21, height: 18), flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: 1, width: 15, height: 15))
            if state == .off {
                NSColor.black.setStroke()
                let sleep = NSBezierPath()
                sleep.lineWidth = 1
                sleep.lineCapStyle = .round
                sleep.move(to: NSPoint(x: 15, y: 14))
                sleep.line(to: NSPoint(x: 19, y: 14))
                sleep.line(to: NSPoint(x: 15, y: 10))
                sleep.line(to: NSPoint(x: 19, y: 10))
                sleep.stroke()
            } else {
                let sparkle = NSBezierPath()
                sparkle.move(to: NSPoint(x: 17, y: 16))
                sparkle.line(to: NSPoint(x: 18, y: 13))
                sparkle.line(to: NSPoint(x: 21, y: 12))
                sparkle.line(to: NSPoint(x: 18, y: 11))
                sparkle.line(to: NSPoint(x: 17, y: 8))
                sparkle.line(to: NSPoint(x: 16, y: 11))
                sparkle.line(to: NSPoint(x: 13, y: 12))
                sparkle.line(to: NSPoint(x: 16, y: 13))
                sparkle.close()
                NSColor.black.setFill()
                sparkle.fill()
            }
            return true
        }
        decorated.isTemplate = true
        return decorated
    }

    private static func coffeeFrame(_ number: Int) -> NSImage {
        let phase = 2 * Double.pi * Double(number) / 16
        let image = NSImage(size: NSSize(width: 21, height: 18), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
            func stroke(_ path: NSBezierPath, opacity: CGFloat = 1) {
                NSColor.black.withAlphaComponent(opacity).setStroke()
                path.lineWidth = 1.35
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }

            let saucer = NSBezierPath()
            saucer.move(to: point(3, 2.4))
            saucer.line(to: point(18, 2.4))
            stroke(saucer)

            NSGraphicsContext.saveGraphicsState()
            let tilt = NSAffineTransform()
            tilt.translateX(by: 10, yBy: 5)
            tilt.rotate(byDegrees: CGFloat(10 * sin(phase)))
            tilt.translateX(by: -10, yBy: -5)
            tilt.concat()
            let cup = NSBezierPath()
            cup.move(to: point(4, 10))
            cup.line(to: point(15, 10))
            cup.curve(to: point(12.8, 4.5), controlPoint1: point(15, 7.8), controlPoint2: point(14.2, 5.3))
            cup.line(to: point(7.1, 4.5))
            cup.curve(to: point(4, 10), controlPoint1: point(5.5, 5.1), controlPoint2: point(4.2, 7.8))
            cup.close()
            cup.move(to: point(15, 9.2))
            cup.curve(to: point(14.3, 6.3), controlPoint1: point(20, 9.9), controlPoint2: point(19, 6.2))
            stroke(cup)
            NSGraphicsContext.restoreGraphicsState()

            for strand in 0..<2 {
                let x = CGFloat(7.6 + Double(strand) * 4.6)
                let wave = CGFloat(sin(phase + Double(strand) * 1.8))
                let steam = NSBezierPath()
                steam.move(to: point(x, 12))
                steam.curve(to: point(x + wave, 16.6), controlPoint1: point(x - 2, 13.8),
                            controlPoint2: point(x + 1.8 + wave, 14.7))
                stroke(steam, opacity: 0.74 + 0.22 * wave)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
