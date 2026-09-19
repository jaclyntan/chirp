import SwiftUI

// MARK: - Help
//
// A flat reference, not a browsable widget. The previous pass nested two
// levels of accordion (category tiles, each holding collapsible
// questions) behind an intro banner, so reading any one answer cost two
// clicks and finding an answer you couldn't already name cost several —
// the opposite of what a help page is for. Everything is visible at once
// now: small section labels, plain rows, no tiles, no disclosure, no
// banner. The rail already says which page this is, so the page doesn't
// repeat it back.

struct HelpPage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page

    var body: some View {
        GlassPanelPage {
            ThinScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    section("Dictating") {
                        row("Push-to-talk",
                            "Hold \(app.hotkey.displayName), speak, release — the cleaned-up "
                            + "text lands at your cursor. A tap too short to count as a hold "
                            + "is ignored, so a stray touch never starts a recording.")
                        row("Hands-free",
                            "Tap \(app.hotkey.displayName) twice quickly to keep recording "
                            + "without holding it down. One more tap stops and transcribes.")
                        row("Paste the last transcript again",
                            "If focus moved mid-dictation and your text landed in the "
                            + "wrong place, a shortcut drops the most recent transcript "
                            + "wherever the cursor is now. Off by default — switch it on "
                            + "and pick a key in Settings.",
                            link: ("Settings", { page = .settings }))
                        row("Voice commands",
                            "Say “new line” or “new paragraph” mid-dictation to add line "
                            + "breaks. Punctuation is added automatically from your pauses "
                            + "and tone.")
                    }

                    section("Automatic") {
                        row("Snippets",
                            "Say a saved trigger phrase mid-dictation and it expands into "
                            + "the full saved text. Say it as one phrase — snippets match "
                            + "exact wording.",
                            link: ("Snippets", { page = .snippets }))
                        row("Learned corrections",
                            "Fix a transcript in History and Chirp learns the misheard-to-"
                            + "intended word for next time.",
                            link: ("Dictionary", { page = .dictionary }))
                        row("Recognition",
                            "Apple's on-device speech engine — instant, no download, no "
                            + "network. Terminals and code editors get your exact words "
                            + "untouched, with no cleanup applied.",
                            link: ("Settings", { page = .settings }))
                    }

                    section("Microphone modes") {
                        row("Standard vs Voice Isolation",
                            "macOS offers these in Control Centre while an app is using "
                            + "your mic — they're a system setting, not a Chirp one, and "
                            + "they change the audio before Chirp ever hears it. "
                            + "Standard applies light processing and keeps the room "
                            + "sound. Voice Isolation aggressively strips background "
                            + "noise and narrows onto your voice.")
                        row("Which to use",
                            "Standard is the safer default for dictation. Voice Isolation "
                            + "helps in genuinely noisy places — a café, a fan, traffic — "
                            + "but its processing can clip quiet consonants and the starts "
                            + "of words, which costs accuracy in a quiet room. Wide "
                            + "Spectrum is the opposite extreme: it keeps everything, "
                            + "including the noise, and is meant for recording a room "
                            + "rather than dictating into it.")
                        row("Where to change it",
                            "Start a dictation, then open Control Centre from the menu "
                            + "bar — a Mic Mode control appears there while the mic is "
                            + "in use. The choice sticks per app.")
                    }

                    section("Privacy") {
                        row("The one optional download",
                            "Live transcript while speaking uses a separate streaming "
                            + "model that's fetched the first time you enable it "
                            + "(~220 MB). It's off by default, and it's the only "
                            + "download Chirp makes beyond macOS's own speech assets.",
                            link: ("Settings", { page = .settings }))
                        row("Everything stays on this Mac",
                            "Recognition runs on Apple's on-device speech model, and every "
                            + "cleanup pass afterward — grammar, filler removal, your learned "
                            + "corrections — is deterministic, not AI, and just as local. The "
                            + "one exception is Notetaker's optional Summarize, which you "
                            + "trigger yourself per note.")
                    }

                    section("If something's wrong") {
                        row("Text landed on my clipboard instead of being typed",
                            "Accessibility isn't granted yet, so Chirp can't paste "
                            + "automatically — it copies the result instead. Press ⌘V now, "
                            + "then grant Accessibility so future dictations paste themselves.")
                        row("Holding the dictation key does nothing",
                            "The global hotkey needs Accessibility permission to be monitored "
                            + "system-wide. Grant it, then relaunch Chirp once.")
                        row("I can't find Chirp — there's no Dock icon",
                            "That's by design — Chirp runs as a menu bar app. Look for its "
                            + "icon in the menu bar, or click the floating wren if you have "
                            + "it enabled.")
                        row("The floating wren disappeared, or I don't want it",
                            "Settings has a \"Floating pet\" toggle — turn it back on there, "
                            + "or off if you'd rather use only the menu bar icon and hotkey.",
                            link: ("Settings", { page = .settings }))
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.manrope(10.5, .bold))
                .tracking(1.05)
                .foregroundStyle(Palette.warmInkFaint)
                .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    private func row(
        _ title: String, _ detail: String,
        link: (title: String, action: () -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.manrope(13.5, .semibold))
                .foregroundStyle(Palette.warmInk)
            Text(detail)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
            if let link {
                Button(action: link.action) {
                    Text("\(link.title) →")
                        .font(.manrope(12, .medium))
                        .foregroundStyle(Palette.sunsetDeep)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
        }
    }
}
