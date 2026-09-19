import AppKit
import Carbon.HIToolbox

/// A global shortcut that actually *swallows* the keystroke.
///
/// `NSEvent.addGlobalMonitorForEvents` can only observe — the event still
/// reaches the focused app afterwards. For a modifier-only hotkey (the
/// `fn` dictation key) that's harmless, because those produce no text.
/// For a normal key it is not: ⌥V fires the shortcut *and* types `√` into
/// whatever you were writing, so the paste arrives with a stray character
/// glued to the front of it.
///
/// A `CGEvent` tap can return `nil` to consume the event outright, which
/// is the only way to bind a character key without leaking it. It needs
/// Accessibility, which Chirp already requires for pasting, so this asks
/// nothing new of the user.
@MainActor
final class ConsumingHotkeyMonitor {
    /// Supplies the combination to match. Read on every keystroke rather
    /// than captured once, so rebinding in Settings takes effect without
    /// restarting the tap.
    private let combination: () -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
    var onTrigger: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(combination: @escaping () -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)) {
        self.combination = combination
    }

    var isRunning: Bool { tap != nil }

    func start() {
        stop()
        guard AXIsProcessTrusted() else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ConsumingHotkeyMonitor>
                .fromOpaque(userInfo).takeUnretainedValue()

            // macOS disables a tap that takes too long in its callback, or
            // when input is otherwise disrupted. Re-enabling is the
            // documented recovery; without it the shortcut silently stops
            // working until relaunch.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { monitor.reenable() }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }

            return MainActor.assumeIsolated { () -> Unmanaged<CGEvent>? in
                let wanted = monitor.combination()
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let modifiers = NSEvent(cgEvent: event)?.modifierFlags
                    .intersection([.command, .option, .control, .shift]) ?? []
                guard keyCode == wanted.keyCode, modifiers == wanted.modifiers else {
                    return Unmanaged.passUnretained(event)
                }
                monitor.onTrigger?()
                // nil == consumed: the keystroke never reaches the app,
                // so no stray character lands in the user's text.
                return nil
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
