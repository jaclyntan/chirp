import AppKit
import SwiftUI

// MARK: - Home
//
// Redesigned per the "Main" canvas (Main.dc.html): the capture zone becomes
// a warm sunset-gradient hero instead of the old dark banner, and the whole
// page now sits on its own frosted glass panel over a sage-to-cream
// backdrop rather than the shell's flat panel background. Every store call
// and binding is unchanged from the previous implementation — this is a
// View-layer rewrite only.

struct HomePage: View {
    @ObservedObject var app: AppDelegate
    @State private var searchText = ""
    @State private var searchOpen = false
    @State private var showClearConfirm = false
    @State private var editingEntry: HistoryEntry?
    @State private var editText = ""
    @State private var learnFeedback: String?
    // Shared so opening a second row's overflow menu can't leave two open
    // at once — each row only shows its own menu when this matches its own
    // entry (see `HistoryRowView.isMenuOpen`).
    @State private var openMenuEntryID: HistoryEntry.ID?

    private var openMenuEntry: HistoryEntry? {
        guard let id = openMenuEntryID else { return nil }
        return app.entries.first { $0.id == id }
    }

    var body: some View {
        GlassPanelPage {
            VStack(alignment: .leading, spacing: 20) {
                captureZone
                statStrip
                historySection
            }
        }
        .sheet(item: $editingEntry) { entry in correctionSheet(entry) }
        // Rendered here — above `historySection`'s own `ScrollView`, not
        // nested inside it — so the menu is never a `LazyVStack` sibling
        // of the rows below it. A same-row `.overlay` plus `.zIndex` (tried
        // first) still lost to those rows in practice: `LazyVStack` only
        // *sometimes* honored the raised index, likely the same known
        // unreliability other SwiftUI/AppKit lazy-stack z-ordering reports
        // describe — not something to keep fighting. `RowMenuAnchorKey` is
        // the row's own action-icons bounds, reported only while its menu
        // is open; resolving it against this `GeometryReader` gives a
        // position independent of that row's place in the list, and of
        // scroll offset.
        .overlayPreferenceValue(RowMenuAnchorKey.self) { anchor in
            if let anchor, let entry = openMenuEntry {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    // `RowActionsMenu` is a fixed 190×~84 card, so its
                    // placement only needs that constant, not a measured
                    // round-trip: right-aligned under the icon by default,
                    // flipped upward when there isn't 84pt of headroom
                    // below, and kept clear of the left/right edges.
                    let menuWidth: CGFloat = 190
                    let menuHeight: CGFloat = 84
                    let opensUpward = rect.maxY + 6 + menuHeight > proxy.size.height
                    let x = max(0, min(rect.maxX - menuWidth, proxy.size.width - menuWidth))
                    let y = opensUpward ? rect.minY - 6 - menuHeight : rect.maxY + 6

                    // An almost-invisible, page-filling tap catcher behind
                    // the card: clicking anywhere outside the menu closes
                    // it, while the opaque card in front always takes the
                    // tap first wherever the two overlap.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { openMenuEntryID = nil }
                    RowActionsMenu(
                        onDelete: {
                            openMenuEntryID = nil
                            app.deleteHistoryEntry(id: entry.id)
                        },
                        onDismiss: { openMenuEntryID = nil })
                        .offset(x: x, y: y)
                }
            }
        }
        .animation(.chirpEase(0.14), value: openMenuEntryID)
    }

    // MARK: Capture zone

    /// The top of Home: what Chirp is doing right now, at headline
    /// scale, with the hotkey beside it and the waveform to the right.
    ///
    /// This used to be a bordered card carrying a fixed three-line
    /// marketing headline ("Speak naturally. Chirp formats it for every
    /// app, right on your Mac."). That's a launch-page pitch, and Home
    /// is the screen you see every single day — after the first minute
    /// it's just a large advertisement sitting above your actual work,
    /// telling you nothing. The line is state now, so the same space
    /// answers the only two live questions: is it listening, and what do
    /// I press.
    ///
    /// No card, no border, no fill — the headline is large enough to
    /// hold the top of the page on its own. Boxing it was doing the job
    /// the type should do.
    private var captureZone: some View {
        HStack(alignment: .center, spacing: 36) {
            VStack(alignment: .leading, spacing: 12) {
                Text(captureHeadline)
                    .font(.chirpDisplay(31, .regular))
                    .foregroundStyle(Palette.warmInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 10) {
                    PulsingDot(
                        color: app.uiState == .idle
                            ? Palette.warmInkFainter : Palette.sunsetDeep,
                        size: 6, maxScale: 2.2, active: app.uiState != .idle)
                    Text(captureSubhead)
                        .font(.manrope(12.5))
                        .foregroundStyle(Palette.warmInkSoft)
                    // Changing the hotkey where you're already reading it,
                    // rather than a trip to Settings for the single most
                    // likely thing anyone wants to change.
                    FieldSelect(
                        options: HotkeyMonitor.Hotkey.allCases,
                        label: { "Hold \($0.displayName)" },
                        selection: Binding(
                            get: { app.hotkey },
                            set: { app.setHotkey($0) }),
                        tint: Palette.warmInk,
                        background: .white,
                        borderColor: Palette.warmDivider)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only moves while something is actually being captured —
            // a waveform that animates forever on an idle screen is
            // decoration pretending to be feedback.
            HeroCaptureWaveform(active: app.uiState != .idle)
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// State, in the page's own serif — not a fixed brand line.
    private var captureHeadline: String {
        switch app.uiState {
        case .idle: return "Ready when you are."
        case .recording: return app.isHandsFree ? "Listening, hands-free." : "Listening…"
        case .processing: return "Working on it…"
        }
    }

    private var captureSubhead: String {
        if let status = app.transformStatus { return status }
        switch app.uiState {
        case .idle: return "Start talking with"
        case .recording: return "Release to insert —"
        case .processing: return "Cleaning up your words —"
        }
    }

    // MARK: Stat strip

    /// Words-today, wpm, and streak used to be two boxed `Card`s with big
    /// colored numerals fighting the capture zone for top billing. One
    /// quiet inline row instead — the trend arrow and the 7-day pip strip
    /// stay on Insights, which already exists for exactly this, rather
    /// than duplicating them here too.
    private var statStrip: some View {
        HStack(spacing: 20) {
            statItem(wordsToday.formatted(), "words today")
            if let wpm = wpmToday {
                stripDivider
                statItem("\(wpm)", "wpm")
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.manrope(17, .medium))
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundStyle(Palette.warmInk)
            Text(label)
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkSoft)
        }
    }

    private var stripDivider: some View {
        Rectangle().fill(Palette.warmDivider).frame(width: 1, height: 14)
    }

    // MARK: History
    //
    // No card of its own anymore — by request, this now lives directly on
    // the glass panel instead of a separate white surface floating inside
    // it. `warmRowBorder`'s near-white hairline read fine against solid
    // white but all but disappeared against the frosted, gradient-tinted
    // material, so row dividers switched to `glassDivider` (a translucent
    // black that keeps working regardless of exactly what's blurred behind
    // it); the faintest ink/dot tones moved one step darker for the same
    // reason.

    /// Fills whatever height the hero and stat strip leave behind.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyHeader
            ThinScrollView(bottomInset: 12) {
                historyRows
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Stays fixed above the scrolling list.
    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Each day group below carries its own label ("Today",
                // "July 12, 2026", …) — a static label here would either
                // repeat the first one or, worse, go stale exactly like
                // the old fixed "Today" did once the list scrolled past
                // it. "Results" is the one case worth stating up front,
                // since a search match isn't otherwise obvious from the
                // day grouping alone.
                if searchOpen && !searchText.isEmpty {
                    Text("RESULTS")
                        .font(.manrope(10, .semibold))
                        .kerning(0.9)
                        .foregroundStyle(Palette.warmInkSoft)
                }
                Spacer()
                if showClearConfirm {
                    Text("Clear all \(app.entries.count) transcript\(app.entries.count == 1 ? "" : "s")? This can't be undone.")
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                    Button("Cancel") { showClearConfirm = false }
                        .buttonStyle(GhostButtonStyle())
                    Button("Clear History") {
                        app.clearHistoryEntries()
                        showClearConfirm = false
                    }
                    .buttonStyle(DangerButtonStyle())
                } else {
                    if searchOpen {
                        HStack(spacing: 8) {
                            ChirpIconView(icon: .search)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(Palette.warmInkFaint)
                            TextField("Search transcripts", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.manrope(12.5))
                                .foregroundStyle(Palette.warmInk)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                        .frame(width: 200)
                    }
                    IconButton(icon: searchOpen ? .plus : .search,
                               rotated: searchOpen,
                               help: searchOpen ? "Close search" : "Search transcripts") {
                        searchOpen.toggle()
                        if !searchOpen { searchText = "" }
                    }
                    IconButton(icon: .trash, help: "Clear all history") {
                        showClearConfirm = true
                    }
                }
            }
            .padding(.bottom, 14)

            if let feedback = learnFeedback {
                HStack(spacing: 6) {
                    ChirpIconView(icon: .check).frame(width: 12, height: 12)
                    Text(feedback).font(.manrope(12, .medium))
                }
                .foregroundStyle(Palette.sunsetDeep)
                .padding(.bottom, 10)
                .task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    learnFeedback = nil
                }
            }
        }
    }

    /// The only part of Home that scrolls. Grouped by calendar day — the
    /// fixed header above can only ever say one static thing, which is
    /// what let a flat, ungrouped list read as if everything in it were
    /// from today even once older days scrolled into view. Each row now
    /// carries a small leading dot and its own hairline top rule (matching
    /// the mockup) instead of the old per-day bordered/filled card — the
    /// dot is only lit (sunset orange) on the single newest entry across
    /// the whole list, not once per day.
    ///
    /// Flattened into one `ForEach` (day labels and entries as siblings)
    /// rather than a `ForEach` of day-groups each containing its own
    /// nested `ForEach` of rows — `LazyVStack` only lazily instantiates
    /// its own *direct* children, so the nested version made it treat an
    /// entire day (however many transcripts that turned out to be) as one
    /// unsplittable unit of work instead of one row at a time.
    private var historyRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.entries.isEmpty {
                emptyState(
                    "No transcripts yet — click into any text field, hold \(app.hotkey.displayName), and speak.")
            } else if filteredEntries.isEmpty {
                emptyState("No transcripts match “\(searchText)”.")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(flatHistoryRows.enumerated()), id: \.element.id) { index, row in
                        switch row {
                        case .day(let date):
                            daySectionLabel(date, isFirst: index == 0)
                        case .entry(let entry):
                            HistoryRowView(
                                entry: entry,
                                isNewest: entry.id == newestEntryID,
                                openMenuEntryID: $openMenuEntryID,
                                onCopy: {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(entry.text, forType: .string)
                                },
                                onCorrect: {
                                    editText = entry.text
                                    editingEntry = entry
                                })
                        }
                    }
                }
            }
        }
    }

    private func daySectionLabel(_ day: Date, isFirst: Bool) -> some View {
        Text(dayLabel(day).uppercased())
            .font(.manrope(10, .semibold))
            .kerning(0.9)
            .foregroundStyle(Palette.warmInkSoft)
            .padding(.top, isFirst ? 0 : 14)
            .padding(.bottom, 6)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.manrope(12.5))
            .italic()
            .foregroundStyle(Palette.warmInkFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func correctionSheet(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct this transcript").font(.manrope(15, .semibold))
            Text("Fix what Chirp misheard. It compares your fix with the "
                 + "original and learns the corrections for future dictations.")
                .font(.manrope(12))
                .foregroundStyle(Palette.inkSoft)
            TextEditor(text: $editText)
                .font(.manrope(13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(width: 460, height: 140)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.md))
            HStack {
                Spacer()
                Button("Cancel") { editingEntry = nil }
                Button("Save & Learn") {
                    let learnedCount = app.correctHistoryEntry(id: entry.id, newText: editText)
                    learnFeedback = learnedCount > 0
                        ? "Learned \(learnedCount) correction\(learnedCount == 1 ? "" : "s") from your fix."
                        : "Transcript updated."
                    editingEntry = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: Derived data

    private var filteredEntries: [HistoryEntry] {
        HistoryStore.matching(searchText, in: app.entries)
    }

    /// `filteredEntries` grouped by calendar day, most recent day first.
    /// `app.entries` (and so `filteredEntries`) is already newest-first —
    /// appending each day the first time it's seen preserves that order
    /// for the groups too, with no separate sort needed.
    private var groupedEntries: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [HistoryEntry]] = [:]
        for entry in filteredEntries {
            let day = calendar.startOfDay(for: entry.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { (day: $0, entries: byDay[$0] ?? []) }
    }

    /// The id of the single most recent entry across every group — what
    /// `HistoryRowView` uses to decide which one row (not one per day) gets
    /// the accent treatment.
    private var newestEntryID: String? {
        groupedEntries.first?.entries.first?.id
    }

    /// `groupedEntries` flattened into one list of day-labels and entries
    /// as equal siblings, so `historyRows`' `ForEach` can hand `LazyVStack`
    /// one row at a time instead of one whole day at a time.
    private var flatHistoryRows: [HistoryListRow] {
        groupedEntries.flatMap { group in
            [.day(group.day)] + group.entries.map { .entry($0) }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    private func words(on day: Date) -> Int {
        let calendar = Calendar.current
        return app.entries
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
            .reduce(0) { $0 + $1.wordCount }
    }

    private var wordsToday: Int { words(on: Date()) }

    /// Words per minute across today's timed dictations only. The trend
    /// vs. yesterday and the 7-day pip strip that used to sit alongside
    /// these numbers stay on Insights, which already exists for exactly
    /// this — Home's stat strip is a teaser, not a second copy of it.
    private var wpmToday: Int? {
        let calendar = Calendar.current
        let timed = app.entries.filter {
            calendar.isDateInToday($0.date) && ($0.duration ?? 0) > 1
        }
        let seconds = timed.reduce(0.0) { $0 + ($1.duration ?? 0) }
        guard seconds > 0 else { return nil }
        let words = timed.reduce(0) { $0 + $1.wordCount }
        return Int(Double(words) / (seconds / 60))
    }


}

/// One flattened item of `historyRows`' single `ForEach` — a day-section
/// label or a transcript, as equal siblings (see `flatHistoryRows`).
private enum HistoryListRow: Identifiable {
    case day(Date)
    case entry(HistoryEntry)

    var id: String {
        switch self {
        case .day(let date): return "day-\(date.timeIntervalSince1970)"
        case .entry(let entry): return entry.id
        }
    }
}

// MARK: - History row

/// Its own `View` rather than a method on `HomePage` returning `some View`,
/// specifically so `hovering` is local `@State` scoped to one row instead
/// of a single `String?` shared on `HomePage` for every row to compare
/// itself against. With the shared version, scrolling the list under a
/// stationary cursor fires an enter/exit on every row that passes under
/// it, and each one reassigned `HomePage`'s own state — which invalidated
/// `HomePage.body` and re-evaluated every row in the list on every single
/// one of those events, not just the row whose own hover actually changed.
/// A real `View` type gives SwiftUI a stable identity to diff against, so
/// a hover change here only ever re-renders this one row.
private struct HistoryRowView: View {
    let entry: HistoryEntry
    let isNewest: Bool
    @Binding var openMenuEntryID: HistoryEntry.ID?
    let onCopy: () -> Void
    let onCorrect: () -> Void

    @State private var hovering = false

    /// Shared across rows (`openMenuEntryID` lives on `HomePage`) so
    /// opening a second row's menu can't leave two open at once.
    private var isMenuOpen: Bool { openMenuEntryID == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.glassDivider).frame(height: 1)
            HStack(alignment: .top, spacing: 13) {
                // No leading dot — just the time, top-aligned with the
                // entry text so both start at the same line regardless of
                // whether the text wraps to a second line.
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.manrope(12, .semibold))
                    .foregroundStyle(isNewest ? Palette.sunsetDeep : Palette.warmInkSoft)
                    // `font-variant-numeric: tabular-nums`. Verified Manrope
                    // ships Monospaced Numbers, so this stays in Manrope
                    // rather than falling back to a substitute face.
                    .monospacedDigit()
                    .lineLimit(1)
                    // 40pt fit a 24-hour clock ("13:37") but wrapped a
                    // 12-hour one ("1:37 AM") mid-word into "1:37 a" / "m"
                    // — wide enough for the longest realistic case
                    // ("12:37 PM"), plus `.lineLimit(1)` as a hard
                    // backstop so a still-too-narrow width clips instead
                    // of wrapping.
                    .frame(width: 58, alignment: .leading)
                Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.manrope(13))
                    .lineSpacing(4)
                    .foregroundStyle(isNewest ? Palette.warmInk : Palette.warmInkSoft)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Actions stay laid out and only fade, so hovering a row
                // never reflows its text. Copy and Correct & learn are the
                // two used on almost every row, so they stay a single
                // click away; Turn into a note and Delete move behind one
                // overflow trigger, which also leaves room to append a
                // future action without adding another permanent icon.
                HStack(spacing: 6) {
                    IconButton(icon: .copy, help: "Copy", action: onCopy)
                    IconButton(icon: .edit, help: "Correct & learn", action: onCorrect)
                    IconButton(icon: .moreVertical, help: "More") {
                        openMenuEntryID = isMenuOpen ? nil : entry.id
                    }
                }
                .opacity((hovering || isMenuOpen) ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: hovering)
                // Reports this HStack's own bounds up to `HomePage`'s
                // `overlayPreferenceValue(RowMenuAnchorKey.self)` whenever
                // this row's menu is open, rather than drawing the menu
                // here directly — see that overlay's own comment for why a
                // same-row overlay isn't good enough inside a `LazyVStack`.
                .anchorPreference(key: RowMenuAnchorKey.self, value: .bounds) {
                    isMenuOpen ? $0 : nil
                }
            }
            // No leading inset — the dot that used to want a little room
            // from the edge is gone, so the time column now sits flush
            // with the day-section label above it.
            .padding(.trailing, 6)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(hovering ? Palette.cardHover : Color.clear))
            // Without an explicit hit-testable shape, SwiftUI only counts
            // actually-drawn content (the text glyphs) as hoverable when the
            // background is .clear — the padding and inter-column gaps read as
            // "not part of the view" for hover purposes until the background
            // is already filled, so entering the row anywhere but directly on
            // the text failed to reveal the actions. This makes the whole
            // padded frame one hoverable region regardless of what's drawn.
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }
}

/// Reports the open row's action-icons bounds up to `HomePage`, which
/// resolves it against its own `GeometryReader` to place `RowActionsMenu`
/// outside the scrolling list entirely. `reduce` just keeps whichever
/// candidate is non-nil — `openMenuEntryID` already guarantees at most one
/// row ever reports itself open at a time.
private struct RowMenuAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The history row's overflow menu. Positioned by `HomePage`'s
/// `overlayPreferenceValue` (see `RowMenuAnchorKey`) — this view itself
/// knows nothing about where it ends up. Styled after the nav bar HUD's
/// own popovers (`NavPopover`/`NavPopoverRow` in NavBarHUD.swift) — not a
/// system `.popover` (generic native chrome, not the app's own design) —
/// re-themed onto Home's white/warm palette, but flat rather than
/// elevated: no shadow, matching this app's own standing rule that a
/// glass-panel-page card never gets one (`HistoryRowView`'s own hover
/// background is the same plain fill, no shadow, right next to this).
/// A later action just becomes another `MenuRow` above the divider.
private struct RowActionsMenu: View {
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: .trash, label: "Delete", tint: Palette.danger, action: onDelete)
        }
        .padding(6)
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.warmRowBorder, lineWidth: 1))
        .environment(\.colorScheme, .light)
        .onExitCommand(perform: onDismiss)
        .transition(.opacity.combined(with: .scale(0.96, anchor: .topTrailing)))
    }
}

