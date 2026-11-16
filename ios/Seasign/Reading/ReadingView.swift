import SwiftUI

/// One headline opened from Today (`ref-img/00-reading.png`): the source,
/// category and date, the title, the site's own excerpt, and a way to read
/// the article on the site.
///
/// Everything shown here except the labels came from a website, so it is
/// shown as plain text only (`Text(verbatim:)`, `Text(caps:)`). The article is
/// opened with the system's `openURL`, in the user's default browser, and
/// only when `ArticleLink.url` accepts the link (https with a host). It is
/// never loaded in a web view inside the app.
struct ReadingView: View {
    var entry: FeedEntry
    /// The zone the date is shown in (the zip's when known, else the phone's).
    var timeZone: TimeZone

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
                    saveMark
                }
                .padding(.top, 14)

                Text(verbatim: entry.title)
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
    }

    // MARK: Parts

    private var details: some View {
        let date = ReadingDate(entry: entry, timeZone: timeZone)
        return VStack(alignment: .leading, spacing: 10) {
            detailRow("Publication", entry.source)
            detailRow("Category", entry.category)
            detailRow(date.label, date.value)
        }
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

    /// The save control of the mockup. Saving comes with Saved (task 9); until
    /// then it is shown dimmed and does nothing.
    private var saveMark: some View {
        LineIconView(icon: .saved, size: 22, lineWidth: 1.5)
            .foregroundStyle(Palette.rule)
            .frame(width: 44, height: 44)
            .background(Palette.rule.opacity(0.25))
            .opacity(0.6)
            .accessibilityElement()
            .accessibilityLabel("Save")
            .accessibilityValue("Not available yet")
    }

    @ViewBuilder
    private var summary: some View {
        if let excerpt = entry.excerpt, !excerpt.isEmpty {
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
        if let url = ArticleLink.url(entry.link) {
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
