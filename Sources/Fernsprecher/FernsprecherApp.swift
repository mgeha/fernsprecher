import AppKit
import SwiftUI

@main
struct FernsprecherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.connection {
        case .connected where model.activeCalls.contains(where: \.isRinging):
            Image(systemName: "phone.arrow.down.left")
        case .connected where !model.activeCalls.isEmpty:
            Image(systemName: "phone.connection")
        case .connected where model.unanswered > 0:
            Image(systemName: forwarded ? "phone.fill.arrow.right" : "phone.fill")
            Text(verbatim: "\(model.unanswered)")
        case .connected where forwarded:
            Image(systemName: "phone.arrow.right")
        case .connected, .connecting:
            Image(systemName: "phone")
        // Only use symbols that exist on macOS 14 – a missing one leaves the
        // status item invisible.
        case .unconfigured:
            Image(systemName: "phone.down")
        default:
            // Not connected: the "!" sets it apart from a merely idle line.
            Image(systemName: "phone.down")
            Text(verbatim: "!")
        }
    }

    private var forwarded: Bool { model.forward?.isActive == true }
}

/// Owns the model (so it exists from launch, not only once the menu was
/// opened) and logs out of the PBX before quitting to free the line's session.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(environment: .current)
    private let popup = CallPopupController()
    private var alerts: ConnectionAlerts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onRingingChanged = { [weak self] call in
            guard let self else { return }
            popup.update(ringing: call, model: model)
        }
        let alerts = ConnectionAlerts()
        self.alerts = alerts
        model.onConnectionChanged = { [weak self] state in
            guard let self else { return }
            alerts.update(state, line: model.line)
        }
        alerts.update(model.connection, line: model.line)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Already logged out by `AppModel.relaunch()`, which quits from a
        // task where `.terminateLater` would deadlock.
        if model.readyToQuit { return .terminateNow }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        // Do not hang on an unreachable PBX.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
