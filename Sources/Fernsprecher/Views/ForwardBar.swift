import OxoKit
import SwiftUI

/// The line's forward, whether set here, on the desk phone or in another
/// client.
struct ForwardBar: View {
    @Environment(AppModel.self) private var model
    let forward: ForwardState
    @ViewState private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.arrow.right")
                .foregroundStyle(forward.isActive ? Color.accentColor : .secondary)
            Text(forward.text(name: model.name(for:)))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(forward.isActive ? .primary : .secondary)
            Spacer()
            if forward.isActive {
                Button("Off", action: model.cancelForward)
                    .help("Cancel forward")
            } else {
                Button("Forward …") { editing = true }
                    .help("Forward all calls immediately")
            }
        }
        .controlSize(.small)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(forward.isActive ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            // Sent as typed, like on the desk phone: external targets need the trunk prefix.
            InputEditor(title: String(localized: "Forward all calls immediately to"),
                        placeholder: String(localized: "Number"),
                        text: model.lastForwardNumber, saveLabel: String(localized: "Forward"),
                        hint: model.trunkPrefix.isEmpty ? nil
                            : String(localized: "Enter external numbers with the trunk prefix \(model.trunkPrefix) in front.")) {
                guard let number = AppModel.dialable($0) else { return false }
                model.forward(to: number)
                return true
            }
        }
    }
}

extension ForwardState {
    /// "No forward", "Forwarded to 11 · Reception", "When busy to
    /// voicemail". `name` names a target the PBX delivered without one
    /// (directory, address book).
    func text(name: (String?) -> String?) -> String {
        let label: String
        switch kind {
        case .none: return String(localized: "No forward")
        case .immediate: label = String(localized: "Forwarded")
        case .onBusy: label = String(localized: "When busy")
        case .onNoAnswer: label = String(localized: "On no answer")
        }
        if toVoiceMail { return String(localized: "\(label) to voicemail") }
        guard let number = targetNumber else { return label }
        if let target = targetName ?? name(number) { return String(localized: "\(label) to \(number) · \(target)") }
        return String(localized: "\(label) to \(number)")
    }
}
