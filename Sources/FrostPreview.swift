import AppKit

final class FrostPreview: NSObject {
    private let window: NSWindow
    private let sample = NativeFrostView(blending: .withinWindow)
    private let angle = NSSlider(value: 45, minValue: 15, maxValue: 120, target: nil, action: nil)
    private let blur = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let darkness = NSSlider(value: 85, minValue: 0, maxValue: 98, target: nil, action: nil)
    private let source = NSSegmentedControl()
    private let angleLabel = NSTextField(labelWithString: "")
    private let trialButton = NSButton()
    private let demoButton = NSButton()
    private let language: InterfaceLanguage
    private var trialDeadline: TimeInterval?
    private var demoStart: TimeInterval?
    private var liveAngle: Double?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var isLive: Bool { source.selectedSegment == 1 }

    var frostSettings: FrostSettings {
        var settings = FrostSettings()
        settings.blur = blur.doubleValue
        settings.darkness = darkness.doubleValue / 100
        return settings
    }

    private var previewSettings: FrostSettings {
        var settings = frostSettings
        settings.angle = isLive ? liveAngle ?? 120 : angle.doubleValue
        return settings
    }

    var activeTrial: FrostSettings? {
        guard let deadline = trialDeadline else { return nil }
        guard window.isVisible, now < deadline else { stopTrial(); return nil }
        return previewSettings
    }

    init(language: InterfaceLanguage) {
        self.language = language
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 475),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = language.text("磨砂预览", "Frost Preview")
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }

        let surface = NSView(frame: NSRect(x: 20, y: 166, width: 580, height: 289))
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.27, blue: 0.43, alpha: 1).cgColor
        surface.layer?.cornerRadius = 12
        surface.layer?.masksToBounds = true
        let card = NSView(frame: NSRect(x: 45, y: 55, width: 490, height: 175))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 10
        surface.addSubview(card)
        let title = NSTextField(labelWithString: language.text("这是一张磨砂测试卡", "Frost Preview"))
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.textColor = .black
        title.frame = NSRect(x: 25, y: 107, width: 436, height: 35)
        card.addSubview(title)
        for index in 0..<3 {
            let line = NSView(frame: NSRect(x: 25, y: 80 - index * 22, width: 400 - index * 75, height: 7))
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor(calibratedWhite: 0.23, alpha: 1).cgColor
            line.layer?.cornerRadius = 3
            card.addSubview(line)
        }
        sample.frame = surface.bounds
        surface.addSubview(sample)
        content.addSubview(surface)

        source.segmentCount = 2
        source.setLabel(language.text("模拟角度", "Simulated Angle"), forSegment: 0)
        source.setLabel(language.text("真实铰链", "Live Hinge"), forSegment: 1)
        source.selectedSegment = 0
        source.frame = NSRect(x: 20, y: 125, width: 218, height: 28)
        source.target = self
        source.action = #selector(sourceChanged)
        content.addSubview(source)
        angleLabel.frame = NSRect(x: 555, y: 128, width: 50, height: 22)
        content.addSubview(angleLabel)
        angle.frame = NSRect(x: 254, y: 128, width: 280, height: 22)
        content.addSubview(angle)

        addSlider(blur, label: language.text("磨砂强度", "Frost Strength"), y: 91, to: content)
        addSlider(darkness, label: language.text("变暗程度", "Dimming"), y: 58, to: content)
        for slider in [angle, blur, darkness] {
            slider.target = self
            slider.action = #selector(update)
            slider.isContinuous = true
        }

        demoButton.title = language.text("播放开合", "Play Hinge Demo")
        demoButton.target = self
        demoButton.action = #selector(playDemo)
        demoButton.frame = NSRect(x: 20, y: 15, width: 167, height: 31)
        content.addSubview(demoButton)
        trialButton.title = language.text("在内置屏试用 20 秒", "Try on Built-in Display for 20s")
        trialButton.target = self
        trialButton.action = #selector(toggleTrial)
        trialButton.frame = NSRect(x: 367, y: 15, width: 233, height: 31)
        content.addSubview(trialButton)
        update()
    }

    private func addSlider(_ slider: NSSlider, label: String, y: CGFloat, to content: NSView) {
        let caption = NSTextField(labelWithString: label)
        caption.frame = NSRect(x: 20, y: y, width: 130, height: 22)
        slider.frame = NSRect(x: 155, y: y, width: 445, height: 22)
        slider.setAccessibilityLabel(label)
        content.addSubview(caption)
        content.addSubview(slider)
    }

    func show() { window.makeKeyAndOrderFront(nil) }
    func close() { stopTrial(); window.close() }

    func stopTrialIfActive() {
        if trialDeadline != nil { stopTrial() }
    }

    func stopTrial() {
        trialDeadline = nil
        trialButton.title = language.text("在内置屏试用 20 秒", "Try on Built-in Display for 20s")
    }

    func updateLiveAngle(_ value: Double?) {
        guard window.isVisible else { return }
        liveAngle = value
        if let start = demoStart {
            let elapsed = now - start
            if elapsed >= 8 {
                demoStart = nil
                angle.doubleValue = 110
                demoButton.title = language.text("播放开合", "Play Hinge Demo")
            } else {
                angle.doubleValue = 67.5 + 42.5 * cos(elapsed / 8 * 2 * .pi)
            }
        }
        update()
    }

    @objc private func toggleTrial() {
        if trialDeadline != nil { stopTrial(); return }
        trialDeadline = now + 20
        trialButton.title = language.text("结束试用", "End Display Trial")
    }

    @objc private func sourceChanged() {
        demoStart = nil
        demoButton.title = language.text("播放开合", "Play Hinge Demo")
        demoButton.isEnabled = !isLive
        angle.isEnabled = !isLive
        update()
    }

    @objc private func playDemo() {
        if demoStart == nil {
            demoStart = now
            demoButton.title = language.text("停止开合演示", "Stop Hinge Demo")
        } else {
            demoStart = nil
            demoButton.title = language.text("播放开合", "Play Hinge Demo")
        }
    }

    @objc private func update() {
        let settings = previewSettings
        angleLabel.stringValue = isLive && liveAngle == nil ? "—°" : String(format: "%.0f°", settings.angle)
        sample.update(progress: settings.progress, strength: settings.blur / 100,
                      darkness: settings.darkness, dimProgress: settings.dimProgress)
    }
}
