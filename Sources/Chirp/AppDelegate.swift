import AppKit
import AVFoundation
import Foundation
import OSLog
import SwiftUI

/// Dictation-path tracing. The pipeline runs entirely while the app's own
/// window is hidden behind whatever you're dictating into, so when it
/// stalls there is otherwise nothing at all to inspect — read it back with:
/// `log show --predicate 'subsystem == "local.chirp"' --last 10m`
let dictationLog = Logger(subsystem: "local.chirp", category: "dictation")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {

    enum UIState {
        case idle, recording, processing
    }

    // Observable state for the dashboard window.
    @Published var uiState: UIState = .idle { didSet { updateIcon(); updateHUD() } }
    @Published var isHandsFree = false { didSet { updateHUD() } }
    @Published var entries: [HistoryEntry] = []
    @Published var micAuthorized = false
    @Published var axTrusted = false
    @Published var hotkey: HotkeyMonitor.Hotkey = Settings.hotkey
    @Published var localeID: String = Settings.locale.identifier
    @Published var lastError: String?
    /// A rolling, best-effort transcript of the recording in flight,
    /// shown while you speak. Never feeds the real pipeline — see
    /// `LivePreviewTranscriber` — and is cleared the moment recording
    /// stops, at which point the real transcript takes over.
    @Published var livePreviewText = "" {
        didSet { statusHUD.setLiveText(livePreviewText) }
    }

    /// Height of the custom titlebar strip drawn in SwiftUI; the traffic
    /// lights are aligned to its vertical center.
    static let titlebarHeight: CGFloat = 44
    /// AppKit's own y for the traffic lights, captured before any change.
    private var trafficLightBaselineY: CGFloat?

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var onboardingWindow: NSWindow?
    private let petPanel = PetPanelController()
    private let recorder = AudioRecorder()
    private let history = HistoryStore()
    let pipelineStats = PipelineStatsStore()
    let notetaker = NotetakerController()
    private let notetakerHotkeyMonitor = NotetakerHotkeyMonitor()
    private var transcriber = Transcriber(locale: Settings.locale)
    private lazy var hotkeyMonitor = HotkeyMonitor(hotkey: Settings.hotkey)
    let rewriteEngine = RewriteEngine()
    let vadEngine = VadEngine()
    private let livePreview = LivePreviewTranscriber()
    private lazy var turnDetector = TurnDetector(vadEngine: vadEngine)

    /// Extra status line shown in the top bar — currently always nil in
    /// practice (its one setter, the live-dictation rewrite pass, was
    /// removed along with Style/Templates), kept rather than torn out
    /// because `HomeView`'s status readout and `updateHUD()` both still
    /// read it as a general-purpose "something's happening" override.
    @Published var transformStatus: String? { didSet { updateHUD() } }
    /// Set when a notification click (or other outside prompt) should jump
    /// the dashboard to a specific page; `AppShellRoot` picks it up and
    /// clears it.
    @Published var pendingNavigateToPage: Page?
    /// A real, newer GitHub release — set once by `checkForUpdates()` at
    /// launch, `nil` otherwise. `AppShellRoot` presents the update sheet
    /// via `.sheet(item:)` off this.
    @Published var availableUpdate: AppUpdate?

    private let statusHUD = StatusHUDController()

    /// Mirrors the app's live state onto the floating HUD, which is the only
    /// status visible while dictating into another app — the main window is
    /// behind it. Reads three properties; called from all three `didSet`s.
    private func updateHUD() {
        let state: HUDState
        switch uiState {
        case .recording:
            state = .recording(handsFree: isHandsFree)
        case .processing:
            state = .processing(transformStatus ?? "Transcribing")
        case .idle:
            // A transform (⌥1/⌥2) runs with no recording in flight, so idle
            // plus a status line still means work is happening.
            state = transformStatus.map { .processing($0) } ?? .hidden
        }
        // Deferred, never inline. These observers fire during a @Published
        // change — i.e. in the middle of SwiftUI's own update pass — and
        // building an NSHostingView/NSPanel there would start a nested
        // SwiftUI update on the same actor. Hopping to the next main-actor
        // turn keeps all window work out of that cycle.
        Task { @MainActor [statusHUD] in
            statusHUD.update(state)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.registerManrope()
        // Pinned to light always — dark mode support (a System/Light/Dark
        // picker, `Palette.dynamic()` resolving per-appearance) was cut:
        // most of the app's own color tokens never actually had real dark
        // values to begin with (several pages pinned themselves to
        // `.light` colorScheme specifically because of that), so the
        // "support" was mostly a source of real bugs this session — text
        // unreadable against a background that didn't adapt with it —
        // for a mode that added little. `NSApp.appearance = .aqua` here,
        // before any window exists, makes every window (and every
        // `dynamic()`-resolved color, which reads the window's own
        // effective appearance) light regardless of the system setting.
        NSApp.appearance = NSAppearance(named: .aqua)
        entries = history.entries
        setUpStatusItem()
        // First run asks for these itself, at the moment `OnboardingRoot`'s
        // own permission step explains why — not silently the instant the
        // process launches, before that screen has even drawn.
        refreshPermissions(promptAccessibility: Settings.hasCompletedOnboarding)
        wireHotkey()
        hotkeyMonitor.startMonitoring()
        // The pet (default-visible from launch, same as the hotkey
        // monitor regardless of onboarding) replaced the old nav-bar HUD
        // as the idle-state UI — see PetPanelController's own header for
        // why: that HUD's Dock-adjacent position collided with the Dock's
        // own hover-reveal strip in a way a user-positioned icon can't.
        petPanel.setActive(true, app: self)
        // VAD refines the silence gate ahead of recognition — see
        // docs/removed-engines.md for why this (and FluidAudio generally)
        // stays even with only the Apple engine selectable.
        vadEngine.preload()
        livePreview.onUpdate = { [weak self] text in self?.livePreviewText = text }
        // Same reason `vadEngine.preload()` is here: the model's cold
        // start is seconds long, and paying it on the first dictation
        // means the preview misses the very words it exists to show.
        if Settings.livePreviewEnabled { livePreview.preload() }
        if Settings.hasCompletedOnboarding {
            showMainWindow()
            Task {
                micAuthorized = await AudioRecorder.requestMicrophoneAccess()
            }
        } else {
            showOnboarding()
        }
        // Warm up the on-device speech model in the background.
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
        // Same idea for the rewrite model — its only remaining caller is
        // Notetaker's on-demand Summarize (live dictation no longer uses
        // it at all), so this is what keeps a note's first summarize from
        // paying the model's cold-start cost.
        if rewriteEngine.isAvailable {
            Task.detached { [rewriteEngine] in
                rewriteEngine.prewarm()
            }
        }
        checkForUpdates()

        // Same engine-selection/fallback path every normal dictation
        // already goes through — a meeting clip isn't a second,
        // differently-behaved transcription pipeline.
        notetaker.transcribeFile = { [weak self] url in
            try await self?.recognize(fileAt: url, bundleID: nil) ?? ""
        }
        notetaker.rewriteEngine = rewriteEngine
        notetaker.recordPipelineStats = { [weak self] harper, dictionary, snippets in
            self?.pipelineStats.record(
                harperFixes: harper, dictionaryFixes: dictionary, snippetExpansions: snippets)
        }
        notetaker.setWindowExcludedFromCapture = { [weak self] excluded in
            self?.window?.sharingType = excluded ? .none : .readOnly
        }

        notetakerHotkeyMonitor.onTrigger = { [weak self] in
            guard let self else { return }
            if self.notetaker.canStart {
                self.notetaker.start(app: self.notetaker.detector.activeMeetingApp)
            } else if case .capturing = self.notetaker.state {
                self.notetaker.stop()
            }
        }
        notetakerHotkeyMonitor.startMonitoring()
    }

    /// Checks GitHub's own Releases API for this repo — no appcast, no
    /// Sparkle. Silent on any failure (offline, rate-limited): a missed
    /// check just means no sheet this launch, never an error surfaced to
    /// the user. Skips a release the user already dismissed via "Skip
    /// This Version", but a newer one past that still shows.
    private func checkForUpdates() {
        Task {
            guard let update = await UpdateChecker.checkLatest() else { return }
            guard update.version != Settings.skippedUpdateVersion else { return }
            availableUpdate = update
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// whisper.cpp's Metal backend keeps a static C++ registry of Metal
    /// devices. Something in its cleanup path aborts when that registry's
    /// destructor runs during normal process exit — `exit()` finalizes C++
    /// static-storage objects after AppKit has already begun tearing down,
    /// and ggml's Metal teardown doesn't tolerate that ordering. It only
    /// fires once whisper.cpp has actually been used this session, but from
    /// then on it hits on every ordinary quit — confirmed via a real crash
    /// report (`ggml_metal_rsets_free` → `ggml_abort` → SIGABRT, inside the
    /// vector-of-devices destructor called from `__cxa_finalize_ranges`).
    ///
    /// The bug is inside the vendored library, not this app's code, so
    /// rather than let AppKit's normal `terminate:` → `exit()` path reach
    /// that destructor at all, everything this app actually needs saved is
    /// flushed here and the process ends immediately via `_exit`, which
    /// skips atexit handlers and C++ static destructors entirely. Every
    /// termination route — Cmd+Q, the Quit menu item, an AppleEvent, and
    /// `relaunch()`'s `NSApp.terminate(nil)` — funnels through this one
    /// delegate method first, so this is the single place that needs it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UserDefaults.standard.synchronize()
        _exit(0)
    }

    // MARK: - Onboarding

    func showOnboarding() {
        let hosting = NSHostingController(
            rootView: OnboardingRoot(app: self) { [weak self] in
                self?.completeOnboarding()
            })
        hosting.sizingOptions = []
        let onboarding = NSWindow(contentViewController: hosting)
        onboarding.styleMask = [.titled, .closable, .fullSizeContentView]
        onboarding.titleVisibility = .hidden
        onboarding.titlebarAppearsTransparent = true
        // Pinned light regardless of the system/app appearance — by
        // request, and the same idea as `Palette.paper` always
        // staying its own fixed tone: one deliberately fixed surface, this
        // time the other direction. `Palette`'s colors resolve dynamically
        // off the *window's* effective appearance, so overriding it here
        // is enough; nothing in `OnboardingRoot` itself needs to change.
        onboarding.appearance = NSAppearance(named: .aqua)
        onboarding.setContentSize(NSSize(width: 600, height: 780))
        onboarding.isReleasedWhenClosed = false
        onboarding.center()
        onboardingWindow = onboarding
        NSApp.activate(ignoringOtherApps: true)
        onboarding.makeKeyAndOrderFront(nil)
    }

    private func completeOnboarding() {
        Settings.hasCompletedOnboarding = true
        refreshPermissions()
        onboardingWindow?.close()
        onboardingWindow = nil
        showMainWindow()
    }

    // MARK: - Main window

    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: AppShellRoot(app: self))
            // By default a hosting controller pushes its SwiftUI content's
            // ideal size up to the window, so a long transcript list would
            // stretch the window to fit rather than scrolling inside it.
            // The window's size belongs to the user; content scrolls within.
            hosting.sizingOptions = []
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Chirp"
            newWindow.styleMask = [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
            ]
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            // Sized for a utility you glance at, not a workspace you live
            // in. 1180×840 was set when pages carried full-width promo
            // heroes and boxed dashboards that genuinely needed the room;
            // with those gone every page is a header and a list, and the
            // old size just meant a lot of empty paper. The min is low
            // enough to park it in a corner beside real work.
            newWindow.setContentSize(NSSize(width: 860, height: 620))
            newWindow.minSize = NSSize(width: 620, height: 460)
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        alignTrafficLights()
        refreshPermissions()
    }

    /// macOS centers the traffic lights for its own 28pt titlebar, putting
    /// them 16pt below the window top. Our titlebar strip is 44pt, so its
    /// content — the status pill, the bell — centers at 22pt, leaving the
    /// buttons sitting visibly high. Nudge the buttons onto the same line.
    ///
    /// Works off AppKit's own baseline captured once, rather than measuring
    /// across view hierarchies: the buttons live in the window's theme
    /// frame, not in contentView, so converting between the two produces
    /// meaningless offsets (which previously pushed them out of sight).
    private func alignTrafficLights() {
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let reference = buttons.first else { return }

        // Capture AppKit's unmodified layout the first time only.
        if trafficLightBaselineY == nil {
            trafficLightBaselineY = reference.frame.origin.y
        }
        guard let baseline = trafficLightBaselineY else { return }

        // Titlebar content centers at 22pt; AppKit centers buttons at 16pt.
        // NSView is bottom-up, so subtracting moves them down.
        let target = baseline - (Self.titlebarHeight / 2 - 16)
        for button in buttons where abs(button.frame.origin.y - target) > 0.5 {
            button.frame.origin.y = target
        }
    }

    // AppKit re-lays out the titlebar on these, undoing the alignment.
    func windowDidResize(_ notification: Notification) { alignTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { alignTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { alignTrafficLights() }

    // MARK: - Permissions

    func refreshPermissions(promptAccessibility: Bool = false) {
        if promptAccessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            axTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        } else {
            axTrusted = AXIsProcessTrusted()
        }
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Settings changes (from window or menu)

    func setHotkey(_ key: HotkeyMonitor.Hotkey) {
        Settings.hotkey = key
        hotkey = key
        hotkeyMonitor.hotkey = key
        rebuildMenu()
    }

    func setPetEnabled(_ enabled: Bool) {
        Settings.petEnabled = enabled
        petPanel.refreshEnabled(app: self)
    }

    /// Language codes the active recognition engine can actually
    /// transcribe. Always `nil` now that Apple's on-device engine (see
    /// docs/removed-engines.md for the others) is the only one — its
    /// supported set is a fixed, per-locale asset list that only
    /// `SpeechTranscriber` knows, which the Settings and HUD language
    /// pickers already load and cache themselves. Kept as a function
    /// (not inlined at its call sites) since a re-added engine would
    /// restore real per-engine/per-model logic here, same shape as
    /// before.
    func supportedLanguageIDs() -> [String]? {
        nil
    }

    func setLocale(_ identifier: String) {
        Settings.localeIdentifier = identifier
        localeID = identifier
        if String(identifier.prefix(while: { $0 != "-" })).lowercased() != "en" {
            Settings.lastNonEnglishLocaleIdentifier = identifier
        }
        transcriber = Transcriber(locale: Locale(identifier: identifier))
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
    }

    func clearHistoryEntries() {
        history.clear()
        entries = []
        rebuildMenu()
    }

    /// Deletes any stale Accessibility grant (recorded against an older
    /// build's signature) and relaunches so macOS asks again — the new grant
    /// is recorded against the stable certificate and survives updates.
    func resetAccessibilityGrant() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = [
            "reset", "Accessibility",
            Bundle.main.bundleIdentifier ?? "local.chirp",
        ]
        try? process.run()
        process.waitUntilExit()
        relaunch()
    }

    /// Starts a fresh instance of the app and quits this one. Needed after
    /// granting Accessibility, which macOS only applies to new processes.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func deleteHistoryEntry(id: String) {
        history.delete(id: id)
        entries = history.entries
        rebuildMenu()
    }

    /// Applies a user correction to a transcript and learns the
    /// misheard → intended word mappings from it. Returns how many were learned.
    @discardableResult
    func correctHistoryEntry(id: String, newText: String) -> Int {
        guard let entry = history.entries.first(where: { $0.id == id }),
              entry.text != newText else { return 0 }
        let learnedCount = LearnedStore.learn(original: entry.text, corrected: newText)
        history.update(id: id, text: newText)
        entries = history.entries
        rebuildMenu()
        return learnedCount
    }

    /// Runs recognition. Used to dispatch across whichever engine the user
    /// had selected (Whisper/whisper.cpp/Parakeet, each with its own
    /// not-ready-yet/failure fallback to Apple) — see docs/removed-engines.md
    /// for that logic's shape if an engine choice comes back; with only
    /// Apple's on-device engine left, there's nothing left to choose
    /// between or fall back from.
    private func recognize(fileAt url: URL, bundleID: String?) async throws -> String {
        let developerVocabulary = DictationDefaults.developerVocabularyEnabled(forBundleID: bundleID)
        let biasTerms = LearnedStore.biasTerms(includeDeveloperVocabulary: developerVocabulary)
        dictationLog.info(
            "recognize: locale=\(Settings.localeIdentifier, privacy: .public) developerVocabulary=\(developerVocabulary)")
        return try await transcriber.transcribe(fileAt: url, biasTerms: biasTerms)
    }

    // MARK: - Hotkey wiring

    private func wireHotkey() {
        hotkeyMonitor.onStart = { [weak self] in
            DispatchQueue.main.async { self?.startRecording() }
        }
        hotkeyMonitor.onStop = { [weak self] in
            DispatchQueue.main.async { self?.stopAndTranscribe() }
        }
        hotkeyMonitor.onCancel = { [weak self] in
            DispatchQueue.main.async {
                // Cancel is the other way out of a recording, so it has to
                // tear the preview down too — otherwise the tap hook stays
                // attached and the next session starts with a stale one
                // already running.
                self?.stopLivePreview()
                self?.recorder.cancel()
                self?.uiState = .idle
            }
        }
        hotkeyMonitor.onHandsFreeChange = { [weak self] active in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isHandsFree = active
                self.updateIcon()
                if active {
                    NSSound(named: "Pop")?.play()
                    if Settings.handsFreeAutoStop {
                        self.turnDetector.start()
                        self.recorder.onLiveBuffer = { [weak self] buffer in
                            Task { @MainActor in await self?.turnDetector.ingest(buffer) }
                        }
                    }
                } else {
                    self.recorder.onLiveBuffer = nil
                    self.turnDetector.stop()
                }
            }
        }
        turnDetector.onTurnEnd = { [weak self] in
            guard let self else { return }
            self.recorder.onLiveBuffer = nil
            self.hotkeyMonitor.resetHandsFree()
            self.stopAndTranscribe()
        }
    }

    private var recordingStartedAt: Date?
    private var recordingTargetBundleID: String?

    /// The pet's own mic button — same hands-free semantics as a
    /// double-tap of the hotkey (start and keep listening, rather than
    /// push-to-talk), since a click has no "hold" to speak of. A second
    /// click while recording stops and transcribes, same as the hotkey's
    /// own hands-free stop.
    func togglePetDictation() {
        if uiState == .idle {
            startRecording()
            isHandsFree = true
            NSSound(named: "Pop")?.play()
        } else if uiState == .recording {
            stopAndTranscribe()
        }
    }

    /// Detaches the tap hook first, then stops the session — the other
    /// order can enqueue one more buffer into a session that has already
    /// reset, which shows up as a stale word appearing after the preview
    /// should have gone quiet.
    /// Starts the model loading as soon as the feature is switched on,
    /// rather than waiting for the first recording. The model is slow to
    /// wake — a cold session can take ten seconds or more to emit its
    /// first words, which on a short dictation means the preview shows
    /// nothing at all and looks broken.
    func warmLivePreview() {
        guard Settings.livePreviewEnabled else { return }
        livePreview.preload()
    }

    private func stopLivePreview() {
        recorder.onLivePreviewBuffer = nil
        livePreview.stop()
        livePreviewText = ""
    }

    private func startRecording() {
        guard uiState != .recording else { return }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            let frontmost = NSWorkspace.shared.frontmostApplication
            recordingTargetBundleID = frontmost?.bundleIdentifier
            statusHUD.setTargetAppIcon(frontmost?.icon)
            uiState = .recording
            lastError = nil
            if Settings.livePreviewEnabled {
                livePreviewText = ""
                livePreview.start()
                // `onLivePreviewBuffer`, not `onLiveBuffer`: the two run
                // independently so a slow preview can never stall the
                // level meter (see AudioRecorder's own note).
                recorder.onLivePreviewBuffer = { [weak self] buffer in
                    Task { @MainActor in self?.livePreview.enqueue(buffer) }
                }
            }
            NSSound(named: "Pop")?.play()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            NSSound(named: "Basso")?.play()
        }
    }

    private func stopAndTranscribe() {
        isHandsFree = false
        stopLivePreview()
        guard let url = recorder.stop() else {
            uiState = .idle
            return
        }
        NSSound(named: "Tink")?.play()
        uiState = .processing
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) }
        recordingStartedAt = nil
        let targetBundleID = recordingTargetBundleID
        recordingTargetBundleID = nil

        let frames = recorder.capturedFrames
        let rate = recorder.capturedFormat?.sampleRate ?? 0
        dictationLog.info("stop: \(frames) frames @ \(rate, format: .fixed(precision: 0)) Hz")
        guard frames > 0 else {
            // The microphone delivered nothing at all. Previously this still
            // went to the recognizer, which returned an empty string, and the
            // whole dictation vanished with no explanation.
            dictationLog.error("stop: NO AUDIO CAPTURED")
            lastError = "No audio was captured — the microphone delivered "
                + "nothing. If you're on Bluetooth headphones, try switching "
                + "input to the built-in microphone."
            NSSound(named: "Basso")?.play()
            uiState = .idle
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard recorder.hasSignal else {
            // Frames exist (room tone, mic self-noise) but no real speech —
            // pressing the key and releasing it without saying anything.
            // Whisper models hallucinate on exactly this: fed silence, they
            // fill it in with a sign-off phrase like "Thank you." rather
            // than admitting there's nothing there, because their training
            // data is full of transcripts that end that way. Skipping the
            // recognizer entirely here is what actually fixes it — no
            // amount of prompting talks a model out of a pattern this deep
            // in its training.
            dictationLog.info("stop: no speech detected, skipping recognition")
            uiState = .idle
            try? FileManager.default.removeItem(at: url)
            return
        }

        Task { [history, rewriteEngine, pipelineStats] in
            defer { try? FileManager.default.removeItem(at: url) }
            // A second, sharper opinion on top of the RMS-based `hasSignal`
            // gate just above — catches what raw amplitude can't, like a
            // loud non-speech sound clearing the floor. Independent of
            // whichever recognition engine is selected below.
            if await vadEngine.hasNoDetectedSpeech(fileAt: url) {
                dictationLog.info("recognize: VAD found no speech, skipping recognition")
                uiState = .idle
                return
            }
            do {
                dictationLog.info("recognize: start")
                let raw = try await recognize(fileAt: url, bundleID: targetBundleID)
                dictationLog.info("recognize: done, \(raw.count) chars")
                let developerVocabulary = DictationDefaults.developerVocabularyEnabled(
                    forBundleID: targetBundleID)

                // Whisper-family engines hallucinate a small, specific set
                // of sign-off phrases ("Thank you.") on near-silent audio
                // that still clears the earlier signal-duration gate — the
                // model's own confidence score doesn't catch this (measured:
                // ~0.00002 "no speech" probability on a confidently
                // hallucinated "Thank you."), so the output itself is
                // checked directly. Caught here, before any further
                // processing spends time or an LLM call on text that's
                // about to be discarded anyway.
                guard !HallucinationFilter.isLikelyHallucination(raw) else {
                    dictationLog.error(
                        // No `privacy: .public` on `raw`: that forced real
                        // dictated speech into the unified log in cleartext,
                        // where it persists and is collected by sysdiagnose.
                        // The default redaction still records that a
                        // discard happened, without the transcript itself.
                        "recognize: discarded as a likely hallucination: \(raw)")
                    uiState = .idle
                    return
                }

                let style = DictationDefaults.style(forBundleID: targetBundleID)
                dictationLog.info("style resolved: \(style.rawValue, privacy: .public)")

                // Personal-correction stores are English-only by nature:
                // `LearnedStore` holds mishearing fixes, and `TextFormatter`'s
                // dictionary holds spellings, both learned from past
                // *English* dictations. Applied to another language, a short
                // "heard" trigger (e.g. "up", "there") can exact-word-match a
                // coincidental token in the transcript and get swapped for
                // its English "intended" text — corrupting part of an
                // otherwise-correct non-English sentence (this is what was
                // silently reintroducing the Latvian-dictation bug even
                // after Harper below was fixed). Harper has the same problem
                // for the same reason, just for spelling/grammar instead of
                // personal corrections.
                let isEnglishDictation =
                    String(Settings.localeIdentifier.prefix(while: { $0 != "-" }))
                    .lowercased() == "en"
                dictationLog.info(
                    "locale gate: Settings.localeIdentifier=\(Settings.localeIdentifier, privacy: .public) isEnglishDictation=\(isEnglishDictation)")

                // Tallied for Insights' "Fixes made by Chirp" card only —
                // each count comes from a plain before/after read of
                // `formatted` around a call already made below, never from
                // changing what that call does or re-deriving its result.
                var harperFixCount = 0
                var dictionaryFixCount = 0
                var snippetExpansionCount = 0

                var formatted: String
                if style.skipsAllProcessing {
                    // Raw: exact words, no cleanup, no AI. For terminals and
                    // code editors, where "corrections" would be corruption.
                    formatted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isEnglishDictation {
                        let beforeDictionary = formatted
                        formatted = LearnedStore.apply(
                            in: formatted, includeDeveloperVocabulary: developerVocabulary)
                        dictionaryFixCount += PipelineDiff.wordChangeCount(
                            from: beforeDictionary, to: formatted)
                    }
                    snippetExpansionCount += PipelineDiff.snippetMatchCount(
                        in: formatted, snippets: SnippetStore.load())
                    formatted = SnippetStore.expand(in: formatted)
                } else {
                    formatted = TextFormatter(
                        dictionary: isEnglishDictation ? TextFormatter.loadDictionary() : [:]
                    ).format(raw)
                    if isEnglishDictation {
                        let beforeDictionary = formatted
                        formatted = LearnedStore.apply(
                            in: formatted, includeDeveloperVocabulary: developerVocabulary)
                        dictionaryFixCount += PipelineDiff.wordChangeCount(
                            from: beforeDictionary, to: formatted)
                    }
                    snippetExpansionCount += PipelineDiff.snippetMatchCount(
                        in: formatted, snippets: SnippetStore.load())
                    formatted = SnippetStore.expand(in: formatted)

                    // Everything below needs the model, and the spoken
                    // trigger must not be stripped out of the text unless
                    // something is actually going to act on it.
                    //
                    // The on-device model rewrite pass that used to run
                    // here (tone styles, note templates, Voice Profile)
                    // is gone along with those three features — Style,
                    // Templates, and Voice Profile were all cut, and
                    // Raw mode (the one thing from that family worth
                    // keeping) never needed the model at all: it's
                    // handled entirely by `style.skipsAllProcessing`
                    // above, before this branch is even reached. What's
                    // left below (formatter, dictionary, learned
                    // corrections, Harper) already covers ordinary
                    // cleanup in ~20ms, against the 7-15s the model pass
                    // measured at — removing it from every dictation's
                    // default path was the whole point of this pass, not
                    // just an option left off.

                    // A fast, local, deterministic grammar pass — runs after
                    // the LLM step (catching whatever it missed) but doesn't
                    // depend on it: Harper needs no Apple Intelligence, so
                    // this still improves grammar on Macs where the pass
                    // above was skipped entirely. Milliseconds, not worth a
                    // status message next to a multi-second LLM round-trip.
                    //
                    // English only — see `isEnglishDictation` above: Harper
                    // hardcodes an English parser/dictionary, so it
                    // "corrects" other languages' real words into the
                    // nearest English one instead of leaving them alone.
                    if !formatted.isEmpty, isEnglishDictation {
                        let beforeHarper = formatted
                        formatted = HarperChecker.fix(
                            formatted,
                            vocabulary: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary))
                        harperFixCount += PipelineDiff.wordChangeCount(from: beforeHarper, to: formatted)
                    }
                }
                dictationLog.info("pipeline done: \(formatted.count) chars")
                if !formatted.isEmpty {
                    history.add(formatted, duration: duration, targetBundleID: targetBundleID)
                    pipelineStats.record(
                        harperFixes: harperFixCount, dictionaryFixes: dictionaryFixCount,
                        snippetExpansions: snippetExpansionCount)
                    entries = history.entries
                    dictationLog.info("history: added, inserting text")
                    if AXIsProcessTrusted() {
                        // Dictating into Chirp's own window (Scratchpad,
                        // Ask, Transforms' try-it box, …) is the one case
                        // where the paste target and the app posting the
                        // synthetic ⌘V are the same process. The HUD panels
                        // are deliberately non-activating so they never
                        // steal focus from *another* app mid-dictation —
                        // but the several-second gap between "recording
                        // stops" and "text is ready" is enough for Chirp
                        // itself to lose active-app status in the interim
                        // (e.g. the user's attention/pointer drifting to
                        // another window), which the other-app path never
                        // had to survive since it was never Chirp's status
                        // to lose. Reactivating right before the paste
                        // restores it without touching the window's own
                        // first responder, which AppKit preserves across an
                        // app losing and regaining active status.
                        if targetBundleID == Bundle.main.bundleIdentifier {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        TextInserter.insert(formatted)
                    } else {
                        // Can't synthesize ⌘V without Accessibility — never
                        // fail silently: leave the transcript on the clipboard.
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatted, forType: .string)
                        lastError = "Accessibility isn't active for this build, " +
                            "so the text was copied to your clipboard instead — " +
                            "press ⌘V to paste it. Fix this in Settings."
                        NSSound(named: "Basso")?.play()
                    }
                    rebuildMenu()
                } else {
                    // Previously a silent no-op: nothing pasted, nothing in
                    // History, and no indication anything had gone wrong —
                    // indistinguishable from the app being broken.
                    lastError = "Nothing was transcribed — the recording came "
                        + "through empty. Check the microphone is picking you up."
                    NSSound(named: "Basso")?.play()
                }
            } catch {
                dictationLog.error("FAILED: \(error.localizedDescription, privacy: .public)")
                lastError = "Transcription failed: \(error.localizedDescription)"
                NSSound(named: "Basso")?.play()
            }
            uiState = .idle
            dictationLog.info("idle")
        }
    }

    // MARK: - Status item / menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        let symbol: String
        switch uiState {
        case .idle: symbol = "mic"
        case .recording: symbol = isHandsFree ? "mic.badge.plus" : "mic.fill"
        case .processing: symbol = "hourglass"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Chirp")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open Chirp…", action: #selector(openMainWindow),
            keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let hint = NSMenuItem(
            title: "Hold \(hotkeyMonitor.hotkey.displayName) to dictate",
            action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, entry) in history.entries.prefix(8).enumerated() {
                let preview = entry.text.count > 60
                    ? String(entry.text.prefix(57)) + "…" : entry.text
                let item = NSMenuItem(
                    title: preview.replacingOccurrences(of: "\n", with: " "),
                    action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Chirp", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu actions

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard sender.tag < history.entries.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(history.entries[sender.tag].text, forType: .string)
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Gates first-run setup — `OnboardingRoot` vs the normal main window.
    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    static var hotkey: HotkeyMonitor.Hotkey {
        get {
            HotkeyMonitor.Hotkey(
                rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var localeIdentifier: String {
        get { defaults.string(forKey: "locale") ?? "en-US" }
        set { defaults.set(newValue, forKey: "locale") }
    }

    /// The last non-English locale the user deliberately selected — kept
    /// separately from `localeIdentifier` so `reconcileLocaleWithEngine`
    /// can restore it after a temporary English fallback (forced by
    /// switching to an English-only engine/model) instead of leaving the
    /// user stuck on English once the original engine/model is reselected.
    static var lastNonEnglishLocaleIdentifier: String? {
        get { defaults.string(forKey: "lastNonEnglishLocale") }
        set { defaults.set(newValue, forKey: "lastNonEnglishLocale") }
    }

    /// Auto-stop a hands-free recording on a detected pause, instead of
    /// requiring a second hotkey press. Defaults on; the underlying
    /// streaming VAD is FluidAudio's own "beta" feature, so this stays a
    /// real, visible toggle rather than invisible infrastructure — manual
    /// double-tap-to-stop keeps working regardless of this setting.
    static var handsFreeAutoStop: Bool {
        get { defaults.object(forKey: "handsFreeAutoStop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "handsFreeAutoStop") }
    }

    /// The version the user chose "Skip This Version" for, if any — that
    /// specific release won't show the update sheet again, but a later
    /// one still will.
    static var skippedUpdateVersion: String? {
        get { defaults.string(forKey: "skippedUpdateVersion") }
        set { defaults.set(newValue, forKey: "skippedUpdateVersion") }
    }

    /// The nav rail's pinned/expanded state. Defaults to fully open on
    /// first launch — an icon-only rail with hidden groups is a reasonable
    /// compact mode for someone who already knows their way around, but a
    /// poor first impression that hides App Profiles (and everything else)
    /// behind an undiscovered toggle. Once the user sets their own
    /// preference it's respected on every later launch, not fought.
    static var railPinned: Bool {
        get { defaults.object(forKey: "railPinned") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "railPinned") }
    }

    /// The floating pet icon — on by default since it exists specifically
    /// to replace the Dock-colliding hover HUD, not as an opt-in extra.
    static var petEnabled: Bool {
        get { defaults.object(forKey: "petEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "petEnabled") }
    }

    /// Show a rough live transcript while you're still speaking.
    ///
    /// **Off by default, and it has to stay that way.** The preview runs
    /// on a separate streaming model that FluidAudio fetches on first use
    /// — ~220MB into `~/Library/Application Support/FluidAudio/Models/`.
    /// Everything else Chirp does is local with no download beyond
    /// macOS's own speech assets, and that promise is on the tin. Pulling
    /// 220MB in the background because a default said so would break it
    /// silently, for a feature the user never asked for.
    static var livePreviewEnabled: Bool {
        get { defaults.bool(forKey: "livePreviewEnabled") }
        set { defaults.set(newValue, forKey: "livePreviewEnabled") }
    }

    /// Off by default — relocating itself across the desktop is a bigger
    /// behavior change than the pet just sitting where it's dragged, so
    /// this needs an explicit opt-in rather than arriving on for everyone.
    static var petWanders: Bool {
        get { defaults.object(forKey: "petWanders") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "petWanders") }
    }

    /// A temporary "stay put" the user can flip from the pet's own pill
    /// without going to Settings, for when a wandering wren is in the way
    /// right now. Deliberately separate from `petWanders`: that's the
    /// feature switch, this is the moment-to-moment override, so
    /// unpinning restores wandering without having to remember whether
    /// the feature was ever on.
    static var petPinned: Bool {
        get { defaults.bool(forKey: "petPinned") }
        set { defaults.set(newValue, forKey: "petPinned") }
    }

    /// `nil` until the user drags it once — `PetPanelController` computes
    /// a sensible default (bottom-right of the active screen) rather than
    /// this storing one, so that default can keep adapting to whichever
    /// screen/resolution is active until the user actually states a
    /// preference by dragging it.
    static var petPosition: NSPoint? {
        get {
            guard let x = defaults.object(forKey: "petPositionX") as? Double,
                  let y = defaults.object(forKey: "petPositionY") as? Double
            else { return nil }
            return NSPoint(x: x, y: y)
        }
        set {
            defaults.set(newValue?.x, forKey: "petPositionX")
            defaults.set(newValue?.y, forKey: "petPositionY")
        }
    }

    /// Off by default, unlike every other meeting-detection signal —
    /// turning this on means `MeetingDetector` periodically reads the
    /// frontmost browser's own active-tab URL (via Apple Events) to check
    /// it against known meeting-link patterns, which is a meaningfully
    /// different privacy footprint from just checking a native app's
    /// bundle ID, so it needs an explicit opt-in rather than being on from
    /// first launch.
    static var browserMeetingDetectionEnabled: Bool {
        get { defaults.object(forKey: "browserMeetingDetectionEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "browserMeetingDetectionEnabled") }
    }

    /// Notetaker's own global hotkey, via
    /// `NotetakerHotkeyMonitor`/`NotetakerHotkeyEditor`.
    static var notetakerHotkeyKeyCode: UInt16 {
        get {
            guard let stored = defaults.object(forKey: "notetakerHotkeyKeyCode") as? Int else {
                return NotetakerHotkeyMonitor.defaultKeyCode
            }
            return UInt16(stored)
        }
        set { defaults.set(Int(newValue), forKey: "notetakerHotkeyKeyCode") }
    }
    static var notetakerHotkeyModifiers: NSEvent.ModifierFlags {
        get {
            guard let stored = defaults.object(forKey: "notetakerHotkeyModifiers") as? UInt else {
                return NotetakerHotkeyMonitor.defaultModifiers
            }
            return NSEvent.ModifierFlags(rawValue: stored)
        }
        set { defaults.set(newValue.rawValue, forKey: "notetakerHotkeyModifiers") }
    }

    /// Gates whether `NotetakerController` runs its two `LivePreviewTranscriber`
    /// instances at all during a capture — on by default (it's the reassurance
    /// feature it was built to be), off for anyone who finds a live caption
    /// distracting rather than helpful.
    static var notetakerLiveTranscriptEnabled: Bool {
        get { defaults.object(forKey: "notetakerLiveTranscriptEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notetakerLiveTranscriptEnabled") }
    }

    /// Excludes the main window from screen recording/sharing for as long
    /// as Notetaker is capturing or processing — off by default since it's
    /// a real behavior change (anything you screen-share won't show Chirp
    /// at all while this is on, not just the Notetaker page).
    static var notetakerHideFromScreenCapture: Bool {
        get { defaults.object(forKey: "notetakerHideFromScreenCapture") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "notetakerHideFromScreenCapture") }
    }

    /// Auto-stops a capture once the app it started with has fully quit —
    /// checked against the *running* apps list, not the frontmost one, so
    /// tabbing away to check email mid-call doesn't stop a still-live
    /// meeting. On by default: a capture nobody remembered to stop is more
    /// likely a forgotten one than an intentional long one.
    static var notetakerAutoStopOnCallEnd: Bool {
        get { defaults.object(forKey: "notetakerAutoStopOnCallEnd") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notetakerAutoStopOnCallEnd") }
    }

    /// Minutes before a capture stops itself automatically; `0` means no
    /// limit. Defaults to 120 — long enough for nearly any real meeting,
    /// short enough that an accidentally-left-running capture doesn't fill
    /// the disk with hours of silence.
    static var notetakerMaxRecordingMinutes: Int {
        get { defaults.object(forKey: "notetakerMaxRecordingMinutes") as? Int ?? 120 }
        set { defaults.set(newValue, forKey: "notetakerMaxRecordingMinutes") }
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }
}
