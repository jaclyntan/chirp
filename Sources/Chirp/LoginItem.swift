import Foundation
import OSLog
import ServiceManagement

/// Whether Chirp starts itself when you log in.
///
/// `SMAppService.mainApp` rather than a helper target or the long-dead
/// `LSSharedFileList`: the app registers *itself* as a login item, which
/// needs no extra bundle, no separate signing identity, and shows up under
/// System Settings → General → Login Items where the user can turn it off
/// without coming back here.
///
/// Deliberately not mirrored into `Settings`/`UserDefaults`. The system
/// owns this state and the user can change it from System Settings at any
/// time, so a cached copy would drift and start lying — every read asks
/// the real thing instead.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Best-effort. The common failure is `.requiresApproval` — macOS has
    /// the item registered but the user (or a profile) has disabled it in
    /// System Settings, and nothing the app does can override that. The
    /// caller re-reads `isEnabled` afterwards precisely so the UI shows
    /// what actually happened rather than what was asked for.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger(subsystem: "local.chirp", category: "loginitem")
                .error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
