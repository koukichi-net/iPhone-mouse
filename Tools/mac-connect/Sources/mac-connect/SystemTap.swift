import Foundation
import CoreGraphics

/// Listen-only CGEventTap for key events reaching the window server (all keyboards). It is
/// the "did it reach the system?" oracle: under a working seize, keys sent by the phone must
/// not show up here. Each event carries the keyboard type macOS assigned to its source.
///
/// The source is attributed by scanning the event's integer fields for a registry entry ID
/// of a known BLE HID device (or one of its child services); `senderField` reports which
/// field matched. This is an observation, not a documented API.
final class SystemTap: @unchecked Sendable {
    struct Event: Sendable {
        var time: Double
        var type: CGEventType
        var keycode: Int
        var keyboardType: Int
        var flags: UInt64
        /// (field number, registry ID) if a field matched a known BLE service ID.
        var bleSender: (field: Int, id: UInt64)?
    }

    private let lock = NSLock()
    private var bleIDs: Set<UInt64> = []
    private var tap: CFMachPort?
    private let handler: @Sendable (Event) -> Void
    private(set) var started = false

    init(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
    }

    func setBLEIDs(_ ids: Set<UInt64>) {
        lock.lock(); bleIDs = ids; lock.unlock()
    }

    private func knownIDs() -> Set<UInt64> {
        lock.lock(); defer { lock.unlock() }
        return bleIDs
    }

    /// Starts the tap on its own thread. Returns false if the tap could not be created
    /// (Input Monitoring not granted).
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask),
                                           callback: { _, type, event, ctx in
                                               let me = Unmanaged<SystemTap>.fromOpaque(ctx!).takeUnretainedValue()
                                               me.received(type, event)
                                               return Unmanaged.passUnretained(event)
                                           }, userInfo: ref) else { return false }
        tap = port
        started = true
        let thread = Thread { [self] in
            guard let port = self.tap else { return }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "SystemTap"
        thread.start()
        return true
    }

    private func received(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            handler(Event(time: Date().timeIntervalSince1970, type: type, keycode: -1, keyboardType: -1, flags: 0, bleSender: nil))
            return
        }
        let ids = knownIDs()
        var sender: (Int, UInt64)?
        if !ids.isEmpty {
            for f in 0..<200 {
                guard let field = CGEventField(rawValue: UInt32(f)) else { continue }
                let v = UInt64(bitPattern: event.getIntegerValueField(field))
                if v != 0, ids.contains(v) { sender = (f, v); break }
            }
        }
        handler(Event(time: Date().timeIntervalSince1970, type: type,
                      keycode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                      keyboardType: Int(event.getIntegerValueField(.keyboardEventKeyboardType)),
                      flags: event.flags.rawValue, bleSender: sender))
    }
}
