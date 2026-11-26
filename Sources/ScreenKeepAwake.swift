import CoreGraphics
import Foundation
import IOKit.pwr_mgt

final class ScreenKeepAwake {
    static let defaultInterval = 240
    static let intervalRange = 5...270
    private static let anyInput = CGEventType(rawValue: UInt32.max)!

    private var displayAssertion = IOPMAssertionID(0)
    private var nextCheckAt: TimeInterval = 0
    private var nextAutomaticStartAt: TimeInterval = 0
    private var lastPulseAt: TimeInterval = -.infinity

    var isRunning: Bool { displayAssertion != 0 }

    static var isLocalSessionUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["kCGSSessionOnConsoleKey"] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    func start() -> Bool {
        guard Self.isLocalSessionUnlocked, CGPreflightPostEventAccess() else { return false }
        guard !isRunning else { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Hinge Frost Review" as CFString, &displayAssertion
        )
        nextCheckAt = 0
        lastPulseAt = -.infinity
        return result == kIOReturnSuccess && isRunning
    }

    func stop() {
        guard isRunning else { return }
        IOPMAssertionRelease(displayAssertion)
        displayAssertion = 0
    }

    func updateAutomatically(active: Bool, now: TimeInterval, interval: Int) {
        guard active else {
            stop()
            nextAutomaticStartAt = 0
            return
        }
        if !isRunning {
            guard now >= nextAutomaticStartAt else { return }
            nextAutomaticStartAt = now + 1
            guard start() else { return }
        }
        if !refresh(now: now, interval: interval) { stop() }
    }

    func refresh(now: TimeInterval, interval: Int) -> Bool {
        guard isRunning else { return false }
        guard now >= nextCheckAt else { return true }
        nextCheckAt = now + 1
        guard Self.isLocalSessionUnlocked, CGPreflightPostEventAccess() else { return false }

        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
        let buttons: [CGMouseButton] = [.left, .right, .center]
        guard now - lastPulseAt >= Double(interval), idle >= Double(interval),
              !buttons.contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }),
              let position = CGEvent(source: nil)?.location,
              let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: position, mouseButton: .left) else { return true }
        event.post(tap: .cghidEventTap)
        lastPulseAt = now
        return true
    }
}
