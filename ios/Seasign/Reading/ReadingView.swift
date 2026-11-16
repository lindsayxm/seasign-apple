import SwiftUI

/// One article (`ref-img/00-reading.png`), opened from Today, History or
/// Saved: the source, category and date, the save mark, the title, the
/// site's own excerpt, and a way to read the article on the site.
///
/// It is driven by a `ReadingItem`, which a cached feed item and a saved item
/// both produce, so a saved article opens after its feed item is gone.
///
/// Everything shown here except the labels came from a website, so it is
/// shown as plain text only (`Text(verbatim:)`, `Text(caps:)`). The article is
/// opened with the system's `openURL`, in the user's default browser, and
/// only when `ArticleLink.url` accepts the link (https with a host). It is
/// never loaded in a web view inside the app.
struct ReadingView: View {
    var item: ReadingItem
    /// The zone the date is shown in (the zip's when known, else the phone's).
    var timeZone: TimeZone

    @Environment(SavedModel.self) private var saved
    /// The phone's 12- or 24-hour setting, for the published time.
    @Environment(\.clockStyle) private var clockStyle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var confirming: RemovalConfirmation?

    static let noExcerptNote = "This site doesn't publish a summary of its articles. Read the article on the site itself."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text(caps: "Close")
                            .capsRelative(11)
                            .foregroundStyle(Palette.dimText)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                details
                    .padding(.top, 12)

                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
                    .padding(.top, 28)

                HStack {
                    Spacer()
                    SaveMark(isSaved: saved.isSaved(item.link), title: item.title) {
                        if saved.toggleSave(item) == .needsConfirmation {
                            confirming = RemovalConfirmation(link: item.link, in: saved)
                        }
                    }
                }
                .padding(.top, 14)

                if let problem = saved.problem, problem != .notesNotSaved {
                    SavedProblemLine(problem: problem, retry: {}, dismiss: { saved.problem = nil })
                        .padding(.top, 8)
                }

                Text(verbatim: item.title)
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 18)

                summary
                    .padding(.top, 26)

                readOnSite
                    .padding(.top, 36)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.charcoal.ignoresSafeArea())
        .statusBarCover()
        .preferredColorScheme(.dark)
        .removalConfirmation($confirming, model: saved)
    }

    // MARK: Parts

    private var details: some View {
        let date = ReadingDate(item: item, timeZone: timeZone, clock: clockStyle)
        return VStack(alignment: .leading, spacing: 10) {
            if item.isAI {
                aiBanner
            }
            detailRow("Publication", item.source)
            if item.isAI {
                // An AI-found article has no category of the user's: say
                // which interest it matched and who found it.
                detailRow("Found by", AILabel.foundBy(item.provider))
                if let interest = item.interest, !interest.isEmpty {
                    detailRow("Interest", interest)
                }
            } else {
                detailRow("Category", item.category)
            }
            detailRow(date.label, date.value)
        }
    }

    /// The AI mark with a line saying what it means.
    private var aiBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            AIMark(size: 10, color: Palette.white)
            Text(caps: "Found by AI search on your interests")
                .capsRelative(9.5, tracking: 0.12)
                .foregroundStyle(Palette.dimText)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AILabel.spoken + " article, found by AI search on your interests")
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(caps: label)
                .capsRelative(10, tracking: 0.12)
                .foregroundStyle(Palette.dimText)
            Spacer(minLength: 8)
            Text(caps: value)
                .capsRelative(10.5, tracking: 0.1)
                .foregroundStyle(Palette.white)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var summary: some View {
        if let excerpt = item.excerpt, !excerpt.isEmpty {
            Text(verbatim: excerpt)
                .font(.system(.body, design: .serif))
                .lineSpacing(8)
                .foregroundStyle(Palette.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(caps: Self.noExcerptNote)
                .capsRelative(10, tracking: 0.12)
                .lineSpacing(4)
                .foregroundStyle(Palette.dimText)
        }
    }

    @ViewBuilder
    private var readOnSite: some View {
        if let url = ArticleLink.url(item.link) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    openURL(url)
                } label: {
                    Text(caps: "Read on original site")
                        .capsRelative(11, medium: true, tracking: 0.15)
                        .foregroundStyle(Palette.white)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the article in your browser")
                if let host = url.host() {
                    Text(verbatim: host)
                        .font(.capsRelative(9.5))
                        .foregroundStyle(Palette.dimText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
