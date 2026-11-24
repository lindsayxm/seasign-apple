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
    /// The site the remove dialog asks about, as plain values: the dialog
    /// never holds a SwiftData row that the removal deletes.
    @State private var removing: Removal?
    @FocusState private var focus: Field?

    private enum Field {
        case address, category
    }

    private struct Removal {
        var id: UUID
        var title: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDSectionHeader(title: "Sites")

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

            note("The main screen shows the newest headlines from these sites.")
        }
        .confirmationDialog(
            Text(verbatim: "Stop following this site?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { removal in
            Button(role: .destructive) {
                let id = removal.id
                Task {
                    if let site = model.sites.first(where: { $0.id == id }) {
                        model.remove(site)
                    }
                }
            } label: {
                Text(verbatim: "Remove " + removal.title)
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
                        .hudText(.rowName)
                        .foregroundStyle(Palette.white)
                        .lineLimit(2)
                    Text(caps: [site.category, host].filter { !$0.isEmpty }.joined(separator: " · "))
                        .hudText(.detail)
                        .foregroundStyle(Palette.dimText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    removing = Removal(id: site.id, title: site.title)
                } label: {
                    Text(caps: "Remove")
                }
                .buttonStyle(.hudLink(minWidth: 44, alignment: .trailing))
                .accessibilityLabel("Remove " + site.title)
            }
            HUDNote(text: line.text, warning: line.isProblem)
            HUDRule()
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh(force: true) }
        } label: {
            Text(caps: model.isRefreshing ? "Refreshing" : "Refresh headlines now")
        }
        .buttonStyle(.hudLink)
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
                HUDNote(text: problem.message, warning: true)
            }

            Button {
                add()
            } label: {
                Text(caps: isChecking ? "Checking" : "Follow site")
            }
            .buttonStyle(.hudFilled)
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
                    }
                    .buttonStyle(.hudChip(selected: selected))
                    .accessibilityLabel("Use category " + name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caps: label)
                .hudText(.label)
                .foregroundStyle(Palette.dimText)
                .accessibilityHidden(true)
            TextField("", text: text, prompt: Text(verbatim: prompt).foregroundStyle(Palette.rule))
                .hudField()
                .frame(minHeight: 44)
                .accessibilityLabel(label)
            HUDRule(accent: true)
        }
    }

    private func note(_ text: String) -> some View {
        HUDNote(text: text)
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
