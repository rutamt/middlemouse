import AppKit
import CoreGraphics

/// The single key that, held during a left click, turns it into a middle click.
enum MiddleClickKey: String, CaseIterable {
    case fn
    case control
    case option
    case command
    case shift

    var title: String {
        switch self {
        case .fn: return "fn"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .shift: return "Shift"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .shift: return .maskShift
        }
    }

    /// The flag plus its left/right-specific bits, which must go too or the
    /// target app can still see the key as held.
    var strippedFlags: CGEventFlags {
        switch self {
        case .fn: return flag
        case .control: return flag.union(CGEventFlags(rawValue: 0x0001 | 0x2000))
        case .option: return flag.union(CGEventFlags(rawValue: 0x0020 | 0x0040))
        case .command: return flag.union(CGEventFlags(rawValue: 0x0008 | 0x0010))
        case .shift: return flag.union(CGEventFlags(rawValue: 0x0002 | 0x0004))
        }
    }
}

/// Owns the CGEventTap. Rewrites qualifying left/right clicks into middle clicks in place,
/// and watches for the icon-toggle shortcut. Everything here runs on the main thread.
final class EventTapManager {
    private enum SourceButton {
        case left
        case right
    }

    /// A physical press that is currently being presented to the system as the middle button.
    private struct ActiveClick {
        let source: SourceButton
        let strippedFlags: CGEventFlags
    }

    private static let middleButton: Int64 = 2
    private static let keyCodeM: Int64 = 46
    private static let keyCodeEscape: Int64 = 53
    /// Tags our own synthesized clicks so the tap doesn't treat them as a hardware middle button.
    private static let synthesizedEventMarker: Int64 = 0x4657_4845_454C
    private static let shortcutRequired: CGEventFlags = [.maskSecondaryFn, .maskControl, .maskAlternate]
    private static let shortcutExcluded: CGEventFlags = [.maskCommand, .maskShift]

    /// nil turns the key + click shortcut off.
    var middleClickKey: MiddleClickKey? = .fn
    var threeFingerClickEnabled = true
    var ignoredBundleIDs: Set<String> = []
    var mouseAutoScrollEnabled = true
    var trackpadAutoScrollEnabled = false
    var noAutoScrollBundleIDs: Set<String> = []
    var onToggleIconShortcut: (() -> Void)?

    let autoScroll = AutoScrollManager()

    private let trackpad: TrackpadManager
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeClick: ActiveClick?
    /// The held button that started the current auto-scroll, if it hasn't been released yet.
    private var scrollPress: Int64?
    /// Buttons whose press ended auto-scroll, so the rest of that press must not reach apps.
    private var swallowedButtons: Set<Int64> = []

    var isRunning: Bool { eventTap != nil }

    init(trackpad: TrackpadManager) {
        self.trackpad = trackpad
    }

