import AVFoundation
import AppKit
import SwiftUI

/// First-run setup: welcome → permissions → hotkey → mic test → done.
/// Shown once (`Settings.hasCompletedOnboarding`), then replaced by the
/// normal main window. Every choice here applies for real the moment
/// it's made — same as `SettingsPage` — so there's nothing to save on
/// Continue, only somewhere further to go.
///
/// Used to have a "recognition engine" step between permissions and
/// hotkey — dropped along with the Whisper/whisper.cpp/Parakeet engines
/// themselves (see docs/removed-engines.md): with only Apple's on-device
/// engine left, there's no real choice to present, and a picker with one
/// pre-selected, un-changeable option is worse than no picker at all.
struct OnboardingRoot: View {
    @ObservedObject var app: AppDelegate
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    /// Live during `.micTest` only — started on appearing, stopped on
    /// leaving. Never actually written to disk in any lasting way: `stop()`
    /// still returns a temp-file URL like a real dictation would, but
    /// nothing here reads it back; only the live per-buffer level matters.
    @State private var micTestRecorder: AudioRecorder?
    /// Normalized 0...1, updated from `micTestRecorder`'s live buffers —
    /// see `CaptureWaveform.level` for how it drives the bars, and
    /// `startMicTest()` for the scaling from raw RMS.
    @State private var micLevel: CGFloat = 0
    /// Latches once the mic has clearly picked up speech. Latched, not
    /// live, so the confirmation doesn't blink on and off between words.
    @State private var micHeard = false
    /// Polls while onboarding is on screen. Faster than the main
    /// window's 5s: this is the one moment the user is actively waiting
    /// for a permission to flip, rather than a background check.
    private let permissionTimer = Timer.publish(
        every: 1.5, on: .main, in: .common).autoconnect()
    /// Drives the small wren next to the permissions step's own header —
    /// see `celebratePermissionGrant()`.
    @State private var permissionWrenState = "idle"

