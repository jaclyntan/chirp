import AppKit
import SwiftUI

/// Layout facts the controller works out from real screen geometry and
/// the SwiftUI content needs in order to draw itself correctly.
///
/// The panel gets clamped so a bubble near a screen edge stays fully on
/// screen, which means the bird is no longer at the panel's centre — so
/// the bubble's tail has to be told how far to shift to keep pointing at
/// it, and near the top of the screen the bubble has to move below the
/// bird entirely. Only the controller knows any of that (it owns the
/// `NSPanel` and the `NSScreen` maths), so it publishes it here.
@MainActor
final class PetLayout: ObservableObject {
    /// Horizontal distance from the panel's centre to the wren, after
    /// clamping. Zero whenever the bird is centred as usual.
    @Published var tailOffset: CGFloat = 0
    /// Bubble sits below the bird rather than above it — set when there
    /// isn't room above without running off the top of the screen.
    @Published var bubbleBelow = false
}

/// A small, always-on-top, draggable floating wren — click its face to
/// bring Chirp's main window forward, hover to reveal a small pill for
/// dictating or reaching Settings without needing the hotkey. Exists
/// specifically as a replacement for hovering near the bottom of the
/// screen to reveal a nav-bar HUD, which collided with the Dock (see
/// `HUDDock.origin`'s own note on why that happened) — this lives
/// wherever *you* put it, so it can't end up sitting in the Dock's own
/// reveal strip by construction. `NavBarHUDController`, the thing this
/// replaces, is gone; `StatusHUDController` (the in-flight "Listening…"
/// pill shown only *during* a dictation) is untouched — this is purely
/// the idle-state launcher.

@MainActor
final class PetPanelController {
    private var panel: NSPanel?
    private var currentSize = PetPanelController.idleSize
    private let layout = PetLayout()

    /// Two tiers, same idea `NavBarHUDController` used to grow through
    /// on hover — width never changes (SwiftUI content stays centered
    /// within it), only height, so the only origin math a resize needs
    /// is sliding the bottom edge down/up to keep the wren's own position
    /// visually fixed while the pill grows in beneath it.
    static let idleSize = NSSize(width: 160, height: 90)
    static let hoverSize = NSSize(width: 160, height: 140)
    /// The bubble layout is the only one this wide, which is also what
    /// tells `wrenInset` a given size is a bubble at all.
    static let bubbleWidth: CGFloat = 320

    /// The panel needed to show a bubble `bubbleHeight` tall above the
    /// wren. Height is dynamic — the bubble hugs its own text — so this
    /// is a function rather than the fixed constant it used to be: a
    /// one-line transcript in a 300pt box was mostly empty space with the
    /// buttons stranded at the bottom.
    static func bubbleSize(bubbleHeight: CGFloat) -> NSSize {
        NSSize(width: bubbleWidth,
               height: bubbleHeight + PetView.bubbleGap + hoverSize.height)
    }

    /// How far the wren's own top edge sits below the panel's top edge.
    /// In the idle/hover layouts — and with the bubble flipped below —
    /// the wren is the first thing in the stack, so it's just the top
    /// padding; with a bubble above it, everything the bubble occupies
    /// pushes it down.
    ///
    /// `resize(to:)` uses this to hold the wren still on screen while the
    /// window grows and shrinks around it.
    static func wrenInset(for size: NSSize, below: Bool = false) -> CGFloat {
        // With the bubble below the bird (or no bubble at all) the wren is
        // the first thing in the stack, so the inset is just the top
        // padding. With it above, everything the bubble occupies pushes
        // the bird down — and since `bubbleSize` builds the panel as
        // bubble + gap + the standard wren/pill block, that distance falls
        // straight back out of the panel's own height.
        guard size.width == bubbleWidth, !below else { return 10 }
        return size.height - hoverSize.height + 10
    }

