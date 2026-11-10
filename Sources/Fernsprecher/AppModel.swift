import AppKit
import Foundation
import Observation
import os
import OxoKit

/// Setting for checking the PBX's certificate; see ``TrustPolicy``.
enum CertificateMode: String, CaseIterable {
    /// Trust on first use, then only that certificate.
    case pinned
    /// macOS validation (a CA the Mac trusts).
    case system
    case any
}

/// App state: one long-lived OXO session, polling for missed calls, and the
/// data shown in the menu.
@MainActor @Observable
final class AppModel {
    typealias Connection = ConnectionState

    static let pollInterval: Duration = .seconds(30)

    // Settings (UserDefaults); the PIN is in ``PinStore``.
    var host: String { didSet { defaults.set(host, forKey: "host") } }
    var port: Int { didSet { defaults.set(port, forKey: "port") } }
    var line: String { didSet { defaults.set(line, forKey: "line") } }
    var popupEnabled: Bool {
        didSet {
            defaults.set(popupEnabled, forKey: "popupEnabled")
            onRingingChanged?(ringingCall)
        }
    }

    /// Dialled before external numbers (trunk prefix).
    var trunkPrefix: String { didSet { defaults.set(trunkPrefix, forKey: "trunkPrefix") } }

    private(set) var certificateMode: CertificateMode {
        didSet { defaults.set(certificateMode.rawValue, forKey: "certificateMode") }
    }
    /// SHA-256 of the PBX's certificate for ``CertificateMode/pinned``, learnt
    /// on the first connect; empty while unknown.
    private(set) var certificateFingerprint: String {
        didSet { defaults.set(certificateFingerprint, forKey: "certificateFingerprint") }
    }

    /// App language; read by macOS at launch (see ``LanguageSetting``).
    private(set) var language: AppLanguage
    /// The language this process runs in; a different choice needs a restart.
    private let launchLanguage: AppLanguage
    var languageChanged: Bool { language != launchLanguage }
    private(set) var relaunching = false
    /// Logged out for a relaunch: quitting needs no further shutdown.
    private(set) var readyToQuit = false
    private(set) var relaunchError: String?
    private static let languageSetting = LanguageSetting(
        defaults: .standard, domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)

    /// Last target of "Forward …", offered again next time.
    var lastForwardNumber: String { didSet { defaults.set(lastForwardNumber, forKey: "lastForwardNumber") } }

    /// Connecting, re-login and retries; see ``SessionCoordinator``.
    private let session: SessionCoordinator<OxoClient>
    var connection: Connection { session.state }
    private(set) var displayName: String?
    /// Newest page of the call log plus older pages loaded via "Load older".
    private(set) var callLog = CallLogList()
    var calls: [CallLogEntry] { callLog.entries }
    private(set) var loadingOlderCalls = false
    private(set) var unanswered = 0
    private(set) var directory: [PhoneBookEntry] = []
    /// The user's own names for external numbers (local file).
    private(set) var addressBook = AddressBook()
    /// Set when an unreadable file could not be moved aside; saving would
    /// overwrite it.
    private var addressBookLocked = false
    /// Calls on the line right now, from the live events.
    private(set) var activeCalls: [ActiveCall] = []
    /// The line's forward; nil while unknown (not connected, not loaded yet).
    private(set) var forward: ForwardState?
    /// Whether the event channel is up (otherwise only polling runs).
    private(set) var liveEvents = false
    var ringingCall: ActiveCall? { activeCalls.first(where: \.isRinging) }
    /// Drives the call popup (set by the app delegate).
    @ObservationIgnored var onRingingChanged: ((ActiveCall?) -> Void)?
    /// Drives the connection notifications (set by the app delegate).
    @ObservationIgnored var onConnectionChanged: ((Connection) -> Void)?
    /// Short-lived feedback in the footer, e.g. "Dialling 019 …".
    private(set) var notice: String?

    private let defaults: UserDefaults
    private let pins: PinStore
    private let addressBookURL: URL
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    /// Whether a PIN is stored; cached so views never touch the file.
    private(set) var hasPin = false
    /// Why the last ``save(host:port:line:pin:)`` could not store the PIN.
    private(set) var pinError: String?
    var isConfigured: Bool { !host.isEmpty && !line.isEmpty && hasPin }
    private var pin: String? { pins.pin(account: pinAccount) }
    private var pinAccount: String { "\(line)@\(host)" }

