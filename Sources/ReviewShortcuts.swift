import AppKit
import Carbon

struct ReviewShortcut: Codable, Equatable {
    let code: UInt32
    let modifiers: UInt32
    let key: String

    static let defaultEnter = ReviewShortcut(code: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey), key: "H")
    static let defaultExit = ReviewShortcut(code: UInt32(kVK_ANSI_H), modifiers: 0, key: "H")
    static let emergency = ReviewShortcut(code: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey | cmdKey), key: "F")

    func label(in language: InterfaceLanguage) -> String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        if let number = key.split(separator: " ").last, key.hasPrefix("键位 ") || key.hasPrefix("Key ") {
            return prefix + language.text("键位", "Key") + " " + number
        }
        if key == "空格" || key == "Space" { return prefix + language.text("空格", "Space") }
        return prefix + key
    }

    var hasEntryModifier: Bool { modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 }

    func usesSameKeys(as other: ReviewShortcut) -> Bool {
        code == other.code && modifiers == other.modifiers
    }

    static func from(_ event: NSEvent) -> ReviewShortcut {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let code = UInt32(event.keyCode)
        let key: String
        switch Int(code) {
        case kVK_Escape: key = "Esc"
        case kVK_Space: key = "空格"
        case kVK_Return, kVK_ANSI_KeypadEnter: key = "↩"
        case kVK_Tab: key = "⇥"
        case kVK_Delete: key = "⌫"
        case kVK_ForwardDelete: key = "⌦"
        case kVK_LeftArrow: key = "←"
        case kVK_RightArrow: key = "→"
        case kVK_UpArrow: key = "↑"
        case kVK_DownArrow: key = "↓"
        default:
            let value = event.charactersIgnoringModifiers?.uppercased() ?? ""
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            if let index = functionKeys.firstIndex(of: Int(code)) { key = "F\(index + 1)" }
            else { key = value.isEmpty ? "键位 \(code)" : value }
        }
        return ReviewShortcut(code: code, modifiers: modifiers, key: key)
    }
}

final class ReviewShortcuts {
    enum Action: UInt32 { case emergency = 1, enter, exit }
    private static let signature: OSType = 0x48465253
    private var handler: EventHandlerRef?
    private var bindings: [Action: (ReviewShortcut, EventHotKeyRef)] = [:]
    var onAction: ((Action) -> Void)?

    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == ReviewShortcuts.signature, let action = Action(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<ReviewShortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak owner] in
                guard let owner, owner.isRegistered(action) else { return }
                owner.onAction?(action)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func isRegistered(_ action: Action) -> Bool { bindings[action] != nil }

    @discardableResult
    func set(_ action: Action, to shortcut: ReviewShortcut?) -> Bool {
        if let existing = bindings[action], existing.0 == shortcut { return true }
        if let existing = bindings.removeValue(forKey: action) { UnregisterEventHotKey(existing.1) }
        guard let shortcut else { return true }
        guard handler != nil else { return false }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let result = RegisterEventHotKey(shortcut.code, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else { return false }
        bindings[action] = (shortcut, reference)
        return true
    }

    func removeAll() {
        for (_, reference) in bindings.values { UnregisterEventHotKey(reference) }
        bindings.removeAll()
    }

    func stop() {
        removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

func recordReviewShortcut(title: String, current: ReviewShortcut, suggestion: ReviewShortcut,
                          entry: Bool, language: InterfaceLanguage, reserved: @escaping (ReviewShortcut) -> String?) -> ReviewShortcut? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = entry ? language.text("按下组合键，包含 ⌃、⌥ 或 ⌘。", "Press a shortcut containing ⌃, ⌥, or ⌘.") : language.text("按下一个键或组合键。", "Press a key or shortcut.")
    let save = alert.addButton(withTitle: language.text("保存", "Save"))
    let cancel = alert.addButton(withTitle: language.text("取消", "Cancel"))
    alert.addButton(withTitle: language.text("恢复默认", "Restore Default"))
    save.keyEquivalent = ""
    cancel.keyEquivalent = ""
    let display = NSTextField(labelWithString: current.label(in: language))
    display.frame = NSRect(x: 0, y: 0, width: 240, height: 31)
    display.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
    display.alignment = .center
    alert.accessoryView = display
    let instructions = alert.informativeText
    var pending = current
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.window === alert.window else { return event }
        pending = ReviewShortcut.from(event)
        display.stringValue = pending.label(in: language)
        let error = entry && !pending.hasEntryModifier ? language.text("请加 ⌃、⌥ 或 ⌘，以免打字时误开启。", "Include ⌃, ⌥, or ⌘ to avoid triggering Frost Mode while typing.") : reserved(pending)
        alert.informativeText = error ?? instructions
        save.isEnabled = error == nil
        return nil
    }
    defer { if let monitor { NSEvent.removeMonitor(monitor) } }
    NSApp.activate(ignoringOtherApps: true)
    switch alert.runModal() {
    case .alertFirstButtonReturn: return pending
    case .alertThirdButtonReturn: return suggestion
    default: return nil
    }
}
