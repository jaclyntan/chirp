import AppKit
import SwiftUI

// MARK: - Notetaker
//
// Same `GlassPanelPage` shell and warm palette as every other page in this
// redesign. Structurally: a status card covering permissions and the
// current capture, and a Recents list below — same shape Scratchpad
// already established for "a list of past things this page produced,"
// not a new pattern invented just for this page.
//
// A full-width promo hero used to sit above the status card, restating
// what the header subtitle two lines above it already said. Removed with
// the rest of this app's page-opening banners: the page's actual content
// now starts at the top of the page.

struct NotetakerPage: View {
    @ObservedObject var app: AppDelegate
    @State private var selectedNote: MeetingNote?
    @State private var searchText = ""
    @State private var searchOpen = false
    /// Mirrors `Settings.browserMeetingDetectionEnabled` — plain
    /// `UserDefaults`, not `@Published`, so this needs its own state to
    /// actually re-render once the button below flips it, the same
    /// pattern Scratchpad's own hotkey chip already uses for the same
    /// reason.
    @State private var browserDetectionEnabled = Settings.browserMeetingDetectionEnabled

    private var controller: NotetakerController { app.notetaker }

    /// Title, calendar title, and transcript text all match — a note
    /// found by what was actually said, not just by its title, the same
    /// substring search `HistoryStore.matching` already does for History.
    private var filteredNotes: [MeetingNote] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return controller.notes }
        return controller.notes.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.calendarTitle?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.transcriptText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        GlassPanelPage {
            ThinScrollView(bottomInset: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    statusCard.padding(.top, 20)
                    recentsHeader.padding(.top, 28)
                    recentsList.padding(.top, 10)
                }
            }
        }
        .onAppear { controller.refreshScreenRecordingStatus() }
        .sheet(item: $selectedNote) { note in
            // Only `note.id` is actually used below — `MeetingDetailSheet`
            // re-reads the live note from `controller` itself on every
            // render, rather than holding the snapshot from the moment the
            // sheet opened, so a rename or a checkbox toggle inside it
            // shows up immediately instead of only after closing and
            // reopening.
            MeetingDetailSheet(controller: controller, noteID: note.id) { selectedNote = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notetaker")
                .font(.chirpDisplay(23, .regular))
                .foregroundStyle(Palette.warmInk)
            Text("Automatic notes for your calls — captured, transcribed, and summarized on-device.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusCard: some View {
        if !controller.screenRecordingAuthorized {
            permissionCard
        } else {
            captureCard
        }
    }

    private var permissionCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Palette.warmRowBorder)
                ChirpIconView(icon: .notetaker)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording access needed")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("Notetaker uses this only to hear the other side of a call through the "
                     + "meeting app's own audio — it never records your screen.")
                    .font(.manrope(12))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Enable in System Settings") {
                    controller.requestScreenRecordingAccess()
                }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .chirpSurface()
    }

    private var captureCard: some View {
        HStack(spacing: 14) {
            switch controller.state {
            case .idle:
                statusDot(color: Palette.warmInkFainter)
                VStack(alignment: .leading, spacing: 2) {
                    Text(idleStatusLabel)
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    Text(controller.isDiarizerReady
                         ? "Ready — captures your mic and, if you start it, the call's own audio."
                         : "Preparing the on-device speaker model — capture still works meanwhile.")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkFaint)
                    if !controller.detector.calendarAuthorized {
                        // Entirely optional — capture works without this —
                        // so this asks for the permission on request, not
                        // automatically at launch the way Mic does: a
                        // calendar-access prompt with no clear trigger the
                        // user just did reads as Chirp reaching for more
                        // than it needs.
                        Button("Connect Calendar for real titles & speaker names") {
                            Task { await controller.detector.requestCalendarAccess() }
                        }
                        .buttonStyle(.plain)
                        .font(.manrope(11, .medium))
                        .foregroundStyle(Palette.sunsetDeep)
                        .padding(.top, 2)
                    }
                    if !browserDetectionEnabled {
                        // Off by default and turned on here rather than
                        // silently — this means Chirp periodically reads
                        // the active browser tab's URL while a browser is
                        // frontmost, purely to check it against known
                        // meeting-link patterns, so it's worth the user
                        // actually choosing it rather than inheriting it.
                        Button("Also detect meetings in your browser (Chrome, Safari, Edge, Arc, Brave)") {
                            Settings.browserMeetingDetectionEnabled = true
                            browserDetectionEnabled = true
                        }
                        .buttonStyle(.plain)
                        .font(.manrope(11, .medium))
                        .foregroundStyle(Palette.sunsetDeep)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Button("Start Notetaker") {
                    controller.start(app: controller.detector.activeMeetingApp)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .font(.manrope(12.5, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.navActivePill, in: RoundedRectangle(cornerRadius: Radius.sm))

            case .capturing(let startedAt):
                statusDot(color: Palette.sunsetDeep, pulsing: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening…")
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    Text("Started \(startedAt, format: .dateTime.hour().minute())")
                        .font(.manrope(11.5))
                        .foregroundStyle(Palette.warmInkFaint)
                    // A rough, live-updating caption of what's being
                    // picked up on each side — not the real transcript
                    // (that's diarized properly once capture stops), just
                    // reassurance Chirp is actually hearing the call, the
                    // same role a live preview plays during normal
                    // dictation. Head-truncated so the most recent words
                    // stay visible as the line keeps growing.
                    if !controller.liveTranscriptYou.isEmpty {
                        liveLine("You", controller.liveTranscriptYou)
                    }
                    if !controller.liveTranscriptOthers.isEmpty {
                        liveLine("Them", controller.liveTranscriptOthers)
                    }
                }
                Spacer(minLength: 0)
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(GhostButtonStyle())
                Button("Stop & Save") { controller.stop() }
                    .buttonStyle(DangerButtonStyle())

            case .processing:
                statusDot(color: Palette.warmInkFainter)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing and summarizing…")
                        .font(.manrope(12.5))
                        .foregroundStyle(Palette.warmInkSoft)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .chirpSurface()
        .overlay(alignment: .bottom) {
            if let error = controller.lastError {
                Text(error)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: 26)
            }
        }
    }

    /// "Google Meet looks like it's running" for a browser match, same as
    /// a native app's own name — the raw browser name ("Chrome looks like
    /// it's running") would say nothing useful about whether there's
    /// actually a call to capture.
    private var idleStatusLabel: String {
        guard let app = controller.detector.activeMeetingApp else { return "No meeting detected" }
        let name = controller.detector.activeMeetingServiceName ?? app.displayName
        return "\(name) looks like it's running"
    }

    private func statusDot(color: Color, pulsing: Bool = false) -> some View {
        PulsingDot(color: color, size: 9, maxScale: 2.0, active: pulsing)
            .frame(width: 20, height: 20)
    }

    private func liveLine(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .font(.manrope(10.5, .semibold))
                .foregroundStyle(Palette.warmInkFainter)
            Text(text)
                .font(.manrope(11))
                .foregroundStyle(Palette.warmInkSoft)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.top, 2)
    }

    private var recentsHeader: some View {
        HStack(spacing: 10) {
            Text("Recents")
                .font(.chirpDisplay(15.5, .medium))
                .foregroundStyle(Palette.warmInk)
            Spacer()
            if searchOpen {
                HStack(spacing: 8) {
                    ChirpIconView(icon: .search)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Palette.warmInkFaint)
                    TextField("Search meetings", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.manrope(12.5))
                        .foregroundStyle(Palette.warmInk)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                .frame(width: 200)
            } else {
                Text("\(controller.notes.count) note\(controller.notes.count == 1 ? "" : "s")")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            IconButton(icon: searchOpen ? .plus : .search,
                       rotated: searchOpen,
                       help: searchOpen ? "Close search" : "Search meetings") {
                searchOpen.toggle()
                if !searchOpen { searchText = "" }
            }
        }
    }

    private var recentsList: some View {
        Group {
            if controller.notes.isEmpty {
                Text("No meetings captured yet — start Notetaker before or during a call.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if filteredNotes.isEmpty {
                Text("No meetings match “\(searchText)”.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredNotes.enumerated()), id: \.element.id) { index, note in
                        MeetingRow(note: note, isFirst: index == 0) { selectedNote = note }
                    }
                }
                .chirpSurface()
            }
        }
    }
}

private struct MeetingRow: View {
    let note: MeetingNote
    let isFirst: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title)
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                        .lineLimit(1)
                    Text(note.summary?.isEmpty == false ? note.summary! : "\(note.wordCount) words transcribed")
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(note.date, format: .dateTime.month(.abbreviated).day())
                        .font(.manrope(11.5, .semibold))
                        .foregroundStyle(Palette.warmInkSoft)
                    Text(durationLabel)
                        .font(.manrope(11))
                        .foregroundStyle(Palette.warmInkFaint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(hovering ? Palette.warmRowBorder : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(Palette.warmRowBorder).frame(height: 1) }
        }
    }

    private var durationLabel: String {
        let minutes = Int(note.duration / 60)
        return minutes < 1 ? "< 1 min" : "\(minutes) min"
    }
}

// MARK: - Detail sheet

private struct MeetingDetailSheet: View {
    @ObservedObject var controller: NotetakerController
    let noteID: UUID
    let onDismiss: () -> Void

    @State private var renamingSpeaker: Int?
    @State private var renameText = ""
    @State private var justCopied = false

    /// Re-read from `controller.notes` on every render rather than held as
    /// a frozen snapshot — a rename or a checkbox toggle updates `notes`
    /// through the store, and this makes that show up in the still-open
    /// sheet immediately. Nil only in the brief moment between "user
    /// deleted this note" and the sheet actually dismissing.
    private var note: MeetingNote? { controller.notes.first { $0.id == noteID } }

    var body: some View {
        Group {
            if let note {
                content(for: note)
            } else {
                Color.clear.onAppear(perform: onDismiss)
            }
        }
        .frame(width: 580, height: 640)
        .background(Palette.paper)
        .environment(\.colorScheme, .light)
    }

    private func content(for note: MeetingNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader(for: note)
            Rectangle().fill(Palette.warmDivider).frame(height: 1)
            ThinScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let summary = note.summary, !summary.isEmpty {
                        section("Summary") {
                            Text(summary)
                                .font(.manrope(13))
                                .foregroundStyle(Palette.warmInk)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !note.decisions.isEmpty {
                        section("Decisions") { bulletList(note.decisions) }
                    }
                    if !note.actionItems.isEmpty {
                        section("Action items") { actionItemsList(note.actionItems) }
                    }
                    section("Transcript") { transcript(for: note) }
                }
                .padding(24)
            }
        }
    }

    private func sheetHeader(for note: MeetingNote) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.manrope(16, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("\(note.date.formatted(date: .abbreviated, time: .shortened)) · \(note.wordCount) words")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            Spacer()
            IconButton(icon: justCopied ? .check : .copy, tint: justCopied ? Palette.sunsetDeep : nil,
                       help: "Copy note") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(note.formattedNoteText, forType: .string)
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    justCopied = false
                }
            }
            IconButton(icon: .trash, help: "Delete") {
                controller.delete(id: note.id)
                onDismiss()
            }
            IconButton(icon: .plus, rotated: true, help: "Close", action: onDismiss)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.manrope(10.5, .bold))
                .kerning(0.6)
                .foregroundStyle(Palette.warmInkFaint)
            content()
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Palette.sunsetDeep).frame(width: 4, height: 4).padding(.top, 6)
                    Text(item)
                        .font(.manrope(13))
                        .foregroundStyle(Palette.warmInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Same shape as `bulletList` but each row is a checkbox toggling that
    /// item's own `isDone` through `controller` — action items used to be
    /// read-only text with no way to mark one handled.
    private func actionItemsList(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                Button {
                    controller.toggleActionItem(noteID: noteID, itemID: item.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        // No dedicated checkbox glyph in `ChirpIcons` — a
                        // small rounded square reusing the existing `.check`
                        // mark, same "reuse what's already in the icon set"
                        // rule the rest of this page follows.
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(item.isDone ? Palette.sunsetDeep : Color.clear)
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(item.isDone ? Color.clear : Palette.warmInkFainter, lineWidth: 1.4)
                            if item.isDone {
                                ChirpIconView(icon: .check)
                                    .frame(width: 8, height: 8)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 14, height: 14)
                        .padding(.top, 1)
                        Text(item.text)
                            .font(.manrope(13))
                            .foregroundStyle(item.isDone ? Palette.warmInkFaint : Palette.warmInk)
                            .strikethrough(item.isDone, color: Palette.warmInkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Distinct speakers in this note, in first-appearance order — what
    /// drives both the transcript's own speaker headers and which ones
    /// `renameSpeakerRow` offers to rename. Index 0 ("You") is skipped:
    /// it's never ambiguous, so there's nothing to rename it to.
    private func speakerIndices(for note: MeetingNote) -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for segment in note.segments where segment.speakerIndex != 0 {
            if seen.insert(segment.speakerIndex).inserted { ordered.append(segment.speakerIndex) }
        }
        return ordered
    }

    private func transcript(for note: MeetingNote) -> some View {
        let indices = speakerIndices(for: note)
        return VStack(alignment: .leading, spacing: 14) {
            if !indices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(indices, id: \.self) { renameSpeakerRow($0, in: note) }
                }
                .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(note.segments) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(segment.speakerName ?? "Speaker \(segment.speakerIndex + 1)")
                            .font(.manrope(11.5, .semibold))
                            .foregroundStyle(segment.speakerIndex == 0 ? Palette.sunsetDeep : Palette.warmInkSoft)
                        Text(segment.text)
                            .font(.manrope(13))
                            .foregroundStyle(Palette.warmInk)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func renameSpeakerRow(_ index: Int, in note: MeetingNote) -> some View {
        let currentName = note.segments.first { $0.speakerIndex == index }?.speakerName
        return HStack(spacing: 8) {
            if renamingSpeaker == index {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.manrope(12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .chirpSurface()
                    .frame(width: 140)
                    .onSubmit {
                        controller.rename(noteID: note.id, speakerIndex: index, to: renameText)
                        renamingSpeaker = nil
                    }
                Button("Save") {
                    controller.rename(noteID: note.id, speakerIndex: index, to: renameText)
                    renamingSpeaker = nil
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Text(currentName ?? "Speaker \(index + 1)")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.warmInkSoft)
                Button("Rename") {
                    renameText = currentName ?? ""
                    renamingSpeaker = index
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }
}
