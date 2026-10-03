import AppKit
import Combine
import SwiftUI

/// Mirrors `Resources/Pet/pet_sprites.json`'s shape exactly — see that
/// file (and `Resources/Pet/README.md` at the repo root for the full
/// design-side story) for where it came from. Runtime-only subset: loop
/// flag, which sheet/frames belong to a state, and per-frame timing —
/// nothing a player doesn't need.
private struct PetSpriteManifest: Codable {
    struct State: Codable {
        let loop: Bool
        let frameCount: Int
        let frameDurationsMs: [Int]

        enum CodingKeys: String, CodingKey {
            case loop
            case frameCount = "frame_count"
            case frameDurationsMs = "frame_durations_ms"
        }
    }
    let states: [String: State]
}

/// Loads and caches the wren sprite frames + timing. Numbered PNG
/// sequences (`wren_idle_00.png` …), not the sprite-sheet PNGs also
/// shipped alongside them — both were delivered ("either loading style
/// works" per the asset README), and pre-sliced frames need no runtime
/// cropping math.
enum PetSpriteStore {
    private static let manifest: PetSpriteManifest? = loadManifest()
    private static var frameCache: [String: [NSImage]] = [:]
    private static var rasterCache: [ObjectIdentifier: CGImage] = [:]

    /// Packaged `.app`: Pet assets live under `Contents/Resources/Pet` —
    /// `Bundle.main` resolves that. SwiftPM's `Bundle.module` accessor
    /// instead expects a `Chirp_Chirp.bundle` at the app's top level,
    /// which trips codesign's resource sealing, so the shipped app
    /// doesn't use it — same reasoning, same fallback order,
    /// `FontLoader.registerManrope()` already established for Fonts.
    private static func resourceURL(_ name: String, ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Pet")
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Pet")
    }

    private static func loadManifest() -> PetSpriteManifest? {
        guard let url = resourceURL("pet_sprites", ext: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(PetSpriteManifest.self, from: data)
    }

    static func frames(for state: String) -> [NSImage] {
        if let cached = frameCache[state] { return cached }
        guard let count = manifest?.states[state]?.frameCount else { return [] }
        var images: [NSImage] = []
        for index in 0..<count {
            let name = "wren_\(state)_\(String(format: "%02d", index))"
            if let url = resourceURL(name, ext: "png"), let image = NSImage(contentsOf: url) {
                images.append(image)
            }
        }
        frameCache[state] = images
        return images
    }

    /// Convert each sprite once; the layer can reuse its bitmap directly.
    static func raster(for image: NSImage) -> CGImage? {
        let key = ObjectIdentifier(image)
        if let cached = rasterCache[key] { return cached }
        guard let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        rasterCache[key] = raster
        return raster
    }

    /// Seconds, not milliseconds — converted once here so call sites
    /// never juggle the unit.
    static func frameDurations(for state: String) -> [TimeInterval] {
        (manifest?.states[state]?.frameDurationsMs ?? []).map { TimeInterval($0) / 1000 }
    }

    static func loops(_ state: String) -> Bool {
        manifest?.states[state]?.loop ?? true
    }
}

/// Drives one sprite animation at a time: shows a frame, waits that
/// frame's own specific duration (these aren't fixed-FPS loops — a
/// tail-flick holds for 600ms either side of a 70ms snap), advances,
/// repeats or stops. `play(_:onFinished:)` on a non-looping state (just
/// `activated`) calls back once the last frame's hold ends, so a caller
/// can hand off to whatever should play next rather than freezing on
/// the final frame.
@MainActor
final class PetAnimator: ObservableObject {
    @Published private(set) var currentFrame: NSImage?

    private(set) var paused = true
    private var state = ""
    private var frameIndex = 0
    private var finished = false
    private var pendingAdvance: DispatchWorkItem?
    private var onFinished: (() -> Void)?

