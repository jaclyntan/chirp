import AppKit
import Observation

/// Event-driven power policy: no polling, and overlapping sleep/display/
/// session events cannot accidentally resume work before all have cleared.
@MainActor
@Observable
final class RuntimeActivity {
    private(set) var systemSleeping = false
    private(set) var displaySleeping = false
    private(set) var sessionInactive = false
    private(set) var reducesMotion = false
    var suspendsAmbientWork: Bool { systemSleeping || displaySleeping || sessionInactive }

    @ObservationIgnored var onSleep: (() -> Void)?
    @ObservationIgnored var onWake: (() -> Void)?
    @ObservationIgnored var onAmbientChange: ((Bool) -> Void)?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSystemSleeping(true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSystemSleeping(false) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setDisplaySleeping(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setDisplaySleeping(false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSessionInactive(true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSessionInactive(false) }
        observe(.default, .NSProcessInfoPowerStateDidChange) { $0.refreshPowerPolicy() }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { $0.refreshPowerPolicy() }
        refreshPowerPolicy()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (RuntimeActivity) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Synchronous on the main queue: stop capture before sleep,
            // rather than enqueueing cleanup that might run after wake.
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func refreshPowerPolicy() {
        let info = ProcessInfo.processInfo
        updatePowerPolicy(lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }

    private func updatePowerPolicy(lowPower: Bool, thermal: ProcessInfo.ThermalState) {
        reducesMotion = lowPower || thermal == .serious || thermal == .critical
    }

    func setSystemSleeping(_ value: Bool) {
        guard systemSleeping != value else { return }
        let oldAmbient = suspendsAmbientWork
        systemSleeping = value
        if value { onSleep?() }
        else {
            onWake?()
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
        if oldAmbient != suspendsAmbientWork { onAmbientChange?(suspendsAmbientWork) }
    }

    func setDisplaySleeping(_ value: Bool) {
        let oldAmbient = suspendsAmbientWork
        displaySleeping = value
        if oldAmbient != suspendsAmbientWork { onAmbientChange?(suspendsAmbientWork) }
    }

    func setSessionInactive(_ value: Bool) {
        let oldAmbient = suspendsAmbientWork
        sessionInactive = value
        if oldAmbient != suspendsAmbientWork { onAmbientChange?(suspendsAmbientWork) }
    }

    /// Finish capture now, but defer new transcription/model work to wake.
    /// Display sleep alone doesn't block audio or meeting processing.
    func waitUntilAwake() async {
        while systemSleeping {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    static func runSelfTest() async -> Bool {
        var passed = true
        func check(_ value: Bool, _ label: String) {
            if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }
        let activity = RuntimeActivity()
        var ambient: [Bool] = []
        var sleeps = 0
        var wakes = 0
        activity.onSleep = { sleeps += 1 }
        activity.onWake = { wakes += 1 }
        activity.onAmbientChange = { ambient.append($0) }
        activity.setDisplaySleeping(true)
        activity.setSystemSleeping(true)
        activity.setSystemSleeping(true)
        activity.setSessionInactive(true)
        activity.setSystemSleeping(false)
        check(activity.suspendsAmbientWork && sleeps == 1 && wakes == 1,
              "system wake does not resume decoration while display or session is asleep")
        activity.setDisplaySleeping(false)
        check(activity.suspendsAmbientWork, "inactive session keeps ambient work suspended")
        activity.setSessionInactive(false)
        check(ambient == [true, false], "overlapping power events produce one suspend and one resume")
        activity.setSystemSleeping(true)
        var finished = false
        let task = Task { await activity.waitUntilAwake(); finished = true }
        await Task.yield()
        check(!finished, "new processing waits while the system is asleep")
        activity.setSystemSleeping(false)
        await task.value
        check(finished, "pending processing resumes on system wake")
        activity.updatePowerPolicy(lowPower: true, thermal: .nominal)
        check(activity.reducesMotion, "Low Power Mode suspends ambient motion")
        activity.updatePowerPolicy(lowPower: false, thermal: .serious)
        check(activity.reducesMotion, "thermal pressure suspends ambient motion")
        activity.updatePowerPolicy(lowPower: false, thermal: .nominal)
        check(!activity.reducesMotion, "ambient motion returns after power and thermal pressure clear")
        return passed
    }
}
