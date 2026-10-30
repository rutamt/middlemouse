import AppKit
import ApplicationServices
import ServiceManagement

private enum DefaultsKey {
    static let middleClickKey = "middleClickKey"
    static let legacyClickEnabled = "fnClickEnabled"
    static let legacyClickModifiers = "clickModifiers"
    static let mouseAutoScroll = "mouseAutoScrollEnabled"
    static let legacyTrackpadAutoScroll = "trackpadAutoScrollEnabled"
    static let threeFingerClickAutoScroll = "threeFingerClickAutoScrollEnabled"
    static let threeFingerTapAutoScroll = "threeFingerTapAutoScrollEnabled"
    static let noAutoScrollApps = "noAutoScrollBundleIDs"
    static let reverseAutoScroll = "reverseAutoScrollEnabled"
    static let autoScrollSensitivity = "autoScrollSensitivity"
    static let threeFingerClick = "threeFingerClickEnabled"
    static let threeFingerTap = "threeFingerTapEnabled"
    static let ignoredApps = "ignoredBundleIDs"
    static let iconHidden = "menuBarIconHidden"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let permissionPollInterval: TimeInterval = 2
    private static let permissionChangeDelay: TimeInterval = 0.5
    private static let middleClickKeyOff = "off"

    private let defaults = UserDefaults.standard
    private let trackpad = TrackpadManager.shared
    private lazy var eventTap = EventTapManager(trackpad: trackpad)

    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var frontmostBundleID: String?

