import Foundation
import OxoKit

/// Where the model keeps its settings and files, and how it reaches the PBX.
struct AppEnvironment {
    var defaults = UserDefaults.standard
    var pins = PinStore.standard
    var addressBookURL = URL.applicationSupportDirectory.appending(path: "Fernsprecher/addressbook.json")
    var makeClient: @MainActor (Credentials) -> OxoClient = {
        OxoClient(host: $0.host, port: $0.port, trust: $0.trust)
    }

    @MainActor static var current: AppEnvironment {
        #if DEBUG
        if CommandLine.arguments.contains("--demo") {
            return .demo(incomingCall: CommandLine.arguments.contains("--demo-call"))
        }
        #endif
        return AppEnvironment()
    }
}
