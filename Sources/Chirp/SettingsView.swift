import AppKit
import Speech
import SwiftUI

// MARK: - Settings
//
// Redesigned per the "Main" canvas (Settings.dc.html): same `GlassPanelPage`
// shell as the other redesigned pages, warm palette instead of the shared
// dynamic `Palette`. Functionally unchanged — appearance, permissions,
// dictation key, and recognition engine, all still wired to the exact same
// `AppDelegate` state.
//
// The mockup's own "Software" section shows a version number plus an
// "Update available" pill — that pill is real here too: `UpdateChecker`
// (AppUpdate.swift) polls GitHub's Releases API for this repo, no
// Sparkle/appcast involved, and `SoftwareUpdateView` renders whatever it
// finds.

struct SettingsPage: View {
    @ObservedObject var app: AppDelegate
    // Separate `@ObservedObject`s for these two, rather than reading
    // `app.notetaker.screenRecordingAuthorized`/`app.notetaker.detector
    // .calendarAuthorized` straight through `app` — neither is `@Published`
    // *on* `AppDelegate` itself, so a plain `@ObservedObject var app` alone
    // doesn't resubscribe when either changes; this page's Calendar/Screen
    // Recording rows would just go stale until some unrelated part of the
    // page happened to re-render for a different reason.
    @ObservedObject private var notetaker: NotetakerController
    @ObservedObject private var meetingDetector: MeetingDetector

    @State private var supportedLocaleIDs: [String] = []
    @State private var handsFreeAutoStop = Settings.handsFreeAutoStop
    @State private var livePreviewEnabled = Settings.livePreviewEnabled
    @State private var petEnabled = Settings.petEnabled
    @State private var petWanders = Settings.petWanders
    @State private var launchAtLogin = LoginItem.isEnabled
    /// Which `AccentFieldSelect` (by its `id`) has its panel open, if any.
    /// Lifted up to the whole page rather than owned by each dropdown —
    /// see the panel-rendering `.overlayPreferenceValue` below for why.
    @State private var openDropdown: String?
    @State private var notetakerLiveTranscriptEnabled = Settings.notetakerLiveTranscriptEnabled
    @State private var notetakerHideFromScreenCapture = Settings.notetakerHideFromScreenCapture
    @State private var notetakerAutoStopOnCallEnd = Settings.notetakerAutoStopOnCallEnd
    @State private var notetakerMaxRecordingMinutes = Settings.notetakerMaxRecordingMinutes
    @State private var browserMeetingDetectionEnabled = Settings.browserMeetingDetectionEnabled
    @State private var notetakerHotkeyKeyCode = Settings.notetakerHotkeyKeyCode
    @State private var notetakerHotkeyModifiers = Settings.notetakerHotkeyModifiers
    @State private var showingNotetakerHotkeyEditor = false

