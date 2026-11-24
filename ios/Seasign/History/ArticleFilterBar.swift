import SwiftUI

/// The search field and CATEGORY menu at the top of History and Saved
/// (`ref-img/00-save-list.png`): two underlined fields side by side, stacked
/// at accessibility text sizes. HUD look (task 197): grey capital labels,
/// white mono entries, accent underlines, cursor and chevron.
struct ArticleFilterBar: View {
    /// "Search saved", "Search the last 7 days"; shown in caps and spoken as the field's label.
    var searchLabel: String
    @Binding var query: ArticleQuery
    /// The categories present in the list, each once.
    var categories: [CategoryChoice]

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.hudAccent) private var accent

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
                    .hudField()
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
                            .foregroundStyle(Palette.dimText)
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
                    Text(verbatim: "All").tag(CategoryChoice?.none)
                    // The user's own category names and interests, shown verbatim.
                    ForEach(categories, id: \.self) { category in
                        Text(verbatim: category.label).tag(CategoryChoice?.some(category))
                    }
                } label: {
                    Text(verbatim: "Category")
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: query.category?.label ?? "All")
                        .hudText(.field)
                        .foregroundStyle(Palette.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Category")
            .accessibilityValue(query.category.map(Self.spoken) ?? "All")
            rule
        }
    }

    /// "AI-found: tide pools" for an interest, the name for a category.
    static func spoken(_ choice: CategoryChoice) -> String {
        guard choice.isAI else { return choice.name }
        return choice.name.isEmpty ? AILabel.spoken : AILabel.spoken + ": " + choice.name
    }

    private func label(_ text: String) -> some View {
        Text(caps: text)
            .hudText(.label)
            .foregroundStyle(Palette.dimText)
            .accessibilityHidden(true)
    }

    private var rule: some View {
        HUDRule(accent: true)
    }
}

/// The `Source · Date` line of a History or Saved row, in grey mono, mixed
/// case as the site wrote it (task 197).
struct SourceDateLine: View {
    var item: ReadingItem
    var timeZone: TimeZone

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.isAI {
                AIMark(size: 9, color: Palette.white)
            }
            Text(verbatim: Self.text(item, timeZone: timeZone))
                .hudText(.detail)
                .foregroundStyle(Palette.dimText)
                // Two lines (a source is up to 120 characters); more at the
                // accessibility text sizes, where two cut the date off (task 198).
                .lineLimit(Self.lineLimit(accessibilitySize: typeSize.isAccessibilitySize))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The most lines the line takes.
    static func lineLimit(accessibilitySize: Bool) -> Int {
        accessibilitySize ? 6 : 2
    }

    /// Joined by hand: the source came from a website.
    static func text(_ item: ReadingItem, timeZone: TimeZone) -> String {
        let day = ReadingDate.day(item.published, timeZone: timeZone)
        return item.source.isEmpty ? day : item.source + " · " + day
    }
}
