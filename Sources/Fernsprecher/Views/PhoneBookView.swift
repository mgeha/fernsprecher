import OxoKit
import SwiftUI

struct PhoneBookView: View {
    @Environment(AppModel.self) private var model
    let entries: [PhoneBookEntry]
    /// Matches from the user's own address book, shown first.
    let own: [AddressBookEntry]

    var body: some View {
        if entries.isEmpty && own.isEmpty {
            Text(model.directory.isEmpty && model.addressBook.entries.isEmpty
                 ? String(localized: "Phone book empty") : String(localized: "No matches"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !own.isEmpty {
                    Section {
                        ForEach(own) { entry in
                            DirectoryRow(name: entry.name, number: entry.number, editable: true) {
                                model.dial(entry.number, name: entry.name)
                            }
                            .listRowSeparatorTint(.listSeparator)
                        }
                    } header: {
                        header(String(localized: "Own entries"))
                    }
                }
                Section {
                    ForEach(entries) { entry in
                        DirectoryRow(name: entry.displayName, number: entry.number, editable: false) {
                            model.dial(entry.number, name: entry.displayName)
                        }
                        .listRowSeparatorTint(.listSeparator)
                    }
                } header: {
                    header(String(localized: "PBX"))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// Section titles only when both sources have matches.
    @ViewBuilder private func header(_ title: String) -> some View {
        if !entries.isEmpty && !own.isEmpty {
            Text(title)
        }
    }
}

private struct DirectoryRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let number: String
    /// Own address book entry: can be renamed and removed.
    let editable: Bool
    let dial: () -> Void
    @ViewState private var hovering = false
    @ViewState private var editing = false

    var body: some View {
        HStack {
            Text(name).lineLimit(1)
            Spacer()
            // Both stay in the layout so hovering never changes the row height
            // (see CallRow).
            ZStack(alignment: .trailing) {
                Text(number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .opacity(hovering ? 0 : 1)
                Button(action: dial) { Image(systemName: "phone.fill") }
                    .buttonStyle(.borderless)
                    .help("Call")
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .accessibilityHidden(!hovering)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: dial)
        .contextMenu {
            Button("Copy number") { model.copy(number) }
            if editable {
                Divider()
                NameMenu(number: number) { editing = true }
            }
        }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            NameEditor(number: number, name: name)
        }
    }
}