    init(app: AppDelegate) {
        self.app = app
        _notetaker = ObservedObject(wrappedValue: app.notetaker)
        _meetingDetector = ObservedObject(wrappedValue: app.notetaker.detector)
    }

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ThinScrollView's own doc comment (DesignSystem.swift) for why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    sections.padding(.top, 26)
                }
                // Attached to the whole page, not to any individual tile or
                // trigger: an `.overlay` only ever paints above its *own*
                // host view, and a later sibling declared outside that host
                // still draws on top of it — which is exactly the bug where
                // the Parakeet-model row's own white trigger rendered over
                // the still-open Recognition-engine panel behind it.
                // Anchoring here means the open panel always has every row
                // on the page as an earlier sibling, so it wins regardless
                // of which trigger (in whichever tile) opened it.
                .overlayPreferenceValue(DropdownAnchorKey.self) { anchors in
                    if let openDropdown, let anchor = anchors[openDropdown] {
                        DropdownPanel(
                            openDropdown: openDropdown,
                            anchor: anchor,
                            options: dropdownOptions(for: openDropdown),
                            label: dropdownLabel(for: openDropdown),
                            selection: dropdownSelection(for: openDropdown),
                            close: { self.openDropdown = nil })
                    }
                }
            }
        }
        .onAppear {
            loadLocales()
            launchAtLogin = LoginItem.isEnabled
        }
        .sheet(isPresented: $showingNotetakerHotkeyEditor, onDismiss: {
            notetakerHotkeyKeyCode = Settings.notetakerHotkeyKeyCode
            notetakerHotkeyModifiers = Settings.notetakerHotkeyModifiers
        }) { NotetakerHotkeyEditor() }
    }

    // MARK: Sections

    /// Every setting, on one page, always visible.
    ///
    /// These four groups used to be collapsed accordion tiles — a 52pt
    /// blue icon square, a title, a summary listing the very settings it
    /// was hiding — so reaching any one of about fifteen options meant
    /// reading a menu, guessing a category, and clicking. For fifteen
    /// options that's a navigation layer paying for nothing: scrolling
    /// is cheaper than deciding, and a section you can see is a section
    /// you can scan for the word you're after.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 34) {
            settingsSection("General") {
                appearanceSection
                softwareSection
            }
            settingsSection("Dictation") { dictationSection }
            settingsSection("Notetaker") { notetakerSection }
            settingsSection("Privacy & permissions") { privacyPermissionsSection }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.chirpDisplay(15.5, .medium))
                .foregroundStyle(Palette.warmInk)
                .padding(.bottom, 4)
            VStack(spacing: 0) { content() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.chirpDisplay(23, .regular))
                .foregroundStyle(Palette.warmInk)
            Text("Everything Chirp does, and the permissions it needs to do it.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.field-row` reskinned in warm tokens: a label/detail on the left, a
    /// control on the right, a hairline below unless it's the section's
    /// last row. Reused for every row on this page rather than shared —
    /// same call as every other bespoke warm view this redesign has added.
    private func fieldRow<Control: View>(
        label: String, detail: String? = nil, isLast: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.manrope(12.5, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    if let detail {
                        Text(detail)
                            .font(.manrope(11))
                            .foregroundStyle(Palette.warmInkSoft)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control()
            }
            .padding(.vertical, 12)
            if !isLast {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(spacing: 0) {
            fieldRow(
                label: "Open at login",
                detail: "Start Chirp automatically when you log in, so the dictation "
                    + "key works without opening anything first.",
                isLast: false
            ) {
                WarmToggle(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LoginItem.setEnabled(newValue)
                        // The system is the source of truth, not this
                        // toggle: registration can fail (most often
                        // because the user has the login item disabled in
                        // System Settings), and silently showing "on"
                        // when it isn't would be worse than snapping back.
                        launchAtLogin = LoginItem.isEnabled
                    }
            }
            fieldRow(
                label: "Floating pet",
                detail: "A small draggable icon — click to open Chirp. Replaces hovering "
                    + "near the bottom of the screen, which can collide with the Dock.",
                isLast: false
            ) {
                WarmToggle(isOn: $petEnabled)
                    .onChange(of: petEnabled) { _, newValue in
                        app.setPetEnabled(newValue)
                    }
            }
            fieldRow(
                label: "Let it wander",
                detail: "Occasionally walks itself to a new spot nearby while idle, "
                    + "instead of only moving when you drag it.",
                isLast: true
            ) {
                WarmToggle(isOn: $petWanders)
                    .onChange(of: petWanders) { _, newValue in
                        Settings.petWanders = newValue
                    }
            }
        }
    }


    // MARK: Privacy & Permissions

    private var privacyPermissionsSection: some View {
        VStack(spacing: 0) {
            permissionRow(
                granted: app.micAuthorized,
                title: "Microphone",
                detail: "Required to hear your dictation.",
                pane: "Privacy_Microphone",
                isLast: false)
            permissionRow(
                granted: app.axTrusted,
                title: "Accessibility",
                detail: "Required for the global hotkey and pasting. "
                    + "Relaunch Chirp after granting.",
                pane: "Privacy_Accessibility",
                isLast: false)
            if !app.axTrusted {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Toggle on in System Settings but still red here? The saved grant "
                         + "belongs to an older build. Click Reset Grant — the app relaunches, "
                         + "macOS asks once more, and the new grant sticks for all future updates.")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Reset Grant & Relaunch") { app.resetAccessibilityGrant() }
                            .buttonStyle(WarmGhostButtonStyle())
                        Button("Relaunch") { app.relaunch() }
                            .buttonStyle(WarmGhostButtonStyle())
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 12)
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
            requestPermissionRow(
                granted: meetingDetector.calendarAuthorized,
                title: "Calendar",
                detail: "Gives Notetaker a meeting's real title and its attendees' names, "
                    + "instead of \u{201c}Zoom, 2:14 PM.\u{201d}",
                isLast: false
            ) {
                Task { await meetingDetector.requestCalendarAccess() }
            }
            requestPermissionRow(
                granted: notetaker.screenRecordingAuthorized,
                title: "Screen Recording",
                detail: "Lets Notetaker hear the other side of a call through the meeting "
                    + "app's own audio — it never records your screen.",
                isLast: true
            ) {
                notetaker.requestScreenRecordingAccess()
            }
        }
    }

    private func permissionRow(
        granted: Bool, title: String, detail: String, pane: String, isLast: Bool
    ) -> some View {
        fieldRow(label: title, detail: detail, isLast: isLast) {
            if granted {
                HStack(spacing: 6) {
                    ChirpIconView(icon: .check).frame(width: 13, height: 13)
                    Text("Granted").font(.manrope(12, .semibold))
                }
                .foregroundStyle(Palette.sunsetDeep)
            } else {
                Button("Open Settings") {
                    let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(WarmGhostButtonStyle())
            }
        }
    }

    /// Same shape as `permissionRow`, but the grant flow is an in-app
    /// request (`EKEventStore`/`CGRequestScreenCaptureAccess`) rather than
    /// a System Settings deep link — Calendar and Screen Recording are both
    /// requested in-app elsewhere already (Notetaker's own page), so this
    /// reuses that same flow instead of sending the user to System Settings
    /// for something Chirp can just ask for directly.
    private func requestPermissionRow(
        granted: Bool, title: String, detail: String, isLast: Bool, action: @escaping () -> Void
    ) -> some View {
        fieldRow(label: title, detail: detail, isLast: isLast) {
            if granted {
                HStack(spacing: 6) {
                    ChirpIconView(icon: .check).frame(width: 13, height: 13)
                    Text("Granted").font(.manrope(12, .semibold))
                }
                .foregroundStyle(Palette.sunsetDeep)
            } else {
                Button("Connect", action: action)
                    .buttonStyle(WarmGhostButtonStyle())
            }
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        VStack(spacing: 0) {
            fieldRow(label: "Dictation key") {
                AccentFieldSelect(
                    id: "hotkey", label: app.hotkey.displayName, openID: $openDropdown)
            }
            fieldRow(
                label: "Live transcript while speaking",
                detail: "Shows a rough transcript in the wren's speech bubble as you "
                    + "talk, when you start a dictation from its mic button. The real "
                    + "transcript is still produced from the full recording "
                    + "afterwards. Downloads a ~220 MB streaming model the first time "
                    + "it runs — the only download Chirp ever makes beyond macOS's "
                    + "own speech assets.",
                isLast: false
            ) {
                WarmToggle(isOn: $livePreviewEnabled)
                    .onChange(of: livePreviewEnabled) { _, newValue in
                        Settings.livePreviewEnabled = newValue
                        // Downloads/loads the model now, so the first
                        // dictation after switching this on isn't the one
                        // that pays for it.
                        if newValue { app.warmLivePreview() }
                    }
            }
            fieldRow(
                label: "Hands-free auto-stop",
                detail: "Double-tap to start, then stop automatically on a real pause "
                    + "instead of tapping again. Manual stop always still works.",
                isLast: false
            ) {
                WarmToggle(isOn: $handsFreeAutoStop)
                    .onChange(of: handsFreeAutoStop) { _, newValue in
                        Settings.handsFreeAutoStop = newValue
                    }
            }
            fieldRow(label: "Language") {
                AccentFieldSelect(
                    id: "language",
                    label: Locale.current.localizedString(forIdentifier: app.localeID) ?? app.localeID,
                    openID: $openDropdown)
            }
            // A plain info row, not a picker — Whisper/whisper.cpp/Parakeet
            // (and their own model-size sub-rows, which used to appear
            // here conditionally) were removed for fewer dependencies; see
            // docs/removed-engines.md for how to bring one back and
            // restore a real picker here. One fixed engine with nothing
            // to choose between doesn't need one.
            fieldRow(
                label: "Recognition engine",
                detail: "Apple's on-device engine — instant, no download, no network.",
                isLast: true
            ) {
                Text("Apple")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.warmInkSoft)
            }
        }
    }

    /// The shared panel rendered by the page-level `.overlayPreferenceValue`
    /// needs to know which options/labels/binding go with whichever
    /// `AccentFieldSelect.id` is currently open — these three dispatch on
    /// that id rather than the panel carrying a generic `Binding<T>` itself,
    /// since all four dropdowns on this page happen to be `String`-valued
    /// anyway.
    private func dropdownOptions(for id: String) -> [String] {
        switch id {
        case "hotkey": return HotkeyMonitor.Hotkey.allCases.map(\.rawValue)
        case "language": return pickerLocaleIDs
        case "notetakerMaxLength": return ["30", "60", "120", "240", "0"]
        default: return []
        }
    }

    private func dropdownLabel(for id: String) -> (String) -> String {
        switch id {
        case "hotkey":
            return { raw in HotkeyMonitor.Hotkey(rawValue: raw)?.displayName ?? raw }
        case "language":
            return { id in Locale.current.localizedString(forIdentifier: id) ?? id }
        case "notetakerMaxLength":
            return { raw in
                switch raw {
                case "30": return "30 minutes"
                case "60": return "1 hour"
                case "120": return "2 hours"
                case "240": return "4 hours"
                default: return "No limit"
                }
            }
        default: return { $0 }
        }
    }

    private func dropdownSelection(for id: String) -> Binding<String> {
        switch id {
        case "hotkey":
            return Binding(
                get: { app.hotkey.rawValue },
                set: { if let hotkey = HotkeyMonitor.Hotkey(rawValue: $0) { app.setHotkey(hotkey) } })
        case "language": return Binding(get: { app.localeID }, set: { app.setLocale($0) })
        case "notetakerMaxLength":
            return Binding(
                get: { String(notetakerMaxRecordingMinutes) },
                set: { raw in
                    guard let minutes = Int(raw) else { return }
                    notetakerMaxRecordingMinutes = minutes
                    Settings.notetakerMaxRecordingMinutes = minutes
                })
        default: return .constant("")
        }
    }

    // MARK: Notetaker

    private var notetakerSection: some View {
        VStack(spacing: 0) {
            fieldRow(
                label: "Show live transcript",
                detail: "Rough captions from both sides of the call while it's still running "
                    + "— the real, diarized transcript is only written once you stop."
            ) {
                WarmToggle(isOn: $notetakerLiveTranscriptEnabled)
                    .onChange(of: notetakerLiveTranscriptEnabled) { _, newValue in
                        Settings.notetakerLiveTranscriptEnabled = newValue
                    }
            }
            fieldRow(
                label: "Don't show Notetaker in screen capture",
                detail: "Keeps Chirp's own window out of anything you screen-record or "
                    + "share while capturing a meeting."
            ) {
                WarmToggle(isOn: $notetakerHideFromScreenCapture)
                    .onChange(of: notetakerHideFromScreenCapture) { _, newValue in
                        Settings.notetakerHideFromScreenCapture = newValue
                    }
            }
            fieldRow(
                label: "Stop automatically when the call ends",
                detail: "Ends the capture on its own once the meeting app closes."
            ) {
                WarmToggle(isOn: $notetakerAutoStopOnCallEnd)
                    .onChange(of: notetakerAutoStopOnCallEnd) { _, newValue in
                        Settings.notetakerAutoStopOnCallEnd = newValue
                    }
            }
            fieldRow(
                label: "Maximum recording length",
                detail: "Stops automatically at this length."
            ) {
                AccentFieldSelect(
                    id: "notetakerMaxLength",
                    label: dropdownLabel(for: "notetakerMaxLength")(String(notetakerMaxRecordingMinutes)),
                    openID: $openDropdown)
            }
            fieldRow(
                label: "Also detect meetings in your browser",
                detail: "Chrome, Safari, Edge, Arc, Brave. Reads only the active tab's URL "
                    + "to check for a meeting link — never your browsing history."
            ) {
                WarmToggle(isOn: $browserMeetingDetectionEnabled)
                    .onChange(of: browserMeetingDetectionEnabled) { _, newValue in
                        Settings.browserMeetingDetectionEnabled = newValue
                    }
            }
            fieldRow(
                label: "Keyboard shortcut",
                detail: "Starts or stops capturing the current call, from anywhere.",
                isLast: true
            ) {
                Button { showingNotetakerHotkeyEditor = true } label: {
                    HStack(spacing: 6) {
                        ForEach(KeyComboLabel.symbols(for: notetakerHotkeyModifiers), id: \.self) { symbol in
                            notetakerKeycap(symbol)
                        }
                        notetakerKeycap(KeyComboLabel.keyName(for: notetakerHotkeyKeyCode))
                        ChirpIconView(icon: .edit)
                            .frame(width: 10, height: 10)
                            .foregroundStyle(Palette.warmInkFaint)
                            .padding(.leading, 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func notetakerKeycap(_ label: String) -> some View {
        Text(label)
            .font(.manrope(11, .semibold))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: Software

    /// Real status, not decoration — `app.availableUpdate` is the same
    /// published property that drives `SoftwareUpdateView`'s own sheet
    /// (`AppShellRoot`'s `.sheet(item: $app.availableUpdate)`), which
    /// already shows itself automatically the moment `checkForUpdates()`
    /// finds a newer release. By the time anyone is looking at this row,
    /// that's almost always already resolved one way or the other, so this
    /// just reflects the same state rather than checking again.
    private var softwareSection: some View {
        fieldRow(label: "Chirp", detail: "Version \(appVersion)", isLast: true) {
            if app.availableUpdate == nil {
                // Quiet, not a badge — the normal state deserves no more
                // visual weight than a permission that's already
                // `Granted` gets (`permissionRow`'s own identical
                // treatment just below, in the Privacy tile): a check and
                // some text, no fill. Reserving the filled orange pill for
                // "Update available" is what actually makes that state
                // read as worth noticing.
                HStack(spacing: 6) {
                    ChirpIconView(icon: .check).frame(width: 13, height: 13)
                    Text("Up to date").font(.manrope(12, .semibold))
                }
                .foregroundStyle(Palette.sunsetDeep)
            } else {
                // Same outer-capsule treatment as the Theme picker just
                // above — a white capsule with a `warmRowBorder` stroke
                // and 2pt inset around the filled inner pill — so this
                // reads as belonging to the same control family, not a
                // one-off badge, precisely because it's the state that
                // should draw the eye the way a selected theme option does.
                HStack(spacing: 0) {
                    Text("Update available")
                        .font(.manrope(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Palette.sunsetDeep))
                }
                .padding(2)
                .background(Color.white, in: Capsule())
                .overlay(Capsule().stroke(Palette.warmRowBorder, lineWidth: 1))
                .fixedSize()
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// `app.supportedLanguageIDs()` always returns `nil` now that Apple's
    /// engine is the only one — falls through to `supportedLocaleIDs`
    /// (Apple's own fixed on-device asset list, loaded below) every time.
    /// Used to branch per-engine back when Whisper/whisper.cpp/Parakeet
    /// were still selectable, each with its own trained-language set; see
    /// docs/removed-engines.md.
    private var pickerLocaleIDs: [String] {
        var ids = sortedByLocalizedName(app.supportedLanguageIDs() ?? supportedLocaleIDs)
        if !ids.contains(app.localeID) { ids.insert(app.localeID, at: 0) }
        return ids
    }

    private func sortedByLocalizedName(_ ids: [String]) -> [String] {
        ids.sorted {
            (Locale.current.localizedString(forIdentifier: $0) ?? $0)
            < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
        }
    }

    private func loadLocales() {
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocaleIDs = sortedByLocalizedName(locales.map { $0.identifier(.bcp47) })
        }
    }
}

/// `.switch` reskinned in warm tokens.
private struct WarmToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.chirpEase(0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.sunsetDeep : Palette.warmDivider)
                    .frame(width: 32, height: 19)
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2)
            }
            .frame(width: 32, height: 19)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `GhostButtonStyle` reskinned in warm tokens — same soft-accent pairing
/// the mockup itself uses for its "Update available" pill.
private struct WarmGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(Palette.sunsetDeep)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Palette.sunsetSoft, in: RoundedRectangle(cornerRadius: Radius.sm))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// Reports each `AccentFieldSelect` trigger's on-screen bounds, keyed by
/// its `id`, up to the page-level `.overlayPreferenceValue` that actually
/// draws the open panel — see that call site for why the panel can't just
/// be a plain `.overlay` on the trigger itself.
private struct DropdownAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Positions and sizes the floating options panel for whichever dropdown
/// is open. Deliberately its own `View` rather than an inline closure in
/// `SettingsPage.body`: `@Environment` is resolved by a view's position in
/// the *rendered tree*, not by where a line of code textually sits, so
/// reading `\.tooltipClipBounds` from a property on `SettingsPage` itself
/// silently returned nil — `SettingsPage` sits *above* `ThinScrollView` in
/// the hierarchy, and `ThinScrollView` is what actually sets that value,
/// only for views nested inside it. This struct is constructed from
/// inside `.overlayPreferenceValue`, which *is* nested inside
/// `ThinScrollView`'s content, so its own `@Environment` read here
/// resolves correctly. Concretely, that bug meant the panel always
/// believed it had infinite room below the trigger, so it opened
/// downward unconditionally and simply ran off the bottom of the window
/// whenever real content was too tall to fit.
private struct DropdownPanel: View {
    let openDropdown: String
    let anchor: Anchor<CGRect>
    let options: [String]
    let label: (String) -> String
    let selection: Binding<String>
    let close: () -> Void

    @Environment(\.tooltipClipBounds) private var clipBounds

    var body: some View {
        GeometryReader { proxy in
            let rect = proxy[anchor]
            // The visible viewport's bottom edge, converted from
            // `clipBounds`' global space into this GeometryReader's own
            // local space, so it's directly comparable to `rect`.
            let viewportMaxY = (clipBounds?.maxY ?? .infinity)
                - proxy.frame(in: .global).minY
            let viewportHeight = clipBounds?.height ?? .greatestFiniteMagnitude
            let searchFieldHeight: CGFloat = openDropdown == "language" ? 50 : 0
            // The list's own ideal height, from its *actual* option count
            // — Language used to hardcode 396 here regardless of how many
            // locales were really on offer, which broke the moment
            // Parakeet v2 (English-only) narrowed it down to 2 options:
            // the estimate stayed at "whole page's worth," so the card
            // rendered huge with almost nothing in it. Per-row, not a flat
            // multiply: at this card's width (max 320pt, minus padding),
            // a label past ~38 characters wraps to two lines — measured
            // against "Parakeet v3 — multilingual (10 languages), ~600 MB"
            // (52 chars) actually clipping its second line at 36pt/row.
            // Model/engine labels routinely run this long; locale names
            // never do, so this only ever affects the non-Language lists.
            let rowHeight: (String) -> CGFloat = { label($0).count > 38 ? 56 : 36 }
            let idealContentHeight = options.reduce(0) { $0 + rowHeight($1) } + 12 + searchFieldHeight
            let availableBelow = max(0, viewportMaxY - rect.maxY - 6)
            let availableAbove = max(0, rect.minY - 6)
            let opensUpward = availableBelow < idealContentHeight
                && availableAbove > availableBelow
            // A *sensible* size, not just whatever happens to be free —
            // capped at half the visible viewport regardless of how much
            // *more* room a direction has: a short list opening upward
            // from low on a tall page had the whole page above it to use,
            // which is exactly why it rendered as a mostly-empty card
            // stretching nearly to the top. This only ever shrinks
            // `idealContentHeight` down for the *card's own size*
            // (`listHeight` below) — it must stay completely separate
            // from the positioning math right below, which needs the
            // real, uncapped distance to the trigger to line up against
            // it; conflating the two once already sent every panel
            // floating off to some fixed spot unrelated to its trigger.
            let sizeCap = max(160, min(
                opensUpward ? availableAbove : availableBelow, viewportHeight / 2))
            let listHeight = max(100, min(idealContentHeight, sizeCap) - searchFieldHeight)

            ZStack(alignment: .topLeading) {
                // Click-outside-to-dismiss: far bigger than any real
                // screen so it covers the window regardless of where the
                // trigger sits, invisible but still hit-testable via
                // `contentShape`. Declared first so the panel below —
                // drawn after, i.e. on top — intercepts its own clicks
                // instead of this catcher swallowing them.
                Color.clear
                    .frame(width: 6000, height: 6000)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .offset(x: -3000, y: -3000)
                // Trailing-aligned to the trigger's own right edge without
                // needing to know the panel's width up front: proposing a
                // container exactly `rect.maxX` wide (from the content
                // area's left edge to the trigger's right edge) and
                // right-aligning within it puts the panel's own right
                // edge flush with the trigger's, however wide the panel
                // ends up being — a fixed guessed offset undershot for a
                // long label like "Parakeet v2 — English, highest recall,
                // ~600 MB" and ran the panel past the window's edge. The
                // vertical side uses the same trick: rather than subtract
                // an estimated panel height to position it (compounding
                // that estimate's own error), bottom-aligning within a
                // frame that ends exactly at the trigger's top edge lets
                // the panel's *real* height determine how far upward it
                // grows.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AccentFieldSelectList(
                        options: options,
                        label: label,
                        selection: selection,
                        close: close,
                        showsSearch: openDropdown == "language",
                        listHeight: listHeight)
                        .frame(height: opensUpward ? max(0, rect.minY - 6) : nil,
                               alignment: .bottom)
                }
                .frame(width: max(1, rect.maxX))
                .offset(y: opensUpward ? 0 : rect.maxY + 6)
            }
        }
    }
}

/// The canvas's dedicated `Dropdown` component. Originally reserved for
/// just the two choices the mockup itself gives the treatment
/// (recognition engine, model) — Dictation key and Language used a
/// plainer, now-deleted `WarmFieldSelect` instead — but that inconsistency
/// read as leftover old UI once the rest of the page moved to this one, so
/// every dropdown on the page now shares it.
///
/// Deliberately not `.popover` — a native macOS popover always draws its
/// own arrow/caret pointing back at the trigger, which read as "old
/// system style" next to the mockup's plain floating card with no arrow
/// at all. Deliberately not a plain `.overlay` on the trigger either —
/// that only ever paints above its own host view, so a later sibling row
/// (e.g. the Parakeet-model trigger sitting right below the open
/// Recognition-engine panel) still drew on top of it. This only reports
/// *where* the trigger is via `.anchorPreference`; the panel itself is
/// drawn once, at the whole-page level, by `SettingsPage.body`'s own
/// `.overlayPreferenceValue` — see that for the actual positioning.
///
/// Also differs from `WarmFieldSelect` in that the trigger's accent
/// border and chevron color only appear while open — both mockup
/// illustrations of this only ever show the accent state *together with*
/// the panel already open, never at rest, and the closed/idle look
/// should match every other trigger on the page — and the selected row
/// in the panel carries a permanent tinted background plus a checkmark
/// instead of relying on hover alone to show which option is current.
/// No drop shadow on the panel, by request — overriding the mockup's own
/// (which does specify one), same no-shadow call as every other
/// floating/card element in this redesign. The mockup's own
/// `Dropdown.dc.html` also adds a search field, but only for its
/// Language illustration — a handful of engine/model options doesn't
/// need one, and the screenshot this was requested from shows none.
private struct AccentFieldSelect: View {
    let id: String
    let label: String
    @Binding var openID: String?

    private var isOpen: Bool { openID == id }

    var body: some View {
        Button {
            withAnimation(.chirpEase(0.12)) { openID = isOpen ? nil : id }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.manrope(12, .medium))
            .foregroundStyle(isOpen ? Palette.sunsetDeep : Palette.warmInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .chirpSurface()
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .stroke(isOpen ? Palette.sunsetDeep : Palette.warmRowBorder, lineWidth: isOpen ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

private struct AccentFieldSelectList: View {
    let options: [String]
    let label: (String) -> String
    @Binding var selection: String
    let close: () -> Void
    /// Only Language needs this — a couple dozen locales is the one list
    /// on this page long enough to warrant filtering, matching the
    /// mockup's own `Dropdown.dc.html`, which only ever illustrates the
    /// search field on its Language example, not a generic dropdown
    /// feature every instance gets.
    var showsSearch = false
    /// The options list's *exact* rendered height, computed by the caller
    /// (`DropdownPanel`) from the option count and available space —
    /// applied directly rather than as a maximum. A plain `ScrollView`
    /// fills whatever height it's offered instead of shrinking to fit
    /// short content, so a bare max-height cap alone left a 2-option list
    /// rendering as a mostly-empty card the full size of the cap.
    var listHeight: CGFloat = 336
    @State private var hovered: String?
    @State private var searchText = ""

    private var filteredOptions: [String] {
        guard showsSearch, !searchText.isEmpty else { return options }
        return options.filter { label($0).localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSearch {
                searchField
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ThinScrollView's own doc comment (DesignSystem.swift) for why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself. Applied unconditionally
            // now, not just for Language.
            ThinScrollView {
                optionsList.padding(6)
            }
            .frame(height: listHeight)
        }
        // `maxWidth`, not just `minWidth` — without a cap, the `Spacer`
        // pushing each row's checkmark to the trailing edge had unlimited
        // room to expand into and stretched the whole panel across most
        // of the page instead of hugging its content.
        .frame(minWidth: 220, maxWidth: 320)
        .chirpSurface()
        // Every other white card on this page (the tiles themselves) gets
        // a border — this floating panel didn't, which was invisible on
        // its own but broke down the moment Settings grew tall enough for
        // a panel to open directly over another white tile card behind
        // it: same fill, no shadow (kept — see this type's own header),
        // and now no border either meant literally nothing drawn marked
        // where one surface ended and the other began. `warmDivider`, not
        // `warmRowBorder` — the latter is tuned to nearly vanish against
        // white by design (it's a *fill* for chips sitting on the glass
        // panel elsewhere), which is exactly the problem here; this needs
        // to actually read as an edge.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.warmDivider, lineWidth: 1))
        .environment(\.colorScheme, .light)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            ChirpIconView(icon: .search)
                .frame(width: 13, height: 13)
                .foregroundStyle(Palette.warmInkFaint)
            TextField("Search languages…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // `#F7F5F0` in the mockup — happens to be the exact same value as
        // `homeGradientBottom`, reused here rather than adding a new
        // one-off token for a single search field.
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.sm))
        .padding(10)
    }

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredOptions, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                    close()
                } label: {
                    HStack {
                        Text(label(option))
                            .font(.manrope(13, isSelected ? .medium : .regular))
                            .foregroundStyle(Palette.warmInk)
                        Spacer(minLength: 12)
                        if isSelected {
                            ChirpIconView(icon: .check)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(Palette.sunsetDeep)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        isSelected ? Palette.sunsetSoft
                            : (hovered == option ? Palette.warmRowBorder : Color.clear),
                        in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? option : nil }
            }
        }
    }
}
