import SwiftUI

extension Page {
    /// True for pages that fill the pane and scroll internally, rather
    /// than being a document inside the shell's own ScrollView.
    var managesOwnScrolling: Bool {
        self == .home || self == .notetaker || self == .dictionary
            || self == .snippets
            || self == .settings || self == .help || self == .legal
    }

    var chirpIcon: ChirpIcon {
        switch self {
        case .home: return .home
        case .notetaker: return .notetaker
        case .dictionary: return .dict
        case .snippets: return .snip
        case .settings: return .settings
        case .help: return .help
        case .legal: return .lock
        }
    }
}

// MARK: - Rail

/// The collapsible nav: icon-only at rest (72pt), full icon+label while
/// pinned or peeking (192pt). Peeking floats over content without
/// reflowing it — pinning actually reserves the width. One flat list, no
/// groups or accordions: every page is one row, always visible, always one
/// click away whether the rail is open or closed.
struct RailView: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @Binding var pinned: Bool
    @Binding var peeking: Bool

    /// Everything above the footer, in order. Settings/Help/Legal sit in
    /// their own bottom cluster (`footerPages`) rather than here.
    private static let mainPages: [Page] = [.home, .notetaker, .dictionary, .snippets]
    private static let footerPages: [Page] = [.settings, .help, .legal]

    static let collapsedWidth: CGFloat = 60
    // Main.dc.html's nav column is a fixed `width: 192px` — this predates
    // the "Main" redesign (was 236, from the old design system) and was
    // missed when everything else in the rail was re-measured against the
    // mockup, leaving the expanded rail visibly wider than intended.
    static let expandedWidth: CGFloat = 168

    private var expanded: Bool { pinned || peeking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.mainPages, id: \.self) { railRow($0) }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Self.footerPages, id: \.self) { railRow($0) }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Unboxed per the "Main" redesign: transparent, not its own fill —
        // `appBody` paints one `homeGradient` behind the rail *and* the
        // pane together, so the rail reads as sitting directly on the same
        // continuous backdrop rather than a separately-colored strip.
    }

    // MARK: Top

    private var top: some View {
        HStack(spacing: 9) {
            HStack(spacing: 10) {
                ChirpLogoBadge(app: app)
                if expanded {
                    Text("Chirp")
                        .font(.chirpDisplay(18, .regular))
                        .foregroundStyle(Palette.warmInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
    }

    // MARK: Rows

    /// The old flat sidebar had a permanent "N permissions needed → Fix
    /// now" card — a big element that doesn't fit a 72pt collapsed rail.
    /// A dot on Settings preserves the same proactive, always-visible
    /// (not just once you happen to expand the rail) nudge instead.
    private var needsPermissions: Bool { !app.micAuthorized || !app.axTrusted }

    private func railRow(_ item: Page) -> some View {
        RailRow(
            item: item, selected: page == item, expanded: expanded,
            needsPermissions: item == .settings && needsPermissions,
            missingCount: [app.micAuthorized, app.axTrusted].filter { !$0 }.count
        ) { page = item }
    }
}

/// The sidebar's own brand mark — the wren itself, isolated (the same
/// sprite frames the floating pet and onboarding use), not the full app
/// icon. The icon lockup (cream rounded-square field + "CHIRP" wordmark)
/// was tried here first and didn't work at this size: the wordmark is
/// illegible at 40pt and the icon's own background box read as a
/// redundant border sitting inside the sidebar's own chrome. No
/// background/shadow of its own — it sits directly on the sidebar,
/// consistent with the pet's own "just the character, no backing plate"
/// look elsewhere.
private struct ChirpLogoBadge: View {
    @ObservedObject var app: AppDelegate

    @State private var state = "idle"

    private let songTimer = Timer.publish(every: 11, on: .main, in: .common).autoconnect()

    /// Not a static mark — the same bird, reacting to the same states the
    /// floating pet does. With the pet turned off this is the only wren
    /// on screen, so it's the only thing that shows a dictation is live
    /// while the window is open.
    ///
    /// It also sings to itself now and then while idle. Same reasoning as
    /// Home's wren: `chirp` is the most characterful sprite in the set
    /// and was otherwise nearly unreachable. On a slow random interval
    /// rather than a loop — this sits in the corner of every page, so a
    /// bird chirping continuously here would be genuinely irritating.
    var body: some View {
        AnimatedWrenView(state: state, size: 32)
            .onChange(of: app.uiState) { _, newValue in state = base(for: newValue) }
            .onReceive(songTimer) { _ in
                guard app.uiState == .idle, state == "idle", Bool.random() else { return }
                state = "chirp"
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if app.uiState == .idle { state = "idle" }
                }
            }
            .onAppear { state = base(for: app.uiState) }
    }

    private func base(for uiState: AppDelegate.UIState) -> String {
        switch uiState {
        case .idle: return "idle"
        case .recording: return "listening"
        case .processing: return "processing"
        }
    }
}


// MARK: - App shell
//
// `.proto-frame` + `.titlebar` + `.app-body`: the whole window is one
// rounded panel; the titlebar spans its full width, and the rail sits
// below it alongside the content — not overlapping it.

struct AppShellRoot: View {
    @ObservedObject var app: AppDelegate
    @State private var page: Page = .home
    @State private var pinned = Settings.railPinned
    @State private var peeking = false
    @State private var peekCloseWork: DispatchWorkItem?
    /// Drives `.pane-swap`: a 150ms fade + 3pt rise whenever the page changes.
    @State private var paneSwapping = false

    // Every 2s was polling two system permission checks 30 times a
    // minute for the entire time the window is open, to catch a change
    // the user can only make by leaving the app, walking through System
    // Settings and coming back. 5s still feels instant on return and
    // cuts the polling by 60%.
    private let permissionTimer = Timer.publish(
        every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        // No simulated frame here. The mockup's `.proto-frame` — rounded
        // corners, border, drop shadow, and the gray backdrop around it —
        // exists only because a web page has to *draw* a fake app window.
        // In the real app the macOS window IS that frame, so drawing our
        // own inside it produces a visible window-within-a-window.
        VStack(spacing: 0) {
            titlebar
            Rectangle().fill(Palette.border).frame(height: 1)
            errorBanner
            appBody
        }
        .animation(.chirpEase(0.2), value: app.lastError)
        .background(Palette.panel)
        .ignoresSafeArea()
        .onReceive(permissionTimer) { _ in app.refreshPermissions() }
        .onChange(of: pinned) { _, newValue in Settings.railPinned = newValue }
        // Outside triggers — the App Profile discovery notification, and
        // the nav bar HUD's quick-action popovers — jump the shown page
        // directly, unlike `pendingTemplateText`, which a page that's
        // already visible picks up itself.
        .onChange(of: app.pendingNavigateToPage) { _, newValue in
            guard let newValue else { return }
            page = newValue
            app.pendingNavigateToPage = nil
        }
        // `.sheet(item:)` clears `app.availableUpdate` back to nil on its
        // own however the sheet closes (a button's own `dismiss()`,
        // Escape, clicking outside) — none of the three actions need to
        // touch it themselves.
        .sheet(item: $app.availableUpdate) { update in
            SoftwareUpdateSheet(update: update)
        }
    }

    /// `.titlebar` — 44px tall, shell-colored, hairline bottom border,
    /// spanning the full window width above both rail and content.
    private var titlebar: some View {
        HStack(spacing: 7) {
            // Space for the real macOS traffic lights.
            Color.clear.frame(width: 62, height: 1)
            // Used to also show a StatusPill here — removed as a duplicate
            // of Home's capture zone, which now shows the same
            // Ready/Listening/Working status at far more prominent scale.
            // The floating StatusHUD still covers dictation into other
            // apps regardless of which page is showing.
            //
            // Drives the same `pinned` state the rail itself reads — this
            // is now the one control for it (the rail's own in-line caret
            // button was removed as redundant once this shipped). No
            // tooltip: a sidebar-toggle glyph next to the traffic lights
            // is a standard enough macOS convention (Mail, Notes, Xcode)
            // not to need one.
            IconButton(icon: .sidebar) {
                withAnimation(.chirpEase()) { pinned.toggle() }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        // Fixed, a shade darker than `homeGradient`'s own leading stop —
        // not `Palette.shell`'s neutral gray, which read as a disconnected
        // bar sitting on top of the sage-tinted body instead of a related
        // surface; matching the gradient's stop exactly, in turn, read as
        // *too* related — no visible seam between the titlebar and the
        // body at all.
        .background(Palette.paper)
    }

    /// Errors used to render as small red text in the titlebar, aligned
    /// right, competing with nothing and read by nobody — several of them
    /// (no audio captured, Accessibility inactive) are the difference
    /// between "Chirp is broken" and "one switch is off", so they have to
    /// be impossible to miss. Full width, tinted, with its own dismiss.
    @ViewBuilder
    private var errorBanner: some View {
        if let error = app.lastError, !error.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ChirpIconView(icon: .help)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Palette.danger)
                    .padding(.top, 1)
                Text(error)
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.danger)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                IconButton(icon: .close, size: 20, iconSize: 10, tint: Palette.danger) {
                    app.lastError = nil
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Palette.danger.opacity(0.09))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.danger.opacity(0.25)).frame(height: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var appBody: some View {
        HStack(spacing: 0) {
            // The slot reserves layout width; the rail itself overlays it
            // so a hover-peek floats above the content without reflowing.
            Color.clear
                .frame(width: pinned ? RailView.expandedWidth : RailView.collapsedWidth)
            pane
        }
        // One gradient instance spanning the rail *and* the pane, not two
        // separately-scaled copies (rail used to paint its own). A
        // `LinearGradient`'s start/end points are resolved as fractions of
        // whatever view draws it — painted once here and left transparent
        // in the rail, the sage-to-cream backdrop is continuous behind
        // both; painted twice, the same gradient stretches over two
        // different-width boxes and comes out at two different angles,
        // showing up as a visible seam right at the rail's edge.
        .background(Palette.paper)
        .overlay(alignment: .topLeading) {
            RailView(app: app, page: pageBinding, pinned: $pinned, peeking: $peeking)
                .frame(width: (pinned || peeking) ? RailView.expandedWidth : RailView.collapsedWidth)
                .shadow(color: .black.opacity(peeking && !pinned ? 0.26 : 0),
                        radius: peeking && !pinned ? 16 : 0, x: 7)
                .animation(.chirpEase(0.22), value: pinned || peeking)
                .onHover { inside in
                    guard !pinned else { return }
                    peekCloseWork?.cancel()
                    if inside {
                        peeking = true
                    } else {
                        let work = DispatchWorkItem { peeking = false }
                        peekCloseWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
                    }
                }
        }
    }

    /// `.pane` — 32px top / 36px sides / 40px bottom, with the swap
    /// transition applied on every page change. Pages on the "Main"
    /// redesign's `GlassPanelPage` shell are the exception: their own
    /// canvas paints edge-to-edge (the sage-to-cream backdrop behind the
    /// glass panel), so they supply their own matching padding internally
    /// instead of taking the generic inset here. Extend this list as more
    /// pages adopt `GlassPanelPage`.
    private static let glassPanelPages: Set<Page> = [
        .home, .notetaker, .dictionary,
        .snippets, .settings, .help, .legal,
    ]

    private var pane: some View {
        Group {
            if page.managesOwnScrolling {
                Group {
                    if Self.glassPanelPages.contains(page) {
                        pageContent
                    } else {
                        pageContent
                            .padding(.horizontal, 36)
                            .padding(.top, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    pageContent
                        .padding(.horizontal, 36)
                        .padding(.top, 32)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(paneSwapping ? 0 : 1)
        .offset(y: paneSwapping ? 3 : 0)
    }

    /// Navigating fades the pane out, swaps, and fades back in — the
    /// mockup's `.pane-swap`, which the app was missing entirely.
    private var pageBinding: Binding<Page> {
        Binding(get: { page }, set: { select($0) })
    }

    private func select(_ newPage: Page) {
        guard newPage != page else { return }
        withAnimation(.chirpEase(0.15)) { paneSwapping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            page = newPage
            withAnimation(.chirpEase(0.15)) { paneSwapping = false }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .home: HomePage(app: app)
        case .notetaker: NotetakerPage(app: app)
        case .dictionary: DictionaryPage(page: pageBinding)
        case .snippets: SnippetsPage(page: pageBinding)
        case .settings: SettingsPage(app: app)
        case .help: HelpPage(app: app, page: pageBinding)
        case .legal: LegalPage()
        }
    }
}


/// `.rail-item` — 34pt tall, 17pt icon, 12pt gap, with the hover wash and
/// press-scale the design specifies (the app had neither).
private struct RailRow: View {
    let item: Page
    let selected: Bool
    let expanded: Bool
    let needsPermissions: Bool
    let missingCount: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    // ChirpIconView's stroke width is a fixed fraction of
                    // its rendered size (`nativeStrokeWidth * scale` in
                    // ChirpIcons.swift), not a constant point value — so
                    // sizing the icon up here is what thickens its stroke
                    // too, in the same move, rather than a separate lever.
                    ChirpIconView(icon: item.chirpIcon)
                        .frame(width: 16, height: 16)
                    if needsPermissions {
                        Circle()
                            .fill(Palette.danger)
                            .frame(width: 6, height: 6)
                            .offset(x: 5, y: -4)
                    }
                }
                if expanded {
                    // `.semibold`, not `.medium` — legible on its own, but
                    // specifically needed a bit more visual weight to not
                    // read as "faint" sitting right next to the icon's own
                    // bold stroke and, before this pass, right next to the
                    // stark black active pill.
                    Text(item.label)
                        .font(.manrope(13.5, .medium))
                        .lineLimit(1)
                    if needsPermissions {
                        Text("\(missingCount)")
                            .font(.manrope(10, .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Palette.danger, in: Circle())
                    }
                }
                Spacer(minLength: 0)
            }
            // Selected: a soft sage wash + sage text, not `navActivePill`'s
            // solid near-black block — that reads fine as a floating HUD
            // pill (still used there, and in Notetaker's own buttons) but
            // was a jarring, dated-looking slab of contrast against this
            // page's much lighter surrounding palette.
            //
            // `sunsetDeep`/`sunsetPale` here, not the dynamic `accentText`/
            // `accentSoft` — the rail sits on the always-light, fixed
            // `homeGradient` with no `.light` colorScheme pin (nothing
            // else on it needs one; see `warmInk`'s own note in
            // DesignTokens.swift for why a dynamic token here breaks in
            // dark mode specifically). Same reasoning for the hover fill:
            // `Color.black.opacity(...)` instead of the dynamic
            // `cardHover`, just with a stronger, more visible opacity than
            // the original hack had.
            // Selected is now ink + a warm wash, not cobalt-on-pale-blue.
            // A blue pill was the loudest thing on the screen while
            // being the thing you look at least — the rail's job is to
            // say where you are, quietly, and then get out of the way.
            .foregroundStyle(selected ? Palette.warmInk : Palette.warmInkSoft)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(selected ? Color.black.opacity(0.055)
                          : (hovering ? Color.black.opacity(0.03) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.chirpEase(0.13), value: hovering)
        .help(expanded ? "" : item.label)
    }
}
