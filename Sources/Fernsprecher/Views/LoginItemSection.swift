import os
import OxoKit
import ServiceManagement
import SwiftUI

/// "Open at login" via `SMAppService.mainApp`. The state is not stored in the
/// defaults but read from macOS each time, because the user can also change it
/// in System Settings → General → Login Items.
struct LoginItemSection: View {
    @ViewState private var status = SMAppService.mainApp.status
    @ViewState private var error: String?

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { isOn }, set: { set($0) }))
            if status == .requiresApproval {
                LabeledContent {
                    Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                } label: {
                    Text("Needs to be allowed in System Settings.")
                }
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        // Pick up changes made in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private var isOn: Bool { status == .enabled || status == .requiresApproval }

    private func set(_ on: Bool) {
        error = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            OxoLog.session.error("login item: \(error.diagnosticKind, privacy: .public)")
            self.error = String(localized: "Could not change login item: \(error.localizedDescription)")
        }
        status = SMAppService.mainApp.status
    }
}