    private let permissionItem = NSMenuItem(title: "", action: #selector(requestAccessibility), keyEquivalent: "")
    private let middleClickMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let middleClickOffItem = NSMenuItem(title: "Off", action: #selector(selectMiddleClickKey(_:)), keyEquivalent: "")
    private let middleClickKeyItems: [NSMenuItem] = MiddleClickKey.allCases.map { key in
        let item = NSMenuItem(title: "\(key.title) + Click", action: #selector(selectMiddleClickKey(_:)), keyEquivalent: "")
        item.representedObject = key.rawValue
        return item
    }
    private let autoScrollMenuItem = NSMenuItem(title: "Auto-Scroll", action: nil, keyEquivalent: "")
    private let mouseAutoScrollItem = NSMenuItem(title: "Mouse Wheel Click", action: #selector(toggleMouseAutoScroll), keyEquivalent: "")
    private let threeFingerClickAutoScrollItem = NSMenuItem(title: "Three-Finger Click", action: #selector(toggleThreeFingerClickAutoScroll), keyEquivalent: "")
    private let threeFingerTapAutoScrollItem = NSMenuItem(title: "Three-Finger Tap", action: #selector(toggleThreeFingerTapAutoScroll), keyEquivalent: "")
    private let reverseAutoScrollItem = NSMenuItem(title: "Reverse Direction", action: #selector(toggleReverseAutoScroll), keyEquivalent: "")
    private let noAutoScrollItem = NSMenuItem(title: "", action: #selector(toggleNoAutoScrollFrontmost), keyEquivalent: "")
    private let threeFingerClickItem = NSMenuItem(title: "Three-Finger Click", action: #selector(toggleThreeFingerClick), keyEquivalent: "")
    private let threeFingerTapItem = NSMenuItem(title: "Three-Finger Tap", action: #selector(toggleThreeFingerTap), keyEquivalent: "")
    private let ignoreItem = NSMenuItem(title: "", action: #selector(toggleIgnoreFrontmost), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
    private let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideIcon), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            DefaultsKey.mouseAutoScroll: true,
            DefaultsKey.reverseAutoScroll: false,
            DefaultsKey.autoScrollSensitivity: 1.0,
            DefaultsKey.threeFingerClickAutoScroll: false,
            DefaultsKey.threeFingerTapAutoScroll: false,
            DefaultsKey.threeFingerClick: true,
            DefaultsKey.threeFingerTap: false,
            DefaultsKey.iconHidden: false,
        ])

        eventTap.middleClickKey = loadMiddleClickKey()
        eventTap.mouseAutoScrollEnabled = defaults.bool(forKey: DefaultsKey.mouseAutoScroll)
        eventTap.autoScroll.reverseDirection = defaults.bool(forKey: DefaultsKey.reverseAutoScroll)
        let sensitivity = CGFloat(defaults.double(forKey: DefaultsKey.autoScrollSensitivity))
        eventTap.autoScroll.sensitivity = min(max(sensitivity, SensitivitySliderView.range.lowerBound), SensitivitySliderView.range.upperBound)
        migrateTrackpadAutoScroll()
        eventTap.threeFingerClickAutoScrollEnabled = defaults.bool(forKey: DefaultsKey.threeFingerClickAutoScroll)
        eventTap.threeFingerTapAutoScrollEnabled = defaults.bool(forKey: DefaultsKey.threeFingerTapAutoScroll)
        eventTap.noAutoScrollBundleIDs = Set(defaults.stringArray(forKey: DefaultsKey.noAutoScrollApps) ?? [])
        eventTap.threeFingerClickEnabled = defaults.bool(forKey: DefaultsKey.threeFingerClick)
        eventTap.threeFingerTapEnabled = defaults.bool(forKey: DefaultsKey.threeFingerTap)
        eventTap.ignoredBundleIDs = Set(defaults.stringArray(forKey: DefaultsKey.ignoredApps) ?? [])
        eventTap.onToggleIconShortcut = { [weak self] in
            guard let self else { return }
            self.setIconVisible(!self.statusItem.isVisible)
        }
        trackpad.onThreeFingerTap = { [weak self] in
            self?.eventTap.handleThreeFingerTap()
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

        let middleClickMenu = NSMenu()
        middleClickMenu.autoenablesItems = false
        for item in [middleClickOffItem] + middleClickKeyItems {
            item.target = self
            middleClickMenu.addItem(item)
        }
        middleClickMenuItem.submenu = middleClickMenu

        let autoScrollMenu = NSMenu()
        autoScrollMenu.autoenablesItems = false
        for item in [mouseAutoScrollItem, threeFingerClickAutoScrollItem, threeFingerTapAutoScrollItem] {
            item.toolTip = "Starts auto-scroll instead of middle clicking."

            item.target = self
            autoScrollMenu.addItem(item)
        }
        reverseAutoScrollItem.target = self
        let sensitivityView = SensitivitySliderView(sensitivity: eventTap.autoScroll.sensitivity)
        sensitivityView.onChange = { [weak self] sensitivity in
            self?.eventTap.autoScroll.sensitivity = sensitivity
            self?.defaults.set(Double(sensitivity), forKey: DefaultsKey.autoScrollSensitivity)
        }
        let sensitivityItem = NSMenuItem()
        sensitivityItem.view = sensitivityView
        autoScrollMenu.addItem(.separator())
        autoScrollMenu.addItem(reverseAutoScrollItem)
        autoScrollMenu.addItem(sensitivityItem)
        autoScrollMenuItem.submenu = autoScrollMenu

        for item in [permissionItem, threeFingerClickItem, threeFingerTapItem, ignoreItem, noAutoScrollItem, loginItem, hideItem] {
            item.target = self
        }
        for item in [
            permissionItem, middleClickMenuItem, threeFingerClickItem, threeFingerTapItem, autoScrollMenuItem,
            .separator(),
            ignoreItem, noAutoScrollItem,
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

        refreshMiddleClickItems()
        mouseAutoScrollItem.state = eventTap.mouseAutoScrollEnabled ? .on : .off
        reverseAutoScrollItem.state = eventTap.autoScroll.reverseDirection ? .on : .off
        threeFingerClickAutoScrollItem.state = eventTap.threeFingerClickAutoScrollEnabled ? .on : .off
        threeFingerTapAutoScrollItem.state = eventTap.threeFingerTapAutoScrollEnabled ? .on : .off
        threeFingerClickItem.state = eventTap.threeFingerClickEnabled ? .on : .off
        threeFingerTapItem.state = eventTap.threeFingerTapEnabled ? .on : .off
        threeFingerClickItem.isEnabled = trackpad.isAvailable
        threeFingerTapItem.isEnabled = trackpad.isAvailable
        threeFingerClickAutoScrollItem.isEnabled = trackpad.isAvailable
        threeFingerTapAutoScrollItem.isEnabled = trackpad.isAvailable

        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostBundleID = frontmost?.bundleIdentifier
        let appName = frontmost?.localizedName ?? "Current App"
        ignoreItem.title = "Ignore \(appName)"
        noAutoScrollItem.title = "No Auto-Scroll in \(appName)"
        noAutoScrollItem.isEnabled = frontmostBundleID != nil
        noAutoScrollItem.state = frontmostBundleID.map(eventTap.noAutoScrollBundleIDs.contains) == true ? .on : .off
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

    @objc private func selectMiddleClickKey(_ sender: NSMenuItem) {
        let rawValue = sender.representedObject as? String
        eventTap.middleClickKey = rawValue.flatMap(MiddleClickKey.init(rawValue:))
        defaults.set(rawValue ?? Self.middleClickKeyOff, forKey: DefaultsKey.middleClickKey)
    }

    private func loadMiddleClickKey() -> MiddleClickKey? {
        if let stored = defaults.string(forKey: DefaultsKey.middleClickKey) {
            return MiddleClickKey(rawValue: stored)
        }

        // Carry over the earlier checkbox-based settings; a saved combination keeps its first key.
        var key: MiddleClickKey? = .fn
        if defaults.object(forKey: DefaultsKey.legacyClickModifiers) != nil {
            let flags = CGEventFlags(rawValue: UInt64(truncatingIfNeeded: defaults.integer(forKey: DefaultsKey.legacyClickModifiers)))
            key = MiddleClickKey.allCases.first { flags.contains($0.flag) } ?? .fn
        }
        if defaults.object(forKey: DefaultsKey.legacyClickEnabled) != nil, !defaults.bool(forKey: DefaultsKey.legacyClickEnabled) {
            key = nil
        }
        defaults.set(key?.rawValue ?? Self.middleClickKeyOff, forKey: DefaultsKey.middleClickKey)
        defaults.removeObject(forKey: DefaultsKey.legacyClickEnabled)
        defaults.removeObject(forKey: DefaultsKey.legacyClickModifiers)
        return key
    }

    private func refreshMiddleClickItems() {
        let current = eventTap.middleClickKey
        middleClickMenuItem.title = "Middle Click Shortcut: \(current.map { "\($0.title) + Click" } ?? "Off")"
        middleClickOffItem.state = current == nil ? .on : .off
        for item in middleClickKeyItems {
            item.state = item.representedObject as? String == current?.rawValue ? .on : .off
        }
    }

    @objc private func toggleMouseAutoScroll() {
        eventTap.mouseAutoScrollEnabled.toggle()
        defaults.set(eventTap.mouseAutoScrollEnabled, forKey: DefaultsKey.mouseAutoScroll)
    }

    @objc private func toggleReverseAutoScroll() {
        eventTap.autoScroll.reverseDirection.toggle()
        defaults.set(eventTap.autoScroll.reverseDirection, forKey: DefaultsKey.reverseAutoScroll)
    }

    @objc private func toggleThreeFingerClickAutoScroll() {
        eventTap.threeFingerClickAutoScrollEnabled.toggle()
        defaults.set(eventTap.threeFingerClickAutoScrollEnabled, forKey: DefaultsKey.threeFingerClickAutoScroll)
        applyTrackpadSettings()
    }

    @objc private func toggleThreeFingerTapAutoScroll() {
        eventTap.threeFingerTapAutoScrollEnabled.toggle()
        defaults.set(eventTap.threeFingerTapAutoScrollEnabled, forKey: DefaultsKey.threeFingerTapAutoScroll)
        applyTrackpadSettings()
    }

    /// The old single Trackpad switch becomes Three-Finger Click, leaving taps as middle clicks for links.
    private func migrateTrackpadAutoScroll() {
        guard defaults.object(forKey: DefaultsKey.legacyTrackpadAutoScroll) != nil else { return }
        defaults.set(defaults.bool(forKey: DefaultsKey.legacyTrackpadAutoScroll), forKey: DefaultsKey.threeFingerClickAutoScroll)
        defaults.removeObject(forKey: DefaultsKey.legacyTrackpadAutoScroll)
    }

    @objc private func toggleNoAutoScrollFrontmost() {
        guard let bundleID = frontmostBundleID else { return }
        if eventTap.noAutoScrollBundleIDs.remove(bundleID) == nil {
            eventTap.noAutoScrollBundleIDs.insert(bundleID)
        }
        defaults.set(Array(eventTap.noAutoScrollBundleIDs), forKey: DefaultsKey.noAutoScrollApps)
    }

    @objc private func toggleThreeFingerClick() {
        eventTap.threeFingerClickEnabled.toggle()
        defaults.set(eventTap.threeFingerClickEnabled, forKey: DefaultsKey.threeFingerClick)
        applyTrackpadSettings()
    }

    @objc private func toggleThreeFingerTap() {
        eventTap.threeFingerTapEnabled.toggle()
        defaults.set(eventTap.threeFingerTapEnabled, forKey: DefaultsKey.threeFingerTap)
        applyTrackpadSettings()
    }

    private func applyTrackpadSettings() {
        let recognizeTaps = eventTap.threeFingerTapEnabled || eventTap.threeFingerTapAutoScrollEnabled
        let watchClicks = eventTap.threeFingerClickEnabled || eventTap.threeFingerClickAutoScrollEnabled
        trackpad.tapEnabled = recognizeTaps
        trackpad.setRunning(recognizeTaps || watchClicks)
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