    private enum Step: Int, CaseIterable {
        case welcome, permissions, hotkey, micTest, done
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 20)
            progress
            // Scrolls rather than a bare `.frame(maxHeight: .infinity)`
            // around the switch: the window is fixed-size (`.styleMask`
            // has no `.resizable`, see AppDelegate's `showOnboarding`), so
            // any step whose content can grow — `engineStep`'s "MODEL
            // SIZE" list appears only for non-Apple engines and adds
            // several rows — used to push `footer`'s Continue button
            // straight out of the window instead of the step scrolling.
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .permissions: permissionsStep
                    case .hotkey: hotkeyStep
                    case .micTest: micTestStep
                    case .done: doneStep
                    }
                }
                .padding(.horizontal, 44)
                .padding(.top, 30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
    }

    // MARK: - Chrome

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Palette.sunsetDeep : Palette.warmDivider)
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 44)
        .animation(.chirpEase(), value: step)
    }

    private var footer: some View {
        HStack {
            Button("Back") { move(-1) }
                .buttonStyle(GhostButtonStyle())
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
            Spacer()
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Text(primaryLabel)
                    ChirpIconView(icon: .arrowRight).frame(width: 12, height: 12)
                }
                .font(.manrope(13, .semibold))
                .foregroundStyle(Palette.accentInk)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.sm))
            }
            .buttonStyle(PressScaleButtonStyle())
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 26)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .permissions: return "Continue"
        case .hotkey: return "Continue"
        case .micTest: return "Continue"
        case .done: return "Open Chirp"
        }
    }

    private func primaryAction() {
        if step == .done {
            onFinish()
            return
        }
        move(1)
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.chirpEase()) { step = next }
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.chirpDisplay(26, .regular))
                .foregroundStyle(Palette.warmInk)
            Text(subtitle)
                .font(.manrope(13.5))
                .foregroundStyle(Palette.warmInkSoft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430, alignment: .leading)
        }
        .padding(.bottom, 26)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            AnimatedWrenView(state: "idle", size: 72)
                .padding(.bottom, 22)
            Text("WELCOME TO CHIRP")
                .font(.manrope(10.5, .bold))
                .tracking(1.05)
                .foregroundStyle(Palette.warmInkFaint)
                .padding(.bottom, 14)
            Text("Everything you say, turned into text — without leaving your Mac.")
                .font(.chirpDisplay(31, .regular))
                .lineSpacing(3)
                .foregroundStyle(Palette.warmInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.bottom, 12)
            Text("Chirp listens only while you hold a key, transcribes on-device, and drops the result wherever your cursor already is.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430, alignment: .leading)
                .padding(.bottom, 28)
            HStack(alignment: .top, spacing: 26) {
                fact(.lock, "Nothing leaves your Mac")
                fact(.apps, "Works in every app")
                fact(.check, "Cleans up as it types")
            }
        }
    }

    private func fact(_ icon: ChirpIcon, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ChirpIconView(icon: icon)
                .frame(width: 18, height: 18)
                .foregroundStyle(Palette.sunsetDeep)
            Text(text)
                .font(.manrope(11.5, .medium))
                .foregroundStyle(Palette.warmInkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 122, alignment: .leading)
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                AnimatedWrenView(state: permissionWrenState, size: 44)
                stepHeader(
                    "Let's get you set up",
                    "Two permissions and Chirp is ready.")
            }
            VStack(spacing: 10) {
                PermissionRow(
                    icon: .mic, title: "Microphone",
                    detail: "Captures your voice while you hold the hotkey — never listens otherwise.",
                    granted: app.micAuthorized
                ) {
                    Task { app.micAuthorized = await AudioRecorder.requestMicrophoneAccess() }
                }
                PermissionRow(
                    icon: .fingerprint, title: "Accessibility",
                    detail: "Lets Chirp watch for your hotkey and paste the result. Without it, text is copied to your clipboard instead.",
                    granted: app.axTrusted
                ) {
                    app.refreshPermissions(promptAccessibility: true)
                }
            }
            // The escape hatch for a *stale* grant: Chirp is ticked in
            // System Settings but macOS still reports it as untrusted,
            // because the saved approval belongs to an older build's
            // signature. Settings has had this button for a while, but
            // Settings is unreachable from here — and onboarding is
            // exactly where someone hits this, having just ticked the box
            // and watched nothing happen. With no way out, the only read
            // is "this app is broken".
            if !app.axTrusted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Already switched Chirp on in System Settings but it still says "
                         + "Allow? The saved approval belongs to an older build. Reset it "
                         + "and macOS will ask once more.")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkSoft)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset & Relaunch") { app.resetAccessibilityGrant() }
                        .buttonStyle(GhostButtonStyle())
                }
                .padding(.top, 14)
                .frame(maxWidth: 440, alignment: .leading)
            }
            Text("You can change either of these later in System Settings → Privacy & Security.")
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkFaint)
                .padding(.top, 16)
        }
        .onChange(of: app.micAuthorized) { _, granted in if granted { celebratePermissionGrant() } }
        .onChange(of: app.axTrusted) { _, granted in if granted { celebratePermissionGrant() } }
        // Granting Accessibility happens in System Settings, in another
        // app — so nothing here would otherwise notice. Without this the
        // step sits on "Allow" forever after the user has already granted
        // it, which reads as Chirp being broken on the very first screen.
        //
        // Both, deliberately: becoming active catches the common case
        // (switching back from System Settings) the instant it happens,
        // and the timer catches granting it while this window is still
        // frontmost, which `didBecomeActive` never fires for.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
        }
        .onReceive(permissionTimer) { _ in app.refreshPermissions() }
    }

    /// A one-shot "activated" hop the instant either permission is
    /// actually granted — the wren otherwise just idles here, so this is
    /// the one moment in this step worth a reaction to. Reverts to idle
    /// itself after the one-shot's own ~0.43s runtime (`pet_sprites.json`)
    /// plus a small buffer, since `AnimatedWrenView` has no completion
    /// callback of its own to hang this off of — onboarding is the only
    /// caller so far, and a fixed delay is simpler than threading one
    /// through just for this.
    private func celebratePermissionGrant() {
        permissionWrenState = "activated"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            permissionWrenState = "idle"
        }
    }

    // MARK: - Hotkey

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(
                "Pick your hotkey",
                "Hold it anywhere to dictate, release to stop. Tap twice quickly to go hands-free — tap once more to stop.")
            VStack(spacing: 8) {
                ForEach(HotkeyMonitor.Hotkey.allCases, id: \.self) { key in
                    HotkeyOptionRow(hotkey: key, selected: app.hotkey == key) {
                        app.setHotkey(key)
                    }
                }
            }
        }
    }

    // MARK: - Mic test

    private var micTestStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader("Let's test your microphone", "Say something out loud — Chirp should react.")
            HStack(spacing: 10) {
                ChirpIconView(icon: .mic)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(Palette.warmInkSoft)
                Text(defaultInputName)
                    .font(.manrope(12.5, .semibold))
                    .foregroundStyle(Palette.warmInk)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Palette.warmDivider, lineWidth: 1))
            .frame(maxWidth: 300, alignment: .leading)
            Spacer(minLength: 20)
            // The wren alone wasn't enough. It chirps on a loop whatever
            // the microphone is doing, so the only thing tied to the live
            // level was a 22% scale pulse — invisible against a sprite
            // that's already moving. This step exists to answer one
            // question ("is my microphone working?") and it has to answer
            // it unmistakably: a meter that visibly tracks your voice,
            // and a latched confirmation once it has definitely heard
            // you, which stays put instead of flickering with every syllable.
            VStack(spacing: 18) {
                // Side by side, not stacked: a mic source next to its
                // level meter is the arrangement people already know from
                // every recording app, so it reads as "this bird is
                // hearing that" without needing to be explained.
                HStack(spacing: 22) {
                    AnimatedWrenView(state: micHeard ? "chirp" : "listening", size: 76)
                        .scaleEffect(1 + micLevel * 0.12)
                        .animation(.chirpEase(0.1), value: micLevel)
                    MicLevelMeter(level: micLevel)
                }
                HStack(spacing: 8) {
                    if micHeard {
                        ChirpIconView(icon: .check)
                            .frame(width: 13, height: 13)
                            .foregroundStyle(Palette.sunsetDeep)
                        Text("Your microphone is working")
                            .font(.manrope(13, .semibold))
                            .foregroundStyle(Palette.sunsetDeep)
                    } else {
                        PulsingDot(color: Palette.warmInkFaint, size: 6,
                                   maxScale: 2.2, active: true)
                        Text("Listening — say something")
                            .font(.manrope(13))
                            .foregroundStyle(Palette.warmInkSoft)
                    }
                }
                .animation(.chirpEase(0.2), value: micHeard)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 20)
        }
        .onAppear { startMicTest() }
        .onDisappear { stopMicTest() }
    }

    private var defaultInputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "System Default"
    }

    /// Opens a real mic tap for the duration of this step, purely to
    /// drive `micLevel` — nothing is transcribed and nothing written by
    /// this recording is ever read back. `onLiveBuffer` fires on the
    /// audio engine's own real-time thread, never the main thread, so the
    /// `@State` write is dispatched back rather than set directly.
    private func startMicTest() {
        guard micTestRecorder == nil else { return }
        let recorder = AudioRecorder()
        recorder.onLiveBuffer = { buffer in
            let rms = AudioRecorder.rmsLevel(in: buffer)
            // 0.15 is a by-ear calibration, not a measured spec: normal
            // speaking volume at typical laptop-mic gain and distance
            // lands the bars in a visibly moving mid-to-high range
            // without needing to raise your voice.
            let normalized = min(1, CGFloat(rms) / 0.15)
            DispatchQueue.main.async {
                micLevel = normalized
                // Comfortably above room tone, so it takes real speech to
                // trip rather than a fan or a passing car.
                if normalized > 0.35 { micHeard = true }
            }
        }
        micTestRecorder = recorder
        try? recorder.start()
    }

    private func stopMicTest() {
        _ = micTestRecorder?.stop()
        micTestRecorder = nil
        micLevel = 0
        micHeard = false
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle().fill(Palette.accentSoft).frame(width: 56, height: 56)
                ChirpIconView(icon: .check)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .padding(.bottom, 22)
            Text("You're all set.")
                .font(.chirpDisplay(26, .regular))
                .foregroundStyle(Palette.warmInk)
                .padding(.bottom, 8)
            Text("Chirp lives in your menu bar — there's no Dock icon.")
                .font(.manrope(13.5))
                .foregroundStyle(Palette.warmInkSoft)
                .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Keycap(text: app.hotkey.shortSymbol)
                    Text("Hold **\(app.hotkey.displayName)** anywhere to dictate — release when you're done.")
                        .font(.manrope(12.5))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(Palette.warmDivider)
                HStack(spacing: 14) {
                    AnimatedWrenView(state: "idle", size: 34)
                    Text("The wren on your desktop opens Chirp when clicked. Hover it for "
                         + "a mic button — dictations started there show up in a speech "
                         + "bubble you can copy from.")
                        .font(.manrope(12.5))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .chirpSurface()
            .frame(maxWidth: 440, alignment: .leading)
        }
    }
}