    func play(_ newState: String, onFinished: (() -> Void)? = nil) {
        guard newState != state || !PetSpriteStore.loops(newState) else { return }
        pendingAdvance?.cancel()
        state = newState
        frameIndex = 0
        finished = false
        self.onFinished = onFinished
        showCurrentFrame()
        scheduleAdvance()
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        pendingAdvance?.cancel()
        pendingAdvance = nil
        if !paused { scheduleAdvance() }
    }

    private func showCurrentFrame() {
        let frames = PetSpriteStore.frames(for: state)
        guard frames.indices.contains(frameIndex) else { return }
        currentFrame = frames[frameIndex]
    }

    private func scheduleAdvance() {
        guard !paused, !finished else { return }
        let durations = PetSpriteStore.frameDurations(for: state)
        guard durations.indices.contains(frameIndex) else { return }
        let item = DispatchWorkItem { [weak self] in self?.advance() }
        pendingAdvance = item
        DispatchQueue.main.asyncAfter(deadline: .now() + durations[frameIndex], execute: item)
    }

    private func advance() {
        let frameCount = PetSpriteStore.frames(for: state).count
        frameIndex += 1
        if frameIndex >= frameCount {
            guard PetSpriteStore.loops(state) else {
                frameIndex = max(0, frameCount - 1)
                finished = true
                let completion = onFinished
                onFinished = nil
                completion?()
                return
            }
            frameIndex = 0
        }
        showCurrentFrame()
        scheduleAdvance()
    }
}

/// A small reusable animated wren, for places other than the floating
/// pet itself that want the same character — onboarding, currently.
/// Backed by its own independent `PetAnimator` (sprite frames are cached
/// by `PetSpriteStore` regardless, so a second animator instance is
/// cheap), not the pet panel's, since this needs to keep animating
/// inside a normal SwiftUI window rather than a floating `NSPanel`.
struct AnimatedWrenView: View {
    let state: String
    var size: CGFloat = 72

    @State private var animator = PetAnimator()

    var body: some View {
        PetSpriteFrameView(animator: animator, size: size)
            .onAppear { animator.play(state) }
            .onChange(of: state) { _, newValue in animator.play(newValue) }
    }
}

/// Sprite ticks update a native layer directly instead of invalidating a
/// SwiftUI view graph. SwiftUI still controls size, hover, and mirroring.
struct PetSpriteFrameView: View {
    let animator: PetAnimator
    let size: CGFloat

    var body: some View {
        NativeSpriteView(animator: animator)
            .frame(width: size, height: size)
    }
}

private struct NativeSpriteView: NSViewRepresentable {
    let animator: PetAnimator

    func makeNSView(context: Context) -> SpriteView {
        let view = SpriteView()
        view.bind(animator)
        return view
    }

    func updateNSView(_ nsView: SpriteView, context: Context) {
        if nsView.animator !== animator { nsView.bind(animator) }
    }

    static func dismantleNSView(_ nsView: SpriteView, coordinator: ()) {
        nsView.stopObserving()
        nsView.frames = nil
    }

    final class SpriteView: NSView {
        weak var animator: PetAnimator?
        fileprivate var frames: AnyCancellable?
        private var observer: NSObjectProtocol?
        private var raster: CGImage?

        // The image is decorative; enclosing SwiftUI controls own clicks,
        // hover, and dragging, just as they did with the SwiftUI Image.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var wantsUpdateLayer: Bool { true }

        func bind(_ animator: PetAnimator) {
            self.animator?.setPaused(true)
            self.animator = animator
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.magnificationFilter = .nearest
            layer?.minificationFilter = .nearest
            frames = animator.$currentFrame.sink { [weak self] frame in
                guard let self else { return }
                self.raster = frame.flatMap(PetSpriteStore.raster(for:))
                self.updateLayer()
            }
            refreshVisibility()
        }

        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = raster
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshVisibility() }
            }
            Task { @MainActor [weak self] in self?.refreshVisibility() }
        }

        private func refreshVisibility() {
            animator?.setPaused(window?.occlusionState.contains(.visible) != true)
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            animator?.setPaused(true)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
