import AppKit
import IOKit
import os

// Layout of one contact in a MultitouchSupport frame. The framework is private, so this
// mirrors its C struct field for field; the stride must stay 96 bytes.
struct MTPoint {
    var x: Float
    var y: Float
}

struct MTReadout {
    var position: MTPoint
    var velocity: MTPoint
}

struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTReadout
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTReadout
    var zero2: (Int32, Int32)
    var density: Float
}

private typealias MTDevice = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (MTDevice?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
private typealias MTRegisterCallbackFn = @convention(c) (MTDevice, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (MTDevice, Int32) -> Int32
private typealias MTDeviceStopFn = @convention(c) (MTDevice) -> Int32

/// The private framework is resolved at runtime so a future macOS that changes it
/// disables the trackpad features instead of stopping the app from launching.
private struct MultitouchAPI {
    let createList: MTDeviceCreateListFn
    let register: MTRegisterCallbackFn
    let unregister: MTRegisterCallbackFn
    let start: MTDeviceStartFn
    let stop: MTDeviceStopFn

    init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard MemoryLayout<MTTouch>.stride == 96,
              let handle = dlopen(path, RTLD_LAZY),
              let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop") else {
            return nil
        }
        self.createList = unsafeBitCast(createList, to: MTDeviceCreateListFn.self)
        self.register = unsafeBitCast(register, to: MTRegisterCallbackFn.self)
        self.unregister = unsafeBitCast(unregister, to: MTRegisterCallbackFn.self)
        self.start = unsafeBitCast(start, to: MTDeviceStartFn.self)
        self.stop = unsafeBitCast(stop, to: MTDeviceStopFn.self)
    }
}

/// Tracks fingers on every multitouch device. Frames arrive on a private framework thread, so
/// the gesture state is lock-protected; everything else is main-thread only. Nothing runs at
/// all while `setRunning(false)`, and the framework only delivers frames while fingers are down.
final class TrackpadManager {
    static let shared = TrackpadManager()

    private static let touchStateMakeTouch: Int32 = 4
    private static let touchStateTouching: Int32 = 5
    private static let tapMaxDuration = 0.30
    private static let tapMaxMovement: Float = 0.03
    private static let restartDelay = 1.0

    private struct FingerAnchor {
        let identifier: Int32
        let x: Float
        let y: Float
    }

    private struct DeviceState {
        var fingers = 0
        var gestureStart: Double?
        var anchors: [FingerAnchor] = []
        var tapRejected = false
    }

    /// Fired on the main thread.
    var onThreeFingerTap: (() -> Void)?

    private let api = MultitouchAPI()
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var deviceStates: [UInt: DeviceState] = [:]
    private var tapRecognitionEnabled = false

    private var isRunning = false
    private var deviceList: CFArray?
    private var devices: [MTDevice] = []
    private var pendingRestart: DispatchWorkItem?
    private var notificationPort: IONotificationPortRef?
    private var hotplugIterators: [io_iterator_t] = []
    private var wakeObservers: [NSObjectProtocol] = []

    var isAvailable: Bool { api != nil }

    private init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    var tapEnabled: Bool {
        get { withLock { tapRecognitionEnabled } }
        set { withLock { tapRecognitionEnabled = newValue } }
    }

    var isThreeFingersDown: Bool {
        withLock { deviceStates.values.contains { $0.fingers == 3 } }
    }

    func cancelPendingTap() {
        withLock {
            for key in deviceStates.keys {
                deviceStates[key]?.tapRejected = true
            }
        }
    }

    func setRunning(_ running: Bool) {
        guard running != isRunning, api != nil else { return }
        isRunning = running
        if running {
            startDevices()
            installRestartTriggers()
        } else {
            removeRestartTriggers()
            stopDevices()
        }
    }

    // MARK: Frame handling

