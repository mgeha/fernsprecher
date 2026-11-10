import OxoKit
import SwiftUI

extension Color {
    static let listSeparator = Color.primary.opacity(0.08)
}

struct CallLogView: View {
    @Environment(AppModel.self) private var model
    let query: String

    private var entries: [CallLogEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return model.calls }
        // Same name the row shows: the PBX's, else directory or address book.
        let key = AddressBook.numberKey(needle)
        return model.calls.filter { entry in
            if (entry.name ?? model.name(for: entry.number) ?? "").localizedCaseInsensitiveContains(needle) {
                return true
            }
            guard let key, let number = entry.displayNumber else { return false }
            return AddressBook.number(number, contains: key)
        }
    }

    var body: some View {
        if entries.isEmpty {
            Text(model.calls.isEmpty ? String(localized: "No calls") : String(localized: "No matches"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(entries) { entry in
                    CallRow(entry: entry, directoryName: entry.name == nil ? model.name(for: entry.number) : nil) {
                        if let number = entry.number { model.dial(number, name: entry.name) }
                    }
                    .listRowSeparatorTint(.listSeparator)
                }
                if model.callLog.hasOlder, let total = model.callLog.total {
                    loadOlder(total: total)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func loadOlder(total: Int) -> some View {
        HStack {
            Spacer()
            if model.loadingOlderCalls {
                ProgressView().controlSize(.small)
            } else {
                Button("Load older (\(model.calls.count) of \(total))", action: model.loadOlderCalls)
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct CallRow: View {
    @Environment(AppModel.self) private var model
    let entry: CallLogEntry
    /// Directory or address book name when the PBX delivered only a number.
    let directoryName: String?
    let dial: () -> Void

    private var title: String { entry.name ?? directoryName ?? entry.displayNumber ?? String(localized: "Unknown") }
    private var showsNumber: Bool { (entry.name ?? directoryName) != nil }
    /// `dialled` still carries the trunk prefix; `number` never does.
    private var copyableNumber: String? {
        entry.number ?? entry.dialled.map { AddressBook.withoutTrunkPrefix($0, trunkPrefix: model.trunkPrefix) }
    }
    @ViewState private var hovering = false
    @ViewState private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            // Colour only on the symbol; text stays readable on the menu material.
            Image(systemName: entry.incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill")
                .font(.callout)
                .foregroundStyle(entry.missed ? .red : entry.unreached ? .orange : .secondary)
                .frame(width: 18)
                .help(entry.missed ? String(localized: "Missed")
                      : entry.unreached ? String(localized: "Not reached") : "")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(entry.missed && !entry.acknowledged ? .semibold : .regular)
                    .lineLimit(1)
                let detail = [showsNumber ? entry.number : nil, CallRow.outcome(entry)].compactMap { $0 }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Both stay in the layout so hovering never changes the row height:
            // a row that shrank under the cursor lost the hover, grew again and
            // looped until AppKit aborted the layout (crash 2026-10-16).
            let showsDial = hovering && entry.number != nil
            ZStack(alignment: .trailing) {
                if let date = entry.date {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(CallRow.format(date)).foregroundStyle(.secondary)
                        if let duration = entry.duration {
                            Text(CallRow.format(duration: duration)).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .opacity(showsDial ? 0 : 1)
                }
                if entry.number != nil {
                    Button(action: dial) { Image(systemName: "phone.fill") }
                        .buttonStyle(.borderless)
                        .help("Call back")
                        .opacity(showsDial ? 1 : 0)
                        .allowsHitTesting(showsDial)
                        .accessibilityHidden(!showsDial)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: dial)
        .contextMenu {
            if let number = copyableNumber {
                Button("Copy number") { model.copy(number) }
            }
            if let number = entry.number {
                Divider()
                NameMenu(number: number) { editing = true }
            }
        }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            if let number = entry.number {
                NameEditor(number: number, name: model.addressBook.name(for: number) ?? entry.name ?? "")
            }
        }
    }

    /// What happened to the call; nil for answered calls and causes whose
    /// meaning is unclear.
    static func outcome(_ entry: CallLogEntry) -> String? {
        let target = entry.newDestNumber.map { " → \($0)" } ?? ""
        switch entry.outcome {
        case .normal where entry.missed:
            return entry.ringDuration.map { String(localized: "missed after \(format(ring: $0))") }
                ?? String(localized: "missed")
        case .normal where entry.unreached: return String(localized: "not reached")
        case .normal, .other: return nil
        case .busy: return String(localized: "busy")
        case .voiceMail: return String(localized: "voicemail")
        case .pickedUpElsewhere: return String(localized: "answered elsewhere") + target
        case .pickedUp: return String(localized: "picked up")
        case .forwarded: return String(localized: "forwarded") + target
        case .transferred: return String(localized: "transferred") + target
        }
    }

    /// Talk time as `1:18`, `1:02:05`.
    static func format(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Ring time: `26 s`, from a minute on `1:05`.
    static func format(ring: TimeInterval) -> String {
        ring < 59.5 ? "\(Int(ring.rounded())) s" : format(duration: ring)
    }

    static func format(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday \(date.formatted(date: .omitted, time: .shortened))")
        }
        return date.formatted(.dateTime.day().month(.twoDigits).hour().minute())
    }
}