    func setActive(_ active: Bool, app: AppDelegate) {
        guard Settings.petEnabled else {
            panel?.orderOut(nil)
            return
        }
        if active {
            let panel = existingOrNewPanel(app: app)
            clampIntoView(panel)
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    /// Called whenever `Settings.petEnabled` changes live from Settings,
    /// rather than only being read once at launch.
    func refreshEnabled(app: AppDelegate) {
        setActive(true, app: app)
    }

    private func existingOrNewPanel(app: AppDelegate) -> NSPanel {
        if let panel { return panel }

        // `FirstMouseHostingView`, not plain `NSHostingView` — without
        // its `acceptsFirstMouse` override, a click on any control in
        // here (the mic button in particular) can land as a no-op
        // "wake this window" instead of actually triggering, specifically
        // when a *different* Chirp window (e.g. Settings) currently holds
        // key-window status. `.nonactivatingPanel` on the panel below
        // means this panel itself never *becomes* key from a click, so
        // this same problem would otherwise show up on every single
        // click, not just while another window is key.
        let hosting = FirstMouseHostingView(rootView: PetView(
            app: app,
            layout: layout,
            onDragEnded: { [weak self] origin in self?.persistPosition(origin) },
            onSizeChange: { [weak self] size in self?.resize(to: size) },
            onWander: { [weak self] willMove, completion in
                self?.wander(willMove: willMove, completion: completion)
                    ?? completion()
            }))
        hosting.frame = NSRect(
            origin: .zero, size: Self.bubbleSize(bubbleHeight: PetView.maxBubbleHeight))

        // `.nonactivatingPanel` — clicking it must not steal focus/bring
        // every other Chirp window forward the way a normal window
        // would; each control inside `PetView` explicitly calls into
        // `app` only on a real click.
        let newPanel = NSPanel(
            contentRect: NSRect(origin: Self.initialOrigin(), size: Self.idleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        // No window-level shadow, and the sprite draws none of its own
        // either — the sprite's art already carries a 1px outline for
        // legibility (see Resources/Pet/README.md); the pill/menu below
        // it, being ordinary UI chrome rather than "the pet," keep their
        // own small shadows.
        newPanel.hasShadow = false
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isMovableByWindowBackground = false
        newPanel.contentView = hosting
        panel = newPanel
        currentSize = Self.idleSize
        return newPanel
    }

    /// Grows/shrinks the panel to `newSize` while holding the *wren*
    /// still on screen.
    ///
    /// Everything else in this panel hangs off the bird, so the bird is
    /// what must not move: the pill unfolds beneath it, the transcript
    /// bubble opens above it. Anchoring the window's own top edge (what
    /// this did when the pill was the only thing that grew) breaks the
    /// moment something needs to grow *upward* — the bird would slide
    /// down the screen by the full height of the bubble.
    ///
    /// So both axes are solved from the wren's own position rather than
    /// the window's: its top edge (panel top, minus `wrenInset`, in
    /// AppKit's bottom-up coordinates) and its horizontal center, since
    /// the SwiftUI content keeps the sprite centered and the bubble
    /// layout is wider than the idle one.
    private func resize(to newSize: NSSize) {
        guard let panel else { return }
        let oldInset = Self.wrenInset(for: currentSize, below: layout.bubbleBelow)
        var frame = panel.frame
        // The two fixed points: the wren's own top edge and its centre.
        let wrenTop = frame.maxY - oldInset
        let wrenCenterX = frame.midX
        let visible = currentScreenVisibleFrame(for: frame.origin)

        // Flip the bubble under the bird when there isn't room above it.
        // A bubble that runs off the top of the screen is worse than one
        // on the "wrong" side — the tail still points at the bird either
        // way, so below reads fine; clipped text does not.
        var below = false
        if newSize.width == Self.bubbleWidth, let visible {
            let bubbleHeight = newSize.height - Self.hoverSize.height - PetView.bubbleGap
            below = wrenTop + bubbleHeight + PetView.bubbleGap > visible.maxY
        }
        layout.bubbleBelow = below

        let newInset = Self.wrenInset(for: newSize, below: below)
        frame.size = newSize
        frame.origin.y = wrenTop - newSize.height + newInset
        frame.origin.x = wrenCenterX - newSize.width / 2

        // Clamp fully on screen. The bubble is twice the idle width, so
        // a bird sitting near either edge would otherwise have half its
        // transcript hanging off the display.
        if let visible {
            let margin: CGFloat = 8
            let minX = visible.minX + margin
            let maxX = visible.maxX - newSize.width - margin
            if maxX > minX { frame.origin.x = min(max(frame.origin.x, minX), maxX) }
            let minY = visible.minY + margin
            let maxY = visible.maxY - newSize.height - margin
            if maxY > minY { frame.origin.y = min(max(frame.origin.y, minY), maxY) }
        }

        // Whatever the clamp moved, the tail makes up for, so the bubble
        // still visibly belongs to the bird rather than floating near it.
        layout.tailOffset = wrenCenterX - frame.midX
        currentSize = newSize

        // `setFrame(_:display:animate:)`'s own "animate: true" plays at
        // AppKit's default duration/curve, not `PetView`'s own
        // `withAnimation(.chirpEase(0.16))` — the pill's opacity/move
        // transition and the window's own resize were animating side by
        // side at two different paces, which is exactly what reads as
        // janky/desynced rather than one continuous motion. Matching
        // both the duration and the timing curve here (same
        // cubic-bezier(0.4, 0, 0.2, 1) `chirpEase` uses) via
        // `NSAnimationContext` instead keeps the window edge and the
        // content sliding out from under it moving in lockstep.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// A remembered drag position (persisted per-launch) if there is one;
    /// otherwise bottom-right of whichever screen currently has the
    /// mouse, with enough margin to clear the Dock even if it's not
    /// auto-hidden — same screen-selection approach `HUDDock.origin`
    /// already uses, so this lands on the display you're actually on.
    private static func initialOrigin(ignoringStored: Bool = false) -> NSPoint {
        if !ignoringStored, let stored = Settings.petPosition { return stored }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return NSPoint(x: 40, y: 40) }
        return NSPoint(
            x: frame.maxX - idleSize.width - 24,
            y: frame.minY + 24)
    }

    /// Stores a position in *idle-layout* terms, whatever size the panel
    /// happens to be right now.
    ///
    /// The stored value is fed straight back to a fresh panel's
    /// `contentRect` at `idleSize` on next launch, so persisting a raw
    /// origin taken while the panel was bubble-sized (twice as wide, and
    /// offset upward to make room above the bird) would reopen the pet
    /// visibly displaced from where it was left. Normalising here — by
    /// converting through the one thing that stays put, the wren itself —
    /// keeps "where the bird is" the meaning of the saved value.
    private func persistPosition(_ origin: NSPoint) {
        guard let panel else {
            Settings.petPosition = origin
            return
        }
        var frame = panel.frame
        frame.origin = origin
        let wrenTop = frame.maxY - Self.wrenInset(for: currentSize, below: layout.bubbleBelow)
        Settings.petPosition = NSPoint(
            x: frame.midX - Self.idleSize.width / 2,
            y: wrenTop - Self.idleSize.height + Self.wrenInset(for: Self.idleSize, below: false))
    }

    /// The visible frame of whichever screen the pet is standing on,
    /// matched on its own midpoint rather than its origin so a pet
    /// straddling two displays resolves to the one it's mostly on.
    private func currentScreenVisibleFrame(for origin: NSPoint) -> NSRect? {
        let mid = NSPoint(x: origin.x + Self.idleSize.width / 2, y: origin.y)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// Pulls the pet back into view if its remembered position is no
    /// longer on any screen — an external display unplugged, a
    /// resolution change, or the Dock/menu bar changing the visible
    /// frame out from under it. Without this the pet is simply invisible
    /// and unreachable after any of those, with no way to get it back
    /// short of resetting the stored position by hand.
    private func clampIntoView(_ panel: NSPanel) {
        let frame = panel.frame
        let onAnyScreen = NSScreen.screens.contains {
            $0.visibleFrame.intersects(frame)
        }
        guard !onAnyScreen else { return }
        let origin = Self.initialOrigin(ignoringStored: true)
        panel.setFrameOrigin(origin)
        persistPosition(origin)
    }

    /// Picks a random point along the same horizontal line the pet is
    /// already standing on, within the visible frame of whichever screen
    /// it's currently on (so it never wanders over the Dock, the menu
    /// bar, or off onto a different display), and glides there.
    ///
    /// Deliberately a *short* trip — `maxStep` — rather than anywhere on
    /// the screen, which is what this did first and which read wrong in
    /// two separate ways: a bird that crosses a 5K display in one go
    /// looks like it's being dragged rather than pottering, and a pet
    /// that can reappear anywhere is much more likely to end up over
    /// whatever you're actually working on. Short local steps keep it
    /// roughly where you left it while still visibly alive.
    ///
    /// Uses `NSAnimationContext` + the window's `.animator()` proxy rather
    /// than a hand-rolled per-frame `setFrameOrigin` loop — a manual loop
    /// is exactly what made dragging jittery and translucency-flickery
    /// before (see the drag-handle notes below); the animator proxy hands
    /// this same kind of continuous window move over to the same native,
    /// compositor-synced path `performDrag` uses for dragging.
    ///
    /// `willMove` fires once, before the move starts, with how the bird
    /// should travel (see `PetTravel`) and whether it's heading left, so
    /// the caller can pick the right sprite and mirror it to face the way
    /// it's actually going. `completion` fires once it has arrived (or
    /// immediately, with no movement, if wandering is off, the pet is
    /// pinned, or there's no room to move).
    func wander(
        willMove: (PetTravel, Bool) -> Void, completion: @escaping () -> Void
    ) {
        guard Settings.petWanders, !Settings.petPinned, let panel else {
            completion()
            return
        }
        let current = panel.frame.origin
        guard let visible = currentScreenVisibleFrame(for: current),
              let target = randomNearbyPoint(from: current, within: visible)
        else {
            completion()
            return
        }

        let dx = target.x - current.x
        let dy = target.y - current.y
        // Anything with real vertical travel is a flight; a move along
        // (or nearly along) the ground is a walk. Fairy-wrens hop rather
        // than stride and don't walk up into the air, so the threshold is
        // deliberately low — a small vertical component still means the
        // bird left the ground, and `walk` played while rising looks like
        // the sprite is moonwalking upward.
        let travel: PetTravel = abs(dy) > 40 ? .flying : .walking
        willMove(travel, dx < 0)

        let distance = (dx * dx + dy * dy).squareRoot()
        switch travel {
        case .walking:
            // Roughly constant walking speed regardless of distance,
            // clamped so a short hop doesn't look instantaneous and a
            // long trip doesn't take forever.
            let duration = max(0.6, min(2.4, Double(distance) / 90))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(
                    NSRect(origin: target, size: panel.frame.size), display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.persistPosition(target)
                    completion()
                }
            })
        case .flying:
            flyAlongArc(panel: panel, from: current, to: target, distance: distance) {
                [weak self] in
                self?.persistPosition(target)
                completion()
            }
        }
    }

    /// A point a short hop away in *both* axes, inside the screen's
    /// visible frame.
    ///
    /// The step cap keeps it local: far enough to be visibly a trip
    /// rather than a twitch, short enough that the bird stays roughly
    /// where you left it and doesn't reappear across the display on top
    /// of whatever you're working on. Ranges are clamped into the screen
    /// rather than rejected, so near an edge the bird simply turns around
    /// into the room that's actually there.
    ///
    /// Vertical travel is capped tighter than horizontal — the usable
    /// height of a screen is smaller than its width, and a bird that
    /// ranges as far vertically as horizontally spends most of its time
    /// stranded in the middle of the desktop rather than around the edges
    /// where it belongs.
    private func randomNearbyPoint(from current: NSPoint, within visible: NSRect) -> NSPoint? {
        let margin: CGFloat = 24
        let minX = visible.minX + margin
        let maxX = visible.maxX - Self.idleSize.width - margin
        let minY = visible.minY + margin
        let maxY = visible.maxY - Self.idleSize.height - margin
        guard maxX > minX, maxY > minY else { return nil }

        let x = axisTarget(current: current.x, low: minX, high: maxX, maxStep: 280, minStep: 70)
        let y = axisTarget(current: current.y, low: minY, high: maxY, maxStep: 170, minStep: 0)
        guard let x else { return nil }
        return NSPoint(x: x, y: y ?? current.y)
    }

    /// One axis of `randomNearbyPoint`. `minStep` excludes a dead zone
    /// around the current value so a "move" is always visible; passing 0
    /// allows staying put on that axis, which is what makes a plain
    /// horizontal walk still possible rather than every trip becoming a
    /// flight.
    private func axisTarget(
        current: CGFloat, low: CGFloat, high: CGFloat, maxStep: CGFloat, minStep: CGFloat
    ) -> CGFloat? {
        let lower = max(low, current - maxStep)
        let upper = min(high, current + maxStep)
        guard lower < upper else { return nil }
        guard minStep > 0 else { return .random(in: lower...upper) }
        let ranges = [
            lower...max(lower, min(upper, current - minStep)),
            max(lower, min(upper, current + minStep))...upper,
        ].filter { $0.lowerBound < $0.upperBound }
        guard let range = ranges.randomElement() else { return nil }
        return .random(in: range)
    }

    /// Flies the panel from `start` to `end` along a shallow upward arc.
    ///
    /// A window's frame can only be animated in a straight line — the
    /// `.animator()` proxy interpolates linearly between two rects — and
    /// a bird crossing the desktop on a perfectly straight diagonal reads
    /// as a dragged icon, not something with wings. So the path is cut
    /// into short segments along a parabola and each one is handed to the
    /// same native animator, chained on completion.
    ///
    /// This is *not* the hand-rolled per-frame `setFrameOrigin` loop the
    /// drag-handle notes below warn about: each segment is still a real
    /// animation on the compositor-synced path, there are ~16 of them
    /// rather than one per frame, and every segment uses linear timing so
    /// the joins are seamless (ease-in-out per segment would visibly
    /// stutter at each boundary). Easing lives on the arc itself instead:
    /// the bird rises fastest at take-off and settles as it lands, which
    /// is what `sin` over half a period gives for free.
    private func flyAlongArc(
        panel: NSPanel, from start: NSPoint, to end: NSPoint, distance: CGFloat,
        completion: @escaping () -> Void
    ) {
        let segments = 16
        let total = max(0.7, min(2.0, Double(distance) / 260))
        // Peak lift, scaled to the trip: a short flit barely arcs, a long
        // one swoops. Capped so it can't sail off the top of the screen.
        let lift = min(90, distance * 0.32)

        func point(at t: CGFloat) -> NSPoint {
            NSPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t + lift * sin(.pi * t))
        }

        func step(_ index: Int) {
            guard index < segments else {
                // Land exactly on the target — accumulated interpolation
                // can leave the last segment a fraction short.
                panel.setFrameOrigin(end)
                completion()
                return
            }
            let t = CGFloat(index + 1) / CGFloat(segments)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = total / Double(segments)
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                panel.animator().setFrame(
                    NSRect(origin: point(at: t), size: panel.frame.size), display: true)
            }, completionHandler: {
                // `runAnimationGroup`'s completion handler always actually
                // fires on the main thread in practice (it's how every
                // AppKit animation callback works), but its type is a plain
                // `() -> Void` with no `@MainActor` annotation of its own, so
                // the compiler can't statically verify that and flags the
                // main-actor-isolated calls below as a possible race without
                // this. `assumeIsolated` documents the real guarantee instead
                // of silently hopping onto an async `Task` for what is,
                // actually, already synchronous main-thread work.
                MainActor.assumeIsolated { step(index + 1) }
            })
        }
        step(0)
    }
}