    func handleFrame(deviceID: UInt, touches: UnsafePointer<MTTouch>?, count: Int, timestamp: Double) {
        var fingers = 0
        var fireTap = false

        os_unfair_lock_lock(lock)
        var state = deviceStates[deviceID] ?? DeviceState()

        if let touches {
            for index in 0..<count {
                let touchState = touches[index].state
                if touchState == Self.touchStateMakeTouch || touchState == Self.touchStateTouching {
                    fingers += 1
                }
            }
        }

        if fingers > 0, state.gestureStart == nil {
            state.gestureStart = timestamp
            state.anchors = []
            state.tapRejected = false
        }

        if let start = state.gestureStart {
            if timestamp - start > Self.tapMaxDuration || fingers > 3 {
                state.tapRejected = true
            }
            if fingers > state.fingers, !state.anchors.isEmpty {
                // A finger came back after the three-finger moment had passed.
                state.tapRejected = true
            }
            if fingers == 3, !state.tapRejected, let touches {
                updateAnchors(&state, touches: touches, count: count)
            }
            if fingers == 0 {
                fireTap = tapRecognitionEnabled && !state.tapRejected && !state.anchors.isEmpty
                state.gestureStart = nil
                state.anchors = []
            }
        }

        state.fingers = fingers
        deviceStates[deviceID] = state
        os_unfair_lock_unlock(lock)

        if fireTap {
            DispatchQueue.main.async { [weak self] in
                self?.onThreeFingerTap?()
            }
        }
    }

    private func updateAnchors(_ state: inout DeviceState, touches: UnsafePointer<MTTouch>, count: Int) {
        for index in 0..<count {
            let touch = touches[index]
            guard touch.state == Self.touchStateMakeTouch || touch.state == Self.touchStateTouching else { continue }
            let x = touch.normalized.position.x
            let y = touch.normalized.position.y
            if let anchor = state.anchors.first(where: { $0.identifier == touch.identifier }) {
                // Movement means a swipe (Mission Control and friends), not a tap.
                if abs(x - anchor.x) > Self.tapMaxMovement || abs(y - anchor.y) > Self.tapMaxMovement {
                    state.tapRejected = true
                }
            } else {
                state.anchors.append(FingerAnchor(identifier: touch.identifier, x: x, y: y))
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    // MARK: Device lifecycle

    private func startDevices() {
        guard let api, let list = api.createList()?.takeRetainedValue() else { return }
        let found: [MTDevice] = (0..<CFArrayGetCount(list)).compactMap { index in
            CFArrayGetValueAtIndex(list, index).map { MTDevice(mutating: $0) }
        }
        for device in found {
            api.register(device, contactFrameCallback)
            _ = api.start(device, 0)
        }
        deviceList = list
        devices = found
    }

    private func stopDevices() {
        if let api {
            for device in devices {
                api.unregister(device, contactFrameCallback)
                _ = api.stop(device)
            }
        }
        devices = []
        deviceList = nil
        withLock { deviceStates = [:] }
    }

    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.stopDevices()
            self.startDevices()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay, execute: work)
    }

    // Device handles die across sleep and when a Magic Trackpad connects or disconnects.
    private func installRestartTriggers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRestart()
            }
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port,
                notification,
                IOServiceMatching("AppleMultitouchDevice"),
                hotplugCallback,
                refcon,
                &iterator
            )
            if result == KERN_SUCCESS {
                // The notification only re-arms once the iterator has been drained.
                drain(iterator)
                hotplugIterators.append(iterator)
            }
        }
    }

    private func removeRestartTriggers() {
        pendingRestart?.cancel()
        pendingRestart = nil
        wakeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        wakeObservers = []
        hotplugIterators.forEach { IOObjectRelease($0) }
        hotplugIterators = []
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    fileprivate func handleHotplug(_ iterator: io_iterator_t) {
        drain(iterator)
        scheduleRestart()
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}

private let contactFrameCallback: MTContactCallback = { device, touches, count, timestamp, _ in
    TrackpadManager.shared.handleFrame(
        deviceID: UInt(bitPattern: device),
        touches: touches?.assumingMemoryBound(to: MTTouch.self),
        count: Int(count),
        timestamp: timestamp
    )
    return 0
}

private let hotplugCallback: IOServiceMatchingCallback = { refcon, iterator in
    guard let refcon else { return }
    Unmanaged<TrackpadManager>.fromOpaque(refcon).takeUnretainedValue().handleHotplug(iterator)
}
