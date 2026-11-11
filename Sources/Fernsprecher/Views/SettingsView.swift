import OxoKit
import SwiftUI

enum SettingsTab: Hashable {
    case general, pbx, certificate
}

/// The settings window: one tab per topic. Only the PBX tab needs an explicit
/// save (it logs in, which ends other sessions on the line); everything else
/// is stored at once, and a new language takes effect after a restart.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            PbxSettings()
                .tabItem { Label("PBX", systemImage: "phone") }
                .tag(SettingsTab.pbx)
            CertificateSettings()
                .tabItem { Label("Certificate", systemImage: "lock.shield") }
                .tag(SettingsTab.certificate)
        }
        .frame(width: 460)
        .onAppear { tab = Self.tab(for: model.connection) }
    }

    /// Opens where something needs to be done.
    static func tab(for connection: ConnectionState) -> SettingsTab {
        switch connection {
        case .unconfigured, .badPin: .pbx
        case .untrustedCertificate: .certificate
        default: .general
        }
    }
}

/// Grouped form sized to its content, so the window fits each tab.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Footnote: View {
    let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim: String) { text = Text(verbatim) }

    var body: some View {
        text.font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Popup for incoming calls", isOn: Binding(
                    get: { model.popupEnabled }, set: { model.popupEnabled = $0 }))
                TextField("Trunk prefix", text: Binding(
                    get: { model.trunkPrefix }, set: { model.trunkPrefix = $0.filter(\.isNumber) }),
                    prompt: Text("none"))
            } header: {
                Text("Calls")
            } footer: {
                Footnote("""
                    Put in front of external numbers when dialling from the call log or phone book. \
                    Typed numbers are dialled as entered.
                    """)
            }
            LoginItemSection()
            languageSection
        }
    }

    /// Takes effect at the next launch; offers to restart right away.
    private var languageSection: some View {
        Section {
            Picker("Language", selection: Binding(
                get: { model.language }, set: { model.setLanguage($0) })) {
                Text("Same as system").tag(AppLanguage.system)
                // Each language in its own words.
                Text(verbatim: "Deutsch").tag(AppLanguage.german)
                Text(verbatim: "English").tag(AppLanguage.english)
            }
            .disabled(model.relaunching)
            if model.languageChanged {
                LabeledContent {
                    HStack(spacing: 8) {
                        if model.relaunching {
                            ProgressView().controlSize(.small)
                        }
                        Button("Restart now") { Task { await model.relaunch() } }
                            .disabled(model.relaunching)
                    }
                } label: {
                    Text("Takes effect after a restart.")
                }
            }
            if let error = model.relaunchError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }
}

// MARK: - PBX

struct PbxSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var host = ""
    @ViewState private var port = 443
    @ViewState private var line = ""
    @ViewState private var pin = ""
    @ViewState private var saving = false

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var trimmedLine: String { line.trimmingCharacters(in: .whitespaces) }
    private var changed: Bool {
        trimmedHost != model.host || port != model.port || trimmedLine != model.line || !pin.isEmpty
    }
    /// Saving again without changes only makes sense to retry a connection.
    private var canSave: Bool {
        !saving && !trimmedHost.isEmpty && !trimmedLine.isEmpty && (!pin.isEmpty || model.hasPin)
            && (changed || model.connection != .connected)
    }

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Address") {
                    HStack(spacing: 4) {
                        TextField("Address", text: $host, prompt: Text("e.g. 192.168.1.10"))
                            .labelsHidden()
                        Text(verbatim: ":").foregroundStyle(.secondary)
                        TextField("Port", value: $port, format: .number.grouping(.never))
                            .labelsHidden()
                            .frame(width: 52)
                    }
                }
                TextField("Extension", text: $line, prompt: Text("e.g. 51"))
                SecureField("PIN", text: $pin,
                            prompt: Text(model.hasPin ? String(localized: "unchanged") : String(localized: "PIN")))
            } header: {
                Text("PBX")
            } footer: {
                Footnote("""
                    The PIN is stored in a file only you can read. Only one session per extension is possible – \
                    logging in here ends e.g. PIMphony on the same extension.
                    """)
            }
            Section {
                HStack(alignment: .firstTextBaseline) {
                    status
                    Spacer()
                    Button("Save and connect", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            host = model.host
            port = model.port
            line = model.line
        }
    }

    private func save() {
        saving = true
        Task {
            await model.save(host: host, port: port, line: line, pin: pin)
            if model.pinError == nil { pin = "" }
            host = model.host
            line = model.line
            saving = false
        }
    }

    @ViewBuilder private var status: some View {
        if let error = model.pinError {
            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .lineLimit(3)
        } else {
            switch model.connection {
            case .connected:
                Label("Connected as \(model.displayName ?? model.line)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .connecting:
                Label {
                    Text("Connecting …")
                } icon: {
                    ProgressView().controlSize(.mini)
                }
                .foregroundStyle(.secondary)
            case .badPin:
                Label("Wrong extension or PIN", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .lineLimit(2)
            case .sessionLost:
                Label("Session lost – possibly taken over by another program", systemImage: "person.2.fill")
                    .foregroundStyle(.orange)
            case .untrustedCertificate:
                Label("PBX certificate rejected", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
            case .unconfigured:
                Label("Not set up yet", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Certificate

struct CertificateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsForm {
            if case .untrustedCertificate(let presented) = model.connection {
                Section {
                    Label(model.certificateProblem, systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Presented") { fingerprint(presented) }
                    HStack {
                        Spacer()
                        Button("Trust this certificate") { model.trustCertificate(presented) }
                    }
                }
            }
            Section {
                Picker("Check", selection: Binding(
                    get: { model.certificateMode }, set: { model.changeCertificateMode($0) })) {
                    Text("Remember fingerprint").tag(CertificateMode.pinned)
                    Text("System check").tag(CertificateMode.system)
                    Text("Accept any").tag(CertificateMode.any)
                }
                .pickerStyle(.radioGroup)
                if model.certificateMode == .pinned {
                    LabeledContent("Remembered") {
                        if model.certificateFingerprint.isEmpty {
                            Text("none yet – on the next connect").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .trailing, spacing: 6) {
                                fingerprint(model.certificateFingerprint)
                                if !model.connection.isUntrustedCertificate {
                                    Button("Forget") { model.forgetCertificate() }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("PBX certificate")
            } footer: {
                Footnote(verbatim: footer)
            }
        }
    }

    private var footer: String {
        switch model.certificateMode {
        case .pinned:
            String(localized: """
                On the first connect Fernsprecher remembers the PBX certificate and from then on only connects \
                if the PBX presents exactly this one. Suitable for the OXO's self-signed certificate.
                """)
        case .system:
            String(localized: "The certificate must come from a certificate authority this Mac trusts, e.g. a company CA.")
        case .any:
            String(localized: "Any certificate is accepted. Anyone intercepting the connection can read the PIN and call data.")
        }
    }

    private func fingerprint(_ value: String) -> some View {
        Text(CertificateFingerprint.display(value))
            .font(.system(.caption, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
}

private extension ConnectionState {
    var isUntrustedCertificate: Bool {
        if case .untrustedCertificate = self { return true }
        return false
    }
}