/// A rounded rectangle with a small triangular tail centered on its
/// bottom edge, pointing down at the wren beneath it.
///
/// A `Shape` rather than a rectangle with a triangle overlaid on top,
/// because the fill and the 1px stroke both have to follow the tail's
/// outline — two separate views would draw a seam straight across the
/// base of the tail where the rectangle's own border still runs.
struct SpeechBubble: Shape {
    /// Horizontal shift of the tail from the bubble's centre, so it keeps
    /// pointing at the bird after the panel has been clamped on screen.
    var tailOffset: CGFloat = 0
    /// Tail on the top edge (bubble sits below the bird) rather than the
    /// bottom edge (bubble above, the usual case).
    var tailOnTop = false
    var cornerRadius: CGFloat = 14
    var tailWidth: CGFloat = 16
    static let defaultTailHeight: CGFloat = 9
    var tailHeight: CGFloat = SpeechBubble.defaultTailHeight

    func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.minX,
            y: tailOnTop ? rect.minY + tailHeight : rect.minY,
            width: rect.width,
            height: max(0, rect.height - tailHeight))
        var path = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)

        // Kept far enough from the corners that the tail always meets a
        // straight run of edge — sliding it into the rounded corner
        // detaches it from the outline and it reads as a stray triangle.
        let inset = cornerRadius + tailWidth
        let tipX = min(max(body.midX + tailOffset, body.minX + inset), body.maxX - inset)
        let edgeY = tailOnTop ? body.minY : body.maxY
        let tipY = tailOnTop ? body.minY - tailHeight : body.maxY + tailHeight
        path.move(to: CGPoint(x: tipX - tailWidth / 2, y: edgeY))
        path.addLine(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: CGPoint(x: tipX + tailWidth / 2, y: edgeY))
        path.closeSubpath()
        return path
    }
}

