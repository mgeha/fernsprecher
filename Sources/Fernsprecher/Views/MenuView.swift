import AppKit
import OxoKit
import SwiftUI

enum MenuTab: Hashable {
    case calls, directory
}

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @ViewState private var query = ""
    @ViewState private var tab: MenuTab = .calls
    @FocusState private var searchFocused: Bool
    @ViewState private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            switch model.connection {
            case .connected:
                connectedContent
            case .connecting:
                placeholder(String(localized: "Connecting to the PBX …"), systemImage: "phone.arrow.up.right")
            case .unconfigured:
                placeholder(String(localized: "Fernsprecher is not set up yet."), systemImage: "gearshape",
                            action: (String(localized: "Set up …"), showSettings))
            case .badPin:
                placeholder(String(localized: "Extension or PIN was rejected."), systemImage: "key",
                            action: (String(localized: "Settings …"), showSettings))
            case .sessionLost:
                placeholder(String(localized: "Session lost – possibly taken over by another program on this extension."),
                            systemImage: "person.2",
                            action: (String(localized: "Reconnect"), { Task { await model.connect() } }))
            case .untrustedCertificate:
                placeholder(String(localized: "\(model.certificateProblem)\nFernsprecher is not connected."),
                            systemImage: "exclamationmark.shield",
                            action: (String(localized: "Settings …"), showSettings))
            case .failed(let message):
                placeholder(String(localized: "No connection to the PBX.\n\(message)"), systemImage: "wifi.exclamationmark",
                            action: (String(localized: "Try again"), { Task { await model.connect() } }))
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 500)
        // The menu window's own material is very thin: over a busy desktop
        // it turned mid-grey and the list text lost its contrast.
        .background(.thickMaterial)
        .background(WindowReader(window: $window))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Fires each time the menu window is shown; ignore other windows.
            guard let window, note.object as? NSWindow === window else { return }
            model.menuOpened()
            searchFocused = true
        }
    }

    private var connectedContent: some View {
        VStack(spacing: 0) {
            ForEach(model.activeCalls) { call in
                ActiveCallBar(call: call)
                Divider()
            }
            if let forward = model.forward {
                ForwardBar(forward: forward)
                    .padding([.horizontal, .top], 10)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Name or number", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(submit)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)

            Picker("", selection: $tab) {
                Text("Calls").tag(MenuTab.calls)
                Text("Phone book").tag(MenuTab.directory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            switch tab {
            case .calls:
                CallLogView(query: query)
            case .directory:
                PhoneBookView(entries: model.searchDirectory(query), own: model.searchAddressBook(query))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let notice = model.notice {
                Text(notice).lineLimit(1)
            } else if model.connection == .connected, let name = model.displayName {
                // green: live events; yellow: only polling (events reconnecting)
                Image(systemName: "circle.fill").font(.system(size: 7))
                    .foregroundStyle(model.liveEvents ? .green : .yellow)
                    .help(model.liveEvents ? String(localized: "Connected live")
                          : String(localized: "Polling every 30 s only – live connection is being set up"))
                Text(name).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("About Fernsprecher", action: showAbout)
                Button("Settings …", action: showSettings)
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// `text` and the action's title come localized.
    private func placeholder(_ text: String, systemImage: String,
                             action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let action {
                Button(action.0, action: action.1)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    /// Enter: a number is dialled; a name dials its single match in the
    /// directory and address book, otherwise the directory tab shows them.
    private func submit() {
        if let number = AppModel.dialable(query) {
            model.dial(number, typed: true)
            query = ""
            return
        }
        let matches = model.searchDirectory(query).map { ($0.number, $0.displayName) }
            + model.searchAddressBook(query).map { ($0.number, $0.name) }
        if matches.count == 1, let (number, name) = matches.first {
            model.dial(number, name: name)
            query = ""
        } else {
            tab = .directory
        }
    }

    /// The standard panel; name, version, build, copyright and icon come
    /// from Info.plist.
    private func showAbout() {
        window?.close()
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: String(localized: """
                Client for Alcatel-Lucent OmniPCX Office.

                Not a product of Alcatel-Lucent Enterprise. OmniPCX, OXO and PIMphony are trademarks of ALE.
                """),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func showSettings() {
        window?.close()   // the menu does not close by itself when another window opens
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

private struct ActiveCallBar: View {
    @Environment(AppModel.self) private var model
    let call: ActiveCall

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(call.isRinging ? .orange : call.isActive ? .green : .secondary)
                .symbolEffect(.pulse, isActive: call.isRinging)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.name ?? model.name(for: call.number) ?? call.number ?? String(localized: "Unknown"))
                    .fontWeight(.semibold).lineLimit(1)
                Text([stateText, model.route(of: call), call.number].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let number = call.number {
                Button { model.copy(number) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy number")
            }
            if call.isRinging {
                Button("Answer") { model.answer(call) }
                    .tint(.green)
            } else {
                Button("Hang up") { model.hangup(call) }
                    .tint(.red)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .contextMenu {
            if let number = call.number {
                Button("Copy number") { model.copy(number) }
            }
        }
    }

    private var icon: String {
        switch call.state {
        case .ringingIncoming: "phone.arrow.down.left"
        case .dialing, .ringingOutgoing: "phone.arrow.up.right"
        case .held: "pause.circle"
        default: "phone.connection"
        }
    }

    private var stateText: String? {
        switch call.state {
        case .ringingIncoming: String(localized: "Ringing")
        case .dialing, .initiating: String(localized: "Dialling")
        case .ringingOutgoing: String(localized: "Calling")
        case .active: String(localized: "Connected")
        case .held: String(localized: "On hold")
        case .conferenced: String(localized: "Conference")
        case .recording: String(localized: "Recording")
        case .waiting: String(localized: "Waiting")
        case .releasing: String(localized: "Ending")
        case .unknown: nil
        }
    }
}
