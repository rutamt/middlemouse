import AppKit
import CoreGraphics

/// Windows-style auto-scroll: while active, content scrolls at a speed set by how far the
/// cursor is from the anchor. The timer and overlay only exist while a session is running.
final class AutoScrollManager {
    static let deadZone: CGFloat = 12
    private static let tickInterval: TimeInterval = 1.0 / 120.0
    /// How quickly the scroll speed catches up with the cursor; hides jitter in hand movement.
    private static let smoothingTime: CGFloat = 0.05
    /// Longest step a late timer may catch up on, so a stall can't turn into a jump.
    private static let maxTickStep: CGFloat = 0.05
    private static let speedExponent: CGFloat = 1.4
    private static let speedScale: CGFloat = 1.2
    private static let maxSpeed: CGFloat = 8000
    private static let overlaySize: CGFloat = 40

    /// Receives vertical and horizontal wheel deltas in pixels.
    var postScroll: (Int32, Int32) -> Void = { vertical, horizontal in
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
    }

    private(set) var isActive = false
    /// True once the cursor has moved out of the dead zone, which is what separates
    /// hold-and-drag from a click that leaves auto-scroll running.
    private(set) var hasLeftDeadZone = false

    private var anchor = CGPoint.zero
    private var lastTick = Date()
    private var remainder = CGVector.zero
    private var velocity = CGVector.zero
    private var verticalWheelSign: CGFloat = 1
    private var timer: Timer?
    private var overlay: NSPanel?
    private var observers: [NSObjectProtocol] = []

    func start(at location: CGPoint) {
        guard !isActive else { return }
        isActive = true
        hasLeftDeadZone = false
        anchor = location
        lastTick = Date()
        remainder = .zero
        velocity = .zero
        verticalWheelSign = Self.isNaturalScrollingEnabled() ? -1 : 1
        showOverlay(at: location)

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            guard let self, let cursor = CGEvent(source: nil)?.location else { return }
            self.tick(cursor: cursor, now: Date())
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
        timer?.invalidate()
        timer = nil
        overlay?.orderOut(nil)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    func tick(cursor: CGPoint, now: Date) {
        guard isActive else { return }
        let offset = CGVector(dx: cursor.x - anchor.x, dy: cursor.y - anchor.y)
        if hypot(offset.dx, offset.dy) > Self.deadZone {
            hasLeftDeadZone = true
        }

        let elapsed = min(max(CGFloat(now.timeIntervalSince(lastTick)), 0), Self.maxTickStep)
        lastTick = now
        let target = Self.velocity(for: offset)
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

    /// macOS applies the natural scrolling setting to posted events too, flipping the vertical
    /// axis only on the way to the app, so it must be flipped first for the page to follow the cursor.
    private static func isNaturalScrollingEnabled() -> Bool {
        let key = "com.apple.swipescrolldirection" as CFString
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? Bool ?? true
    }

    /// Velocity in pixels per second as an app should receive it. Moving the cursor down or
    /// right gives negative values, which scroll the content toward its bottom or right edge.
    static func velocity(for offset: CGVector) -> CGVector {
        let distance = hypot(offset.dx, offset.dy)
        guard distance > deadZone else { return .zero }
        let speed = min(pow(distance - deadZone, speedExponent) * speedScale, maxSpeed)
        return CGVector(dx: -offset.dx / distance * speed, dy: -offset.dy / distance * speed)
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

    private static func overlayImage() -> NSImage {
        let size = NSSize(width: overlaySize, height: overlaySize)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.1, alpha: 0.8).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 1, alpha: 0.9).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1
            ring.stroke()

            NSColor.white.setFill()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            NSBezierPath(ovalIn: NSRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)).fill()

            // One arrowhead on each side, rotating the same triangle around the center.
            for quarterTurn in 0..<4 {
                let angle = CGFloat(quarterTurn) * .pi / 2
                let point = { (along: CGFloat, across: CGFloat) -> NSPoint in
                    NSPoint(
                        x: center.x + along * cos(angle) - across * sin(angle),
                        y: center.y + along * sin(angle) + across * cos(angle)
                    )
                }
                let arrow = NSBezierPath()
                arrow.move(to: point(15, 0))
                arrow.line(to: point(10, 4))
                arrow.line(to: point(10, -4))
                arrow.close()
                arrow.fill()
            }
            return true
        }
    }
}
