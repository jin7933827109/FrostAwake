import AppKit
import Carbon
import LocalAuthentication
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appName = "FrostAwake"
    private let preferences = FrostAwakePreferences()
    private let keepAwake = ScreenKeepAwake()
    private let shortcuts = ReviewShortcuts()
    private let sensor = LidSensor()
    private let wakeIndicator = WakeStatusIndicator()
    private var island: IslandIndicator?
    private var autoFrost = AutoFrost()
    private var manualMode: ManualMode?
    private var authentication: LAContext?
    private var latestAngle: Double?
    private var latestRawAngle: Double?
    private var lastSensorAt: TimeInterval = 0
    private var sessionSuspended = false
    private var isAutoFrosting = false
    private var overlays: [CGDirectDisplayID: FrostDisplayLayer] = [:]
    private var timer: Timer?
    private var localKeyMonitor: Any?
    private var lastDiagnosticsAt: TimeInterval = 0
    private var recentStates: [[String: Any]] = []
    private var activity: NSObjectProtocol?
    private var notice: String?
    private var enterShortcut = ReviewShortcut.defaultEnter
    private var exitShortcut = ReviewShortcut.defaultExit

    private var window: NSWindow!
    private var preview: FrostPreview?
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private var launchButton: NSButton!
    private var autoButton: NSButton!
    private var clearButton: NSButton!
    private var frostButton: NSButton!
    private var offButton: NSButton!
    private var touchButton: NSButton!
    private var durationPicker: NSPopUpButton!
    private var enterButton: NSButton!
    private var exitButton: NSButton!
    private var autoMenu: NSMenuItem!
    private var clearMenu: NSMenuItem!
    private var frostMenu: NSMenuItem!
    private var offMenu: NSMenuItem!
    private var launchMenu: NSMenuItem!
    private var autoToggleMenu: NSMenuItem!
    private var islandMenu: NSMenuItem!
    private var islandCheckbox: NSButton!
    private var clearDurationsMenu: NSMenu!
    private var modeButtons: [NSButton] { [autoButton, clearButton, frostButton, offButton] }

    private var language: InterfaceLanguage { preferences.language }
    private var usesTouchID: Bool { manualMode == .frost && preferences.requiresTouchID }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func text(_ zh: String, _ en: String) -> String { language.text(zh, en) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        enterShortcut = preferences.shortcut("PrivacyEnterShortcut", fallback: .defaultEnter)
        exitShortcut = preferences.shortcut("PrivacyExitShortcut", fallback: .defaultExit)
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .enter:
                if self.manualMode != .frost { self.selectFrost() }
            case .exit: self.requestFrostExit()
            case .emergency: self.emergencyStop()
            }
        }
        shortcuts.install()
        updateShortcuts()

        sessionSuspended = !ScreenKeepAwake.isLocalSessionUnlocked
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        wakeIndicator.attach(button: statusItem.button, appName: appName)
        setupMenus()
        setupWindow()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let key = ReviewShortcut.from(event)
            if key.usesSameKeys(as: .emergency) {
                if !event.isARepeat { self.emergencyStop() }
                return nil
            }
            if self.manualMode == .frost && key.usesSameKeys(as: self.exitShortcut) {
                if !event.isARepeat { self.requestFrostExit() }
                return nil
            }
            if self.manualMode != .frost && key.usesSameKeys(as: self.enterShortcut) {
                if !event.isARepeat { self.selectFrost() }
                return nil
            }
            return event
        }
        do {
            try preferences.initializeLoginItem()
        } catch {
            notice = loginError(error)
        }
        refreshControls()

        sensor.onSample = { [weak self] angle, raw, _ in
            guard let self else { return }
            self.latestAngle = angle
            self.latestRawAngle = raw
            self.lastSensorAt = self.now
        }
        sensor.start()
        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(interrupted), name: event, object: nil)
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                      NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resumed), name: event, object: nil)
        }
        let notifications = DistributedNotificationCenter.default()
        notifications.addObserver(self, selector: #selector(interrupted), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        notifications.addObserver(self, selector: #selector(resumed), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        showWindow()
    }

    private func setupMenus() {
        func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        let main = NSMenu()
        let root = NSMenuItem()
        main.addItem(root)
        let app = NSMenu()
        root.submenu = app
        _ = add(text("打开控制窗", "Open Controls"), #selector(showWindow), to: app, key: "0")
        _ = add(text("导出运行状态", "Export Diagnostics"), #selector(exportDiagnostics), to: app, key: "e")
        app.addItem(.separator())
        _ = add(text("退出 FrostAwake", "Quit FrostAwake"), #selector(quit), to: app, key: "q")
        NSApp.mainMenu = main

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        autoMenu = add(WakeStatusIndicator.State.waiting.modeTitle, #selector(selectAuto), to: menu)
        clearMenu = add(WakeStatusIndicator.State.awakeOnly.modeTitle, #selector(selectClear), to: menu)
        frostMenu = add(WakeStatusIndicator.State.privacy.modeTitle, #selector(selectFrost), to: menu)
        offMenu = add(WakeStatusIndicator.State.off.modeTitle, #selector(selectOff), to: menu)
        for (item, state) in [(autoMenu, WakeStatusIndicator.State.waiting), (clearMenu, .awakeOnly),
                              (frostMenu, .privacy), (offMenu, .off)] {
            item?.image = WakeStatusIndicator.statusIcon(state)
        }
        clearDurationsMenu = NSMenu()
        for hours in FrostAwakePreferences.durations {
            add(durationTitle(hours), #selector(startClearFromMenu(_:)), to: clearDurationsMenu).tag = hours
        }
        menu.addItem(.separator())
        launchMenu = add(text("登录时启动 FrostAwake", "Launch FrostAwake at Login"), #selector(toggleLogin), to: menu)
        autoToggleMenu = add(text("启用 Auto Mode", "Enable Auto Mode"), #selector(toggleAuto), to: menu)
        islandMenu = add(text("灵动岛模式", "Island Mode"), #selector(toggleIsland), to: menu)
        _ = add(text("打开控制窗…", "Open Controls…"), #selector(showWindow), to: menu)
        let panic = add(text("紧急停止", "Emergency Stop"), #selector(emergencyStop), to: menu, key: "f")
        panic.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(.separator())
        _ = add(text("退出 FrostAwake", "Quit FrostAwake"), #selector(quit), to: menu)
        statusItem.menu = menu
    }

    private func setupWindow() {
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 510),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = appName
            window.isReleasedWhenClosed = false
            window.center()
        }
        func heading(_ label: String, size: CGFloat = 14) -> NSTextField {
            let field = NSTextField(labelWithString: label)
            field.font = .systemFont(ofSize: size, weight: .semibold)
            return field
        }
        func caption(_ label: String) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: label)
            field.textColor = .secondaryLabelColor
            return field
        }
        func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = spacing
            return stack
        }
        func rightAlignedRow(_ primary: NSView, _ secondary: NSView) -> NSStackView {
            row([primary, NSView(), secondary])
        }
        func modeButton(_ name: String, _ icon: WakeStatusIndicator.State, _ action: Selector) -> NSButton {
            let button = NSButton(title: name, target: self, action: action)
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.image = WakeStatusIndicator.statusIcon(icon)
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return button
        }
        func rule() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        let languagePicker = NSPopUpButton()
        languagePicker.addItems(withTitles: ["简体中文", "English"])
        languagePicker.selectItem(at: language == .chinese ? 0 : 1)
        languagePicker.setAccessibilityLabel(text("界面语言", "Interface Language"))
        languagePicker.target = self
        languagePicker.action = #selector(changeLanguage(_:))

        autoButton = modeButton(WakeStatusIndicator.State.waiting.modeTitle, .waiting, #selector(selectAuto))
        clearButton = modeButton(WakeStatusIndicator.State.awakeOnly.modeTitle, .awakeOnly, #selector(selectClear))
        frostButton = modeButton(WakeStatusIndicator.State.privacy.modeTitle, .privacy, #selector(selectFrost))
        offButton = modeButton(WakeStatusIndicator.State.off.modeTitle, .off, #selector(selectOff))
        let modes = row(modeButtons, spacing: 8)
        modes.distribution = .fillEqually

        launchButton = NSButton(checkboxWithTitle: text("登录时启动 FrostAwake", "Launch FrostAwake at Login"),
                                target: self, action: #selector(toggleLogin))
        autoButton.toolTip = text("下合开启磨砂和保活，上抬恢复清晰。", "Lower the lid to frost and keep the display awake. Lift it to clear.")
        autoCheckbox = NSButton(checkboxWithTitle: text("启用 Auto Mode", "Enable Auto Mode"),
                                target: self, action: #selector(toggleAuto))
        durationPicker = NSPopUpButton()
        for hours in FrostAwakePreferences.durations {
            durationPicker.addItem(withTitle: durationTitle(hours))
            durationPicker.lastItem?.tag = hours
        }
        durationPicker.selectItem(withTag: preferences.clearHours)
        durationPicker.setAccessibilityLabel(text("Clear Mode 时长", "Clear Mode Duration"))
        durationPicker.target = self
        durationPicker.action = #selector(changeDuration)
        let durationLabel = NSTextField(labelWithString: text("Clear Mode 时长", "Clear Mode Duration"))

        enterButton = NSButton(title: "", target: self, action: #selector(editEnterShortcut))
        exitButton = NSButton(title: "", target: self, action: #selector(editExitShortcut))
        touchButton = NSButton(checkboxWithTitle: text("退出 Frost Mode 时验证 Touch ID", "Require Touch ID to Exit Frost Mode"),
                               target: self, action: #selector(toggleTouchID))
        islandCheckbox = NSButton(checkboxWithTitle: text("灵动岛模式", "Island Mode"),
                                  target: self, action: #selector(toggleIsland))
        islandCheckbox.toolTip = text("状态贴合刘海左缘。点击打开菜单。",
                                      "Show the current mode along the notch. Click to open the menu.")
        let previewButton = NSButton(title: text("磨砂预览…", "Frost Preview…"), target: self, action: #selector(showPreview))
        let intervalButton = NSButton(title: text("保活间隔…", "Idle Interval…"), target: self, action: #selector(editInterval))
        let stopButton = NSButton(title: text("紧急停止", "Emergency Stop"), target: self, action: #selector(emergencyStop))
        detail.font = .systemFont(ofSize: 13, weight: .medium)
        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.textColor = .secondaryLabelColor

        let view = NSView()
        window.contentView = view
        let titleRow = rightAlignedRow(heading(appName, size: 23), languagePicker)
        let footer = rightAlignedRow(row([previewButton, intervalButton, islandCheckbox], spacing: 14), stopButton)
        let group = NSStackView(views: [
            titleRow, modes, detail, rule(), heading(text("自动设置", "Automatic Settings")),
            launchButton, autoCheckbox,
            caption(text("下合开启磨砂和保活，上抬恢复清晰。", "Lower the lid to frost and keep the display awake. Lift it to clear.")),
            rule(), heading(text("手动保活", "Manual Keep Awake")),
            rightAlignedRow(durationLabel, durationPicker),
            caption(text("Clear Mode 保持屏幕清晰。Frost Mode 让内外屏一起磨砂。",
                         "Clear Mode keeps displays clear. Frost Mode frosts all connected displays.")),
            row([enterButton, exitButton]), touchButton, noticeLabel, footer
        ])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 10
        group.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(group)
        NSLayoutConstraint.activate([
            group.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            group.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            group.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            group.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18)
        ])
        for item in [titleRow, modes, footer] as [NSView] {
            item.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        for item in group.arrangedSubviews where item is NSBox || item is NSTextField {
            item.widthAnchor.constraint(lessThanOrEqualTo: group.widthAnchor).isActive = true
            if item is NSBox { item.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        }
    }

    private var autoCheckbox: NSButton!
    private func durationTitle(_ hours: Int) -> String { text("\(hours) 小时", hours == 1 ? "1 hour" : "\(hours) hours") }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        preferences.language = sender.indexOfSelectedItem == 0 ? .chinese : .english
        notice = nil
        preview?.close()
        preview = nil
        setupMenus()
        setupWindow()
        refreshControls()
    }

    @objc private func toggleIsland() {
        preferences.islandEnabled.toggle()
        refreshControls()
    }

    private func updateIsland() {
        guard preferences.islandEnabled, !sessionSuspended else {
            island?.orderOut(nil)
            island = nil
            return
        }
        if island == nil { island = IslandIndicator { [weak self] in self?.statusItem.menu } }
        guard let island else { return }
        island.update(state: wakeIndicator.state, language: language)
        if !island.isVisible, island.positionOnDisplay() { island.orderFrontRegardless() }
    }

    @objc private func changeDuration() {
        preferences.clearHours = durationPicker.selectedTag()
        refreshControls()
    }
    @objc private func startClearFromMenu(_ sender: NSMenuItem) {
        preferences.clearHours = sender.tag
        durationPicker.selectItem(withTag: sender.tag)
        selectClear()
    }

    @objc private func toggleLogin() {
        let status = SMAppService.mainApp.status
        do {
            if status == .requiresApproval {
                let alert = NSAlert()
                alert.messageText = text("登录启动等待系统批准", "Launch at Login Needs Approval")
                alert.addButton(withTitle: text("打开系统设置", "Open System Settings"))
                alert.addButton(withTitle: text("关闭登录启动", "Turn Off Launch at Login"))
                alert.addButton(withTitle: text("取消", "Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: SMAppService.openSystemSettingsLoginItems()
                case .alertSecondButtonReturn: try preferences.setLoginItem(enabled: false)
                default: break
                }
            } else {
                try preferences.setLoginItem(enabled: status != .enabled)
            }
            notice = nil
        } catch {
            notice = loginError(error)
        }
        refreshControls()
    }

    private func loginError(_ error: Error) -> String {
        NSLog("FrostAwake login item: %@", String(describing: error))
        return text("无法更新登录启动，请检查 macOS 的「登录项与扩展」。",
                    "Could not update launch at login. Check Login Items & Extensions in macOS Settings.")
    }

    @objc private func toggleAuto() {
        preferences.autoFrostEnabled.toggle()
        notice = nil
        tick()
        refreshControls()
    }

    @objc private func selectAuto() {
        leaveManual {
            self.preferences.autoFrostEnabled = true
            self.notice = nil
        }
    }

    @objc private func selectOff() {
        leaveManual {
            self.preferences.autoFrostEnabled = false
            self.preview?.stopTrialIfActive()
            self.notice = nil
        }
    }

    @objc private func selectClear() {
        if case .clear = manualMode {
            leaveManual {}
            return
        }
        if usesTouchID {
            requestFrostExit { self.startClear() }
        } else {
            startClear()
        }
    }

    private func startClear() {
        guard startKeepAwake() else { return }
        let deadline = now + TimeInterval(preferences.clearHours * 3600)
        setManualMode(.clear(until: deadline))
    }

    @objc private func selectFrost() {
        if manualMode == .frost {
            requestFrostExit()
            return
        }
        guard !preferences.requiresTouchID || LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            report(text("Touch ID 当前不可用。请先在系统设置中添加指纹，或关闭退出验证。",
                        "Touch ID is unavailable. Add a fingerprint in System Settings or turn off exit verification."))
            return
        }
        guard !NSScreen.screens.isEmpty else { return }
        _ = shortcuts.set(.exit, to: exitShortcut)
        guard shortcuts.isRegistered(.exit) else {
            report(text("退出快捷键无法注册，请设置另一个按键。", "The exit shortcut is unavailable. Choose another key."))
            return
        }
        guard startKeepAwake() else {
            updateShortcuts()
            return
        }
        setManualMode(.frost)
    }

    private func startKeepAwake() -> Bool {
        guard !sessionSuspended, ScreenKeepAwake.isLocalSessionUnlocked else { return false }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            report(text("请在「系统设置 → 隐私与安全 → 设备控制和数据访问」授权 FrostAwake，再开启保活。",
                        "Allow FrostAwake under System Settings → Privacy & Security → Device Control and Data Access, then try again."))
            return false
        }
        guard keepAwake.start() else {
            report(text("无法开启保活。", "Could not keep the display awake."))
            return false
        }
        notice = nil
        return true
    }

    private func setManualMode(_ next: ManualMode?) {
        manualMode = next
        updateShortcuts()
        tick()
        refreshControls()
    }

    private func leaveManual(_ after: @escaping () -> Void) {
        if manualMode == .frost {
            requestFrostExit(after: after)
        } else {
            after()
            setManualMode(nil)
        }
    }

    @objc private func requestFrostExit() { requestFrostExit(after: {}) }

    private func requestFrostExit(after: @escaping () -> Void) {
        guard manualMode == .frost, authentication == nil else { return }
        guard usesTouchID else {
            setManualMode(nil)
            after()
            tick()
            refreshControls()
            return
        }
        let context = LAContext()
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        guard context.canEvaluatePolicy(policy, error: nil) else {
            report(text("Touch ID 当前不可用，Frost Mode 仍在运行。", "Touch ID is unavailable. Frost Mode is still active."))
            return
        }
        context.localizedCancelTitle = text("取消", "Cancel")
        context.localizedFallbackTitle = ""
        authentication = context
        let reason = text("退出 Frost Mode，恢复桌面显示", "Exit Frost Mode and restore the desktop")
        context.evaluatePolicy(policy, localizedReason: reason) { [weak self, weak context] success, _ in
            DispatchQueue.main.async {
                guard let self, let context, self.authentication === context else { return }
                self.authentication = nil
                if success, ScreenKeepAwake.isLocalSessionUnlocked {
                    self.setManualMode(nil)
                    after()
                    self.tick()
                    self.refreshControls()
                } else {
                    self.report(self.text("Touch ID 未通过，Frost Mode 仍在运行。",
                                          "Touch ID did not verify. Frost Mode is still active."))
                }
            }
        }
    }

    @objc private func toggleTouchID() {
        guard manualMode != .frost else { return }
        let enabled = touchButton.state == .on
        guard !enabled || LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            report(text("Touch ID 当前不可用。请先在系统设置中添加指纹。",
                        "Touch ID is unavailable. Set up a fingerprint in System Settings."))
            return
        }
        preferences.requiresTouchID = enabled
        notice = nil
        refreshControls()
    }

    private func updateShortcuts() {
        shortcuts.set(.emergency, to: .emergency)
        if manualMode == .frost {
            shortcuts.set(.enter, to: nil)
            shortcuts.set(.exit, to: exitShortcut)
        } else {
            shortcuts.set(.exit, to: nil)
            shortcuts.set(.enter, to: enterShortcut)
        }
    }

    @objc private func editEnterShortcut() { editShortcut(entering: true) }
    @objc private func editExitShortcut() { editShortcut(entering: false) }

    private func editShortcut(entering: Bool) {
        guard manualMode != .frost else { return }
        let active = entering ? enterShortcut : exitShortcut
        shortcuts.removeAll()
        defer {
            updateShortcuts()
            refreshControls()
        }
        let title = entering ? text("开启 Frost Mode 快捷键", "Start Frost Mode Shortcut")
                             : text("退出 Frost Mode 快捷键", "Exit Frost Mode Shortcut")
        guard let selected = recordReviewShortcut(
            title: title, current: active, suggestion: entering ? .defaultEnter : .defaultExit,
            entry: entering, language: language, reserved: { shortcut in
                if shortcut.usesSameKeys(as: .emergency) || shortcut.usesSameKeys(as: entering ? self.exitShortcut : self.enterShortcut) {
                    return self.text("这个快捷键已分配给 FrostAwake 的另一项操作。",
                                     "This shortcut is assigned to another FrostAwake action.")
                }
                return nil
            }
        ) else { return }
        guard shortcuts.set(entering ? .enter : .exit, to: selected) else {
            report(text("该快捷键已被占用。", "That shortcut is already in use."))
            return
        }
        if entering { enterShortcut = selected } else { exitShortcut = selected }
        preferences.saveShortcut(selected, for: entering ? "PrivacyEnterShortcut" : "PrivacyExitShortcut")
        notice = nil
    }

    @objc private func editInterval() {
        let alert = NSAlert()
        alert.messageText = text("保活间隔", "Idle Interval")
        alert.informativeText = text("空闲多久后发出保活活动。请输入 5 到 270 秒，默认 240 秒。",
                                     "Time idle before sending keep-awake activity. Enter 5–270 seconds. Default: 240.")
        alert.addButton(withTitle: text("保存", "Save"))
        alert.addButton(withTitle: text("取消", "Cancel"))
        let field = NSTextField(string: String(preferences.idleInterval))
        field.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
               ScreenKeepAwake.intervalRange.contains(value) {
                preferences.idleInterval = value
                return
            }
            alert.informativeText = text("请输入 5 到 270 之间的整数秒。", "Enter a whole number from 5 to 270.")
        }
    }

    @objc private func tick() {
        let time = now
        if let manualMode {
            if manualMode.hasExpired(at: time) {
                notice = text("Clear Mode 已到时。", "Clear Mode has ended.")
                setManualMode(nil)
                return
            }
            if !keepAwake.refresh(now: time, interval: preferences.idleInterval) {
                interrupted()
                return
            }
        }

        let shouldRemainResponsive = preferences.autoFrostEnabled || manualMode != nil || preview?.activeTrial != nil
        if shouldRemainResponsive && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "FrostAwake lid and display controls")
        } else if !shouldRemainResponsive, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        let sensorAvailable = time - lastSensorAt < 1
        let angle = sensorAvailable ? latestAngle : nil
        let raw = sensorAvailable ? latestRawAngle : nil
        preview?.updateLiveAngle(angle)
        let base = preview?.frostSettings ?? FrostSettings()
        let autoSettings = sessionSuspended ? nil : autoFrost.settings(raw: raw, smoothed: angle, base: base)
        isAutoFrosting = false

        if manualMode != nil { preview?.stopTrialIfActive() }
        if manualMode == .frost {
            var frost = base
            frost.angle = frost.startAngle - 35
            render(frost, screens: NSScreen.screens)
        } else if manualMode == nil, !sessionSuspended, let trial = preview?.activeTrial {
            render(trial, screens: NSScreen.screens.filter { screen in
                screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            })
        } else if manualMode == nil, preferences.autoFrostEnabled, let autoSettings {
            render(autoSettings, screens: NSScreen.screens)
            isAutoFrosting = !overlays.isEmpty
        } else {
            clearOverlays()
        }
        if manualMode == nil {
            keepAwake.updateAutomatically(active: isAutoFrosting, now: time, interval: preferences.idleInterval)
        }
        let state: WakeStatusIndicator.State
        switch manualMode {
        case .clear: state = .awakeOnly
        case .frost: state = .privacy
        case nil:
            state = preferences.autoFrostEnabled ? (isAutoFrosting ? .autoFrost : .waiting) : .off
        }
        wakeIndicator.setState(state)
        updateStatus()
        updateIsland()
        if time - lastDiagnosticsAt >= 1 {
            lastDiagnosticsAt = time
            recordBackgroundState()
        }
    }

    private func render(_ frost: FrostSettings, screens: [NSScreen]) {
        guard frost.progress > 0 else { clearOverlays(); return }
        let present = Set(screens.compactMap(\.displayID))
        for id in Set(overlays.keys).subtracting(present) {
            overlays.removeValue(forKey: id)?.window.orderOut(nil)
        }
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let layer = overlays[id] ?? FrostDisplayLayer(screen: screen)
            overlays[id] = layer
            if layer.window.frame != screen.frame { layer.window.setFrame(screen.frame, display: true) }
            let strength = manualMode == .frost ? 1 : frost.blur / 100
            layer.view.update(progress: frost.progress, strength: strength, darkness: frost.darkness,
                              dimProgress: frost.dimProgress)
            if !layer.window.isVisible { layer.window.orderFrontRegardless() }
        }
    }

    private func clearOverlays() {
        for layer in overlays.values { layer.window.orderOut(nil) }
        overlays.removeAll()
    }

    private func updateStatus() {
        let message: String
        switch manualMode {
        case let .clear(until):
            let minutes = max(1, Int(ceil((until - now) / 60)))
            let countdown = String(format: "%d:%02d", minutes / 60, minutes % 60)
            message = text("屏幕保持清晰 · 剩余 \(countdown)", "Displays stay clear · \(countdown) remaining")
        case .frost:
            let key = exitShortcut.label(in: language)
            message = usesTouchID ? text("内外屏已磨砂 · 按 \(key) 后验证 Touch ID",
                                         "Displays frosted · Press \(key), then verify Touch ID")
                                   : text("内外屏已磨砂 · 按 \(key) 退出", "Displays frosted · Press \(key) to exit")
        case nil:
            if !preferences.autoFrostEnabled {
                message = text("待机 · 屏幕保持清晰", "Idle · Displays stay clear")
            } else if latestAngle == nil || now - lastSensorAt >= 1 {
                message = text("Auto Mode · 未读到铰链角度", "Auto Mode · Lid sensor unavailable")
            } else if isAutoFrosting {
                message = keepAwake.isRunning
                    ? text("Auto Mode · 保活已开启", "Auto Mode active · Keeping displays awake")
                    : text("Auto Mode · 保活未启动，请检查设备控制权限",
                           "Auto Mode active · Keep Awake unavailable. Check Device Control access.")
            } else {
                message = text("Auto Mode 待命 · 半合屏盖触发", "Auto Mode ready · Lower the lid to start")
            }
        }
        if detail.stringValue != message { detail.stringValue = message }
        if statusLine.title != message { statusLine.title = message }
    }

    private func refreshControls() {
        guard window != nil else { return }
        let modeIndex = manualMode == .frost ? 2 : manualMode != nil ? 1 : preferences.autoFrostEnabled ? 0 : 3
        for (index, button) in modeButtons.enumerated() { button.state = index == modeIndex ? .on : .off }
        for (index, item) in [autoMenu, clearMenu, frostMenu, offMenu].enumerated() { item?.state = index == modeIndex ? .on : .off }
        if case .clear = manualMode {
            clearMenu.title = "End Clear Mode"
            clearMenu.submenu = nil
        } else {
            clearMenu.title = WakeStatusIndicator.State.awakeOnly.modeTitle
            clearMenu.submenu = clearDurationsMenu
            for item in clearDurationsMenu.items { item.state = item.tag == preferences.clearHours ? .on : .off }
        }
        frostMenu.title = manualMode == .frost ? "Exit Frost Mode" : WakeStatusIndicator.State.privacy.modeTitle
        clearButton.title = modeIndex == 1 ? "End Clear Mode" : WakeStatusIndicator.State.awakeOnly.modeTitle
        frostButton.title = modeIndex == 2 ? "Exit Frost Mode" : WakeStatusIndicator.State.privacy.modeTitle
        autoCheckbox.state = preferences.autoFrostEnabled ? .on : .off
        autoToggleMenu.state = autoCheckbox.state
        islandCheckbox.state = preferences.islandEnabled ? .on : .off
        islandMenu.state = islandCheckbox.state
        touchButton.state = preferences.requiresTouchID ? .on : .off
        touchButton.isEnabled = manualMode != .frost
        enterButton.isEnabled = manualMode != .frost
        exitButton.isEnabled = manualMode != .frost
        durationPicker.isEnabled = modeIndex != 1
        enterButton.title = text("开启快捷键", "Enter Shortcut") + "  " + enterShortcut.label(in: language)
        exitButton.title = text("退出快捷键", "Exit Shortcut") + "  " + exitShortcut.label(in: language)
        let loginStatus = SMAppService.mainApp.status
        launchButton.state = loginStatus == .enabled ? .on : .off
        launchMenu.state = launchButton.state
        launchButton.title = loginStatus == .requiresApproval
            ? text("登录时启动 FrostAwake（等待系统批准）", "Launch FrostAwake at Login (Approval Needed)")
            : text("登录时启动 FrostAwake", "Launch FrostAwake at Login")
        launchMenu.title = launchButton.title
        noticeLabel.stringValue = notice ?? (
            shortcuts.isRegistered(.enter) || manualMode == .frost ? "" :
                text("开启快捷键暂不可用，可以从控制窗更改。", "The enter shortcut is unavailable. Change it in Controls.")
        )
        noticeLabel.isHidden = noticeLabel.stringValue.isEmpty
        updateStatus()
        updateIsland()
    }

    private func report(_ message: String) {
        notice = message
        showWindow()
    }

    @objc private func emergencyStop() {
        authentication?.invalidate()
        authentication = nil
        autoFrost.suspend()
        preview?.stopTrial()
        notice = text("当前效果已停止。", "Current effects stopped.")
        setManualMode(nil)
    }

    @objc private func interrupted() {
        sessionSuspended = true
        emergencyStop()
    }

    @objc private func resumed() {
        sessionSuspended = false
        autoFrost.suspend()
        latestAngle = nil
        latestRawAngle = nil
    }

    @objc private func screenChanged() {
        if let island, !island.positionOnDisplay() { island.orderOut(nil) }
        if NSScreen.screens.isEmpty && manualMode != nil { emergencyStop() }
        else { tick() }
    }

    @objc private func showWindow() {
        refreshControls()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showPreview() {
        if preview == nil { preview = FrostPreview(language: language) }
        preview?.show()
    }

    @objc private func quit() {
        if usesTouchID { requestFrostExit { NSApp.terminate(nil) } }
        else { NSApp.terminate(nil) }
    }

    private func diagnostics() -> [String: Any] {
        let mode = manualMode == .frost ? "manual" : manualMode != nil ? "awakeOnly" :
            isAutoFrosting ? "active" : preferences.autoFrostEnabled ? "waiting" : "off"
        return ["time": Date().timeIntervalSince1970, "bundleVersion": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "",
                "appActive": NSApp.isActive, "controlVisible": window.isVisible, "controlMinimized": window.isMiniaturized,
                "hotkeyRegistered": shortcuts.isRegistered(.emergency), "sensorAvailable": latestAngle != nil,
                "sensorAngle": latestAngle as Any? ?? NSNull(), "renderer": "NSVisualEffectView",
                "requiresScreenRecording": false, "nativeOpacity": overlays.values.map { $0.view.alphaValue }.max() ?? 0,
                "reviewMode": mode, "language": language.rawValue, "autoFrostEnabled": preferences.autoFrostEnabled,
                "launchAtLoginStatus": SMAppService.mainApp.status.rawValue, "keepAwake": keepAwake.isRunning,
                "angle": latestAngle as Any? ?? NSNull(), "reviewInterval": preferences.idleInterval,
                "clearModeHours": preferences.clearHours, "overlayVisible": overlays.values.contains { $0.window.isVisible },
                "desktopActive": !overlays.isEmpty, "displayCount": overlays.count, "externalButtonCount": 0,
                "menuBarStatus": wakeIndicator.title, "coffeeAnimating": wakeIndicator.isAnimating,
                "islandEnabled": preferences.islandEnabled, "islandVisible": island?.isVisible == true,
                "islandFrame": island.map { NSStringFromRect($0.frame) } as Any? ?? NSNull(),
                "enterShortcut": enterShortcut.label(in: language), "exitShortcut": exitShortcut.label(in: language),
                "enterShortcutRegistered": shortcuts.isRegistered(.enter), "exitShortcutRegistered": shortcuts.isRegistered(.exit),
                "privacyExitMethod": preferences.requiresTouchID ? "touchID" : "shortcut",
                "privacyAuthenticationPending": authentication != nil, "canPostInputEvents": CGPreflightPostEventAccess()]
    }

    private var artifactsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrostAwake/Diagnostics", isDirectory: true)
    }

    private func writeDiagnostics(_ value: Any, as name: String) throws {
        try FileManager.default.createDirectory(at: artifactsFolder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifactsFolder.appendingPathComponent(name), options: .atomic)
    }

    @objc private func exportDiagnostics() {
        do {
            try writeDiagnostics(diagnostics(), as: "runtime-diagnostics.json")
            report(text("已导出运行状态。", "Diagnostics exported."))
        } catch {
            report(text("无法导出运行状态。", "Could not export diagnostics."))
        }
    }

    private func recordBackgroundState() {
        recentStates.append(diagnostics())
        if recentStates.count > 60 { recentStates.removeFirst() }
        try? writeDiagnostics(recentStates, as: "background-state.json")
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshControls() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        authentication?.invalidate()
        keepAwake.stop()
        clearOverlays()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        wakeIndicator.stop()
        island?.orderOut(nil)
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        shortcuts.stop()
        timer?.invalidate()
        sensor.stop()
    }
}

if CommandLine.arguments.contains("--probe") {
    if let angle = LidSensor().probe() { print("{\"available\":true,\"angle\":\(angle),\"source\":\"Apple HID\"}") }
    else { print("{\"available\":false,\"error\":\"No readable lid angle sensor\"}"); exit(2) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