    init(environment: AppEnvironment = AppEnvironment()) {
        let defaults = environment.defaults
        self.defaults = defaults
        pins = environment.pins
        addressBookURL = environment.addressBookURL
        session = SessionCoordinator(makeClient: environment.makeClient)
        host = defaults.string(forKey: "host") ?? ""
        port = defaults.object(forKey: "port") as? Int ?? 443
        line = defaults.string(forKey: "line") ?? ""
        popupEnabled = defaults.object(forKey: "popupEnabled") as? Bool ?? true
        trunkPrefix = defaults.string(forKey: "trunkPrefix") ?? "0"
        lastForwardNumber = defaults.string(forKey: "lastForwardNumber") ?? ""
        certificateMode = defaults.string(forKey: "certificateMode").flatMap(CertificateMode.init) ?? .pinned
        // An invalid stored value stays as is: it matches no certificate, so
        // the app refuses to connect instead of silently trusting the first one.
        let fingerprint = defaults.string(forKey: "certificateFingerprint") ?? ""
        certificateFingerprint = CertificateFingerprint.normalized(fingerprint) ?? fingerprint
        let language = Self.languageSetting.current
        self.language = language
        launchLanguage = language
        hasPin = pins.pin(account: pinAccount) != nil
        session.credentials = { [weak self] in self?.credentials }
        session.onLogin = { [weak self] client, kind in self?.loggedIn(client, kind) }
        session.onDisconnect = { [weak self] in self?.stopAll() }
        session.onStateChange = { [weak self] in self?.onConnectionChanged?($0) }
        session.reportsTakeOver = { [weak self] in self?.liveEvents ?? false }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.session.wokeUp() }
        }
        loadAddressBook()
        if isConfigured {
            Task { await connect() }
        }
    }

    private var credentials: Credentials? {
        guard isConfigured, let pin else { return nil }
        return Credentials(host: host, port: port, line: line, pin: pin, trust: trustPolicy)
    }

    private var trustPolicy: TrustPolicy {
        switch certificateMode {
        case .pinned: .pinned(certificateFingerprint.isEmpty ? nil : certificateFingerprint)
        case .system: .system
        case .any: .any
        }
    }

    // MARK: - connection

    func save(host: String, port: Int, line: String, pin: String) async {
        let account = pinAccount
        let server = (self.host, self.port)
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = port
        self.line = line.trimmingCharacters(in: .whitespaces)
        // The pinned certificate belongs to the old PBX.
        if (self.host, self.port) != server {
            certificateFingerprint = ""
        }
        if pinAccount != account {
            // Nothing of the old line may show up under the new one.
            callLog = CallLogList()
            unanswered = 0
            directory = []
            forward = nil
        }
        pinError = nil
        if !pin.isEmpty {
            do {
                try pins.setPin(pin, account: pinAccount)
            } catch {
                pinError = error.localizedDescription
            }
        }
        hasPin = pins.pin(account: pinAccount) != nil
        // Connecting now would log in with the old PIN.
        guard pinError == nil else { return }
        await session.connect(restart: true)
    }

    /// "Try again" / "Reconnect"; joins a running attempt.
    func connect() async {
        await session.connect()
    }

    func shutdown() async {
        await session.shutdown()
    }

    // MARK: - language

    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        Self.languageSetting.set(language)
        self.language = language
        relaunchError = nil
    }

    /// Start a new instance and quit. The line is freed first: the new
    /// instance logs in right away, and two logins on one line would take the
    /// session from each other. If the new instance does not start, this one
    /// connects again and stays.
    func relaunch() async {
        guard !relaunching else { return }
        relaunching = true
        relaunchError = nil
        await shutdown()   // also waits for a login still underway
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            // Quit without the usual shutdown: called from a main-actor task,
            // `terminate` would wait in a modal loop for the shutdown task,
            // which cannot run until this task returns (deadlock).
            readyToQuit = true
            NSApp.terminate(nil)
        } catch {
            OxoLog.session.error("relaunch failed: \(error.diagnosticKind, privacy: .public)")
            relaunchError = String(localized: "Restart failed: \(error.localizedDescription)")
            relaunching = false
            await connect()
        }
    }

    // MARK: - certificate

    func changeCertificateMode(_ mode: CertificateMode) {
        guard mode != certificateMode else { return }
        certificateMode = mode
        reconnect()
    }

    /// Pin the certificate the PBX presents now, after it was refused (new
    /// certificate on the PBX, or not trusted by macOS).
    func trustCertificate(_ fingerprint: String) {
        certificateMode = .pinned
        certificateFingerprint = fingerprint
        reconnect()
    }

    /// Forget the pinned certificate; the next connect learns it anew.
    func forgetCertificate() {
        certificateFingerprint = ""
        reconnect()
    }

    /// Why the PBX's certificate was refused, for the menu and settings.
    var certificateProblem: String {
        switch certificateMode {
        case .pinned:
            String(localized: """
                The PBX presents a different certificate than the remembered one. This happens when the PBX \
                got a new certificate – or when someone is intercepting the connection.
                """)
        case .system, .any:
            String(localized: "The PBX certificate is not trusted by this Mac.")
        }
    }

    private func reconnect() {
        guard isConfigured else { return }
        Task { await session.connect(restart: true) }
    }

    private func loggedIn(_ client: OxoClient, _ kind: SessionCoordinator<OxoClient>.LoginKind) {
        // Trust on first use: keep the certificate this session was set up with.
        if certificateMode == .pinned, certificateFingerprint.isEmpty,
           let fingerprint = client.certificateFingerprint {
            certificateFingerprint = fingerprint
            OxoLog.session.notice("certificate pinned")
        }
        startEvents(client)   // a re-login invalidates the old subscription
        guard kind == .connect else { return }
        displayName = session.logon?.name ?? line
        startPolling()
        Task {
            await refreshCalls()
            await refreshForward()
            await loadDirectory()
        }
    }

    private func withSession<T: Sendable>(_ operation: @Sendable (OxoClient) async throws -> T) async throws -> T {
        try await session.withSession(operation)
    }

    /// The session was replaced (other line or PBX, or a reconnect) while a
    /// load was underway; its result is dropped without a message.
    private struct Superseded: Error {}

    /// For results that land in the model: fails with ``Superseded`` unless
    /// `client` – taken when the load started – is still the session's.
    private func withSession<T: Sendable>(on client: OxoClient?,
                                          _ operation: @Sendable (OxoClient) async throws -> T) async throws -> T {
        guard let client, session.client === client else { throw Superseded() }
        let result: T
        do {
            result = try await session.withSession(operation)
        } catch {
            throw session.client === client ? error : Superseded()
        }
        guard session.client === client else { throw Superseded() }
        return result
    }

    // MARK: - polling

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                await self.pollOnce()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func stopAll() {
        stopPolling()
        stopEvents()
        forward = nil
    }

    // MARK: - live events

    /// Keep the event channel open; reconnect with backoff when the PBX
    /// drops it. Polling keeps running as a fallback either way.
    private func startEvents(_ client: OxoClient) {
        stopEvents()
        eventTask = Task { [weak self] in
            var delay: Duration = .seconds(5)
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                attempt += 1
                let opened = ContinuousClock.now
                var wasLive = false
                var received = 0
                var failure: Error?
                do {
                    for try await event in client.lineEvents() {
                        received += 1
                        switch event {
                        case .live:
                            self.liveEvents = true
                            wasLive = true
                            delay = .seconds(5)
                            OxoLog.events.notice("live (attempt \(attempt, privacy: .public))")
                        case .calls(let calls):
                            self.activeCalls = calls
                            self.onRingingChanged?(self.ringingCall)
                        case .callLogChanged:
                            self.scheduleRefresh()
                        case .staticStateChanged:
                            Task { await self.refreshForward() }
                        case .takenOver:
                            OxoLog.events.notice("session taken over by another client")
                            self.session.takenOver(client)   // ends this task via onDisconnect
                        }
                    }
                } catch {
                    failure = error
                }
                // Stopped: stopEvents() already reset the state, which may
                // belong to a newer stream by now.
                guard !Task.isCancelled else { return }
                let uptime = Int((ContinuousClock.now - opened).components.seconds)
                let summary = "attempt \(attempt), live=\(wasLive), \(received) events, after \(uptime) s, retry in \(delay.components.seconds) s"
                if let failure {
                    OxoLog.events.error("""
                        stream failed: \(failure.diagnosticKind, privacy: .public) \
                        (\(summary, privacy: .public)): \(failure.localizedDescription)
                        """)
                } else {
                    OxoLog.events.notice("stream closed by the PBX (\(summary, privacy: .public))")
                }
                self.liveEvents = false
                self.activeCalls = []
                self.onRingingChanged?(nil)
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    private func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
        liveEvents = false
        activeCalls = []
        onRingingChanged?(nil)
    }

    /// How an incoming call reached this line, e.g. "via Reception" or
    /// "for Example B 19", while ringing and once answered; nil for a direct
    /// call. Not for outgoing calls: what the PBX reports for those is not
    /// known yet.
    func route(of call: ActiveCall) -> String? {
        guard call.isIncoming else { return nil }
        if let group = call.groupName { return String(localized: "via \(group)") }
        if let number = call.initialCalledNumber, number != line {
            return String(localized: "for \(call.initialCalledName ?? name(for: number) ?? number)")
        }
        return call.redirected ? String(localized: "forwarded") : nil
    }

    /// Reload call log and counter shortly after a call ended, giving the PBX
    /// a moment to write the entry; several triggers collapse into one.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.refreshCalls()
        }
    }

    /// One poll step while connected. If the PBX is unreachable, the
    /// session is dropped and the coordinator's retry loop takes over; a
    /// lost session is handled by the coordinator.
    private func pollOnce() async {
        do {
            let count = try await withSession(on: session.client) { try await $0.unansweredCount() }
            if count != unanswered {
                unanswered = count
                await refreshCalls()
            }
            // Also catches a forward set on the desk phone, for the menu bar.
            await refreshForward()
        } catch OxoError.transport(let message) {
            session.connectionFailed(OxoError.transport(message))
        } catch OxoError.untrustedCertificate(let fingerprint) {
            session.connectionFailed(OxoError.untrustedCertificate(fingerprint))
        } catch {
            // The coordinator has dealt with a lost session and a superseded
            // result is dropped; anything else is tried again by the next poll.
        }
    }

    // MARK: - call log

    /// Called when the menu window opens: reload, then mark the missed calls
    /// in the list as seen. Older ones stay unacknowledged until loaded.
    func menuOpened() {
        guard connection == .connected else { return }
        Task {
            await refreshCalls()
            await acknowledgeMissed(callLog.unacknowledgedMissed)
            await refreshForward()
        }
    }

    func refreshCalls() async {
        let client = session.client
        do {
            let log = try await withSession(on: client) { try await $0.callLog(count: CallLogList.pageSize) }
            callLog.updateNewest(log.entries, total: log.total)
            unanswered = try await withSession(on: client) { try await $0.unansweredCount() }
        } catch is Superseded {
        } catch {
            show(String(localized: "Call log not loaded: \(error.localizedDescription)"))
        }
    }

    /// "Load older": append the next page. The user is looking at it, so
    /// its missed calls count as seen.
    func loadOlderCalls() {
        guard !loadingOlderCalls, callLog.hasOlder else { return }
        loadingOlderCalls = true
        Task {
            defer { loadingOlderCalls = false }
            let client = session.client
            do {
                let index = callLog.nextIndex
                let log = try await withSession(on: client) {
                    try await $0.callLog(index: index, count: CallLogList.pageSize)
                }
                callLog.appendOlder(log.entries, total: log.total)
                await acknowledgeMissed(log.entries.filter { $0.missed && !$0.acknowledged }.map(\.id))
            } catch is Superseded {
            } catch {
                show(String(localized: "Older calls not loaded: \(error.localizedDescription)"))
            }
        }
    }

    /// `ids` must come from the current session's call log.
    private func acknowledgeMissed(_ ids: [CallLogItemId]) async {
        guard !ids.isEmpty else { return }
        let client = session.client
        do {
            for start in stride(from: 0, to: ids.count, by: 50) {
                let chunk = Array(ids[start..<min(start + 50, ids.count)])
                try await withSession(on: client) { try await $0.acknowledge(chunk) }
                callLog.markAcknowledged(Set(chunk))
            }
            unanswered = try await withSession(on: client) { try await $0.unansweredCount() }
        } catch is Superseded {
        } catch {
            show(String(localized: "Missed calls not acknowledged: \(error.localizedDescription)"))
        }
    }

    // MARK: - forward

    /// On errors the state stays as it was, without a message.
    private func refreshForward() async {
        do {
            forward = try await withSession(on: session.client) { try await $0.forwardState() }
        } catch {
            // Superseded, not connected, or the PBX did not answer
        }
    }

    /// Forward all calls to `number`, sent as typed (like dialling on the
    /// desk phone). The PBX answers without a status and silently ignores a
    /// target it does not allow; only the state read back tells.
    func forward(to number: String) {
        lastForwardNumber = number
        Task {
            do {
                try await withSession { try await $0.forward(to: number) }
            } catch {
                show(String(localized: "Forwarding failed: \(error.localizedDescription)"))
                return
            }
            show(await awaitForward { $0?.kind == .immediate && $0?.targetNumber == number }
                 ? String(localized: "Forwarded to \(number)")
                 : String(localized: "The PBX did not accept the forward to \(number)"))
        }
    }

    func cancelForward() {
        Task {
            do {
                try await withSession { try await $0.cancelForward() }
            } catch {
                show(String(localized: "Forward not cancelled: \(error.localizedDescription)"))
                return
            }
            show(await awaitForward { $0?.isActive == false }
                 ? String(localized: "Forward cancelled")
                 : String(localized: "The PBX did not cancel the forward"))
        }
    }

    /// The PBX applies a change about 2 s later (observed on an R63): read
    /// until it shows, up to 8 times, 500 ms apart.
    private func awaitForward(_ done: (ForwardState?) -> Bool) async -> Bool {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshForward()
            if done(forward) { return true }
        }
        return false
    }

    // MARK: - directory & dialling

    func loadDirectory() async {
        do {
            directory = try await withSession(on: session.client) { try await $0.phoneBook() }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch is Superseded {
        } catch {
            show(String(localized: "Phone book not loaded: \(error.localizedDescription)"))
        }
    }

    func searchDirectory(_ query: String) -> [PhoneBookEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return directory }
        let key = AddressBook.numberKey(needle)
        return directory.filter { entry in
            entry.displayName.localizedCaseInsensitiveContains(needle)
                || key.map { AddressBook.number(entry.number, contains: $0) } == true
        }
    }

    /// Digits plus `*`, `#`, `+` (spaces, dashes, slashes and brackets ignored).
    static func dialable(_ text: String) -> String? {
        AddressBook.numberKey(text)
    }

    /// Name for a number the PBX delivers without one: internal directory
    /// first, then the user's address book.
    func name(for number: String?) -> String? {
        guard let number else { return nil }
        return directory.first { $0.number == number }?.displayName ?? addressBook.name(for: number)
    }

    // MARK: - address book

    func searchAddressBook(_ query: String) -> [AddressBookEntry] {
        addressBook.search(query)
    }

    func saveName(_ name: String, for number: String) {
        var book = addressBook
        book.set(name: name, for: number)
        store(book)
    }

    func removeName(for number: String) {
        var book = addressBook
        book.remove(number: number)
        store(book)
    }

    private func store(_ book: AddressBook) {
        guard !addressBookLocked else {
            show(String(localized: "Address book is locked: file unreadable"))
            return
        }
        do {
            try book.save(to: addressBookURL)
            addressBook = book
        } catch {
            show(String(localized: "Address book not saved: \(error.localizedDescription)"))
        }
    }

    /// An unreadable file is moved aside, never overwritten: it may hold
    /// entries the user edited by hand.
    private func loadAddressBook() {
        let url = addressBookURL
        do {
            addressBook = try AddressBook.load(from: url)
        } catch {
            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            let aside = url.deletingLastPathComponent().appending(path: "addressbook.unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                show(String(localized: "Address book unreadable, moved aside as \(aside.lastPathComponent)"))
            } catch {
                addressBookLocked = true
                show(String(localized: "Address book unreadable: \(url.path)"))
            }
        }
    }

    func answer(_ call: ActiveCall) {
        Task {
            do { try await withSession { try await $0.answer(callRef: call.callRef) } } catch {
                show(String(localized: "Answering failed: \(error.localizedDescription)"))
            }
        }
    }

    func hangup(_ call: ActiveCall) {
        Task {
            do { try await withSession { try await $0.hangup(callRef: call.callRef) } } catch {
                show(String(localized: "Hanging up failed: \(error.localizedDescription)"))
            }
        }
    }

    /// `number` in the PBX's form (call log, directory, address book); the
    /// trunk prefix is added here. A `typed` number is dialled as typed,
    /// like on the desk phone.
    func dial(_ number: String, name: String? = nil, typed: Bool = false) {
        let callee = typed ? number : AddressBook.dialString(number, trunkPrefix: trunkPrefix)
        Task {
            do {
                try await withSession { try await $0.makeCall(callee) }
                show(String(localized: "Dialling \(name ?? number) …"))
            } catch {
                show(String(localized: "Dialling failed: \(error.localizedDescription)"))
            }
        }
    }

    /// `number` in the PBX's form, i.e. without the trunk prefix.
    func copy(_ number: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(number, forType: .string)
        show(String(localized: "\(number) copied"))
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
