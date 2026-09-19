import SwiftUI

// MARK: - Snippets
//
// Redesigned per the "Main" canvas (Snippets.dc.html): same `GlassPanelPage`
// shell as Dictionary, warm palette instead of the shared dynamic
// `Palette`. Functionally unchanged — searchable list with a live count
// and inline add/edit/delete.
//
// The search field, add-row button, and related-link row are bespoke to
// this page rather than the shared `SearchField`/`AddRowButton`/
// `RelatedLink` components, matching Dictionary's own reasoning: those
// are still tuned for the old, not-yet-redesigned shared-component
// palette and shared with pages that haven't been redesigned yet.
//
// The page used to open with a full-width promo hero (three illustrative
// trigger/expansion examples) plus a tip banner, above the actual list.
// Both are gone: what a snippet is and how matching works is Help's job,
// the empty list already prompts for a first one, and a page whose own
// content started two screens down was the single biggest thing making
// this app feel heavier than it is.

struct SnippetsPage: View {
    @Binding var page: Page
    @State private var snippets: [Snippet] = []
    @State private var searchText = ""
    @State private var editingID: UUID?
    @State private var draftTrigger = ""
    @State private var draftExpansion = ""
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
                        snippetEditRow(onSave: commitNew, onCancel: { addingNew = false })
                            .padding(.top, 10)
                    } else {
                        addRowButton
                            .padding(.top, 10)
                    }
                }
            }
        }
        .onAppear { snippets = SnippetStore.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snippets")
                .font(.chirpDisplay(23, .regular))
                .foregroundStyle(Palette.warmInk)
            Text("Say a trigger phrase, get a saved block pasted instead — matched "
                 + "on exact wording.")
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
                TextField("Search snippets…", text: $searchText)
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
            Button("Add starter set") {
                SnippetStore.addMissingStarters()
                snippets = SnippetStore.load()
            }
            .buttonStyle(.plain)
            .font(.manrope(11.5, .medium))
            .foregroundStyle(Palette.sunsetDeep)
            .help("Adds the built-in example snippets you don't already have")
            if !snippets.isEmpty {
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
                snippets.removeAll()
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone, though \"Add starter set\" brings the "
                 + "built-in examples back.")
        }
    }

    private var listCard: some View {
        Group {
            if visible.isEmpty {
                Text(snippets.isEmpty
                     ? "No snippets yet — add signatures, addresses, or canned replies."
                     : "No matches.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, snippet in
                        if editingID == snippet.id {
                            snippetEditRow(onSave: { commitEdit(snippet) },
                                           onCancel: { editingID = nil })
                        } else {
                            SnippetRow(
                                snippet: snippet,
                                onEdit: {
                                    draftTrigger = snippet.trigger
                                    draftExpansion = snippet.expansion
                                    editingID = snippet.id
                                },
                                onDelete: {
                                    snippets.removeAll { $0.id == snippet.id }
                                    save()
                                })
                        }
                        if index != visible.count - 1 {
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

    private func snippetEditRow(onSave: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Say this…", text: $draftTrigger)
                .textFieldStyle(.plain)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
                .frame(width: 140)
            Text("→").foregroundStyle(Palette.warmInkFaint).padding(.top, 8)
            TextEditor(text: $draftExpansion)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInk)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 60)
                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))
            IconButton(icon: .check, help: "Save", action: onSave).padding(.top, 2)
            IconButton(icon: .plus, rotated: true, help: "Cancel", action: onCancel).padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    private var addRowButton: some View {
        Button {
            draftTrigger = ""
            draftExpansion = ""
            addingNew = true
        } label: {
            HStack(spacing: 8) {
                ChirpIconView(icon: .plus).frame(width: 13, height: 13)
                Text("Add snippet").font(.manrope(12.5, .semibold))
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


    private var visible: [Snippet] {
        let term = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return snippets }
        return snippets.filter {
            $0.trigger.lowercased().contains(term) || $0.expansion.lowercased().contains(term)
        }
    }

    private var countLabel: String {
        "\(snippets.count) \(snippets.count == 1 ? "snippet" : "snippets")"
    }

    private func commitEdit(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let trigger = draftTrigger.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else { editingID = nil; return }
        snippets[index].trigger = trigger
        snippets[index].expansion = draftExpansion
        editingID = nil
        save()
    }

    private func commitNew() {
        let trigger = draftTrigger.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !draftExpansion.isEmpty else { addingNew = false; return }
        snippets.append(Snippet(trigger: trigger, expansion: draftExpansion))
        addingNew = false
        save()
    }

    private func save() {
        SnippetStore.save(snippets.filter {
            !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty
        })
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(snippet.trigger)
                .font(.manrope(13, .medium))
                .foregroundStyle(Palette.sunsetDeep)
                .frame(width: 140, alignment: .leading)
            Text(snippet.expansion.replacingOccurrences(of: "\n", with: " "))
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInk)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Always visible, not hover-only like the actions beside it —
            // this is the one thing on the row that says whether a
            // snippet is actually earning its keep, not just a control to
            // reveal on demand.
            if snippet.useCount > 0 {
                Text("\(snippet.useCount) \(snippet.useCount == 1 ? "use" : "uses")")
                    .font(.manrope(11))
                    .foregroundStyle(Palette.warmInkFaint)
                    .lineLimit(1)
                    .frame(width: 46, alignment: .trailing)
            }
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
