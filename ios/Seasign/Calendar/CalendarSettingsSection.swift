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

    /// Where each provider keeps the link. Checked against the providers' help
    /// pages on 2026-11-15: support.google.com/calendar/answer/37648, the
    /// iPhone User Guide's "Share iCloud calendars on iPhone" (iOS 18 and 27),
    /// and Microsoft's "Share your calendar in Outlook.com".
    private static let instructions: [(provider: String, steps: String)] = [
        (
            "Google Calendar",
            "On a computer, open Settings, pick the calendar under Settings for my calendars, choose Integrate calendar and copy the Secret address in iCal format."
        ),
        (
            "Apple Calendar",
            "On your iPhone, open Calendar, tap Calendars, tap the info button next to an iCloud calendar, turn on Public Calendar and tap Share Link."
        ),
        (
            "Outlook",
            "On Outlook.com, open Settings, then Calendar, then Shared calendars. Under Publish a calendar, choose the calendar, select Publish and copy the ICS link."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(caps: "Calendars")
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            ForEach(model.links, id: \.id) { link in
                row(link)
            }

            if model.canAddLink {
                addForm
            } else {
                note(EventsModel.AddProblem.limitReached.message)
            }

            note("Today shows your next three events. Seasign never asks for access to the calendars on your phone. Anyone who has a calendar's link can read that calendar, so links are kept on this phone and sent only to read your events.")

            ForEach(Self.instructions, id: \.provider) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(caps: item.provider)
                        .capsRelative(10, medium: true, tracking: 0.12)
                        .foregroundStyle(Palette.white)
                    note(item.steps)
                }
                .padding(.top, 4)
            }
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
                        .capsRelative(11.5, medium: true)
                        .foregroundStyle(Palette.white)
                    // The host only: the rest of a link is the secret.
                    Text(caps: LinkMask.host(of: link.url) ?? "Link saved")
                        .capsRelative(9.5, tracking: 0.12)
                        .foregroundStyle(Palette.dimText)
                }
                Spacer(minLength: 8)
                Button {
                    removing = link
                } label: {
                    Text(caps: "Remove")
                        .capsRelative(10)
                        .foregroundStyle(Palette.dimText)
                        .underline()
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(link.name)")
            }
            if let message = status?.message {
                Text(caps: message)
                    .capsRelative(10, tracking: 0.12)
                    .lineSpacing(3)
                    // A calendar that could not be read stands out; a partly
                    // read one is only noted.
                    .foregroundStyle(status?.problem != nil ? Palette.sun : Palette.dimText)
            }
            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)
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
                Text(caps: problem.message)
                    .capsRelative(10.5, tracking: 0.12)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.sun)
            }

            Button {
                add()
            } label: {
                Text(caps: isChecking ? "Checking" : "Add calendar")
                    .capsRelative(11, medium: true)
                    .foregroundStyle(canAdd ? Palette.charcoal : Palette.dimText)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(canAdd ? Palette.white : Palette.rule.opacity(0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
        .onChange(of: name) { problem = nil }
        .onChange(of: link) { problem = nil }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caps: label)
                .capsRelative(9.5, tracking: 0.15)
                .foregroundStyle(Palette.dimText)
                .accessibilityHidden(true)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.rule))
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
