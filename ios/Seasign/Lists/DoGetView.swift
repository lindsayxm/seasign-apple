import SwiftUI

/// The Do/Get screen (`ref-img/00-do-get-list.png`): DO on top, GET below, each
/// with its items, a text field and an ADD button. It is the LIST page, one of
/// the four main pages (`MainTabsView`); the tiles are the way back, so it has
/// no close mark.
///
/// The whole page is one `List`: both sections scroll together and rows get
/// the system swipe-to-delete. The field being typed in is kept above the
/// keyboard however long the lists are (see `reveal`).
struct DoGetView: View {
    @Environment(ListsModel.self) private var model
    @Environment(\.hudAccent) private var accent

    @State private var drafts: [ListKind: String] = [:]
    @FocusState private var focus: ListKind?

    /// Sizes are measured from the mockup at about 2.67 px per point (its
    /// 1048 px width as a 393 pt screen).
    private let margin: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 46

    var body: some View {
        ScrollViewReader { proxy in
            List {
                section(.todo)
                divider
                section(.get)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // A new item pushes the field it was typed in down by a row, and
            // the list itself keeps no more than the caret clear of the keyboard.
            .onChange(of: model.items.count) { reveal(focus, with: proxy) }
            .onChange(of: focus) { reveal(focus, with: proxy) }
        }
        .background(Palette.hudPlate.ignoresSafeArea())
        // Rows scroll out under the status bar, not through it.
        .statusBarCover(Palette.hudPlate)
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ kind: ListKind) -> some View {
        header(kind)
            .bare()
        ForEach(model.items(kind), id: \.persistentModelID) { item in
            ListItemRow(item: item, minHeight: rowHeight) {
                model.toggle(item)
            } delete: {
                model.delete(item)
            }
            .padding(.horizontal, margin)
            .bare()
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    model.delete(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        addRow(kind)
            .bare()
            .id(Self.addRowID(kind))
    }

    /// The section's heading, in the accent, with CLEAR CHECKED at the right
    /// while the list has a checked item.
    private func header(_ kind: ListKind) -> some View {
        HStack(alignment: .center) {
            Text(caps: kind.label)
                .hudText(.section)
                .foregroundStyle(accent)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // Only while this list has a checked item: removes those items.
            if model.hasChecked(kind) {
                Button {
                    withAnimation { model.clearChecked(kind) }
                } label: {
                    Text("CLEAR CHECKED")
                }
                .buttonStyle(.hudLink)
                .accessibilityLabel("Clear checked \(kind.label) items")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, margin)
        .padding(.top, 6)
    }

    /// The underlined field with the ADD button to its right: filled with the
    /// accent when there is something to add, outlined in grey when not.
    private func addRow(_ kind: ListKind) -> some View {
        let canAdd = ListsModel.validTitle(drafts[kind] ?? "") != nil
        return HStack(alignment: .bottom, spacing: 14) {
            VStack(spacing: 0) {
                TextField("", text: draft(kind))
                    .hudField(.itemTitle)
                    .submitLabel(.done)
                    .focused($focus, equals: kind)
                    .onSubmit { add(kind) }
                    .frame(minHeight: 44)
                    .accessibilityLabel("New \(kind.label) item")
                HUDRule(accent: true)
            }

            Button {
                add(kind)
            } label: {
                Text("ADD")
            }
            .buttonStyle(.hudFilled)
            .disabled(!canAdd)
            .accessibilityLabel("Add to \(kind.label)")
        }
        .padding(.leading, margin)
        .padding(.trailing, 7)
        .padding(.bottom, 48)
    }

    /// The accent's full-width rule between the two sections.
    private var divider: some View {
        HUDRule(accent: true)
            .bare()
    }

    // MARK: Actions

    /// Brings a section's field, underline and ADD button to the middle of
    /// the screen, which is above the keyboard on every iPhone. (Scrolling it
    /// to the bottom edge is not reliable: on iOS 27 that edge is measured
    /// under the keyboard.) Near the top of the list nothing moves.
    private func reveal(_ kind: ListKind?, with proxy: ScrollViewProxy) {
        guard let kind else { return }
        Task { @MainActor in
            // Wait for the new row and the keyboard to be in place.
            try? await Task.sleep(for: .milliseconds(300))
            guard focus == kind else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.addRowID(kind), anchor: .center)
            }
        }
    }

    private static func addRowID(_ kind: ListKind) -> String {
        "add-\(kind.rawValue)"
    }

    private func draft(_ kind: ListKind) -> Binding<String> {
        Binding {
            drafts[kind] ?? ""
        } set: {
            drafts[kind] = $0
        }
    }

    private func add(_ kind: ListKind) {
        if model.add(drafts[kind] ?? "", to: kind) != nil {
            drafts[kind] = ""
            // Return ends editing; stay in the field so several items can be
            // typed in a row.
            focus = kind
        } else {
            // Nothing to add: return on an empty field puts the keyboard away.
            drafts[kind] = ""
            focus = nil
        }
    }
}

/// One item: the circle checkbox (outlined in the accent; filled with it and
/// a dark tick when done) and the title in mono as typed. The whole row is
/// the checkbox's touch area, so it is at least 44 pt tall and as wide as
/// the list.
private struct ListItemRow: View {
    var item: ListItem
    var minHeight: CGFloat
    var toggle: () -> Void
    var delete: () -> Void

    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = 22.5
    @ScaledMetric(relativeTo: .body) private var gap: CGFloat = 15.5
    @Environment(\.hudAccent) private var accent

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: gap) {
                ZStack {
                    Circle()
                        .strokeBorder(accent, lineWidth: HUDShape.line)
                    if item.isDone {
                        Circle()
                            .fill(accent)
                        Image(systemName: "checkmark")
                            .font(.system(size: circle * 0.48, weight: .bold))
                            .foregroundStyle(Palette.onAccent)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: circle, height: circle)

                // As typed; the button's label below is what is spoken.
                Text(verbatim: item.title)
                    .hudText(.itemTitle)
                    .foregroundStyle(item.isDone ? Palette.dimText : Palette.white)
                    .strikethrough(item.isDone, color: Palette.rule)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .frame(minHeight: max(44, minHeight))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.isDone ? "Mark \(item.title) not done" : "Mark \(item.title) done")
        .accessibilityValue(item.isDone ? "Done" : "Not done")
        .accessibilityAction(named: "Delete", delete)
    }
}

/// The item type of this screen before task 197 (Jost caps); kept, unused,
/// as the other old tokens are.
private enum DoGetType {
    static let itemSize: CGFloat = 12
    static let itemTracking: CGFloat = 0.13
}

private extension View {
    /// A list row with none of the list's own chrome.
    func bare() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
