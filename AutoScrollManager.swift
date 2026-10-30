import AppKit
import CoreGraphics

/// Keeps the real pointer still while looking as if it moves: every motion event warps it back,
/// the event's raw delta moves a stand-in arrow, and on release the real pointer jumps to the
/// arrow. Scroll events go to whatever is under the real pointer, so the target can't change.
/// The approach comes from Mac Mouse Fix's PointerFreeze, including the 0.07 s suppression
/// interval: at 0 repeated warps no longer hold the pointer, and larger makes motion stutter.
private final class PointerFreeze {
    private static let suppressionWhileFrozen: CFTimeInterval = 0.07

    private(set) var isFrozen = false
    private(set) var position = CGPoint.zero
    private var origin = CGPoint.zero
    private var displays: [CGRect] = []
    private var tap: CFMachPort?
    private var arrowPanel: NSPanel?
    private var savedSuppression: CFTimeInterval = 0.25

    /// Creating these takes long enough to be felt, so it happens ahead of the first session.
    func prepare() {
        if arrowPanel == nil { arrowPanel = makeArrowPanel() }
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: pointerFreezeCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0), .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: false)
        tap = newTap
    }

    func freeze(at point: CGPoint) {
        prepare()
        guard let tap else { return }
        origin = point
        position = point
        displays = Self.activeDisplayBounds()
        let source = CGEventSource(stateID: .combinedSessionState)
        savedSuppression = source?.localEventsSuppressionInterval ?? savedSuppression
        source?.localEventsSuppressionInterval = Self.suppressionWhileFrozen
        CGEvent.tapEnable(tap: tap, enable: true)
        isFrozen = true
        moveArrow()
        arrowPanel?.orderFrontRegardless()
        Self.setRealCursorHidden(true)
    }

    func unfreeze() {
        guard isFrozen, let tap else { return }
        isFrozen = false
        CGEvent.tapEnable(tap: tap, enable: false)
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(position)
        Self.setRealCursorHidden(false)
        arrowPanel?.orderOut(nil)
        source?.localEventsSuppressionInterval = savedSuppression
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isFrozen, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard isFrozen else { return }
        CGWarpMouseCursorPosition(origin)
        position = constrained(CGPoint(
            x: position.x + CGFloat(event.getIntegerValueField(.mouseEventDeltaX)),
            y: position.y + CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
        ))
        moveArrow()
    }

    /// Keeps the arrow on a real display: it can cross between screens but not leave them.
    private func constrained(_ point: CGPoint) -> CGPoint {
        if displays.contains(where: { $0.contains(point) }) { return point }
        guard let current = displays.first(where: { $0.contains(position) }) else { return position }
        return CGPoint(
            x: min(max(point.x, current.minX), current.maxX - 1),
            y: min(max(point.y, current.minY), current.maxY - 1)
        )
    }

    private func moveArrow() {
        guard let panel = arrowPanel else { return }
        let hotSpot = NSCursor.arrow.hotSpot
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrameOrigin(NSPoint(
            x: position.x - hotSpot.x,
            y: primaryHeight - (position.y - hotSpot.y) - panel.frame.height
        ))
    }

    private func makeArrowPanel() -> NSPanel {
        let image = NSCursor.arrow.image
        let frame = NSRect(origin: .zero, size: image.size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        let imageView = NSImageView(frame: frame)
        imageView.image = image
        panel.contentView = imageView
        return panel
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    // A background app can only hide the cursor with this private connection property. If a
    // future macOS removes it, the real arrow just stays visible at the start point.
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static func setRealCursorHidden(_ hidden: Bool) {
        let handle = dlopen(nil, RTLD_LAZY)
        if let main = dlsym(handle, "CGSMainConnectionID"), let set = dlsym(handle, "CGSSetConnectionProperty") {
            let connection = unsafeBitCast(main, to: MainConnectionFn.self)()
            _ = unsafeBitCast(set, to: SetPropertyFn.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
        if hidden {
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }
}

private func pointerFreezeCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<PointerFreeze>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// Windows-style auto-scroll: while active, content scrolls at a speed set by how far the
/// cursor is from the anchor. The timer and overlay only exist while a session is running.
final class AutoScrollManager {
    // The dead zone and speed curve are Chromium's middle-click auto-scroll values.
    static let deadZone: CGFloat = 15
    private static let speedExponent: CGFloat = 2.2
    private static let speedScale: CGFloat = 0.008
    /// 60 Hz on purpose: at 120 Hz, Chrome was seen falling behind and scrolling on after the input stopped.
    private static let tickInterval: TimeInterval = 1.0 / 60.0
    /// How quickly the scroll speed catches up with the cursor; hides jitter in hand movement.
    private static let smoothingTime: CGFloat = 0.05
    /// Longest step a late timer may catch up on, so a stall can't turn into a jump.
    private static let maxTickStep: CGFloat = 0.05
    private static let maxSpeed: CGFloat = 8000
    private static let overlaySize: CGFloat = 30

    /// Posting can block for several milliseconds, so it stays off the thread running the event tap.
    private static let postQueue = DispatchQueue(label: "FreeWheel.scroll", qos: .userInteractive)

    /// Receives vertical and horizontal wheel deltas in pixels.
    var postScroll: (Int32, Int32) -> Void = { vertical, horizontal in postQueue.async {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        )
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Must be the session tap with the default location. At the HID tap a posted event's
        // location moves the real cursor, which would pin it to wherever the event points.
        event?.post(tap: .cgSessionEventTap)
    } }

    /// Whether sessions lock onto the view under the start point. Only tests turn this off.
    var freezesPointer = true
    private let pointerFreeze = PointerFreeze()

    /// Multiplies scroll speed; 1 is the default feel.
    var sensitivity: CGFloat = 1
    var reverseDirection = false

    private(set) var isActive = false
    /// True once the cursor has moved out of the dead zone during this session.
    private(set) var hasLeftDeadZone = false
    private(set) var startDate = Date()

    private var anchor = CGPoint.zero
    private var lastTick = Date()
    private var remainder = CGVector.zero
    private var velocity = CGVector.zero
    private var verticalWheelSign: CGFloat = 1
    private var timer: Timer?
    private var overlay: NSPanel?
    private var observers: [NSObjectProtocol] = []

    func prepare() {
        pointerFreeze.prepare()
        if overlay == nil { overlay = makeOverlay() }
    }

    func start(at location: CGPoint) {
        guard !isActive else { return }
        isActive = true
        hasLeftDeadZone = false
        startDate = Date()
        anchor = location
        lastTick = Date()
        remainder = .zero
        velocity = .zero
        verticalWheelSign = Self.isScrollReverserRunning() ? -1 : 1
        showOverlay(at: location)
        if freezesPointer, let pointer = CGEvent(source: nil)?.location {
            pointerFreeze.freeze(at: pointer)
        }

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cursor = self.pointerFreeze.isFrozen ? self.pointerFreeze.position : CGEvent(source: nil)?.location
            if let cursor { self.tick(cursor: cursor, now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.screensDidSleepNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        pointerFreeze.unfreeze()
        timer?.invalidate()
        timer = nil
        overlay?.orderOut(nil)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    func tick(cursor: CGPoint, now: Date) {
        guard isActive else { return }
        let offset = CGVector(dx: cursor.x - anchor.x, dy: cursor.y - anchor.y)
        if abs(offset.dx) > Self.deadZone || abs(offset.dy) > Self.deadZone {
            hasLeftDeadZone = true
        }

        let elapsed = min(max(CGFloat(now.timeIntervalSince(lastTick)), 0), Self.maxTickStep)
        lastTick = now
        var target = Self.velocity(for: offset, sensitivity: sensitivity)
        if reverseDirection {
            target = CGVector(dx: -target.dx, dy: -target.dy)
        }
        let approach = 1 - exp(-elapsed / Self.smoothingTime)
        velocity.dx += (target.dx - velocity.dx) * approach
        velocity.dy += (target.dy - velocity.dy) * approach
        remainder.dx += velocity.dx * elapsed
        remainder.dy += velocity.dy * elapsed

        // Wheel deltas are whole pixels, so carry the fraction or slow speeds would never move.
        let horizontal = remainder.dx.rounded(.towardZero)
        let vertical = remainder.dy.rounded(.towardZero)
        guard horizontal != 0 || vertical != 0 else { return }
        remainder.dx -= horizontal
        remainder.dy -= vertical
        postScroll(Int32(vertical * verticalWheelSign), Int32(horizontal))
    }

    /// Posted events reach apps as sent, whatever the natural scrolling setting, unless Scroll
    /// Reverser's tap sees them. It flips the vertical axis, so flip first to cancel that out.
    private static func isScrollReverserRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.pilotmoon.scroll-reverser").isEmpty
    }

    /// Velocity in pixels per second as an app should receive it. Moving the cursor down or
    /// right gives negative values, which scroll the content toward its bottom or right edge.
    static func velocity(for offset: CGVector, sensitivity: CGFloat = 1) -> CGVector {
        // Each axis has its own dead zone, so scrolling straight down doesn't drift sideways.
        func speed(_ distance: CGFloat) -> CGFloat {
            guard abs(distance) > deadZone else { return 0 }
            let magnitude = min(pow(abs(distance), speedExponent) * speedScale * sensitivity, maxSpeed)
            return distance > 0 ? -magnitude : magnitude
        }
        return CGVector(dx: speed(offset.dx), dy: speed(offset.dy))
    }

    // MARK: Overlay

    private func showOverlay(at location: CGPoint) {
        let panel = overlay ?? makeOverlay()
        overlay = panel
        // Events use a top-left origin on the primary display, windows a bottom-left one.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrameOrigin(NSPoint(
            x: location.x - Self.overlaySize / 2,
            y: primaryHeight - location.y - Self.overlaySize / 2
        ))
        panel.orderFrontRegardless()
    }

    private func makeOverlay() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: Self.overlaySize, height: Self.overlaySize)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let imageView = NSImageView(frame: frame)
        imageView.image = Self.overlayImage()
        panel.contentView = imageView
        return panel
    }

    static func overlayImage() -> NSImage {
        let size = NSSize(width: overlaySize, height: overlaySize)
        return NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let ink = NSColor(white: 0.13, alpha: 1)

            // The soft shadow keeps the marker visible on white pages, the ring on dark ones.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
            shadow.shadowBlurRadius = 2.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 3.5, dy: 3.5))
            NSColor(white: 0.98, alpha: 0.96).setFill()
            disc.fill()
            NSGraphicsContext.restoreGraphicsState()

            disc.lineWidth = 0.75
            NSColor(white: 0, alpha: 0.35).setStroke()
            disc.stroke()

            ink.setFill()
            ink.setStroke()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()

            // Small arrowheads above and below the center; 1 points up, -1 points down.
            for direction: CGFloat in [1, -1] {
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: center.x, y: center.y + direction * 8))
                arrow.line(to: NSPoint(x: center.x - 3, y: center.y + direction * 4.25))
                arrow.line(to: NSPoint(x: center.x + 3, y: center.y + direction * 4.25))
                arrow.close()
                arrow.lineWidth = 0.75
                arrow.lineJoinStyle = .round
                arrow.fill()
                arrow.stroke()
            }
            return true
        }
    }
}

/// The sensitivity control shown inside the Auto-Scroll menu. The slider runs on a log scale
/// so 1x sits in the middle, with as much room to slow down as to speed up.
final class SensitivitySliderView: NSView {
    static let range: ClosedRange<CGFloat> = 0.25...4
    private static let centerSnap = 0.06

    var onChange: ((CGFloat) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider()

    var sensitivity: CGFloat {
        CGFloat(pow(2, slider.doubleValue))
    }

    init(sensitivity: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 50))

        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 28, width: 200, height: 18)
        addSubview(label)

        slider.minValue = log2(Double(Self.range.lowerBound))
        slider.maxValue = log2(Double(Self.range.upperBound))
        slider.numberOfTickMarks = 5
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.frame = NSRect(x: 20, y: 4, width: 200, height: 24)
        slider.doubleValue = log2(Double(sensitivity))
        addSubview(slider)

        updateLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func sliderChanged() {
        if abs(slider.doubleValue) < Self.centerSnap {
            slider.doubleValue = 0
        }
        updateLabel()
        onChange?(sensitivity)
    }

    private func updateLabel() {
        label.stringValue = String(format: "Sensitivity: %.2fx", Double(sensitivity))
    }
}