private struct MenuRow: View {
    let icon: ChirpIcon
    let label: String
    var tint: Color = Palette.warmInk
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ChirpIconView(icon: icon).frame(width: 13, height: 13)
                Text(label).font(.manrope(12.5, .semibold)).lineLimit(1)
                Spacer(minLength: 8)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? Palette.warmRowBorder : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Hero waveform

/// Home hero's own waveform — 13 bars, heights mirrored around the
/// centre, now graded in a single accent-blue hue (faint at the edges, full
/// `Palette.accent` at the peak) rather than the old muted-black-to-sunset
/// gradient, which was tuned for a light orange card and would have been
/// nearly invisible against the flat dark `Palette.panel` background
/// `captureZone` uses now. `.fixedSize()` pins this to its own intrinsic
/// 13-bar width regardless of how much room the parent `HStack` offers —
/// belt-and-suspenders against the reported bug of this stretching wide
/// across the card; nothing in the layout here should do that on its own
/// (no `Spacer()`, no `maxWidth: .infinity`), but nothing prevented it
/// either.
private struct HeroCaptureWaveform: View {
    var active: Bool = true

    @State private var tall = false

    private static let bars: [(height: CGFloat, opacity: Double, delay: Double)] = [
        (16, 0.18, 0),
        (32, 0.30, 0.06),
        (48, 0.42, 0.12),
        (64, 0.58, 0.18),
        (45, 0.34, 0.24),
        (80, 0.78, 0.30),
        (100, 1.0, 0.36),
        (80, 0.78, 0.30),
        (45, 0.34, 0.24),
        (64, 0.58, 0.18),
        (48, 0.42, 0.12),
        (32, 0.30, 0.06),
        (16, 0.18, 0),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(Palette.accent.opacity(bar.opacity))
                    .frame(width: 6, height: bar.height)
                    .scaleEffect(y: tall ? 1 : 0.55, anchor: .center)
                    .animation(
                        tall
                            ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(bar.delay)
                            : .easeOut(duration: 0.3),
                        value: tall)
            }
        }
        .frame(height: 108)
        .fixedSize()
        .onAppear { tall = active }
        .onChange(of: active) { _, isActive in tall = isActive }
    }
}

// MARK: - Button styles

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(Palette.accentText)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.sm))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Palette.danger, in: RoundedRectangle(cornerRadius: Radius.sm))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
