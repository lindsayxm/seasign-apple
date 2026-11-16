import SwiftUI

/// The 7-day history, opened by `>>` on Today: every item that has been in
/// the feed in the last 7 days, newest first, so an article that was not
/// saved can still be found after the feed has moved on. Search, a category
/// filter, a save control per row; a title opens the reading view.
///
/// It reads the cached feed items (`FeedModel.entries`, cache store) and
/// whether each is saved (`SavedModel`, user store). Titles and sources came
/// from websites and are shown verbatim only.
struct HistoryView: View {
    /// The zone dates are shown in (the zip's when known, else the phone's).
    var timeZone: TimeZone

    @Environment(FeedModel.self) private var feed
    @Environment(SavedModel.self) private var saved
    @Environment(\.dismiss) private var dismiss

    @State private var query = ArticleQuery()
    @State private var reading: ReadingItem?
    @State private var confirming: RemovalConfirmation?

    var body: some View {
        let now = Date()
        let categories = HistoryList.categories(feed.entries, now: now)
        let shown = HistoryList.visible(feed.entries, now: now, query: query)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header

                ArticleFilterBar(searchLabel: "Search the last 7 days", query: $query, categories: categories)
                    .padding(.top, 20)

                if let problem = saved.problem {
                    SavedProblemLine(problem: problem) {
                        saved.flushNotes()
                    } dismiss: {
                        saved.problem = nil
                    }
                    .padding(.top, 16)
                }

                if shown.isEmpty {
                    emptyNote(isFiltered: !feed.entries.isEmpty && query != ArticleQuery())
                        .padding(.top, 36)
                } else {
                    ForEach(shown) { entry in
                        row(ReadingItem(entry))
                    }
                    .padding(.top, 12)
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
        .onChange(of: categories) { _, available in
            query.category = ArticleQuery.choice(query.category, among: available)
        }
        .removalConfirmation($confirming, model: saved)
        .fullScreenCover(item: $reading) { item in
            ReadingView(item: item, timeZone: timeZone)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(caps: "Last 7 days")
                .capsRelative(11, medium: true, tracking: 0.15)
                .foregroundStyle(Palette.white)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            CloseMark { dismiss() }
        }
    }

    private func row(_ item: ReadingItem) -> some View {
        let isSaved = saved.isSaved(item.link)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                reading = item
            } label: {
                Text(caps: item.title)
                    .capsRelative(12, tracking: 0.15)
                    .lineSpacing(5)
                    .foregroundStyle(Palette.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.title)
            .accessibilityHint("Opens the article's summary")
            .padding(.top, 14)

            HStack(alignment: .center, spacing: 12) {
                SourceDateLine(item: item, timeZone: timeZone)
                Spacer(minLength: 8)
                saveButton(item, isSaved: isSaved)
            }

            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)
                .padding(.top, 10)
                .accessibilityHidden(true)
        }
    }

    private func saveButton(_ item: ReadingItem, isSaved: Bool) -> some View {
        Button {
            if saved.toggleSave(item) == .needsConfirmation {
                confirming = RemovalConfirmation(link: item.link, in: saved)
            }
        } label: {
            HStack(spacing: 8) {
                Text(caps: isSaved ? "Saved" : "Save")
                    .capsRelative(10, medium: isSaved, tracking: 0.15)
                LineIconView(icon: .saved, size: 12, lineWidth: 1.3)
            }
            .foregroundStyle(isSaved ? Palette.white : Palette.dimText)
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SaveMark.label(isSaved: isSaved, title: item.title))
        .accessibilityValue(isSaved ? "Saved" : "Not saved")
    }

    private func emptyNote(isFiltered: Bool) -> some View {
        Text(caps: isFiltered
            ? "Nothing from the last 7 days matches."
            : "Nothing has been in your feed in the last 7 days. Follow sites in Settings.")
            .capsRelative(10, tracking: 0.15)
            .lineSpacing(4)
            .foregroundStyle(Palette.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The thin X in the top right of History and Saved that closes the screen.
struct CloseMark: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .thin))
                .foregroundStyle(Palette.dimText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
