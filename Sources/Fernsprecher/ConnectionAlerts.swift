import Foundation
import OxoKit
import UserNotifications

/// System notifications when the line needs attention: the session was taken
/// over, the PIN or the PBX's certificate was rejected, or the PBX has been
/// unreachable for a while.
/// Without them a lost connection only shows in the menu bar.
@MainActor
final class ConnectionAlerts: NSObject, UNUserNotificationCenterDelegate {
    /// How long a reconnect may take before it is worth a notification.
    static let outageDelay: Duration = .seconds(300)
    private static let identifier = "connection"

    private let center: UNUserNotificationCenter?
    private var outageTask: Task<Void, Never>?

    override init() {
        // Outside an app bundle (`swift run`) the notification center traps.
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func update(_ state: ConnectionState, line: String) {
        switch state {
        case .connected, .unconfigured:
            stopOutage()
            center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        case .sessionLost:
            stopOutage()
            post(String(localized: "Session lost"),
                 String(localized: """
                    Extension \(line) was possibly taken over by another program. Fernsprecher is not connected.
                    """))
        case .badPin:
            stopOutage()
            post(String(localized: "Login rejected"),
                 String(localized: "Extension or PIN was rejected. Fernsprecher is not connected."))
        case .untrustedCertificate:
            stopOutage()
            post(String(localized: "PBX certificate rejected"),
                 String(localized: "Fernsprecher is not connected. Details in the settings."))
        case .connecting, .failed:
            // Retries alternate between both; the outage runs until connected.
            guard outageTask == nil else { return }
            outageTask = Task { [weak self] in
                try? await Task.sleep(for: Self.outageDelay)
                guard let self, !Task.isCancelled else { return }
                let minutes = Self.outageDelay.components.seconds / 60
                self.post(String(localized: "No connection to the PBX"),
                          String(localized: "Fernsprecher has not been connected for \(minutes) minutes and keeps trying."))
            }
        }
    }

    private func stopOutage() {
        outageTask?.cancel()
        outageTask = nil
    }

    /// One notification at a time: a newer one replaces the older.
    private func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center?.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    /// Show banners even while the menu is open (the app counts as active).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