    /// Creates the tap if needed. Returns false when macOS refuses, which means no Accessibility access.
    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
            .keyDown,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Common modes keep the tap serviced while a menu is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        // Without the tap no click could ever end auto-scroll.
        stopAutoScroll()
        swallowedButtons = []
        releaseActiveClick()
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
    }

    /// The three-finger tap has no physical press to rewrite, so its click is posted here.
    func handleThreeFingerTap() {
        guard isRunning else { return }
        if autoScroll.isActive {
            stopAutoScroll()
            return
        }
        guard !isFrontmostAppIgnored() else { return }
        if trackpadAutoScrollEnabled, isAutoScrollAllowedInFrontmostApp(),
           let location = CGEvent(source: nil)?.location {
            autoScroll.start(at: location)
            return
        }
        postMiddleButton(.otherMouseDown)
        postMiddleButton(.otherMouseUp)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            reconcileActiveClick()
            reconcileScrollPress()
        case .leftMouseDown:
            if interceptPress(event) || handleMouseDown(.left, event: event) { return nil }
        case .rightMouseDown:
            if interceptPress(event) || handleMouseDown(.right, event: event) { return nil }
        case .leftMouseDragged:
            if interceptContinuation(event, isRelease: false) { return nil }
            convert(event, from: .left, to: .otherMouseDragged)
        case .rightMouseDragged:
            if interceptContinuation(event, isRelease: false) { return nil }
            convert(event, from: .right, to: .otherMouseDragged)
        case .leftMouseUp:
            if interceptContinuation(event, isRelease: true) { return nil }
            if convert(event, from: .left, to: .otherMouseUp) { activeClick = nil }
        case .rightMouseUp:
            if interceptContinuation(event, isRelease: true) { return nil }
            if convert(event, from: .right, to: .otherMouseUp) { activeClick = nil }
        case .otherMouseDown:
            if isSynthesized(event) { break }
            if interceptPress(event) || handleHardwareMiddleDown(event) { return nil }
        case .otherMouseDragged:
            if !isSynthesized(event), interceptContinuation(event, isRelease: false) { return nil }
        case .otherMouseUp:
            if !isSynthesized(event), interceptContinuation(event, isRelease: true) { return nil }
        case .keyDown:
            if autoScroll.isActive, !isToggleShortcut(event) {
                stopAutoScroll()
                if event.getIntegerValueField(.keyboardEventKeycode) == Self.keyCodeEscape { return nil }
            }
            if isToggleShortcut(event) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    onToggleIconShortcut?()
                }
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Returns true if the event was consumed. Handles a press arriving during auto-scroll,
    /// and clears leftovers from a press whose release was lost while the tap was disabled.
    private func interceptPress(_ event: CGEvent) -> Bool {
        // A press means this cannot be a three-finger tap, so it must not fire one on lift.
        trackpad.cancelPendingTap()

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        swallowedButtons.remove(button)
        if scrollPress == button { scrollPress = nil }

        guard autoScroll.isActive else { return false }
        stopAutoScroll()
        swallowedButtons.insert(button)
        return true
    }

    /// Returns true if a drag or release belongs to a press we already consumed.
    private func interceptContinuation(_ event: CGEvent, isRelease: Bool) -> Bool {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if button == scrollPress {
            if isRelease {
                scrollPress = nil
                // Dragged while held means hold-to-scroll, which ends on release like on
                // Windows. A plain click leaves auto-scroll running until the next click.
                if autoScroll.hasLeftDeadZone { autoScroll.stop() }
            }
            return true
        }
        if swallowedButtons.contains(button) {
            if isRelease { swallowedButtons.remove(button) }
            return true
        }
        return false
    }

    /// A physical middle button can only come from a mouse: trackpads have none, and our own
    /// trackpad clicks are either rewritten inside this tap or carry the synthesized marker.
    private func handleHardwareMiddleDown(_ event: CGEvent) -> Bool {
        guard mouseAutoScrollEnabled,
              event.getIntegerValueField(.mouseEventButtonNumber) == Self.middleButton,
              activeClick == nil,
              !isFrontmostAppIgnored(),
              isAutoScrollAllowedInFrontmostApp() else {
            return false
        }
        startAutoScroll(event)
        return true
    }

    private func startAutoScroll(_ event: CGEvent) {
        scrollPress = event.getIntegerValueField(.mouseEventButtonNumber)
        autoScroll.start(at: event.location)
    }

    private func stopAutoScroll() {
        autoScroll.stop()
        if let press = scrollPress {
            swallowedButtons.insert(press)
            scrollPress = nil
        }
    }

    private func reconcileScrollPress() {
        guard let press = scrollPress, let button = CGMouseButton(rawValue: UInt32(press)) else { return }
        if !CGEventSource.buttonState(.combinedSessionState, button: button) {
            scrollPress = nil
        }
    }

    private func isSynthesized(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == Self.synthesizedEventMarker
    }

    /// Returns true if the event was consumed.
    private func handleMouseDown(_ source: SourceButton, event: CGEvent) -> Bool {
        if let active = activeClick {
            // Another button pressed mid-drag is left alone. The same button pressing again
            // means its release was lost while the tap was disabled.
            guard active.source == source else { return false }
            releaseActiveClick()
        }

        let clickKey = source == .left ? middleClickKey.flatMap { event.flags.contains($0.flag) ? $0 : nil } : nil
        guard clickKey != nil || (threeFingerClickEnabled && trackpad.isThreeFingersDown) else { return false }
        guard !isFrontmostAppIgnored() else { return false }

        // Key + click always stays a true middle click, so it remains available for CAD
        // panning and opening links even where auto-scroll has taken the mouse's button.
        if clickKey == nil, trackpadAutoScrollEnabled, isAutoScrollAllowedInFrontmostApp() {
            startAutoScroll(event)
            return true
        }

        activeClick = ActiveClick(source: source, strippedFlags: clickKey?.strippedFlags ?? [])
        convert(event, from: source, to: .otherMouseDown)
        return false
    }

    /// Rewrites the event if it belongs to the active click. Deliberately ignores the current
    /// modifier state and frontmost app, so a click that started as middle always ends as middle.
    @discardableResult
    private func convert(_ event: CGEvent, from source: SourceButton, to type: CGEventType) -> Bool {
        guard let active = activeClick, active.source == source else { return false }
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: Self.middleButton)
        event.flags.remove(active.strippedFlags)
        return true
    }

    private func isToggleShortcut(_ event: CGEvent) -> Bool {
        let flags = event.flags
        return flags.contains(Self.shortcutRequired)
            && flags.isDisjoint(with: Self.shortcutExcluded)
            && event.getIntegerValueField(.keyboardEventKeycode) == Self.keyCodeM
    }

    private func isAutoScrollAllowedInFrontmostApp() -> Bool {
        guard !noAutoScrollBundleIDs.isEmpty,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return true
        }
        return !noAutoScrollBundleIDs.contains(bundleID)
    }

    private func isFrontmostAppIgnored() -> Bool {
        guard !ignoredBundleIDs.isEmpty,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return ignoredBundleIDs.contains(bundleID)
    }

    /// While the tap was disabled the release may have gone by unseen. If so, end the middle
    /// press now rather than leaving the target app stuck in a pan.
    private func reconcileActiveClick() {
        guard let active = activeClick else { return }
        let button: CGMouseButton = active.source == .left ? .left : .right
        if !CGEventSource.buttonState(.combinedSessionState, button: button) {
            releaseActiveClick()
        }
    }

    private func releaseActiveClick() {
        guard activeClick != nil else { return }
        activeClick = nil
        postMiddleButton(.otherMouseUp)
    }

    private func postMiddleButton(_ type: CGEventType) {
        guard let location = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.synthesizedEventMarker)
        event.post(tap: .cghidEventTap)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
