import AppKit

final class IslandIndicator: NSPanel {
    private let surface = NotchSurface()
    private let button = IslandButton()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let menuProvider: () -> NSMenu?
    private var displayedState: WakeStatusIndicator.State?
    private var displayedLanguage: InterfaceLanguage?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(menuProvider: @escaping () -> NSMenu?) {
        self.menuProvider = menuProvider
        super.init(contentRect: NSRect(x: 0, y: 0, width: 94, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        contentView = surface
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        icon.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)

        let header = NSStackView(views: [icon, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(header)

        button.frame = surface.bounds
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(showMenu)
        surface.addSubview(button)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 18),
            header.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            header.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -11)
        ])
    }

    func update(state: WakeStatusIndicator.State, language: InterfaceLanguage) {
        if state != displayedState {
            displayedState = state
            titleLabel.stringValue = state.shortTitle
            icon.image = WakeStatusIndicator.statusIcon(state)
            button.setAccessibilityTitle(state.shortTitle)
            button.setAccessibilityLabel("FrostAwake · \(state.shortTitle)")
        }
        guard language != displayedLanguage else { return }
        displayedLanguage = language
        button.setAccessibilityHelp(language.text("打开 FrostAwake 菜单", "Open FrostAwake menu"))
        setAccessibilityTitle("FrostAwake · " + language.text("灵动岛", "Island"))
    }

    func positionOnDisplay() -> Bool {
        let displays = NSScreen.screens
        let builtIn = displays.first { screen in
            screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        guard let screen = builtIn ?? displays.first else { return false }

        let notchLeft = screen.auxiliaryTopLeftArea
        let joinsNotch = notchLeft.map { !$0.isEmpty } ?? false
        let rightEdge: CGFloat
        let topEdge: CGFloat
        let height: CGFloat
        if let notchLeft, joinsNotch {
            rightEdge = notchLeft.maxX + 8
            topEdge = notchLeft.maxY
            height = notchLeft.height
        } else {
            rightEdge = screen.frame.midX - 6
            topEdge = screen.frame.maxY - 3
            height = max(25, min(32, screen.frame.maxY - screen.visibleFrame.maxY - 6))
        }
        surface.joinsNotch = joinsNotch
        let placement = NSRect(x: rightEdge - frame.width, y: topEdge - height, width: frame.width, height: height)
        if placement != frame { setFrame(placement, display: true) }
        return true
    }

    @objc private func showMenu() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, self.isVisible, let menu = self.menuProvider() else { return }
            let anchor = NSPoint(x: 7, y: self.surface.bounds.maxY + 3)
            menu.popUp(positioning: nil, at: anchor, in: self.surface)
        }
    }
}

private final class IslandButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class NotchSurface: NSView {
    var joinsNotch = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        if !joinsNotch {
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            return
        }
        let right = bounds.maxX
        let bottom = bounds.maxY
        let shape = NSBezierPath()
        shape.move(to: .zero)
        shape.line(to: NSPoint(x: right, y: 0))
        shape.line(to: NSPoint(x: right, y: bottom))
        shape.line(to: NSPoint(x: 18, y: bottom))
        shape.curve(to: NSPoint(x: 7, y: bottom - 11),
                    controlPoint1: NSPoint(x: 12, y: bottom), controlPoint2: NSPoint(x: 7, y: bottom - 5))
        shape.line(to: NSPoint(x: 7, y: 7))
        shape.curve(to: .zero, controlPoint1: NSPoint(x: 7, y: 3), controlPoint2: NSPoint(x: 4, y: 0))
        shape.close()
        shape.fill()
    }
}
