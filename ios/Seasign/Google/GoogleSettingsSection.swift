import SwiftUI

/// The Google Calendar part of Settings, above the pasted calendar links:
/// Connect (or Connect again), the account's calendars with a switch each
/// (the primary one on at first, at most ten on), where new events go (or
/// "Connect again to add events" when Google has not allowed adding), what
/// went wrong in plain words, and Disconnect. No token, code or account
/// detail is ever shown.
struct GoogleSettingsSection: View {
    @Environment(GoogleCalendarModel.self) private var model
    @Environment(\.hudAccent) private var accent

    @State private var signIn = GoogleWebSignIn()
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDSectionHeader(title: "Google Calendar")

            switch model.connection {
            case .notConnected:
                note("Seasign reads the calendars you choose and adds only the events you confirm.")
                connectButton("Connect Google Calendar")
            case .expired:
                note("Your Google sign-in has ended, so Google events are off Today. Google ends sign-ins after 7 days while Seasign is in testing, or when access is removed in your Google account. Connect again to bring them back.", warning: true)
                connectButton("Connect again")
                disconnectButton
            case .connected:
                connectedContent
            }

            if let problem = model.connectProblem {
                note(problem.message, warning: true)
            }
            if model.connection == .connected, let problem = model.statusProblem {
                note(problem.message, warning: true)
            }
            if model.connection == .connected, let problem = model.watch.problem {
                note(problem.message, warning: true)
            }
        }
        .task(id: model.listLoadKey) {
            // The list is read again each time Settings opens, for names and
            // calendars added or removed in Google Calendar, and again when
            // a hold that kept it back ends while Settings is open. A Connect
            // made here restarts this when it ends, so a list that failed to
            // load during it is tried again.
            await model.loadCalendarsWhileShown()
        }
        .confirmationDialog(
            Text(verbatim: "Disconnect Google Calendar?"),
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.disconnect() }
            } label: {
                Text(verbatim: "Disconnect")
            }
        } message: {
            Text(verbatim: "Google events leave Today and Seasign forgets your Google sign-in on this phone. Your calendars in Google are not changed.")
        }
    }

    // MARK: Connected

    @ViewBuilder
    private var connectedContent: some View {
        if model.calendars.isEmpty {
            note(model.listHeld ? "Connected. Your calendars will load in a moment." : "Connected. Loading your calendars…")
        } else {
            note("Choose which calendars show on Today, up to \(GoogleCalendarModel.maxCalendars).")
            if model.listHeld {
                note("Your calendar list will be read again in a moment.")
            }
            ForEach(model.calendars, id: \.id) { choice in
                row(choice)
            }
            if model.limitReached {
                note("You can show up to \(GoogleCalendarModel.maxCalendars) Google calendars. Turn one off to turn on another.", warning: true)
            }
        }
        addingEvents
        disconnectButton
    }

    /// Where new events go, or how to allow adding them. Not a problem when
    /// write access is missing: the calendars read as before.
    @ViewBuilder
    private var addingEvents: some View {
        if model.canAddEvents {
            // Roles arrive with the calendar list; until one is known
            // (an older list, or a load still out) nothing is said.
            if model.calendars.contains(where: { $0.accessRole != nil }) {
                if model.newEventsCalendars.isEmpty {
                    note("Seasign adds events only to calendars you own, and none of these is yours.")
                } else {
                    newEventsMenu
                }
            }
        } else {
            note("Seasign reads your calendars but can't add events yet. To add events, connect again and allow Seasign to add them. Seasign adds only the events you confirm.")
            connectButton("Connect again to add events")
        }
    }

    private var newEventsMenu: some View {
        let current = model.newEventsCalendar
        return VStack(alignment: .leading, spacing: 6) {
            Text(caps: "New events go to")
                .hudText(.label)
                .foregroundStyle(Palette.dimText)
                .padding(.top, 8)
            Menu {
                Picker(selection: Binding(
                    get: { current?.id },
                    set: { id in
                        if let choice = model.newEventsCalendars.first(where: { $0.id == id }) {
                            model.setNewEventsCalendar(choice)
                        }
                    }
                )) {
                    // The user's own calendar names, shown verbatim.
                    ForEach(model.newEventsCalendars, id: \.id) { choice in
                        Text(verbatim: choice.displayName).tag(UUID?.some(choice.id))
                    }
                } label: {
                    Text(verbatim: "New events go to")
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text(caps: current?.displayName ?? "Choose a calendar")
                        .hudText(.rowName)
                        .foregroundStyle(Palette.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("New events go to")
            .accessibilityValue(current?.displayName ?? "None")
            .settingsAction(.chooseNewEventsCalendar)
            HUDNote(text: "Only calendars you own are listed. Seasign adds only the events you confirm.")
            HUDRule()
        }
    }

    private func row(_ choice: GoogleCalendarChoice) -> some View {
        let message = model.message(for: choice)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { choice.isOn }, set: { model.setOn(choice, $0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caps: choice.displayName)
                        .hudText(.rowName)
                        .foregroundStyle(Palette.white)
                    if choice.isPrimary {
                        Text(caps: "Main calendar")
                            .hudText(.detail)
                            .foregroundStyle(Palette.dimText)
                    }
                }
            }
            .tint(accent)
            .frame(minHeight: 44)
            .accessibilityLabel(choice.displayName)
            .settingsAction(.chooseGoogleCalendars)
            if let message {
                HUDNote(text: message.text, warning: message.isProblem)
            }
            if let watchMessage = model.watchMessage(for: choice) {
                HUDNote(text: watchMessage)
            }
            HUDRule()
        }
    }

    // MARK: Parts

    private func connectButton(_ title: String) -> some View {
        let enabled = !model.isConnecting
        return Button {
            Task {
                await model.connect { url, scheme in
                    try await signIn.signIn(url: url, callbackScheme: scheme)
                }
            }
        } label: {
            Text(caps: model.isConnecting ? "Connecting" : title)
        }
        .buttonStyle(.hudFilled)
        .disabled(!enabled)
        .settingsAction(.connectGoogle)
    }

    private var disconnectButton: some View {
        Button {
            confirmingDisconnect = true
        } label: {
            Text(caps: "Disconnect Google")
        }
        .buttonStyle(.hudLink)
        .settingsAction(.disconnectGoogle)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        HUDNote(text: text, warning: warning)
    }
}
