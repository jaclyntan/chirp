import SwiftUI

// MARK: - Dictionary
//
// Redesigned per the "Main" canvas (Dictionary.dc.html): same `GlassPanelPage`
// shell as Home/Insights/Scratchpad/Ask, warm palette instead of the shared
// dynamic `Palette`. Functionally unchanged from the previous pass: explains
// the mechanism up front, is searchable, shows a live count, and every row
// is genuinely editable/deletable.
//
// The tip banner, search field, add-row button, and related-link row are
// all bespoke to this page rather than the shared `PageTip`/`SearchField`/
// `AddRowButton`/`RelatedLink` components — those are still tuned for the
// old, not-yet-redesigned shared-component palette and are shared with pages that haven't been
// redesigned yet, so forking them here (rather than editing them in place)
// keeps this page exact without changing how they look anywhere else.
// `EditPairRow`/`DictListRow` below aren't shared with anything else
// (checked: nothing outside this file references them despite an older
// comment claiming Style did too), so those are edited in place instead.

struct DictionaryPage: View {
    @Binding var page: Page
    @State private var rows: [DictionaryRow] = []
    @State private var searchText = ""
    @State private var editingID: UUID?
    @State private var draftFrom = ""
    @State private var draftTo = ""
    @State private var addingNew = false
    @State private var showClearConfirm = false

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ThinScrollView's own doc comment (DesignSystem.swift) for why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchBar
                        .padding(.top, 18)
                    listCard
                        .padding(.top, 14)

