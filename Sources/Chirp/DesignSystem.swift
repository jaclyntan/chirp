import SwiftUI

// MARK: - Page shell

/// The shared page container every full-bleed page uses.
///
/// Formerly a frosted-glass panel: `.ultraThinMaterial`, a white
/// stroke, two drop shadows, inset from the window edge so it floated
/// over a separately-painted backdrop. Stacked inside a window that also
/// had its own titlebar band, that produced three visibly different
/// surfaces before any actual content — and every page then put white
/// cards on top of *that*, so a single list row sat four layers deep.
///
/// Now it's just margins. Content sits directly on the window's own
/// paper ground, and depth is spent only where something genuinely is a
/// separate object. Structure comes from whitespace and hairlines
/// instead, which is what lets the type do the work.
///
/// Pinned to `.light` colorScheme — the app pins `NSApp.appearance` to
/// aqua anyway; this keeps any subview reading a dynamic color in the
/// same place. A page with its own `.sheet`/`.popover` should attach it
/// at the call site rather than inside `content`, so presented content
/// keeps following the system appearance normally.
struct GlassPanelPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, .light)
    }
}

// MARK: - Surfaces

extension View {
    /// The app's one card treatment: a near-white warm fill, a single
    /// hairline, no shadow.
    ///
    /// Every page used to paint its own `Color.white` rounded rectangle
    /// at whatever radius it happened to pick (5, 12, 16, 18, 20 all
    /// appeared), so "a surface" looked like five different things
    /// depending which page you were on, and pure white against the
    /// warm paper ground read as a cold patch cut out of it. One
    /// modifier, one radius, one slightly-warm white — and a hairline
    /// doing the separating that shadows and stark contrast used to.
    func chirpSurface(_ radius: CGFloat = Radius.lg) -> some View {
        self
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.warmDivider, lineWidth: 1))
    }
}

/// `.icon-btn` — 26×26, transparent at rest, `--card-hover` fill and
/// `--ink` icon on hover, 0.9 scale while pressed. The hover fill and the
/// press-scale are what make it read as a real control.
struct IconButton: View {
    let icon: ChirpIcon
    var size: CGFloat = 26
    var iconSize: CGFloat = 14
    var rotated: Bool = false
    var tint: Color? = nil
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChirpIconView(icon: icon)
                .frame(width: iconSize, height: iconSize)
                .rotationEffect(.degrees(rotated ? 45 : 0))
                .foregroundStyle(tint ?? (hovering ? Palette.ink : Palette.inkSoft))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Palette.cardHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .chirpTooltip(help ?? "")
    }
}

/// Shared press feedback: the mockup scales controls down on `:active`
/// (0.9 for icon buttons, 0.96–0.98 for larger ones) rather than only
/// changing color, so a click feels physical.
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.chirpEase(0.09), value: configuration.isPressed)
    }
}

// MARK: - Field select

/// `.field-select` — a real dropdown (unlike `.field-control`, which the
/// mockup only ever uses for two rows it never bothered wiring up as
/// interactive). Every row in Settings needs an actual working picker.
///
/// This is a plain `Button` + `.popover`, not `Menu` — `Menu` combined with
/// `.menuStyle(.borderlessButton)` silently drops the label's custom
/// background/border on this build (confirmed against a freshly-built
/// binary, not a stale one), collapsing to a bare system caret with no
/// chrome at all. A hand-rolled button is exactly how every other control
/// in this file already works, so it renders precisely what's specified
/// instead of fighting Menu's own system styling.
struct FieldSelect<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    /// Defaults match the normal light/dark `Palette` trigger; overridable
    /// for the one place this sits on a surface that's a fixed color
    /// regardless of the app's own appearance (Home's capture zone), where
    /// the theme-reactive defaults would go dark-on-dark in dark mode.
    var tint: Color = Palette.inkSoft
    var background: Color = Palette.panel
    var borderColor: Color = Palette.border
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 6) {
                Text(label(selection))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.manrope(12, .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FieldSelectList(options: options, label: label, selection: $selection, isOpen: $isOpen)
        }
    }
}

private struct FieldSelectList<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @Binding var isOpen: Bool
    @State private var hovered: T?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                    isOpen = false
                } label: {
                    Text(label(option))
                        .font(.manrope(12, .medium))
                        .foregroundStyle(option == selection ? Palette.ink : Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(hovered == option ? Palette.cardHover : Color.clear)
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? option : nil }
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 160)
        // Without an explicit fill here, this had no background at all —
        // AppKit's own `.popover` falls through to its default vibrant
        // material rather than anything `Palette`-driven, which could
        // land dark while `Palette.ink` text (resolved for the app's
        // actual light/dark mode, not whatever the popover material
        // happened to pick) stayed near-black — unreadable, effectively
        // black-on-black. An explicit, opaque, `Palette`-driven fill
        // makes this WYSIWYG with the rest of the app regardless of what
        // the system default would otherwise render.
        .background(Palette.panel)
    }
}

// MARK: - Pulsing dot

/// The app's one "this is live" signal — a filled dot with a ring that
/// expands and fades around it, on loop. Used for recording, in the
/// floating `StatusHUDView` and Home's capture zone; both used to
/// implement their own plain opacity-fade independently, which also read
/// as a weaker, less immediate cue than the ring — a ring says "actively
/// broadcasting," a dimming dot just says "something changed."
///
/// `maxScale` is a parameter rather than a fixed constant because the two
/// call sites have very different padding around the dot before the ring
/// would visibly collide with the pill/HUD's own edge.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    var maxScale: CGFloat = 2.4
    var active: Bool = true

    @State private var expanded = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .scaleEffect(expanded ? maxScale : 1)
                    .opacity(expanded ? 0 : 0.55)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { startPulse() }
        .onChange(of: active) { _, _ in startPulse() }
    }

    private func startPulse() {
        expanded = false
        guard active else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
            expanded = true
        }
    }
}

