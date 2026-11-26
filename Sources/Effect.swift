import Foundation

struct FrostSettings {
    var angle: Double = 105
    var startAngle: Double = 95
    var blur: Double = 100
    var darkness: Double = 0.85
    var dimProgress: Double {
        let x = min(1, max(0, (startAngle - angle) / 80))
        return x * x * (3 - 2 * x)
    }
    var progress: Double {
        let x = min(1, max(0, (startAngle - angle) / 35))
        return x * x * (3 - 2 * x)
    }
}
