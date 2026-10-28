import AppKit
import CoreGraphics
import MurmurCore

/// Watches the keyboard for the dictation key, system-wide.
/// This is the part most dictation apps get wrong, so it is built defensively:
/// if macOS switches the listener off, it is switched back on, and a missed key release is noticed.
@MainActor
final class HotkeyMonitor {
    struct Key {
        let code: Int64
        let flag: CGEventFlags
    }

    static func key(for choice: HotkeyChoice) -> Key {
        switch choice {
        case .fn: Key(code: 63, flag: .maskSecondaryFn)
        case .rightOption: Key(code: 61, flag: .maskAlternate)
        case .rightCommand: Key(code: 54, flag: .maskCommand)
        case .rightControl: Key(code: 62, flag: .maskControl)
        }
    }

    private static let spaceKey: Int64 = 49
    private static let escapeKey: Int64 = 53
    private static let vKey: Int64 = 9

    var key: Key
    var onPress: @MainActor () -> Void = {}
    var onRelease: @MainActor () -> Void = {}
    /// Space pressed while the key is held. Return true to swallow it (the hands-free lock took it).
    var onSpaceWhileHeld: @MainActor () -> Bool = { false }
    /// Another key pressed while the dictation key is held: it was a shortcut like Fn+arrow, not dictation.
    var onOtherKeyWhileHeld: @MainActor () -> Void = {}
    /// Escape pressed. Return true to swallow it (a recording was cancelled).
    var onEscape: @MainActor () -> Bool = { false }
    /// Command+Control+V pressed. Return true if it was handled (swallowed).
    var onPasteLast: @MainActor () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    /// Keys whose press we swallowed, so their release is swallowed too.
    private var swallowed = Set<Int64>()

    init(key: Key) {
        self.key = key
    }

    /// Returns false when macOS refuses (a permission is missing).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The listener is attached to the main run loop, so this always runs on the main thread.
            return MainActor.assumeIsolated { monitor.handle(type, event) }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        isDown = false
    }

    /// Called every couple of seconds. macOS can quietly switch a listener off; this switches it back on.
    func ensureEnabled() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: - Events (these run on the main thread, inside macOS's key delivery, so they must be quick)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // The key may have come up while we were switched off.
            if isDown, !CGEventSource.flagsState(.combinedSessionState).contains(key.flag) {
                isDown = false
                later { self.onRelease() }
            }
            return pass

        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == key.code else { return pass }
            let down = event.flags.contains(key.flag)
            guard down != isDown else { return pass }
            isDown = down
            later { down ? self.onPress() : self.onRelease() }
            return pass

        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == TextInjector.syntheticMarker { return pass }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.escapeKey, onEscape() {
                swallowed.insert(code)
                return nil
            }
            if code == Self.vKey, event.flags.contains([.maskCommand, .maskControl]), onPasteLast() {
                swallowed.insert(code)
                return nil
            }
            if isDown {
                if code == Self.spaceKey, onSpaceWhileHeld() {
                    swallowed.insert(code)
                    return nil
                }
                if code != Self.spaceKey { later { self.onOtherKeyWhileHeld() } }
            }
            return pass

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowed.remove(code) != nil ? nil : pass

        default:
            return pass
        }
    }

    /// Do the real work just after this key event has been answered, so macOS is never kept waiting.
    private func later(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }
}
