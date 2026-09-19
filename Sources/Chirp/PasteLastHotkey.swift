import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Defaults for the paste-last shortcut.
///
/// ⌥V — deliberately adjacent to ⌘V, since it does the same job for the
/// same text. ⌘⇧V is taken by "paste and match style" in enough apps to
/// be a bad neighbour.
///
/// The monitoring itself lives in `ConsumingHotkeyMonitor`: a character
/// key has to be swallowed, or it fires the shortcut *and* types itself
/// (⌥V produces `√`).
enum PasteLastHotkeyMonitor {
    static let defaultKeyCode = UInt16(kVK_ANSI_V)
    static let defaultModifiers: NSEvent.ModifierFlags = [.option]
}

// MARK: - Paste-last shortcut editor
//
// A near-copy of Notetaker's own rebind sheet rather than a shared
// component: the two differ only in which `Settings` pair they write and
// what the copy says, and a generic editor parameterised over both would
// be longer than the duplicate while making each one harder to read.

private final class PasteLastHotkeyCaptureModel: ObservableObject {
    @Published var isRecording = false
    @Published var pendingKeyCode = Settings.pasteLastHotkeyKeyCode
    @Published var pendingModifiers = Settings.pasteLastHotkeyModifiers

    private var monitor: Any?

    func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            stopRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift])
        guard !modifiers.isEmpty else { return }

        pendingKeyCode = event.keyCode
        pendingModifiers = modifiers
        Settings.pasteLastHotkeyKeyCode = event.keyCode
        Settings.pasteLastHotkeyModifiers = modifiers
        stopRecording()
    }
}

/// The rebind sheet for the paste-last shortcut, opened from its row in
/// Settings → Dictation.
struct PasteLastHotkeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = PasteLastHotkeyCaptureModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste last transcript")
                .font(.manrope(16, .semibold))
                .foregroundStyle(Palette.warmInk)
            Text("Press a key combination to paste your most recent transcript at the cursor.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: capture.startRecording) {
                HStack {
                    if capture.isRecording {
                        Text("Press a key combination…")
                            .font(.manrope(12.5))
                            .foregroundStyle(Palette.warmInkFaint)
                    } else {
                        HStack(spacing: 3) {
                            ForEach(KeyComboLabel.symbols(for: capture.pendingModifiers), id: \.self) { symbol in
                                keycap(symbol)
                            }
                            keycap(KeyComboLabel.keyName(for: capture.pendingKeyCode))
                        }
                    }
                    Spacer()
                    ChirpIconView(icon: .edit)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Palette.warmInkFaint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .stroke(capture.isRecording ? Palette.sunsetDeep : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.manrope(12.5, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Palette.navActivePill, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 340)
        .environment(\.colorScheme, .light)
        .onDisappear { capture.stopRecording() }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.manrope(11, .semibold))
            .foregroundStyle(Palette.warmInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
    }
}
