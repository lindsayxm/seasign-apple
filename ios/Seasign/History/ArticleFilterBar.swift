import SwiftUI

/// The search field and CATEGORY menu at the top of History and Saved
/// (`ref-img/00-save-list.png`): two underlined fields side by side, stacked
/// at accessibility text sizes.
struct ArticleFilterBar: View {
    /// "Search saved", "Search the last 7 days"; shown in caps and spoken as the field's label.
    var searchLabel: String
    @Binding var query: ArticleQuery
    /// The categories present in the list, each once.
    var categories: [String]

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 18))
        layout {
            searchField
            categoryMenu
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 128)
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(searchLabel)
            HStack(spacing: 4) {
                TextField("", text: $query.text)
                    .font(.capsRelative(16))
                    .foregroundStyle(Palette.white)
                    .tint(Palette.dayWater)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .frame(minHeight: 44)
                    .accessibilityLabel(searchLabel)
                if !query.text.isEmpty {
                    Button {
                        query.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.rule)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            rule
        }
    }

    private var categoryMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Category")
            Menu {
                Picker(selection: $query.category) {
                    Text(verbatim: "All").tag(String?.none)
                    // The user's own category names, shown verbatim.
                    ForEach(categories, id: \.self) { category in
                        Text(verbatim: category).tag(String?.some(category))
                    }
                } label: {
                    Text(verbatim: "Category")
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: query.category ?? "All")
                        .font(.capsRelative(16))
                        .foregroundStyle(Palette.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(Palette.dimText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Category")
            .accessibilityValue(query.category ?? "All")
            rule
        }
    }

    private func label(_ text: String) -> some View {
        Text(caps: text)
            .capsRelative(10, tracking: 0.15)
            .foregroundStyle(Palette.dimText)
            .accessibilityHidden(true)
    }

    private var rule: some View {
        Rectangle()
            .fill(Palette.rule)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The `SOURCE · DATE` line of a History or Saved row.
struct SourceDateLine: View {
    var item: ReadingItem
    var timeZone: TimeZone

    var body: some View {
        Text(caps: Self.text(item, timeZone: timeZone))
            .capsRelative(10, tracking: 0.15)
            .foregroundStyle(Palette.dimText)
            .lineLimit(2)
    }

    /// Joined by hand: the source came from a website.
    static func text(_ item: ReadingItem, timeZone: TimeZone) -> String {
        let day = ReadingDate.day(item.published, timeZone: timeZone)
        return item.source.isEmpty ? day : item.source + " · " + day
    }
}
