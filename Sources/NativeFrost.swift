import AppKit

/// An independent overlay, not a utility panel tied to the active app.
final class FrostOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// WindowServer composites the native material; no screen pixels are captured.
final class NativeFrostView: NSView {
    private let material = NSVisualEffectView()
    private let shade = NSView()
    private let mist = NSView()

    init(blending: NSVisualEffectView.BlendingMode) {
        super.init(frame: .zero)
        material.blendingMode = blending
        material.material = .hudWindow
        material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        material.autoresizingMask = [.width, .height]
        addSubview(material)
        mist.wantsLayer = true
        mist.layer?.backgroundColor = NSColor(calibratedRed: 0.87, green: 0.91, blue: 0.94, alpha: 1).cgColor
        mist.autoresizingMask = [.width, .height]
        addSubview(mist)
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.cgColor
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        material.frame = bounds
        mist.frame = bounds
        shade.frame = bounds
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(progress: Double, strength: Double, darkness: Double, dimProgress: Double) {
        // Fade the sharp original out much earlier. Linear alpha previously
        // left readable text showing through the material at most useful angles.
        let presence = 1 - pow(1 - min(1, max(0, progress)), 3)
        let frost = min(1, max(0, presence * strength))
        let dim = min(0.98, max(0, darkness * dimProgress))
        alphaValue = frost > 0 || dim > 0 ? 1 : 0
        material.alphaValue = frost
        mist.alphaValue = 0.16 * frost * (1 - dim)
        shade.alphaValue = dim
    }
}
