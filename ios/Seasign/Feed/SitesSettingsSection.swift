import SwiftUI

/// The Sites part of Settings: the pages the user follows (title, category,
/// shortened host and how the last read went), a form to follow another with
/// a category of the user's own, and a way to refresh now.
///
/// Site titles come from the sites themselves and are shown only through
/// `Text(caps:)`, which is verbatim; labels that include one are built as
/// plain `String`s, never as interpolated `LocalizedStringKey`s.
struct SitesSettingsSection: View {
    @Environment(FeedModel.self) private var model

    @State private var address = ""
    @State private var category = ""
    @State private var isChecking = false
    @State private var problem: FeedModel.AddProblem?
    @State private var removing: Site?
    @FocusState private var focus: Field?

    private enum Field {
        case address, category
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(caps: "Sites")
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            ForEach(model.sites, id: \.id) { site in
                row(site)
            }

            if !model.sites.isEmpty {
                refreshButton
            }

            if model.canAddSite {
                addForm
            } else {
                note(FeedModel.AddProblem.limitReached.message)
            }

            note("Today shows the newest headlines from these sites since yesterday. Follow a section page (such as a site's science page) or a feed, and give it a category of your own. Addresses are kept on this phone and sent to Seasign's server to read the sites.")
        }
        .confirmationDialog(
            Text(verbatim: "Stop following this site?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { site in
            Button(role: .destructive) {
                model.remove(site)
            } label: {
                Text(verbatim: "Remove " + site.title)
            }
        } message: { _ in
            Text(verbatim: "Its headlines leave Today. You can add it again later.")
        }
    }

    // MARK: Sites

    private func row(_ site: Site) -> some View {
        let line = SiteStatusLine(status: model.status(for: site), itemCount: model.itemCount(for: site))
        let host = LinkMask.host(of: site.url) ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caps: site.title)
                        .capsRelative(11.5, medium: true)
                        .foregroundStyle(Palette.white)
                        .lineLimit(2)
                    Text(caps: [site.category, host].filter { !$0.isEmpty }.joined(separator: " · "))
                        .capsRelative(9.5, tracking: 0.12)
                        .foregroundStyle(Palette.dimText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    removing = site
                } label: {
                    Text(caps: "Remove")
                        .capsRelative(10)
                        .foregroundStyle(Palette.dimText)
                        .underline()
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove " + site.title)
            }
            Text(caps: line.text)
                .capsRelative(10, tracking: 0.12)
                .lineSpacing(3)
                .foregroundStyle(line.isProblem ? Palette.sun : Palette.dimText)
            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh(force: true) }
        } label: {
            Text(caps: model.isRefreshing ? "Refreshing" : "Refresh headlines now")
                .capsRelative(10)
                .foregroundStyle(Palette.dimText)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRefreshing)
    }

    // MARK: Adding

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Page address", text: $address, prompt: "example.com/science")
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .address)
                .onSubmit { focus = .category }

            field("Category", text: $category, prompt: "Sci")
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focus, equals: .category)
                .onSubmit { add() }

            if !model.categories.isEmpty {
                categoryChoices
            }

            if let problem {
                Text(caps: problem.message)
                    .capsRelative(10.5, tracking: 0.12)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.sun)
            }

            Button {
                add()
            } label: {
                Text(caps: isChecking ? "Checking" : "Follow site")
                    .capsRelative(11, medium: true)
                    .foregroundStyle(canAdd ? Palette.charcoal : Palette.dimText)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(canAdd ? Palette.white : Palette.rule.opacity(0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
        .padding(.top, 8)
        .onChange(of: address) { problem = nil }
        .onChange(of: category) { problem = nil }
    }

    /// The categories already in use, to tap instead of typing one again.
    private var categoryChoices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.categories, id: \.self) { name in
                    let selected = name.caseInsensitiveCompare(category.trimmingCharacters(in: .whitespaces)) == .orderedSame
                    Button {
                        category = name
                    } label: {
                        Text(caps: name)
                            .capsRelative(10, medium: selected, tracking: 0.12)
                            .foregroundStyle(selected ? Palette.charcoal : Palette.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(selected ? Palette.white : Palette.rule.opacity(0.35), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use category " + name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caps: label)
                .capsRelative(9.5, tracking: 0.15)
                .foregroundStyle(Palette.dimText)
                .accessibilityHidden(true)
            TextField("", text: text, prompt: Text(verbatim: prompt).foregroundStyle(Palette.rule))
                .font(.capsRelative(13))
                .foregroundStyle(Palette.white)
                .tint(Palette.dayWater)
                .frame(minHeight: 44)
                .accessibilityLabel(label)
            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)
        }
    }

    private func note(_ text: String) -> some View {
        Text(caps: text)
            .capsRelative(10, tracking: 0.12)
            .lineSpacing(4)
            .foregroundStyle(Palette.dimText)
    }

    private var canAdd: Bool {
        !isChecking
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        isChecking = true
        problem = nil
        let typedAddress = address
        let typedCategory = category
        Task {
            do {
                try await model.add(address: typedAddress, category: typedCategory)
                address = ""
                category = ""
                focus = nil
            } catch let addProblem as FeedModel.AddProblem {
                problem = addProblem
            } catch {
                problem = .unavailable
            }
            isChecking = false
        }
    }
}
