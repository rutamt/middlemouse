import AppKit
import ApplicationServices
import ServiceManagement

private enum DefaultsKey {
    static let modifierClick = "fnClickEnabled"
    static let clickModifiers = "clickModifiers"
    static let threeFingerClick = "threeFingerClickEnabled"
    static let threeFingerTap = "threeFingerTapEnabled"
    static let ignoredApps = "ignoredBundleIDs"
    static let iconHidden = "menuBarIconHidden"
}

// Same order as EventTapManager.supportedClickModifiers.
private let clickModifierNames = ["fn", "Control", "Option", "Command", "Shift"]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let permissionPollInterval: TimeInterval = 2
    private static let permissionChangeDelay: TimeInterval = 0.5

    private let defaults = UserDefaults.standard
    private let trackpad = TrackpadManager.shared
    private lazy var eventTap = EventTapManager(trackpad: trackpad)

    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var frontmostBundleID: String?

    private let permissionItem = NSMenuItem(title: "", action: #selector(requestAccessibility), keyEquivalent: "")
    private let modifierClickItem = NSMenuItem(title: "", action: #selector(toggleModifierClick), keyEquivalent: "")
    private let clickModifierMenuItem = NSMenuItem(title: "Left Click Modifier", action: nil, keyEquivalent: "")
    private let clickModifierItems: [NSMenuItem] = EventTapManager.supportedClickModifiers.indices.map { index in
        let item = NSMenuItem(title: clickModifierNames[index], action: #selector(toggleClickModifier(_:)), keyEquivalent: "")
        item.tag = index
        return item
    }
    private let threeFingerClickItem = NSMenuItem(title: "Three-Finger Click", action: #selector(toggleThreeFingerClick), keyEquivalent: "")
    private let threeFingerTapItem = NSMenuItem(title: "Three-Finger Tap", action: #selector(toggleThreeFingerTap), keyEquivalent: "")
    private let ignoreItem = NSMenuItem(title: "", action: #selector(toggleIgnoreFrontmost), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
    private let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideIcon), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            DefaultsKey.modifierClick: true,
            DefaultsKey.clickModifiers: Int(CGEventFlags.maskSecondaryFn.rawValue),
            DefaultsKey.threeFingerClick: true,
            DefaultsKey.threeFingerTap: false,
            DefaultsKey.iconHidden: false,
        ])

        eventTap.modifierClickEnabled = defaults.bool(forKey: DefaultsKey.modifierClick)
        eventTap.clickModifiers = loadClickModifiers()
        eventTap.threeFingerClickEnabled = defaults.bool(forKey: DefaultsKey.threeFingerClick)
        eventTap.ignoredBundleIDs = Set(defaults.stringArray(forKey: DefaultsKey.ignoredApps) ?? [])
        eventTap.onToggleIconShortcut = { [weak self] in
            guard let self else { return }
            self.setIconVisible(!self.statusItem.isVisible)
        }
        trackpad.onThreeFingerTap = { [weak self] in
            self?.eventTap.synthesizeMiddleClick()
        }
        applyTrackpadSettings()

        setUpStatusItem()

        // The hidden state is only honored when there is still a way back: without Accessibility
        // the shortcut is dead, and without a login item this launch came from the user opening us.
        let wasHidden = defaults.bool(forKey: DefaultsKey.iconHidden)
        let launchedByLoginItem = SMAppService.mainApp.status == .enabled
        setIconVisible(!(wasHidden && launchedByLoginItem && AXIsProcessTrusted()))

        // Posted whenever any app's Accessibility access changes, including ours being revoked.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityDidChange),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )
        refreshPermissionState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setIconVisible(true)
        // The button needs a run loop pass to be laid out after becoming visible.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTap.stop()
        trackpad.setRunning(false)
    }

    // MARK: Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.loadMenuBarImage()
        statusItem.button?.toolTip = "FreeWheel"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        hideItem.toolTip = "Open FreeWheel again or press fn + Control + Option + M to bring the icon back."

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApp

        let modifierMenu = NSMenu()
        modifierMenu.autoenablesItems = false
        for item in clickModifierItems {
            item.target = self
            modifierMenu.addItem(item)
        }
        clickModifierMenuItem.submenu = modifierMenu

        for item in [permissionItem, modifierClickItem, threeFingerClickItem, threeFingerTapItem, ignoreItem, loginItem, hideItem] {
            item.target = self
        }
        for item in [
            permissionItem, modifierClickItem, clickModifierMenuItem, threeFingerClickItem, threeFingerTapItem,
            .separator(),
            ignoreItem,
            .separator(),
            loginItem, hideItem, quitItem,
        ] {
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    private static func loadMenuBarImage() -> NSImage? {
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "computermouse", accessibilityDescription: "FreeWheel")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissionState()

        modifierClickItem.state = eventTap.modifierClickEnabled ? .on : .off
        refreshClickModifierItems()
        threeFingerClickItem.state = eventTap.threeFingerClickEnabled ? .on : .off
        threeFingerTapItem.state = trackpad.tapEnabled ? .on : .off
        threeFingerClickItem.isEnabled = trackpad.isAvailable
        threeFingerTapItem.isEnabled = trackpad.isAvailable

        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostBundleID = frontmost?.bundleIdentifier
        ignoreItem.title = "Ignore \(frontmost?.localizedName ?? "Current App")"
        ignoreItem.isEnabled = frontmostBundleID != nil
        ignoreItem.state = frontmostBundleID.map(eventTap.ignoredBundleIDs.contains) == true ? .on : .off

        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        default: loginItem.state = .off
        }
    }

    // MARK: Accessibility

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissionState()
    }

    @objc private func accessibilityDidChange() {
        // The notification lands slightly before the new value is readable.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.permissionChangeDelay) { [weak self] in
            self?.refreshPermissionState()
        }
    }

    private func refreshPermissionState() {
        let trusted = AXIsProcessTrusted()
        if trusted {
            eventTap.start()
        } else {
            eventTap.stop()
        }

        permissionItem.title = "Accessibility Permission: \(trusted ? "Granted" : "Needs Access")"
        permissionItem.isEnabled = !trusted

        // Polling exists only for the wait on the user; once the tap is live this costs nothing.
        if trusted && eventTap.isRunning {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            let timer = Timer(timeInterval: Self.permissionPollInterval, repeats: true) { [weak self] _ in
                self?.refreshPermissionState()
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }
    }

    // MARK: Actions

    @objc private func toggleModifierClick() {
        eventTap.modifierClickEnabled.toggle()
        defaults.set(eventTap.modifierClickEnabled, forKey: DefaultsKey.modifierClick)
    }

    @objc private func toggleClickModifier(_ sender: NSMenuItem) {
        let flag = EventTapManager.supportedClickModifiers[sender.tag].flag
        var modifiers = eventTap.clickModifiers
        if modifiers.contains(flag) {
            modifiers.remove(flag)
        } else {
            modifiers.insert(flag)
        }
        guard !modifiers.isEmpty else { return }
        eventTap.clickModifiers = modifiers
        defaults.set(Int(modifiers.rawValue), forKey: DefaultsKey.clickModifiers)
    }

    private func loadClickModifiers() -> CGEventFlags {
        let stored = CGEventFlags(rawValue: UInt64(truncatingIfNeeded: defaults.integer(forKey: DefaultsKey.clickModifiers)))
        let modifiers = EventTapManager.supportedClickModifiers.reduce(into: CGEventFlags()) { result, modifier in
            if stored.contains(modifier.flag) { result.insert(modifier.flag) }
        }
        return modifiers.isEmpty ? .maskSecondaryFn : modifiers
    }

    private func refreshClickModifierItems() {
        let modifiers = eventTap.clickModifiers
        let selected = clickModifierItems.filter {
            modifiers.contains(EventTapManager.supportedClickModifiers[$0.tag].flag)
        }
        modifierClickItem.title = (selected.map(\.title) + ["Left Click"]).joined(separator: " + ")
        for item in clickModifierItems {
            item.state = selected.contains(item) ? .on : .off
            // A chord can't be empty, or every plain click would become a middle click.
            item.isEnabled = !(selected.count == 1 && selected[0] === item)
        }
    }

    @objc private func toggleThreeFingerClick() {
        eventTap.threeFingerClickEnabled.toggle()
        defaults.set(eventTap.threeFingerClickEnabled, forKey: DefaultsKey.threeFingerClick)
        applyTrackpadSettings()
    }

    @objc private func toggleThreeFingerTap() {
        let enabled = !trackpad.tapEnabled
        defaults.set(enabled, forKey: DefaultsKey.threeFingerTap)
        applyTrackpadSettings()
    }

    private func applyTrackpadSettings() {
        let tapEnabled = defaults.bool(forKey: DefaultsKey.threeFingerTap)
        trackpad.tapEnabled = tapEnabled
        trackpad.setRunning(tapEnabled || eventTap.threeFingerClickEnabled)
    }

    @objc private func toggleIgnoreFrontmost() {
        guard let bundleID = frontmostBundleID else { return }
        if eventTap.ignoredBundleIDs.remove(bundleID) == nil {
            eventTap.ignoredBundleIDs.insert(bundleID)
        }
        defaults.set(Array(eventTap.ignoredBundleIDs), forKey: DefaultsKey.ignoredApps)
    }

    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change Start at Login"
            alert.runModal()
            return
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func hideIcon() {
        setIconVisible(false)
    }

    private func setIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        defaults.set(!visible, forKey: DefaultsKey.iconHidden)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