// MARK: - Rows

private struct RadioDot: View {
    let selected: Bool
    var body: some View {
        Circle()
            .strokeBorder(selected ? Palette.sunsetDeep : Palette.warmDivider, lineWidth: 1.5)
            .frame(width: 18, height: 18)
            .overlay {
                if selected {
                    Circle().fill(Palette.sunsetDeep).frame(width: 9, height: 9)
                }
            }
    }
}

private struct PermissionRow: View {
    let icon: ChirpIcon
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ChirpIconView(icon: icon)
                .frame(width: 17, height: 17)
                .foregroundStyle(granted ? Palette.sunsetDeep : Palette.warmInkSoft)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(granted ? Palette.sunsetSoft : Palette.warmRowBorder))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.chirpDisplay(15, .medium)).foregroundStyle(Palette.warmInk)
                Text(detail)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.warmInkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                HStack(spacing: 5) {
                    ChirpIconView(icon: .check).frame(width: 11, height: 11)
                    Text("Allowed").font(.manrope(11.5, .semibold))
                }
                .foregroundStyle(Palette.sunsetDeep)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(granted ? Palette.sunsetSoft : Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .stroke(granted ? Color.clear : Palette.warmDivider, lineWidth: 1))
    }
}

private struct HotkeyOptionRow: View {
    let hotkey: HotkeyMonitor.Hotkey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Keycap(
                    text: hotkey.shortSymbol,
                    tint: selected ? Palette.accentInk : Palette.warmInkSoft,
                    background: selected ? Palette.accent : Palette.cardHover,
                    borderColor: selected ? Palette.accent : Palette.warmDivider)
                Text(hotkey.displayName)
                    .font(.chirpDisplay(14.5, .medium))
                    .foregroundStyle(Palette.warmInk)
                Spacer(minLength: 0)
                RadioDot(selected: selected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(selected ? Palette.sunsetSoft : Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(selected ? Palette.sunsetDeep : Palette.warmDivider, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// A live input-level meter: bars light up left-to-right as you get
/// louder, and each one's height tracks the level too.
///
/// Deliberately literal. The wren is charming but it animates on its own
/// schedule, so it can't tell you whether the microphone is picking
/// anything up — a meter that is visibly flat when you're silent and
/// visibly moving when you speak is the only thing here that actually
/// proves the input is live.
private struct MicLevelMeter: View {
    let level: CGFloat

    private static let barCount = 13

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                // Bars nearer the middle need less level to light, so
                // quiet speech moves the centre and only a shout reaches
                // the ends — the shape people already expect from a meter.
                let distance = abs(CGFloat(index) - CGFloat(Self.barCount - 1) / 2)
                let threshold = distance / CGFloat(Self.barCount)
                let lit = level > threshold
                let height = 6 + (lit ? (level - threshold) * 64 : 0)
                Capsule()
                    .fill(lit ? Palette.sunsetDeep : Palette.warmDivider)
                    .frame(width: 5, height: max(6, min(44, height)))
            }
        }
        .frame(height: 44)
        .animation(.chirpEase(0.08), value: level)
    }
}
