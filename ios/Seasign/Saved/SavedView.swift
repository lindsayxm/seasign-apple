import SwiftUI

/// Saved, the SAVE page, one of the four main pages (`MainTabsView`;
/// `ref-img/00-save-list.png`): a search field and a CATEGORY menu, then each
/// saved article as its title in caps, a `SOURCE · DATE` line with REMOVE,
/// and its notes, with thin rules between. A title opens the reading view.
/// `∀` at the top right opens History (the last 7 days) over it; the tiles
/// are the way back, so there is no close mark.
///
/// Notes are typed into `SavedModel`, which holds what is typed until it is
/// written: a moment after typing stops, when a notes field loses focus,
/// when this page is left and when the app leaves the foreground. If a
/// write fails the page says so, and a tile asks before leaving
/// (`MainTabs.select`).
struct SavedView: View {
    var timeZone: TimeZone

    @Environment(SavedModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ArticleQuery()
    @State private var reading: ReadingItem?
    @State private var confirming: RemovalConfirmation?
    /// History (the last 7 days) is open over Saved.
    @State private var showsHistory = false
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
                    HistoryMark { showsHistory = true }
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
        .fullScreenCover(item: $reading) { item in
            ReadingView(item: item, timeZone: timeZone)
        }
        .fullScreenCover(isPresented: $showsHistory) {
            HistoryView(timeZone: timeZone)
        }
        .onChange(of: showsHistory) { _, open in
            // Notes typed so far are written before History covers them.
            if open {
                editing = nil
                model.flushNotes()
            }
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

/// `∀`, for all publications, at the top right of Saved: opens History,
/// every article from the last 7 days.
struct HistoryMark: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            LineIconView(icon: .allPublications, size: 17, lineWidth: 1.4)
                .foregroundStyle(Palette.dimText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Last 7 days")
        .accessibilityHint("Opens every article from the last 7 days")
    }
}