                    if addingNew {
                        EditPairRow(
                            fromPlaceholder: "Say this…",
                            toPlaceholder: "Get this instead",
                            from: $draftFrom, to: $draftTo,
                            onSave: { commitNew() },
                            onCancel: { addingNew = false })
                            .padding(.top, 10)
                    } else {
                        addRowButton
                            .padding(.top, 10)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictionary")
                .font(.chirpDisplay(23, .regular))
                .foregroundStyle(Palette.warmInk)
            // The "matched by sound" caveat used to be its own tip
            // banner card below this. It's genuinely useful and
            // non-obvious, but it's one clause — it belongs in the
            // subtitle that was already here, not in a second box.
            Text("Spoken phrases replaced in every transcript — matched by sound, "
                 + "not exact wording.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchBar: some View {
        HStack {
            HStack(spacing: 8) {
                ChirpIconView(icon: .search)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(Palette.warmInkFaint)
                TextField("Search words and phrases…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInk)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .chirpSurface()
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
            .frame(width: 260)
            Spacer()
            Text(countLabel)
                .font(.manrope(11.5))
                .foregroundStyle(Palette.warmInkFaint)
            // Clearing one preset at a time is tedious when what you
            // actually mean is "none of these are mine".
            Button("Add starter set") {
                TextFormatter.addMissingStarterDictionary()
                load()
            }
            .buttonStyle(.plain)
            .font(.manrope(11.5, .medium))
            .foregroundStyle(Palette.sunsetDeep)
            .help("Adds the built-in capitalisation fixes you don't already have")
            if !rows.isEmpty {
                Button("Remove all") { showClearConfirm = true }
                    .buttonStyle(.plain)
                    .font(.manrope(11.5, .medium))
                    .foregroundStyle(Palette.danger)
            }
        }
        .confirmationDialog(
            "Remove all \(countLabel)?", isPresented: $showClearConfirm
        ) {
            Button("Remove all", role: .destructive) {
                rows.removeAll()
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone, though \"Add starter set\" brings the "
                 + "built-in entries back.")
        }
    }

    private var listCard: some View {
        Group {
            if visibleRows.isEmpty {
                Text(rows.isEmpty
                     ? "No words yet — add the names and jargon Chirp keeps getting wrong."
                     : "No matches.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                        if editingID == row.id {
                            EditPairRow(
                                fromPlaceholder: "Say this…",
                                toPlaceholder: "Get this instead",
                                from: $draftFrom, to: $draftTo,
                                onSave: { commitEdit(row) },
                                onCancel: { editingID = nil })
                        } else {
                            DictListRow(
                                from: row.spoken, to: row.replacement,
                                onEdit: {
                                    draftFrom = row.spoken
                                    draftTo = row.replacement
                                    editingID = row.id
                                },
                                onDelete: {
                                    rows.removeAll { $0.id == row.id }
                                    save()
                                })
                        }
                        if index != visibleRows.count - 1 {
                            Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .chirpSurface()
            }
        }
    }

    private var addRowButton: some View {
        Button {
            draftFrom = ""
            draftTo = ""
            addingNew = true
        } label: {
            HStack(spacing: 8) {
                ChirpIconView(icon: .plus).frame(width: 13, height: 13)
                Text("Add word or phrase").font(.manrope(12.5, .semibold))
            }
            .foregroundStyle(Palette.warmInkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(Palette.warmDivider))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
    }


    private var learnedCorrectionsCount: Int {
        LearnedStore.load().corrections.count
    }

    private var visibleRows: [DictionaryRow] {
        let term = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return rows }
        return rows.filter {
            $0.spoken.lowercased().contains(term) || $0.replacement.lowercased().contains(term)
        }
    }

    private var countLabel: String {
        let n = rows.count
        return "\(n) \(n == 1 ? "entry" : "entries")"
    }

    private func commitEdit(_ row: DictionaryRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let from = draftFrom.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { editingID = nil; return }
        rows[index].spoken = from
        rows[index].replacement = draftTo.trimmingCharacters(in: .whitespaces)
        editingID = nil
        save()
    }

    private func commitNew() {
        let from = draftFrom.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { addingNew = false; return }
        rows.append(DictionaryRow(
            spoken: from, replacement: draftTo.trimmingCharacters(in: .whitespaces)))
        addingNew = false
        save()
    }

    private func load() {
        rows = TextFormatter.loadDictionary()
            .sorted { $0.key < $1.key }
            .map { DictionaryRow(spoken: $0.key, replacement: $0.value) }
    }

    private func save() {
        var dictionary: [String: String] = [:]
        for row in rows {
            let spoken = row.spoken.trimmingCharacters(in: .whitespaces)
            if !spoken.isEmpty { dictionary[spoken] = row.replacement }
        }
        if let data = try? JSONEncoder().encode(dictionary) {
            try? data.write(to: TextFormatter.dictionaryURL, options: .atomic)
        }
    }
}

struct DictionaryRow: Identifiable {
    let id = UUID()
    var spoken: String
    var replacement: String
}

// MARK: - Shared row views

/// A read-only "spoken → replacement" row with hover-revealed actions.
struct DictListRow: View {
    let from: String
    let to: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Text(from)
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInkSoft)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 6) {
                Text("→").foregroundStyle(Palette.warmInkFaint)
                Text(to)
                    .font(.manrope(13, .medium))
                    .foregroundStyle(Palette.warmInk)
            }
            .font(.manrope(13))
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                IconButton(icon: .edit, size: 22, iconSize: 12, help: "Edit", action: onEdit)
                IconButton(icon: .trash, size: 22, iconSize: 12, help: "Delete", action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: hovering)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(hovering ? Palette.warmRowBorder : Color.clear))
        // See HomeView.swift's historyRow for why this is needed: a .clear
        // background makes SwiftUI treat the row's empty space as outside
        // the hoverable region until this forces the whole padded frame to
        // count, regardless of what's actually drawn there.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The inline add/edit form used by Dictionary.
struct EditPairRow: View {
    let fromPlaceholder: String
    let toPlaceholder: String
    @Binding var from: String
    @Binding var to: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(fromPlaceholder, text: $from)
                .textFieldStyle(.plain)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                .frame(width: 140)
                .onSubmit(onSave)
            Text("→").foregroundStyle(Palette.warmInkFaint)
            TextField(toPlaceholder, text: $to)
                .textFieldStyle(.plain)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                .onSubmit(onSave)
            IconButton(icon: .check, help: "Save", action: onSave)
            IconButton(icon: .plus, rotated: true, help: "Cancel", action: onCancel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }
}
