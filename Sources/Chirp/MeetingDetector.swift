import AppKit
import EventKit
import Foundation

/// Meeting apps Chirp can recognize by bundle ID — native calling apps,
/// where the frontmost app *is* the call, and browsers, where it's only
/// possibly a call: `MeetingDetector.refresh()` gates a browser match on
/// its active tab's URL actually looking like a meeting link (see
/// `MeetingURLMatcher`), opt-in via `Settings.browserMeetingDetectionEnabled`
/// since it means reading the frontmost tab's URL periodically.
enum MeetingApp: String, CaseIterable {
    case zoom = "us.zoom.xos"
    case teams = "com.microsoft.teams2"
    case facetime = "com.apple.FaceTime"
    case webex = "Cisco-Systems.Spark"
    case chrome = "com.google.Chrome"
    case safari = "com.apple.Safari"
    case edge = "com.microsoft.edgemac"
    case arc = "company.thebrowser.Browser"
    case brave = "com.brave.Browser"

    var isBrowser: Bool {
        switch self {
        case .chrome, .safari, .edge, .arc, .brave: return true
        case .zoom, .teams, .facetime, .webex: return false
        }
    }

    var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .facetime: return "FaceTime"
        case .webex: return "Webex"
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .edge: return "Edge"
        case .arc: return "Arc"
        case .brave: return "Brave"
        }
    }
}

/// Recognizes a handful of meeting providers' own URL shapes well enough
/// to tell "browsing" from "in a call" apart — substring matching, not a
/// strict parse, since that's all "does this look like a meeting link"
/// needs and it stays robust to whatever query string or locale segment a
/// real meeting link carries.
enum MeetingURLMatcher {
    private static let patterns: [(substring: String, service: String)] = [
        ("meet.google.com/", "Google Meet"),
        ("zoom.us/j/", "Zoom"),
        ("zoom.us/wc/", "Zoom"),
        ("teams.microsoft.com/l/meetup-join", "Microsoft Teams"),
        ("teams.live.com/meet", "Microsoft Teams"),
        ("webex.com/meet", "Webex"),
    ]

    static func service(for url: String) -> String? {
        let lowered = url.lowercased()
        return patterns.first { lowered.contains($0.substring) }?.service
    }
}

/// Reads the frontmost browser's own active-tab URL via Apple Events — the
/// same on-device automation mechanism `AXIsProcessTrusted()`-gated paste
/// already relies on elsewhere in this app, not a network request. macOS
/// asks the user to approve Chirp controlling each browser the first time
/// it's actually queried (System Settings > Privacy & Security >
/// Automation) — expected, and why this is opt-in at the call site rather
/// than run unconditionally.
enum BrowserTabReader {
    private static func script(for app: MeetingApp) -> String? {
        switch app {
        case .chrome, .edge, .arc, .brave:
            // Chromium's own AppleScript dictionary — Edge, Arc, and Brave
            // all implement the same "active tab of front window" shape
            // Chrome does.
            return "tell application id \"\(app.rawValue)\" to " +
                "if (count of windows) > 0 then return URL of active tab of front window"
        case .safari:
            return "tell application id \"\(app.rawValue)\" to " +
                "if (count of windows) > 0 then return URL of front document"
        case .zoom, .teams, .facetime, .webex:
            return nil
        }
    }

    /// Runs synchronously (`NSAppleScript` has no async form) — always
    /// called off the main actor by `MeetingDetector.refresh()` so a slow
    /// or unresponsive browser can't stall the app's own UI.
    static func activeTabURL(for app: MeetingApp) -> String? {
        guard let source = script(for: app), let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}

/// Watches for two things, both purely local: a known meeting app coming
/// to the front (`NSWorkspace`, the same mechanism App Profiles already
/// uses to know what's frontmost), and — best-effort, only for a nicer
/// note title — an in-progress Calendar event via EventKit. Neither one
/// gates whether capture can start; both only feed `NotetakerPage`'s own
/// "a meeting looks like it's happening" prompt and the title a new
/// `MeetingNote` gets.
@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var activeMeetingApp: MeetingApp?
    /// Set only alongside a *browser* match — the meeting provider its
    /// active tab looks like ("Google Meet"), so a note gets that as its
    /// fallback title instead of the browser's own name. Nil for a native
    /// app match, where `activeMeetingApp.displayName` is already right.
    @Published private(set) var activeMeetingServiceName: String?
    @Published var calendarAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    private let eventStore = EKEventStore()
    private var pollTimer: Timer?
    /// Guards against a slow AppleScript call from one poll tick still
    /// running when the next one fires three seconds later — `refresh()`
    /// skips starting a second browser check rather than letting them
    /// queue up and answer out of order.
    private var checkingBrowserTab = false

    func startWatching() {
        guard pollTimer == nil else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            activeMeetingApp = nil
            activeMeetingServiceName = nil
            return
        }
        if let native = MeetingApp.allCases.first(where: { $0.rawValue == bundleID && !$0.isBrowser }) {
            activeMeetingApp = native
            activeMeetingServiceName = nil
            return
        }
        guard Settings.browserMeetingDetectionEnabled, !checkingBrowserTab,
              let browser = MeetingApp.allCases.first(where: { $0.rawValue == bundleID && $0.isBrowser })
        else {
            activeMeetingApp = nil
            activeMeetingServiceName = nil
            return
        }
        checkingBrowserTab = true
        Task.detached(priority: .utility) { [weak self] in
            let url = BrowserTabReader.activeTabURL(for: browser)
            let service = url.flatMap(MeetingURLMatcher.service(for:))
            await MainActor.run {
                guard let self else { return }
                self.checkingBrowserTab = false
                // The frontmost app may have changed again by the time
                // this AppleScript call returns — re-check rather than
                // trusting the value this Task started with.
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.rawValue else { return }
                if let service {
                    self.activeMeetingApp = browser
                    self.activeMeetingServiceName = service
                } else {
                    self.activeMeetingApp = nil
                    self.activeMeetingServiceName = nil
                }
            }
        }
    }

    // MARK: - Calendar (best-effort titling only)

    func requestCalendarAccess() async {
        calendarAuthorized = (try? await eventStore.requestFullAccessToEvents()) ?? false
    }

    /// The calendar event whose time window contains right now, if any —
    /// resolved once and shared by `currentEventTitle()` and
    /// `currentEventAttendeeNames()` below. Never blocks or delays
    /// starting a capture; a failed or declined calendar lookup just
    /// leaves both of those returning nothing, falling back to the app's
    /// own name and to no speaker seeding.
    private func currentEvent() -> EKEvent? {
        guard calendarAuthorized else { return nil }
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-300), end: now.addingTimeInterval(300), calendars: nil)
        return eventStore.events(matching: predicate)
            .first { $0.startDate <= now && $0.endDate >= now }
    }

    /// "Weekly Sync" instead of "Zoom, 2:14 PM".
    func currentEventTitle() -> String? {
        currentEvent()?.title
    }

    /// Attendee names on the in-progress event, minus the organizer
    /// (assumed to be the user) — a best-effort seed for the *first*
    /// unnamed other-speaker in a capture, the same "calendar context"
    /// Wispr Flow's own Notetaker uses for this, not a network lookup
    /// about anyone. Empty whenever there's no matching event, no
    /// attendee list on it, or calendar access was never granted.
    func currentEventAttendeeNames() -> [String] {
        guard let event = currentEvent() else { return [] }
        let organizerName = event.organizer?.name
        return (event.attendees ?? [])
            .compactMap(\.name)
            .filter { $0 != organizerName }
    }
}
