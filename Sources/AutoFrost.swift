import Foundation

struct AutoFrost {
    static let startAngle = 60.0
    static let closedAngle = 10.0
    private(set) var needsReopening = false

    mutating func suspend() {
        needsReopening = true
    }

    mutating func settings(raw: Double?, smoothed: Double?, base: FrostSettings) -> FrostSettings? {
        guard let raw, let smoothed else { return nil }
        if raw <= Self.closedAngle { suspend() }
        if raw > Self.startAngle { needsReopening = false }
        guard !needsReopening, raw <= Self.startAngle else { return nil }
        var frost = base
        frost.startAngle = Self.startAngle
        frost.angle = smoothed
        return frost
    }
}

enum ManualMode: Equatable {
    case clear(until: TimeInterval)
    case frost

    func hasExpired(at now: TimeInterval) -> Bool {
        guard case let .clear(until) = self else { return false }
        return now >= until
    }
}