// MARK: - Keycap & shortcut row

/// `.keycap` — a small monospaced key label, e.g. "⌥1".
///
/// `tint`/`background`/`borderColor` default to the normal light/dark
/// `Palette` tokens, but are overridable — needed for the one place this
/// sits on a surface that's a fixed color regardless of the app's own
/// appearance (Home's capture zone), where the theme-reactive defaults
/// would go dark-on-dark in dark mode.
struct Keycap: View {
    let text: String
    var tint: Color = Palette.ink
    var background: Color = Palette.panel
    var borderColor: Color = Palette.border

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
    }
}

// MARK: - Thin scroll view

/// A scroll view with no visible scroll indicator.
///
/// macOS's own scroller is thick, sits flush against the content edge, and
/// collided with row dividers here — hidden entirely rather than replaced
/// with a thinner one. Scrolling itself (trackpad, scroll wheel) still
/// works exactly as normal; only the indicator is gone.
///
/// `.scrollIndicators(.hidden)` alone doesn't reliably suppress the native
/// `NSScroller` on macOS — confirmed empirically, it still rendered with
/// only that modifier in place — so `ScrollbarHider` reaches into the
/// underlying `NSScrollView` directly as a second, load-bearing layer.
struct ThinScrollView<Content: View>: View {
    var bottomInset: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { outer in
            ScrollView(.vertical) {
                content
                    .padding(.bottom, bottomInset)
                    .background(ScrollbarHider().frame(width: 0, height: 0))
            }
            .scrollIndicators(.hidden)
            .environment(\.tooltipClipBounds, outer.frame(in: .global))
        }
    }
}

/// Zero-size helper that walks up to `enclosingScrollView` once inserted
/// into the hierarchy and turns its scrollers off directly at the AppKit
/// level, bypassing whatever SwiftUI-level quirk leaves `.scrollIndicators`
/// unrespected.
///
/// `scrollerStyle` is forced to `.overlay` *before* disabling the scrollers:
/// under System Settings' "Show scroll bars: Always", `NSScrollView`
/// defaults to `.legacy` style, which reserves a fixed gutter for the
/// vertical scroller's width even once `hasVerticalScroller` is set to
/// false — this showed up as page content sitting a consistent ~15pt
/// short of the glass panel's right edge on a system with that setting.
/// Overlay-style scrollers float over content instead of reserving layout
/// space, so this closes the gap regardless of the user's system
/// preference or of any timing race with the async disable below.
private struct ScrollbarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Tooltip

private struct TooltipClipBoundsKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    /// Global-space bounds of the nearest scrolling container, so a tooltip
    /// can tell whether it has room to open upward before it gets clipped.
    var tooltipClipBounds: CGRect? {
        get { self[TooltipClipBoundsKey.self] }
        set { self[TooltipClipBoundsKey.self] = newValue }
    }
}

/// A small styled tooltip, replacing macOS's default `.help()` bubble.
///
/// The system tooltip uses the OS font at its own size and placement, so on
/// the hover-revealed row actions it appeared as an unstyled grey slab
/// offset away from the icon it described. This one uses the app's own type
/// and surface tokens and sits centered directly above the control.
struct ChirpTooltip: ViewModifier {
    let text: String
    var edge: VerticalEdge = .top

    @Environment(\.tooltipClipBounds) private var clipBounds
    @State private var hovering = false
    @State private var visible = false
    @State private var revealTask: Task<Void, Never>?
    @State private var controlFrame: CGRect = .zero

    /// Opening upward needs ~30pt of headroom. Inside a scroll view the
    /// first visible row has none — the container clips it — so the
    /// tooltip flips below rather than rendering half cut off.
    private var resolvedEdge: VerticalEdge {
        guard edge == .top else { return edge }
        guard let clipBounds, controlFrame != .zero else { return .top }
        return (controlFrame.minY - clipBounds.minY) < 30 ? .bottom : .top
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    // Reads the control's current global frame only at the
                    // moment hover starts, rather than continuously tracking
                    // it via `.onChange` — that used to fire on every scroll
                    // frame for every icon on screen (each one's global Y
                    // shifts as its row scrolls), turning a list of hidden,
                    // rarely-shown tooltips into a steady stream of @State
                    // writes and made scrolling visibly laggy. A tooltip
                    // only needs to know where it is right before it opens
                    // (already gated 320ms behind `revealTask` below), not
                    // on every frame in between.
                    Color.clear
                        .onHover { inside in
                            hovering = inside
                            revealTask?.cancel()
                            if inside {
                                controlFrame = geo.frame(in: .global)
                                revealTask = Task {
                                    try? await Task.sleep(nanoseconds: 320_000_000)
                                    if !Task.isCancelled, hovering {
                                        withAnimation(.chirpEase(0.12)) { visible = true }
                                    }
                                }
                            } else {
                                visible = false
                            }
                        }
                })
            .overlay(alignment: resolvedEdge == .top ? .top : .bottom) {
                if visible, !text.isEmpty {
                    Text(text)
                        .font(.manrope(11, .medium))
                        .foregroundStyle(Palette.onInk)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                        .offset(y: resolvedEdge == .top ? -26 : 26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .accessibilityLabel(text)
    }
}

extension View {
    /// Styled hover tooltip. Pass an empty string to show none.
    func chirpTooltip(_ text: String, edge: VerticalEdge = .top) -> some View {
        modifier(ChirpTooltip(text: text, edge: edge))
    }
}



