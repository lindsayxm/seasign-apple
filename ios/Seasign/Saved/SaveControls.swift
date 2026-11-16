import SwiftUI

/// What tapping a save control, or REMOVE in Saved, led to.
enum SaveOutcome: Equatable {
    case saved
    case removed
    /// The article has notes: ask before removing it (`RemovalConfirmation`).
    case needsConfirmation
    /// The write failed; `SavedModel.problem` says what to show.
    case failed
}

extension SavedModel {
    /// The save control of History and the reading view: saves an article
    /// that is not saved; removes one that is, unless it has notes, which
    /// need the user's confirmation first.
    func toggleSave(_ item: ReadingItem) -> SaveOutcome {
        if isSaved(item.link) {
            if hasNotes(link: item.link) { return .needsConfirmation }
            return unsave(link: item.link) ? .removed : .failed
        }
        return save(item) ? .saved : .failed
    }

    /// REMOVE in Saved: at once, unless the article has notes.
    func requestRemoval(_ id: UUID) -> SaveOutcome {
        if hasNotes(id) { return .needsConfirmation }
        return remove(id) ? .removed : .failed
    }
}

/// The article a remove dialog asks about, as plain values: the dialog never
/// holds a SwiftData row that the removal deletes.
struct RemovalConfirmation: Identifiable, Equatable {
    var id: UUID
    var title: String

    @MainActor
    init?(link: String, in model: SavedModel) {
        guard let entry = model.entry(link: link) else { return nil }
        id = entry.id
        title = entry.item.title
    }

    init(_ entry: SavedEntry) {
        id = entry.id
        title = entry.item.title
    }
}

extension View {
    /// Asks before removing a saved article that has notes; removes it, with
    /// its notes, once the dialog has closed.
    func removalConfirmation(_ pending: Binding<RemovalConfirmation?>, model: SavedModel) -> some View {
        confirmationDialog(
            Text(verbatim: "Remove this article and its notes?"),
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { removal in
            Button(role: .destructive) {
                let id = removal.id
                Task { model.remove(id) }
            } label: {
                Text(verbatim: "Remove and delete notes")
            }
            Button(role: .cancel) {} label: {
                Text(verbatim: "Keep")
            }
        } message: { removal in
            // Built as a String and shown verbatim: the title came from a website.
            Text(verbatim: "“" + removal.title + "” has notes. Removing it from Saved deletes them too.")
        }
    }
}

/// The asterisk save control: bright and filled when the article is saved,
/// dim when it is not. At least 44 pt square.
struct SaveMark: View {
    var isSaved: Bool
    /// The article's title, for the spoken label.
    var title: String
    /// Side of the drawn square.
    var side: CGFloat = 44
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            LineIconView(icon: .saved, size: side * 0.5, lineWidth: 1.5)
                .foregroundStyle(isSaved ? Palette.white : Palette.dimText)
                .frame(width: side, height: side)
                .background(isSaved ? Palette.rule.opacity(0.75) : Palette.rule.opacity(0.22))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.label(isSaved: isSaved, title: title))
        .accessibilityValue(isSaved ? "Saved" : "Not saved")
    }

    /// Plain strings joined by hand, never a localized key built from site text.
    static func label(isSaved: Bool, title: String) -> String {
        isSaved ? "Remove " + title + " from Saved" : "Save " + title
    }
}

/// The problem line under a screen's controls, in the warning colour.
struct SavedProblemLine: View {
    var problem: SavedModel.Problem
    var retry: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: problem.message)
                .font(.capsRelative(12))
                .foregroundStyle(Palette.sun)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                if problem == .notesNotSaved {
                    textButton("Try again", action: retry)
                } else {
                    textButton("OK", action: dismiss)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func textButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: label)
                .capsRelative(10, medium: true)
                .foregroundStyle(Palette.white)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
