import SwiftUI

/// The Do/Get screen (`ref-img/00-do-get-list.png`): DO on top, GET below, each
/// with its items, a text field and an ADD button.
///
/// The whole sheet is one `List`: both sections scroll together and rows get
/// the system swipe-to-delete. The field being typed in is kept above the
/// keyboard however long the lists are (see `reveal`).
struct DoGetView: View {
    @Environment(ListsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [ListKind: String] = [:]
    @FocusState private var focus: ListKind?

    /// Sizes are measured from the mockup at about 2.67 px per point (its
    /// 1048 px width as a 393 pt screen).
    private let margin: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 46

    var body: some View {
        ScrollViewReader { proxy in
            List {
                section(.todo, isFirst: true)
                divider
                section(.get, isFirst: false)
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
        .background(Palette.charcoal.ignoresSafeArea())
        // Rows scroll out under the status bar, not through it.
        .overlay(alignment: .top) {
            Palette.charcoal
                .ignoresSafeArea(edges: .top)
                .frame(height: 0)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ kind: ListKind, isFirst: Bool) -> some View {
        header(kind, showsClose: isFirst)
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

    /// The small section label. The first one shares its line with Close, the
    /// way out of the sheet.
    private func header(_ kind: ListKind, showsClose: Bool) -> some View {
        HStack(alignment: .center) {
            Text(kind.label)
                .capsRelative(9.5, tracking: 0.15)
                .foregroundStyle(Palette.dimText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if showsClose {
                Button {
                    dismiss()
                } label: {
                    Text("Close")
                        .capsRelative(9.5, tracking: 0.15)
                        .foregroundStyle(Palette.dimText)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, margin)
        .padding(.top, 6)
    }

    /// The underlined field with the ADD pill to its right.
    private func addRow(_ kind: ListKind) -> some View {
        let canAdd = ListsModel.validTitle(drafts[kind] ?? "") != nil
        return HStack(alignment: .bottom, spacing: 14) {
            VStack(spacing: 0) {
                TextField("", text: draft(kind))
                    .font(.capsRelative(DoGetType.itemSize))
                    .tracking(DoGetType.itemSize * DoGetType.itemTracking)
                    .foregroundStyle(Palette.white)
                    .tint(Palette.dayWater)
                    .submitLabel(.done)
                    .focused($focus, equals: kind)
                    .onSubmit { add(kind) }
                    .frame(minHeight: 44)
                    .accessibilityLabel("New \(kind.label) item")
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
            }

            Button {
                add(kind)
            } label: {
                Text("ADD")
                    .font(.capsRelative(9.5))
                    .tracking(9.5 * 0.15)
                    .foregroundStyle(canAdd ? Palette.white : Palette.rule)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .overlay {
                        Capsule().strokeBorder(canAdd ? Palette.dimText : Palette.rule, lineWidth: 1)
                    }
                    // The pill is 36 pt tall as drawn; the touch area is 44.
                    .padding(.top, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add to \(kind.label)")
        }
        .padding(.leading, margin)
        .padding(.trailing, 7)
        .padding(.bottom, 48)
    }

    /// The light full-width rule between the two sections.
    private var divider: some View {
        Rectangle()
            .fill(Palette.dayWater)
            .frame(height: 1)
            .bare()
            .accessibilityHidden(true)
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

/// One item: the circle checkbox and the title in caps. The whole row is the
/// checkbox's touch area, so it is at least 44 pt tall and as wide as the list.
private struct ListItemRow: View {
    var item: ListItem
    var minHeight: CGFloat
    var toggle: () -> Void
    var delete: () -> Void

    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = 22.5
    @ScaledMetric(relativeTo: .body) private var gap: CGFloat = 15.5

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: gap) {
                ZStack {
                    Circle()
                        .strokeBorder(item.isDone ? Palette.dimText : Palette.rule, lineWidth: 1)
                    if item.isDone {
                        Circle()
                            .fill(Palette.dimText)
                        Image(systemName: "checkmark")
                            .font(.system(size: circle * 0.48, weight: .bold))
                            .foregroundStyle(Palette.charcoal)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: circle, height: circle)

                // Capitals are made here rather than with `textCase`, which
                // would also put the button's accessibility label in capitals.
                Text(item.title.uppercased())
                    .font(.capsRelative(DoGetType.itemSize))
                    .tracking(DoGetType.itemSize * DoGetType.itemTracking)
                    .foregroundStyle(item.isDone ? Palette.dimText.opacity(0.7) : Palette.white)
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

/// The item type of this screen, shared by the rows and the fields.
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
