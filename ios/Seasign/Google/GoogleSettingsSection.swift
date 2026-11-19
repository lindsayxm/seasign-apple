import SwiftUI

/// The Google Calendar part of Settings, above the pasted calendar links:
/// Connect (or Connect again), the account's calendars with a switch each
/// (the primary one on at first, at most ten on), what went wrong in plain
/// words, and Disconnect. No token, code or account detail is ever shown.
struct GoogleSettingsSection: View {
    @Environment(GoogleCalendarModel.self) private var model

    @State private var signIn = GoogleWebSignIn()
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(caps: "Google Calendar")
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            switch model.connection {
            case .notConnected:
                note("Connect your Google account to see events from the Google calendars you choose on Today. New events show within seconds while Today is open. Seasign can only read your calendars, never change them.")
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
        }
        .task {
            // The list is read again each time Settings opens, for names and
            // calendars added or removed in Google Calendar.
            await model.loadCalendars()
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
            note("Connected. Loading your calendars…")
        } else {
            note("Choose which calendars show on Today, up to \(GoogleCalendarModel.maxCalendars).")
            ForEach(model.calendars, id: \.id) { choice in
                row(choice)
            }
            if model.limitReached {
                note("You can show up to \(GoogleCalendarModel.maxCalendars) Google calendars. Turn one off to turn on another.", warning: true)
            }
        }
        disconnectButton
    }

    private func row(_ choice: GoogleCalendarChoice) -> some View {
        let message = model.message(for: choice)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { choice.isOn }, set: { model.setOn(choice, $0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caps: choice.displayName)
                        .capsRelative(11.5, medium: true)
                        .foregroundStyle(Palette.white)
                    if choice.isPrimary {
                        Text(caps: "Main calendar")
                            .capsRelative(9.5, tracking: 0.12)
                            .foregroundStyle(Palette.dimText)
                    }
                }
            }
            .tint(Palette.dayWater)
            .frame(minHeight: 44)
            .accessibilityLabel(choice.displayName)
            if let message {
                Text(caps: message.text)
                    .capsRelative(10, tracking: 0.12)
                    .lineSpacing(3)
                    .foregroundStyle(message.isProblem ? Palette.sun : Palette.dimText)
            }
            Rectangle()
                .fill(Palette.rule)
                .frame(height: 1)
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
                .capsRelative(11, medium: true)
                .foregroundStyle(enabled ? Palette.charcoal : Palette.dimText)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(enabled ? Palette.white : Palette.rule.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var disconnectButton: some View {
        Button {
            confirmingDisconnect = true
        } label: {
            Text(caps: "Disconnect Google")
                .capsRelative(10)
                .foregroundStyle(Palette.dimText)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(caps: text)
            .capsRelative(10, tracking: 0.12)
            .lineSpacing(4)
            .foregroundStyle(warning ? Palette.sun : Palette.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
