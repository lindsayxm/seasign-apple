import SwiftUI

/// Saved, opened by the asterisk on Today (`ref-img/00-save-list.png`): a
/// search field and a CATEGORY menu, then each saved article as its title in
/// caps, a `SOURCE · DATE` line with REMOVE, and its notes, with thin rules
/// between. A title opens the reading view.
///
/// Notes are typed into `SavedModel`, which holds what is typed until it is
/// written: a moment after typing stops, when a notes field loses focus,
/// when this screen closes and when the app leaves the foreground. If a
/// write fails the screen says so and Close asks before leaving.
struct SavedView: View {
    var timeZone: TimeZone

    @Environment(SavedModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ArticleQuery()
    @State private var reading: ReadingItem?
    @State private var confirming: RemovalConfirmation?
    @State private var closeBlocked = false
    @FocusState private var editing: UUID?

    var body: some View {
        let categories = model.categories
        let shown = model.visible(query)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(caps: "Saved")
                        .capsRelative(11, medium: true, tracking: 0.15)
                        .foregroundStyle(Palette.white)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    CloseMark { close() }
                }

                ArticleFilterBar(searchLabel: "Search saved", query: $query, categories: categories)
                    .padding(.top, 20)

                if let problem = model.problem {
                    SavedProblemLine(problem: problem) {
                        model.flushNotes()
                    } dismiss: {
                        model.problem = nil
                    }
                    .padding(.top, 16)
                }

                if shown.isEmpty {
                    emptyNote(isFiltered: !model.entries.isEmpty)
                        .padding(.top, 36)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isLast: index == shown.count - 1)
                    }
                    .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.charcoal.ignoresSafeArea())
        .statusBarCover()
        .preferredColorScheme(.dark)
        .onAppear {
            // Anything left unwritten from before is tried again.
            model.flushNotes()
        }
        .onDisappear {
            model.flushNotes()
        }
        .onChange(of: editing) { previous, _ in
            if let previous { model.flushNotes(for: previous) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flushNotes() }
        }
        .onChange(of: categories) { _, available in
            query.category = ArticleQuery.choice(query.category, among: available)
        }
        .removalConfirmation($confirming, model: model)
        .alert(
            Text(verbatim: "Your notes aren't saved yet"),
            isPresented: $closeBlocked
        ) {
            Button(role: .cancel) {
                model.flushNotes()
            } label: {
                Text(verbatim: "Try again")
            }
            Button {
                // The drafts stay in memory and show again when Saved opens.
                dismiss()
            } label: {
                Text(verbatim: "Close anyway")
            }
        } message: {
            Text(verbatim: "They couldn't be written to this phone. They're kept while Seasign is open, and saving is tried again each time you open Saved.")
        }
        .fullScreenCover(item: $reading) { item in
            ReadingView(item: item, timeZone: timeZone)
        }
    }

    private func close() {
        editing = nil
        if model.flushNotes() {
            dismiss()
        } else {
            closeBlocked = true
        }
    }

    // MARK: Rows

    private func row(_ entry: SavedEntry, isLast: Bool) -> some View {
        let item = entry.item
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                reading = item
            } label: {
                Text(caps: item.title)
                    .capsRelative(12.5, tracking: 0.15)
                    .lineSpacing(5)
                    .foregroundStyle(Palette.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AILabel.accessibility(title: item.title, isAI: item.isAI))
            .accessibilityHint("Opens the article's summary")

            HStack(alignment: .center, spacing: 12) {
                SourceDateLine(item: item, timeZone: timeZone)
                Spacer(minLength: 8)
                Button {
                    switch model.requestRemoval(entry.id) {
                    case .needsConfirmation:
                        confirming = RemovalConfirmation(entry)
                    default:
                        break
                    }
                } label: {
                    Text(caps: "Remove")
                        .capsRelative(10, tracking: 0.15)
                        .foregroundStyle(Palette.rule)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove " + item.title + " from Saved")
            }
            .padding(.top, 4)

            notesField(entry)
                .padding(.top, 14)

            if !isLast {
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                    .accessibilityHidden(true)
            }
        }
    }

    private func notesField(_ entry: SavedEntry) -> some View {
        let id = entry.id
        let text = model.notes(for: id)
        let left = SavedModel.notesLimit - text.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(caps: "Notes")
                .capsRelative(10, tracking: 0.15)
                .foregroundStyle(Palette.dimText)
                .accessibilityHidden(true)
            TextField(
                "",
                text: Binding(get: { model.notes(for: id) }, set: { model.editNotes($0, for: id) }),
                axis: .vertical
            )
            .font(.capsRelative(14))
            .foregroundStyle(Palette.white)
            .tint(Palette.dayWater)
            .lineLimit(1...12)
            .focused($editing, equals: id)
            .frame(minHeight: 44, alignment: .topLeading)
            .accessibilityLabel("Notes for " + entry.item.title)
            if left <= 200 {
                Text(verbatim: left == 0 ? "Notes are full (\(SavedModel.notesLimit) characters)" : "\(left) characters left")
                    .font(.capsRelative(11))
                    .foregroundStyle(left == 0 ? Palette.sun : Palette.dimText)
            }
        }
    }

    private func emptyNote(isFiltered: Bool) -> some View {
        Text(caps: isFiltered
            ? "No saved article matches."
            : "Nothing saved yet. Save an article from its summary or from the last 7 days.")
            .capsRelative(10, tracking: 0.15)
            .lineSpacing(4)
            .foregroundStyle(Palette.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
