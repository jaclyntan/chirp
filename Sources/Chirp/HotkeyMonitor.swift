import AppKit
import Foundation

/// Watches the chosen modifier key globally.
/// - Hold = push-to-talk (release stops).
/// - Double-tap = hands-free toggle (tap again to stop).
/// Requires Accessibility permission for global key monitoring.
final class HotkeyMonitor {

    enum Hotkey: String, CaseIterable {
        case fn
        case rightOption
        case rightCommand
        case rightControl
        case rightShift

        // Right-side modifiers only, alongside fn — matching the reasoning
        // already established by shipping Right Option instead of Left:
        // left-side modifiers collide far more often with in-flight system
        // and app shortcuts (⌘-anything, ⌥-anything) than their right-side
        // twins do. Caps Lock is deliberately not offered here — it's a
        // stateful toggle with its own OS-level debounce, not a clean
        // press/release pair like every other case below.
        var displayName: String {
            switch self {
            case .fn: return "fn (Globe)"
            case .rightOption: return "Right Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            case .rightControl: return "Right Control (⌃)"
            case .rightShift: return "Right Shift (⇧)"
            }
        }

        /// Short glyph for a keycap-sized chip — `displayName` is too long
        /// once its parenthesized symbol has to stand alone at cap size.
        var shortSymbol: String {
            switch self {
            case .fn: return "fn"
            case .rightOption: return "⌥"
            case .rightCommand: return "⌘"
            case .rightControl: return "⌃"
            case .rightShift: return "⇧"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .fn: return 63
            case .rightOption: return 61
            case .rightCommand: return 54
            case .rightControl: return 62
            case .rightShift: return 60
            }
        }

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .fn: return .function
            case .rightOption: return .option
            case .rightCommand: return .command
            case .rightControl: return .control
            case .rightShift: return .shift
            }
        }
    }

    var hotkey: Hotkey
    var onStart: (() -> Void)?
    /// Called when dictation should stop and be transcribed.
    var onStop: (() -> Void)?
    /// Called when a too-short press should be discarded.
    var onCancel: (() -> Void)?
    var onHandsFreeChange: ((Bool) -> Void)?

    private(set) var isHandsFree = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyIsDown = false
    private var pressStartedAt: Date?
    private var lastTapEndedAt: Date?

    /// Presses shorter than this count as taps, not push-to-talk.
    private let tapThreshold: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.5

    /// How long the key must stay down before the microphone is started.
    ///
    /// Every start spins up the audio engine (re-pins the input device,
    /// installs a tap, starts Core Audio) and every cancel tears it down
    /// again. A brushed key or a few accidental taps used to run that whole
    /// cycle once per tap, back to back — the most hostile thing you can do
    /// to AVAudioEngine, and the likeliest trigger for a crash. A press that
    /// ends inside this window never starts the engine at all.
    ///
    /// The cost is that a deliberate hold begins recording this much later.
    /// It is deliberately small: the engine's own start-up already takes a
    /// few hundred milliseconds, and an accidental brush of the key is
    /// typically shorter than this. Set it to 0 to start on key-down.
    private let startDelay: TimeInterval = 0.12
    private var pendingStart: DispatchWorkItem?
    /// Whether `onStart` has fired for the press in progress, so a release
    /// only cancels (or stops) something that was actually started.
    private var startFired = false

    init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    func startMonitoring() {
        stopMonitoring()
        // A global monitor only receives events posted to *other*
        // applications — it stays silent for the hotkey when Chirp's own
        // window (e.g. Scratchpad, Transforms' try-it box) is what has
        // focus. A local monitor covers exactly that gap; both are needed
        // to catch the key regardless of which app is frontmost.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func resetPressedState() {
        keyIsDown = false
        pendingStart?.cancel()
        pendingStart = nil
        startFired = false
        resetHandsFree()
    }

    func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        resetPressedState()
    }

    static func runSelfTest() -> Bool {
        let monitor = HotkeyMonitor()
        monitor.keyIsDown = true
        monitor.isHandsFree = true
        monitor.pressStartedAt = Date()
        monitor.lastTapEndedAt = Date()
        monitor.resetPressedState()
        var allPassed = !monitor.keyIsDown && !monitor.isHandsFree &&
            monitor.pressStartedAt == nil && monitor.lastTapEndedAt == nil
        print("\(allPassed ? "PASS" : "FAIL"): sleep clears held-key and hands-free shortcut state")

        func check(_ ok: Bool, _ label: String) {
            if !ok { allPassed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }
        /// A fresh monitor with counters for every callback. Presses are
        /// driven directly (`keyDown()` / `keyUp()`), and the delay timer is
        /// simulated by calling `fireStart()`, so nothing here waits.
        func rig() -> (HotkeyMonitor, () -> (start: Int, stop: Int, cancel: Int)) {
            let m = HotkeyMonitor()
            var counts = (start: 0, stop: 0, cancel: 0)
            m.onStart = { counts.start += 1 }
            m.onStop = { counts.stop += 1 }
            m.onCancel = { counts.cancel += 1 }
            return (m, { counts })
        }

        // A brushed key ends inside the start delay: the microphone is never
        // touched, so there is nothing to start, cancel, or tear down.
        do {
            let (m, counts) = rig()
            m.keyDown(); m.keyUp()
            check(counts() == (0, 0, 0) && m.pendingStart == nil,
                  "a brushed key never starts the audio engine")
        }
        // Three accidental taps in a row: one start (the hands-free double
        // tap), one stop — not a start/cancel cycle per tap.
        do {
            let (m, counts) = rig()
            m.keyDown(); m.keyUp()
            m.keyDown(); m.keyUp()
            check(m.isHandsFree && counts() == (1, 0, 0),
                  "a quick double tap still starts hands-free, with a single start")
            m.keyDown()
            check(!m.isHandsFree && counts() == (1, 1, 0),
                  "the next press stops hands-free")
            m.keyUp()
            check(counts() == (1, 1, 0), "releasing that stopping press does nothing more")
        }
        // A press that outlasts the delay but is still a tap is cancelled.
        do {
            let (m, counts) = rig()
            m.keyDown(); m.fireStart(); m.keyUp()
            check(counts() == (1, 0, 1), "a tap that had already started is cancelled")
        }
        // Push-to-talk is unchanged once the delay has passed.
        do {
            let (m, counts) = rig()
            m.keyDown(); m.fireStart()
            m.pressStartedAt = Date().addingTimeInterval(-1)
            m.keyUp()
            check(counts() == (1, 1, 0), "holding the key still records, and release stops it")
        }
        // The release can be handled before the timer ever ran (a busy main
        // thread). It must still start, then stop, exactly once.
        do {
            let (m, counts) = rig()
            m.keyDown()
            m.pressStartedAt = Date().addingTimeInterval(-1)
            m.keyUp()
            check(counts() == (1, 1, 0), "a release that beats the timer still starts then stops once")
            m.fireStart()
            check(counts().start == 1, "a cancelled timer cannot start a second recording")
        }
        // Sleep / re-registering the monitor must not leave a timer armed.
        do {
            let (m, counts) = rig()
            m.keyDown()
            m.resetPressedState()
            check(m.pendingStart == nil && counts().start == 0,
                  "resetting the monitor disarms a pending start")
        }
        return allPassed
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let pressed = event.modifierFlags.contains(hotkey.flag)
        if pressed, !keyIsDown {
            keyIsDown = true
            keyDown()
        } else if !pressed, keyIsDown {
            keyIsDown = false
            keyUp()
        }
    }

    /// For a hands-free session ended by something other than a key press
    /// (auto-stop on a detected pause) — resets the same state `keyDown()`'s
    /// hands-free-stop branch does, minus `onStop?()` itself, which the
    /// caller has already triggered directly. Without this, this monitor's
    /// own `isHandsFree` would stay stuck true, and the next press would be
    /// swallowed as "stop the (already-stopped) session" instead of
    /// starting a new one.
    func resetHandsFree() {
        isHandsFree = false
        pressStartedAt = nil
        lastTapEndedAt = nil
    }

    private func keyDown() {
        if isHandsFree {
            // Any press while hands-free stops the session.
            isHandsFree = false
            onHandsFreeChange?(false)
            onStop?()
            pressStartedAt = nil
            lastTapEndedAt = nil
            return
        }
        pressStartedAt = Date()
        startFired = false
        pendingStart?.cancel()
        guard startDelay > 0 else {
            fireStart()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.fireStart() }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay, execute: work)
    }

    /// Starts recording for the press in progress, at most once. Reached
    /// from the delay timer, or from `keyUp()` when the release is handled
    /// before the timer ran (a busy main thread can delay it).
    private func fireStart() {
        guard !startFired else { return }
        startFired = true
        pendingStart = nil
        onStart?()
    }

    private func keyUp() {
        pendingStart?.cancel()
        pendingStart = nil
        guard let startedAt = pressStartedAt else { return }
        pressStartedAt = nil
        let holdDuration = Date().timeIntervalSince(startedAt)

        if holdDuration >= tapThreshold {
            // Push-to-talk: release ends dictation. If the timer hasn't run
            // yet, start first so the stop has something to end.
            fireStart()
            lastTapEndedAt = nil
            onStop?()
            return
        }

        // Short press: tap. Two taps in quick succession → hands-free.
        if let lastTap = lastTapEndedAt,
           Date().timeIntervalSince(lastTap) <= doubleTapWindow {
            lastTapEndedAt = nil
            // Hands-free needs a live recording, and a tap this short never
            // started one: start it now.
            fireStart()
            isHandsFree = true
            onHandsFreeChange?(true)
        } else {
            lastTapEndedAt = Date()
            // Only undo a recording that was really started. A tap that
            // ended inside the start delay never touched the microphone.
            //
            // Logged either way, with how long the key was down. A tap that
            // is ignored leaves no other trace, so without this there is no
            // way to tell afterwards that the delay did anything, or how
            // long accidental taps really are. Only the duration is logged.
            let heldMs = Int(holdDuration * 1000)
            if startFired {
                dictationLog.notice("hotkey: tap held \(heldMs) ms, recording cancelled")
                onCancel?()
            } else {
                dictationLog.notice("hotkey: tap held \(heldMs) ms, ignored before the microphone started")
            }
        }
    }
}

// MARK: - Key combo label

/// Formats a keyCode + modifier combo as keycap glyphs — used wherever a
/// rebindable global hotkey needs to redisplay itself (Notetaker's own
/// hotkey editor and status rows). Originally lived alongside Scratchpad's
/// hotkey editor, but the formatting itself was never Scratchpad-specific.
enum KeyComboLabel {
    static func symbols(for modifiers: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if modifiers.contains(.control) { out.append("⌃") }
        if modifiers.contains(.option) { out.append("⌥") }
        if modifiers.contains(.shift) { out.append("⇧") }
        if modifiers.contains(.command) { out.append("⌘") }
        return out
    }

    // Standard US ANSI virtual keycodes — covers what anyone would
    // realistically bind a global shortcut to (a letter, digit, or Space).
    // Not exhaustive of every key on every layout; falls back to a numeric
    // label rather than showing nothing for anything outside this set.
    private static let keyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// e.g. "⌃⇧Space" — the compact form used in tooltips/labels that
    /// aren't rendering individual keycap chips.
    static func compact(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        symbols(for: modifiers).joined() + keyName(for: keyCode)
    }
}
