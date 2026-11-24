import SwiftUI

/// The Calendars part of Settings: the links the user has added (name and a
/// masked host, never the link itself), a form to add one, and where to find
/// the link in Google Calendar, Apple Calendar and Outlook.
struct CalendarSettingsSection: View {
    @Environment(EventsModel.self) private var model

    @State private var name = ""
    @State private var link = ""
    @State private var isChecking = false
    @State private var problem: EventsModel.AddProblem?
    @State private var removing: CalendarLink?
    @FocusState private var focus: Field?

    private enum Field {
        case name, link
    }

    /// Where each provider keeps the link. A Google secret iCal address is
    /// still accepted, but is no longer described here (the user, 2026-11-23:
    /// Google goes through Connect). Checked against the providers' help
    /// pages on 2026-11-15: support.google.com/calendar/answer/37648, the
    /// iPhone User Guide's "Share iCloud calendars on iPhone" (iOS 18 and 27),
    /// and Microsoft's "Share your calendar in Outlook.com".
    private static let instructions: [(provider: String, steps: String)] = [
        (
            "Apple Calendar",
            "On your iPhone, open Calendar, open the list of calendars, tap the info button next to an iCloud calendar, turn on Public Calendar and tap Share Link."
        ),
        (
            "Outlook",
            "On Outlook.com, open Settings, then Calendar, then Shared calendars. Under Publish a calendar, choose the calendar, select Publish and copy the ICS link."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDSectionHeader(title: "Other calendars")

            ForEach(model.links, id: \.id) { link in
                row(link)
            }

            if model.canAddLink {
                addForm
                    .settingsAction(.addCalendarLink)
            } else {
                note(EventsModel.AddProblem.limitReached.message)
            }

            ForEach(Self.instructions, id: \.provider) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(caps: item.provider)
                        .hudText(.rowName)
                        .foregroundStyle(Palette.white)
                    note(item.steps)
                }
                .padding(.top, 4)
            }

            note("Apple and Outlook calendars cannot be written to and the links are required to read events.")
        }
        .confirmationDialog(
            "Remove this calendar?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { link in
            Button("Remove \(link.name)", role: .destructive) {
                Task { await model.remove(link) }
            }
        } message: { _ in
            Text("Its events leave Today. To bring it back you will need to paste the link again.")
        }
    }

    // MARK: Links

    private func row(_ link: CalendarLink) -> some View {
        let status = model.status(for: link)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caps: link.name)
                        .hudText(.rowName)
                        .foregroundStyle(Palette.white)
                    // The host only: the rest of a link is the secret.
                    Text(caps: LinkMask.host(of: link.url) ?? "Link saved")
                        .hudText(.detail)
                        .foregroundStyle(Palette.dimText)
                }
                Spacer(minLength: 8)
                Button {
                    removing = link
                } label: {
                    Text(caps: "Remove")
                }
                .buttonStyle(.hudLink(minWidth: 44, alignment: .trailing))
                .accessibilityLabel("Remove \(link.name)")
                .settingsAction(.removeCalendarLink)
            }
            if let message = status?.message {
                // A calendar that could not be read stands out; a partly
                // read one is only noted.
                HUDNote(text: message, warning: status?.problem != nil)
            }
            HUDRule()
        }
    }

    // MARK: Adding

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name", text: $name, prompt: "Family")
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .focused($focus, equals: .name)
                .onSubmit { focus = .link }

            field("Calendar link", text: $link, prompt: "https:// or webcal://")
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focus, equals: .link)
                .onSubmit { add() }

            if let problem {
                HUDNote(text: problem.message, warning: true)
            }

            Button {
                add()
            } label: {
                Text(caps: isChecking ? "Checking" : "Add calendar")
            }
            .buttonStyle(.hudFilled)
            .disabled(!canAdd)
        }
        .onChange(of: name) { problem = nil }
        .onChange(of: link) { problem = nil }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caps: label)
                .hudText(.label)
                .foregroundStyle(Palette.dimText)
                .accessibilityHidden(true)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.rule))
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
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        isChecking = true
        problem = nil
        let typedName = name
        let typedLink = link
        Task {
            do {
                try await model.add(name: typedName, link: typedLink)
                // The link is not kept on screen once it is stored.
                name = ""
                link = ""
                focus = nil
            } catch let addProblem as EventsModel.AddProblem {
                problem = addProblem
            } catch {
                problem = .unavailable
            }
            isChecking = false
        }
    }
}
