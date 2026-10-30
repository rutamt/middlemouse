import AppKit
import CoreGraphics

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
    private static let shortcutRequired: CGEventFlags = [.maskSecondaryFn, .maskControl, .maskAlternate]
    private static let shortcutExcluded: CGEventFlags = [.maskCommand, .maskShift]

    /// Modifiers that may make up the click chord, including the left/right-specific bits
    /// each one sets, which must go too or the target app can still see the key as held.
    static let supportedClickModifiers: [(flag: CGEventFlags, deviceBits: UInt64)] = [
        (.maskSecondaryFn, 0),
        (.maskControl, 0x0001 | 0x2000),
        (.maskAlternate, 0x0020 | 0x0040),
        (.maskCommand, 0x0008 | 0x0010),
        (.maskShift, 0x0002 | 0x0004),
    ]

    var modifierClickEnabled = true
    var clickModifiers: CGEventFlags = .maskSecondaryFn
    var threeFingerClickEnabled = true
    var ignoredBundleIDs: Set<String> = []
    var onToggleIconShortcut: (() -> Void)?

    private let trackpad: TrackpadManager
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeClick: ActiveClick?

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
        releaseActiveClick()
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
    }

    /// Posts a full middle click at the cursor. Used for the three-finger tap, which has no physical press to rewrite.
    func synthesizeMiddleClick() {
        guard isRunning, !isFrontmostAppIgnored() else { return }
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
        case .leftMouseDown:
            handleMouseDown(.left, event: event)
        case .rightMouseDown:
            handleMouseDown(.right, event: event)
        case .leftMouseDragged:
            convert(event, from: .left, to: .otherMouseDragged)
        case .rightMouseDragged:
            convert(event, from: .right, to: .otherMouseDragged)
        case .leftMouseUp:
            if convert(event, from: .left, to: .otherMouseUp) { activeClick = nil }
        case .rightMouseUp:
            if convert(event, from: .right, to: .otherMouseUp) { activeClick = nil }
        case .keyDown:
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

    private func handleMouseDown(_ source: SourceButton, event: CGEvent) {
        // A press means this cannot be a three-finger tap, so it must not fire one on lift.
        trackpad.cancelPendingTap()

        if let active = activeClick {
            // Another button pressed mid-drag is left alone. The same button pressing again
            // means its release was lost while the tap was disabled.
            guard active.source == source else { return }
            releaseActiveClick()
        }

        let isModifierClick = source == .left && modifierClickEnabled && event.flags.contains(clickModifiers)
        guard isModifierClick || (threeFingerClickEnabled && trackpad.isThreeFingersDown) else { return }
        guard !isFrontmostAppIgnored() else { return }

        activeClick = ActiveClick(source: source, strippedFlags: isModifierClick ? strippedFlags(for: clickModifiers) : [])
        convert(event, from: source, to: .otherMouseDown)
    }

    private func strippedFlags(for modifiers: CGEventFlags) -> CGEventFlags {
        var flags = modifiers
        for modifier in Self.supportedClickModifiers where modifiers.contains(modifier.flag) {
            flags.insert(CGEventFlags(rawValue: modifier.deviceBits))
        }
        return flags
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
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        )?.post(tap: .cghidEventTap)
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