/// How the pet gets from one spot to another — which decides both the
/// sprite played and the shape of the path (see `flyAlongArc`).
enum PetTravel {
    case walking
    case flying
}

/// Plain `NSHostingView` except for `acceptsFirstMouse`, which AppKit
/// otherwise defaults to `false` for any view in a non-key window — the
/// first click on a button in here would just bring the window to
/// attention instead of actually activating the button it landed on.
/// Harmless to return `true` unconditionally: this content has no title
/// bar chrome or anything else where "was this click meant to focus the
/// window" is a real question, so always treating it as a real click is
/// exactly what every control here should do.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Pet view

private struct PetView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var layout: PetLayout
    let onDragEnded: (NSPoint) -> Void
    let onSizeChange: (NSSize) -> Void
    /// Requests a self-relocation from `PetPanelController`, which owns
    /// the actual `NSPanel` and screen-bounds math (see its own `wander`
    /// doc comment). Called with a `willMove` callback (fired once,
    /// before the move starts, with how it's travelling and whether it's
    /// heading left, so the sprite can be chosen and mirrored to face the
    /// way it's going) and a `completion` callback (fired once it
    /// arrives).
    let onWander: (@escaping (PetTravel, Bool) -> Void, @escaping () -> Void) -> Void

    @StateObject private var animator = PetAnimator()
    @State private var hovering = false
    @State private var facingLeft = false
    @State private var isWandering = false
    /// What the pill capsule actually morphs between — a thin resting
    /// line to the full pill, the same two-state shape-animation
    /// `NavBarHUDController` (this pet's own predecessor) used, restored
    /// here by request after the plain fade/slide-in this had instead
    /// read as clunkier. See `expandPill()`/`collapsePill()`.
    @State private var pillShapeSize = Self.restingPillSize
    @State private var pillIconsVisible = false
    @State private var pillCollapseTask: Task<Void, Never>?
    /// Mirrors `Settings.petPinned` so the pill's own icon can react
    /// immediately — `Settings` is plain `UserDefaults`, with nothing
    /// SwiftUI observes to redraw from.
    @State private var pinned = Settings.petPinned
    /// The transcript shown in the bubble above the wren, or `nil` when
    /// there's no bubble. Set when a dictation finishes; cleared by the
    /// close button, by the next dictation starting, or by `bubbleTask`.
    @State private var bubbleText: String?
    /// The history entry the bubble is showing, so its Discard button can
    /// delete the right one.
    @State private var bubbleEntryID: String?
    @State private var bubbleCopied = false
    @State private var bubbleDismissTask: Task<Void, Never>?
    @State private var chirpTask: Task<Void, Never>?
    /// Measured from the transcript when the bubble opens, so the panel
    /// can be sized before SwiftUI lays anything out.
    @State private var bubbleHeight = PetView.minBubbleHeight
    /// True when the transcript is too tall to fit — drives both the
    /// scrolling and the "Read more" affordance.
    @State private var bubbleOverflows = false
    @State private var editingBubble = false
    @State private var bubbleDraft = ""
    /// Only a dictation the user started from the pill's own mic button
    /// opens a bubble. A hotkey dictation goes straight into whatever
    /// they had focused — they're already looking at the result, and a
    /// bubble would just cover it.
    @State private var startedFromPill = false
    /// The bubble is showing an error rather than a transcript. Errors
    /// always surface here regardless of how the dictation was started —
    /// a failure you can't see is the one case where staying out of the
    /// way is wrong.
    @State private var bubbleIsError = false
    /// The bubble is streaming the recording in flight rather than
    /// showing a finished transcript — no Copy/Edit/Discard, because
    /// there is nothing saved yet to act on.
    @State private var bubbleIsLive = false
    @State private var hoveringBubble = false

    static let bubbleGap: CGFloat = 8
    /// The bubble hugs its text between these two. Below the minimum a
    /// one-line transcript would leave the buttons floating in space;
    /// above the maximum it would cover the screen, so it scrolls instead
    /// and offers "Read more".
    static let minBubbleHeight: CGFloat = 96
    static let maxBubbleHeight: CGFloat = 260
    /// Everything in the bubble that isn't the transcript: padding top and
    /// bottom, the gap above the button row, the row itself, and the tail.
    static let bubbleChrome: CGFloat = 12 + 10 + 26 + 12 + 9
    /// Text column width: bubble minus horizontal padding and the close
    /// button that sits beside it.
    static let bubbleTextWidth: CGFloat = PetPanelController.bubbleWidth - 24 - 28
    private static let restingPillSize = CGSize(width: 36, height: 5)
    /// Each icon is 28pt wide with a 1pt divider and 2pt gaps between,
    /// inside 6pt padding — so the pill has to be measurably wider on the
    /// four-icon (wandering, therefore pinnable) layout than the three-
    /// icon one, or the extra button overflows its own capsule.
    private var expandedPillSize: CGSize {
        CGSize(width: Settings.petWanders ? 139 : 106, height: 40)
    }

    /// idle/idle_preen/idle_tailflick/hop — cycled between at random
    /// while genuinely idle, per PET_BRIEF.md's own ask. `hop` (a
    /// stays-in-place bounce, the brief's "worth including regardless of
    /// whether autonomous roaming ever gets built" bonus) counts as a
    /// fourth idle flavor rather than a separate, unbuilt "wanders the
    /// screen" behavior.
    private static let idleVariants = ["idle", "idle_preen", "idle_tailflick", "hop"]
    private let idleVarietyTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    /// Checked every 20s but only actually wanders about a third of the
    /// time (`Settings.petWanders` gates the feature entirely on top of
    /// this) — a hard 20s interval reads as mechanical and would be
    /// distracting at that cadence; the random skip spreads real
    /// relocations out to roughly once a minute on average instead,
    /// without needing a genuinely random-interval timer.
    private let wanderTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            if let bubbleText, !layout.bubbleBelow {
                transcriptBubble(bubbleText)
                    .frame(height: bubbleHeight)
                    .padding(.bottom, Self.bubbleGap - 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            wrenSprite
            actionPill
            if let bubbleText, layout.bubbleBelow {
                transcriptBubble(bubbleText)
                    .frame(height: bubbleHeight)
                    .padding(.top, Self.bubbleGap - 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .top)
        .onHover { inside in
            if inside {
                // Growing has nothing to debounce — the panel can resize
                // to fit the full pill the instant a hover starts.
                pillCollapseTask?.cancel()
                pillCollapseTask = nil
                hovering = true
                expandPill()
                reportSize()
                // Real `hover` sprite art now exists (PET_BRIEF.md's ask,
                // delivered) — only while genuinely idle, so this doesn't
                // fight whatever `listening`/`processing`/`walk` is
                // already communicating.
                if app.uiState == .idle, !isWandering {
                    animator.play("hover")
                }
            } else {
                hovering = false
                collapsePill()
                if app.uiState == .idle, !isWandering {
                    animator.play(baseState(for: app.uiState))
                }
                // The real `NSPanel` must not shrink back down until the
                // capsule has actually finished collapsing — shrinking it
                // the instant the cursor leaves would clip the
                // still-animating pill against an already-tiny window
                // (exactly the glitch `NavBarHUDController`, this pet's
                // predecessor, once had to fix the same way). Waiting out
                // the collapse animation first keeps the panel never
                // smaller than what it's currently showing.
                pillCollapseTask?.cancel()
                pillCollapseTask = Task {
                    try? await Task.sleep(nanoseconds: 420_000_000)
                    guard !Task.isCancelled else { return }
                    reportSize()
                }
            }
        }
        .onChange(of: app.uiState) { oldValue, newValue in
            animator.play(baseState(for: newValue))
            // A new dictation starting clears whatever the last one left
            // on screen — the bubble is about the transcript you just
            // made, so keeping a stale one up while speaking again is
            // actively confusing.
            if newValue == .recording {
                dismissBubble()
                // Same rule the finished transcript follows: only a
                // dictation you started from the pill gets a bubble. A
                // hotkey dictation is going straight into the field
                // you're looking at, and a live bubble would sit on top
                // of it.
                if startedFromPill, Settings.livePreviewEnabled { showLiveBubble() }
            }
            // Only a dictation started from the pill's mic button gets a
            // bubble. A hotkey dictation lands in whatever text field the
            // user already had focused — they are looking straight at the
            // result, so a bubble would cover the very thing it's
            // reporting. The flag clears at the end of every cycle so a
            // later hotkey dictation can't inherit it.
            if oldValue == .processing, newValue == .idle {
                if startedFromPill { showBubbleForLatest() }
                startedFromPill = false
            }
        }
        .onReceive(idleVarietyTimer) { _ in
            // `!hovering` too — the deliberate `hover` reaction below
            // shouldn't get interrupted by a random idle variant if this
            // fires mid-hover.
            guard app.uiState == .idle, !isWandering, !hovering else { return }
            let next = Self.idleVariants.randomElement() ?? "idle"
            animator.play(next)
        }
        .onReceive(wanderTimer) { _ in
            // `!pinned` here as well as in the controller's own `wander`
            // guard — without it a pinned pet still visibly plays its
            // walk cycle on the spot before the no-op glide completes.
            guard app.uiState == .idle, !isWandering, !hovering, !pinned,
                  bubbleText == nil,
                  Bool.random() && Bool.random()  // ~1 in 3
            else { return }
            beginWander()
        }
        .onChange(of: app.livePreviewText) { _, newValue in
            guard bubbleIsLive else { return }
            let sized = Self.bubbleHeight(for: newValue.isEmpty ? " " : newValue)
            // Only ever grow while streaming. Re-sizing down on every
            // token — the decoder can briefly shorten its own partial —
            // makes the bubble jitter under the cursor as you speak.
            if sized.height > bubbleHeight {
                bubbleHeight = sized.height
                reportSize()
            }
            bubbleOverflows = sized.overflows
            bubbleText = newValue
        }
        .onChange(of: app.lastError) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            showErrorBubble(newValue)
        }
        .onAppear { animator.play(baseState(for: app.uiState)) }
    }

    /// Grows the capsule from the resting line into the full pill: height
    /// leads, width follows close behind, icons fading in only once the
    /// shape is nearly done widening so they never look stretched — they
    /// just weren't drawn yet. Springs, not a fixed timing curve, per
    /// Apple's own motion guidance for this kind of move/resize:
    /// critically damped (`dampingFraction: 1`, no bounce — a hover
    /// reveal, not a flick with real momentum) and slow enough at this
    /// size to read as growth rather than a snap. Exact values and
    /// staggering carried over from `NavBarHUDController`'s own
    /// `expand()`, which this pet's pill reveal replaces — that one was
    /// tuned the same way for the same reason.
    private func expandPill() {
        withAnimation(.spring(response: 0.28, dampingFraction: 1)) {
            pillShapeSize.height = expandedPillSize.height
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 1).delay(0.12)) {
            pillShapeSize.width = expandedPillSize.width
        }
        withAnimation(.easeOut(duration: 0.22).delay(0.18)) {
            pillIconsVisible = true
        }
    }

    /// Mirrors `expandPill()` in reverse — icons fade out first, then
    /// width, then height — so the collapse reads as the same motion
    /// undoing itself rather than a different animation.
    private func collapsePill() {
        withAnimation(.easeIn(duration: 0.12)) {
            pillIconsVisible = false
        }
        withAnimation(.spring(response: 0.26, dampingFraction: 1)) {
            pillShapeSize.width = Self.restingPillSize.width
        }
        withAnimation(.spring(response: 0.26, dampingFraction: 1).delay(0.1)) {
            pillShapeSize.height = Self.restingPillSize.height
        }
    }

    /// Plays the walk cycle, asks `PetPanelController` to actually glide
    /// the window, and returns to normal idle cycling on arrival. Guarded
    /// by `isWandering` against overlapping with a second wander firing
    /// mid-glide, and left un-guarded against a dictation starting
    /// mid-glide: `app.uiState`'s own `onChange` above already swaps the
    /// sprite to "listening" immediately in that case, which is the
    /// behavior that matters — the window finishing a already-brief
    /// (≤2.4s) glide underneath that is a minor, acceptable rough edge
    /// rather than something worth a full cancellation path for.
    private func beginWander() {
        isWandering = true
        onWander(
            { travel, left in
                facingLeft = left
                // `hover` is the wing-flap the cursor-hover reaction uses;
                // reused here because it's the only sprite with the wings
                // actually out, which is exactly what a bird in the air
                // needs. Walking keeps the ground-travel hop cycle.
                animator.play(travel == .flying ? "hover" : "walk")
            },
            {
                isWandering = false
                animator.play(baseState(for: app.uiState))
            })
    }

    private func baseState(for uiState: AppDelegate.UIState) -> String {
        switch uiState {
        case .idle: return "idle"
        case .recording: return "listening"
        case .processing: return "processing"
        }
    }

    private func reportSize() {
        if bubbleText != nil {
            onSizeChange(PetPanelController.bubbleSize(bubbleHeight: bubbleHeight))
        } else {
            onSizeChange(hovering ? PetPanelController.hoverSize : PetPanelController.idleSize)
        }
    }

    /// How tall the bubble needs to be for this transcript, clamped.
    ///
    /// Measured with TextKit up front rather than by letting SwiftUI lay
    /// out and reporting back: the `NSPanel` has to be sized in AppKit
    /// before its content draws, and a measure-then-resize round trip
    /// shows as the bubble visibly snapping to a new size right after it
    /// appears.
    private static func bubbleHeight(for text: String) -> (height: CGFloat, overflows: Bool) {
        let font = NSFont(name: "Manrope-Regular", size: 12) ?? .systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: bubbleTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]).height
        let wanted = ceil(measured) + bubbleChrome
        return (min(max(wanted, minBubbleHeight), maxBubbleHeight), wanted > maxBubbleHeight)
    }

    // MARK: Transcript bubble

    /// What you just dictated, shown in place above the wren — so a
    /// dictation you started from the pill never requires opening the
    /// main window to read, copy, fix or throw away.
    ///
    /// Drawn as a real speech bubble (rounded card plus a tail pointing
    /// at the bird) rather than a floating panel, because it has to read
    /// as *the wren telling you what it heard*. Without the tail it looks
    /// like an unrelated notification that happens to be nearby.
    private func transcriptBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                if editingBubble {
                    TextEditor(text: $bubbleDraft)
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInk)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if bubbleIsLive, text.isEmpty {
                    HStack(spacing: 8) {
                        PulsingDot(color: Palette.sunsetDeep, size: 6,
                                   maxScale: 2.2, active: true)
                        Text("Listening…")
                            .font(.manrope(12))
                            .foregroundStyle(Palette.warmInkFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ThinScrollView {
                        Text(text)
                            .font(.manrope(12))
                            .foregroundStyle(bubbleIsError ? Palette.danger : Palette.warmInk)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                PetIconButton(icon: .close, active: false, help: "Dismiss") {
                    dismissBubble()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 8) {
                if editingBubble {
                    bubbleButton(icon: .check, label: "Save", tint: Palette.sunsetDeep) {
                        commitBubbleEdit()
                    }
                    bubbleButton(icon: .close, label: "Cancel") {
                        editingBubble = false
                    }
                } else if bubbleIsLive {
                    // Still recording: the only sensible action is to
                    // finish. Copy/Edit/Discard all need a saved
                    // transcript, which doesn't exist yet.
                    bubbleButton(icon: .check, label: "Done", tint: Palette.sunsetDeep) {
                        app.togglePetDictation()
                    }
                } else if bubbleIsError {
                    // Nothing to copy, edit or discard — a failure isn't a
                    // transcript. The one useful action is getting to the
                    // permission switches most of these errors are about.
                    bubbleButton(icon: .settings, label: "Open Settings") {
                        app.showMainWindow()
                        app.pendingNavigateToPage = .settings
                        dismissBubble()
                    }
                } else {
                    bubbleButton(
                        icon: bubbleCopied ? .check : .copy,
                        label: bubbleCopied ? "Copied" : "Copy",
                        tint: bubbleCopied ? Palette.sunsetDeep : nil
                    ) {
                        copyLastDictation()
                        bubbleCopied = true
                    }
                    // Same `correctHistoryEntry` the History list uses, so
                    // a fix made here is learned for next time rather than
                    // just patching this one transcript.
                    bubbleButton(icon: .edit, label: "Edit") {
                        bubbleDraft = text
                        editingBubble = true
                        bubbleDismissTask?.cancel()
                        bubbleDismissTask = nil
                    }
                    // Deletes the saved transcript so a botched dictation
                    // doesn't sit in History — the point being to discard
                    // and say it again. It can't un-type what was already
                    // inserted into whatever app had focus, hence
                    // "Discard" rather than "Undo".
                    bubbleButton(icon: .trash, label: "Discard") {
                        discardBubbleEntry()
                    }
                    // Only when the text genuinely didn't fit: the bubble
                    // scrolls, but scrolling a long transcript in a small
                    // box is miserable, so this hands it to the window
                    // that's actually built for reading.
                    if bubbleOverflows {
                        bubbleButton(icon: .arrowRight, label: "Read more") {
                            app.showMainWindow()
                            dismissBubble()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        // The tail eats into the frame on whichever edge it sits, so the
        // buttons need that much extra clearance or they butt right up
        // against the bubble's edge.
        .padding(.top, layout.bubbleBelow ? 12 + SpeechBubble.defaultTailHeight : 12)
        .padding(.bottom, layout.bubbleBelow ? 12 : 12 + SpeechBubble.defaultTailHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface, in: bubbleShape)
        .overlay(bubbleShape.stroke(
            bubbleIsError ? Palette.danger.opacity(0.55) : Palette.warmDivider,
            lineWidth: bubbleIsError ? 1.5 : 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .onHover { inside in
            hoveringBubble = inside
            // Reading a long transcript shouldn't be interrupted by the
            // auto-dismiss, so the countdown only runs while the cursor
            // is elsewhere and restarts from full whenever it leaves.
            if inside {
                bubbleDismissTask?.cancel()
                bubbleDismissTask = nil
            } else if bubbleText != nil, !editingBubble {
                scheduleBubbleDismiss()
            }
        }
    }

    private func bubbleButton(
        icon: ChirpIcon, label: String, tint: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ChirpIconView(icon: icon)
                    .frame(width: 11, height: 11)
                Text(label)
                    .font(.manrope(11.5, .semibold))
            }
            .foregroundStyle(tint ?? Palette.warmInkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.warmRowBorder, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func commitBubbleEdit() {
        let trimmed = bubbleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = bubbleEntryID, !trimmed.isEmpty {
            app.correctHistoryEntry(id: id, newText: trimmed)
            let sized = Self.bubbleHeight(for: trimmed)
            bubbleHeight = sized.height
            bubbleOverflows = sized.overflows
            bubbleText = trimmed
            reportSize()
        }
        editingBubble = false
        scheduleBubbleDismiss()
    }

    private var bubbleShape: SpeechBubble {
        SpeechBubble(tailOffset: layout.tailOffset, tailOnTop: layout.bubbleBelow)
    }

    /// Surfaces a failure on the pet itself. Before this, a dictation
    /// that failed while you were in another app showed nothing at all:
    /// `lastError` only rendered as small red text in the main window's
    /// titlebar, which is exactly the window you are not looking at when
    /// you dictate. The bird going quietly back to idle read as "nothing
    /// happened", not "that failed".
    private func showErrorBubble(_ message: String) {
        let sized = Self.bubbleHeight(for: message)
        bubbleHeight = sized.height
        bubbleOverflows = sized.overflows
        bubbleIsError = true
        bubbleEntryID = nil
        editingBubble = false
        withAnimation(.chirpEase(0.2)) { bubbleText = message }
        reportSize()
        // Longer than a transcript's: an error you missed is worse than a
        // transcript you missed, and there's nothing to copy from it.
        scheduleBubbleDismiss(after: 20)
    }

    /// Opens an empty bubble the live transcript streams into, so the
    /// words appear as you say them rather than all at once at the end.
    private func showLiveBubble() {
        bubbleIsLive = true
        bubbleIsError = false
        bubbleEntryID = nil
        bubbleCopied = false
        editingBubble = false
        bubbleHeight = Self.minBubbleHeight
        bubbleOverflows = false
        withAnimation(.chirpEase(0.2)) { bubbleText = "" }
        reportSize()
        // No auto-dismiss while live: it ends when the recording does.
        bubbleDismissTask?.cancel()
        bubbleDismissTask = nil
    }

    private func showBubbleForLatest() {
        guard let entry = app.entries.first,
              !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let text = entry.text
        let sized = Self.bubbleHeight(for: text)
        bubbleHeight = sized.height
        bubbleOverflows = sized.overflows
        bubbleEntryID = entry.id
        bubbleCopied = false
        editingBubble = false
        bubbleIsError = false
        bubbleIsLive = false
        withAnimation(.chirpEase(0.2)) { bubbleText = text }
        reportSize()
        // The bird actually chirps as the bubble opens — it's telling you
        // what it heard. This is the `chirp` sprite's only home outside
        // first-run onboarding, where in practice nobody ever saw it
        // twice.
        //
        // Timed rather than using `play`'s own completion: `chirp` is a
        // looping state in the manifest (onboarding's mic test wants it
        // running continuously), so `onFinished` would never fire and the
        // bird would chirp forever. One cycle is ~480ms of frame
        // durations; this lets it run a beat past that, then settles.
        chirpTask?.cancel()
        animator.play("chirp")
        chirpTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            animator.play(baseState(for: app.uiState))
        }
        scheduleBubbleDismiss()
    }

    private func discardBubbleEntry() {
        if let bubbleEntryID { app.deleteHistoryEntry(id: bubbleEntryID) }
        bubbleEntryID = nil
        dismissBubble()
    }

    private func dismissBubble() {
        bubbleDismissTask?.cancel()
        bubbleDismissTask = nil
        guard bubbleText != nil else { return }
        withAnimation(.chirpEase(0.16)) { bubbleText = nil }
        bubbleEntryID = nil
        editingBubble = false
        bubbleIsError = false
        bubbleIsLive = false
        reportSize()
    }

    /// Long enough to read a couple of sentences and reach for Copy,
    /// short enough that an ignored bubble doesn't just become a
    /// permanent box sitting on the desktop. Hovering it cancels this
    /// entirely (see `transcriptBubble`'s own `onHover`).
    private func scheduleBubbleDismiss(after seconds: Double = 12) {
        bubbleDismissTask?.cancel()
        bubbleDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, !hoveringBubble else { return }
            dismissBubble()
        }
    }

    /// No backing plate, no outline, no drop shadow — just the sprite,
    /// floating directly on the desktop. A circular card + stroke was
    /// tried first and read as a hard, sketchy-looking outline once
    /// actually on screen; a shadow was tried next in its place and,
    /// asked plainly, wasn't wanted either — the art's own 1px silhouette
    /// outline (see Resources/Pet/README.md) is already what keeps it
    /// legible against arbitrary desktop backgrounds, without needing
    /// anything this view adds on top.
    private var wrenSprite: some View {
        Group {
            if let frame = animator.currentFrame {
                Image(nsImage: frame)
                    .interpolation(.none) // crisp pixel scaling, no smoothing blur
                    .resizable()
                    .frame(width: 64, height: 64)
            } else {
                Color.clear.frame(width: 64, height: 64)
            }
        }
        // `x` carries both the hover-scale and the facing mirror in one
        // transform — `wren_walk`'s frames are drawn facing right only
        // (per PET_BRIEF.md/Resources/Pet/README.md), so a leftward
        // wander flips them here rather than needing a second art set.
        //
        // The real `hover` sprite (played above, in `onHover`) now
        // carries the "noticed you" read on its own — this is just a
        // modest scale bump on top, not the exaggerated bounce-plus-lift
        // transform that stood in for it before real art existed.
        .scaleEffect(
            x: (facingLeft ? -1 : 1) * (hovering ? 1.06 : 1),
            y: hovering ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hovering)
        .animation(.chirpEase(0.18), value: facingLeft)
        .overlay(
            PetDragHandle(
                onClick: {
                    animator.play("activated") { animator.play(baseState(for: app.uiState)) }
                    app.showMainWindow()
                },
                onDragEnded: onDragEnded))
    }

    /// The quick-actions strip — what `NavBarHUDController` used to show
    /// in a separate, Dock-adjacent hover pill lives here instead, only
    /// while hovering, so the pet reads as just the character the rest
    /// of the time. Three direct actions, no nested "more" menu — that
    /// dropdown only ever held these same two extra items (copy, and a
    /// settings link), so promoting both to their own icons removes a
    /// click for either without losing anything.
    /// One capsule whose own frame animates between the resting line and
    /// the full pill, rather than a differently-shaped view fading/
    /// sliding in — a crossfade always reads as two objects handing off,
    /// no matter how it's tuned; animating one shape's own size is the
    /// same object the whole time, so there's nothing to hand off.
    private var actionPill: some View {
        ZStack {
            Capsule()
                .fill(Palette.warmRowBorder)
                .frame(width: pillShapeSize.width, height: pillShapeSize.height)
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
            pillIcons
                .opacity(pillIconsVisible ? 1 : 0)
                .allowsHitTesting(hovering)
        }
    }

    private var pillIcons: some View {
        HStack(spacing: 2) {
            petIconButton(
                icon: .mic,
                active: app.uiState != .idle,
                help: app.uiState == .idle ? "Start dictating" : "Stop and insert"
            ) {
                if app.uiState == .idle { startedFromPill = true }
                app.togglePetDictation()
            }
            Rectangle().fill(Palette.warmDivider).frame(width: 1, height: 16)
            petIconButton(icon: .copy, active: false, help: "Copy last dictation") {
                copyLastDictation()
            }
            // Only where it can actually do something: with wandering off
            // the pet already stays exactly where it's dragged, so a pin
            // there would be a control that visibly changes nothing.
            if Settings.petWanders {
                Rectangle().fill(Palette.warmDivider).frame(width: 1, height: 16)
                petIconButton(
                    icon: .pin, active: pinned,
                    help: pinned ? "Let it wander again" : "Keep it here"
                ) {
                    pinned.toggle()
                    Settings.petPinned = pinned
                }
            }
            Rectangle().fill(Palette.warmDivider).frame(width: 1, height: 16)
            petIconButton(icon: .settings, active: false, help: "Settings") {
                app.showMainWindow()
                app.pendingNavigateToPage = .settings
            }
        }
        .padding(6)
    }

    private func petIconButton(
        icon: ChirpIcon, active: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        PetIconButton(icon: icon, active: active, help: help, action: action)
    }

    private func copyLastDictation() {
        guard let text = app.entries.first?.text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

}

/// One icon in the pill's own `pillIcons` row. A plain `func` returning
/// a `Button` couldn't hold the per-button `hovering` `@State` this
/// needs, hence a real `View` type — each button tracks its own hover
/// independently, so hovering the mic icon doesn't also highlight
/// Settings next to it.
private struct PetIconButton: View {
    let icon: ChirpIcon
    let active: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChirpIconView(icon: icon)
                .frame(width: 14, height: 14)
                .foregroundStyle(active ? Palette.sunsetDeep : Palette.warmInkSoft)
                .padding(7)
                // Hover uses a neutral highlight (`warmRowBorder`), not
                // the accent-blue `sunsetPale` `active` already uses —
                // sharing that color would read as "this is now
                // recording" on the mic icon when it's really just "the
                // cursor is here."
                .background {
                    if active {
                        Circle().fill(Palette.sunsetSoft)
                    } else if hovering {
                        Circle().fill(Palette.warmRowBorder)
                    }
                }
                // Without this, the button's actual hit target is shaped
                // by wherever the icon glyph itself draws pixels, not the
                // full padded circle behind it — reads as "only the dead
                // center registers a click." This makes the whole visible
                // circle (icon + padding) tappable, matching what it
                // looks like.
                .contentShape(Circle())
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            withAnimation(.chirpEase(0.12)) { hovering = inside }
        }
    }
}

/// Bridges the sprite to AppKit's own window-drag tracking instead of
/// computing window movement from a SwiftUI `DragGesture`'s translation.
/// The earlier approach — calling `window.setFrameOrigin` on every
/// `.onChanged`, computed from the gesture's own translation — visibly
/// jittered and the panel's transparency flickered mid-drag: moving a
/// window's real frame from *inside* a SwiftUI callback each event isn't
/// synced to the window server's own vsync-paced move/compositing path
/// the way native dragging is, so every step showed as a small tear/flash
/// rather than a smooth glide. `NSWindow.performDrag(with:)` hands the
/// entire drag over to that same native path — the one used by e.g. a
/// real title bar — for free, buttery-smooth, correctly-composited
/// movement, no per-frame math of our own at all.
///
/// Also replaces the old `TapGesture().exclusively(before: DragGesture)`
/// click-vs-drag split. `performDrag` blocks until mouse-up and simply
/// doesn't move the window at all if the mouse never left `mouseDown`'s
/// location (a real click has enough hand-tremor to move a pixel or two,
/// but not the several points DragGesture's own translation needed to
/// even start firing before) — comparing the window's frame before and
/// after tells click and drag apart with no separate heuristic needed.
private struct PetDragHandle: NSViewRepresentable {
    let onClick: () -> Void
    let onDragEnded: (NSPoint) -> Void

    func makeNSView(context: Context) -> PetDragHandleView {
        let view = PetDragHandleView()
        view.onClick = onClick
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: PetDragHandleView, context: Context) {
        nsView.onClick = onClick
        nsView.onDragEnded = onDragEnded
    }
}

private final class PetDragHandleView: NSView {
    var onClick: (() -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startOrigin = window.frame.origin
        window.performDrag(with: event)
        if window.frame.origin == startOrigin {
            onClick?()
        } else {
            onDragEnded?(window.frame.origin)
        }
    }
}
