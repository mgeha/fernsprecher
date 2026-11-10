import Foundation
import Observation

/// What the coordinator needs from a client; ``OxoClient`` in the app, a fake
/// in tests.
public protocol LineSession: AnyObject, Sendable {
    @discardableResult
    func login(line: String, password: String) async throws -> LogonResult
    func logout() async
}

extension OxoClient: LineSession {}

public struct Credentials: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var line: String
    public var pin: String
    public var trust: TrustPolicy

    public init(host: String, port: Int, line: String, pin: String, trust: TrustPolicy = .system) {
        self.host = host
        self.port = port
        self.line = line
        self.pin = pin
        self.trust = trust
    }
}

public enum ConnectionState: Equatable, Sendable {
    case unconfigured
    case connecting
    case connected
    /// Network or PBX problem; retried automatically with backoff.
    case failed(String)
    /// PIN rejected; needs the user.
    case badPin
    /// Another client took over the line (the OXO allows one session per
    /// line): reported by the PBX, or the session was lost right after a
    /// login or while no take-over would have been reported (a PBX restart
    /// looks the same). Stays until the user reconnects.
    case sessionLost
    /// The PBX presented a certificate the trust policy refuses (its SHA-256
    /// fingerprint): changed since it was pinned, or not trusted by macOS.
    /// Needs the user.
    case untrustedCertificate(String)
}

/// Owns the one session on the line and decides when to (re)connect.
///
/// - At most one login runs at a time: wake-ups and clicks join a running
///   attempt; ``connect(restart:)`` supersedes it. A new attempt waits for the
///   superseded attempt and re-login to end, so a late login cannot
///   invalidate the newer session on the PBX.
/// - Results of superseded attempts are discarded (`generation`).
/// - After a failure a single retry loop waits 30 → 60 → 120 s, then every
///   120 s; failures of other attempts do not reset it, a success does.
/// - Requests that hit `badSession` share one re-login – only while a
///   take-over would have been reported (``reportsTakeOver``); otherwise the
///   session counts as lost, so the line is never silently taken back.
@MainActor @Observable
public final class SessionCoordinator<Client: LineSession> {
    public enum LoginKind: Sendable { case connect, relogin }

    public static var retryDelays: [Duration] { [.seconds(30), .seconds(60), .seconds(120)] }
    /// A session lost this soon after logging in counts as taken over.
    public static var takeOverWindow: TimeInterval { 120 }

    public private(set) var state: ConnectionState = .unconfigured {
        didSet {
            guard state != oldValue else { return }
            OxoLog.session.notice("state: \(self.state.diagnosticName, privacy: .public)")
            onStateChange?(state)
        }
    }
    public private(set) var client: Client?
    public private(set) var logon: LogonResult?

    /// Current settings, or nil when not set up.
    @ObservationIgnored public var credentials: @MainActor () -> Credentials? = { nil }
    /// After every successful login, with the client to use.
    @ObservationIgnored public var onLogin: ((Client, LoginKind) -> Void)?
    /// When the session was dropped (events and polling must stop).
    @ObservationIgnored public var onDisconnect: (() -> Void)?
    /// After every change of ``state``.
    @ObservationIgnored public var onStateChange: ((ConnectionState) -> Void)?
    /// Whether the PBX would report a take-over right now (event channel up).
    @ObservationIgnored public var reportsTakeOver: @MainActor () -> Bool = { true }

    @ObservationIgnored private let makeClient: @MainActor (Credentials) -> Client
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date

    /// Bumped whenever the session is replaced or dropped; work started under
    /// an older generation must not touch the state.
    @ObservationIgnored private var generation = 0
    /// Bumped on every successful login (connect or re-login).
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var attempt: Task<Void, Never>?
    @ObservationIgnored private var relogin: Task<Client, Error>?
    /// A re-login dropped with its session may still be talking to the PBX;
    /// the next attempt waits for it.
    @ObservationIgnored private var droppedRelogin: Task<Client, Error>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var lastLogin: Date?

    public init(makeClient: @escaping @MainActor (Credentials) -> Client,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @MainActor () -> Date = { .now }) {
        self.makeClient = makeClient
        self.sleep = sleep
        self.now = now
    }

    // MARK: - connecting

    /// One connection attempt. Joins an attempt already running unless
    /// `restart` (settings changed), which supersedes it.
    public func connect(restart: Bool = false) async {
        if let attempt, !restart {
            await attempt.value
            return
        }
        await startAttempt().value
    }

    /// After sleep: reconnect, unless the user has to act first.
    public func wokeUp() {
        switch state {
        case .unconfigured, .badPin, .sessionLost, .untrustedCertificate:
            return
        case .connecting, .connected, .failed:
            if attempt == nil { startAttempt() }
        }
    }

    /// The PBX became unreachable while connected: drop the session and let
    /// the retry loop reconnect.
    public func connectionFailed(_ error: Error) {
        guard state == .connected else { return }
        OxoLog.session.error("connection lost: \(error.diagnosticKind, privacy: .public)")
        drop()
        settle(after: error)
    }

    /// The PBX reported that another client took over the line (see
    /// ``OxoEvent/isTakeOver(of:)``). Ignored unless `client` is still the
    /// session's.
    public func takenOver(_ client: Client) {
        guard state == .connected, self.client === client else { return }
        drop()
        stopRetrying()
        state = .sessionLost
    }

    /// Logs out and returns once no login of this coordinator is still
    /// talking to the PBX: a running attempt or re-login is superseded and
    /// logs out by itself when its answer arrives, so it is awaited too.
    /// Otherwise a process started right after (relaunch) could log in first
    /// and then lose the line to the late login.
    public func shutdown() async {
        let client = self.client
        let pending = attempt
        let relogins = [relogin, droppedRelogin].compactMap { $0 }
        drop()
        stopRetrying()
        state = .unconfigured
        await client?.logout()
        await pending?.value
        for relogin in relogins { _ = try? await relogin.value }
    }

    @discardableResult
    private func startAttempt() -> Task<Void, Never> {
        let previous = attempt
        previous?.cancel()
        let old = client
        drop()
        let gen = generation
        guard let credentials = credentials() else {
            stopRetrying()
            state = .unconfigured
            // Keep `droppedRelogin` for the next attempt to wait on; the old
            // session is closed once a late re-login is done with it.
            let previousRelogin = droppedRelogin
            if let old { Task { _ = try? await previousRelogin?.value; await old.logout() } }
            return Task {}
        }
        let previousRelogin = droppedRelogin
        droppedRelogin = nil
        state = .connecting
        let task = Task { @MainActor [weak self] in
            await previous?.value
            _ = try? await previousRelogin?.value
            await old?.logout()
            guard let self, gen == self.generation else { return }
            let client = self.makeClient(credentials)
            do {
                let logon = try await client.login(line: credentials.line, password: credentials.pin)
                guard gen == self.generation else {
                    await client.logout()
                    return
                }
                self.attempt = nil
                self.client = client
                self.logon = logon
                self.loggedIn()
                self.state = .connected
                self.stopRetrying()
                self.onLogin?(client, .connect)
            } catch {
                guard gen == self.generation else { return }
                self.attempt = nil
                self.failed(error)
            }
        }
        attempt = task
        return task
    }

    // MARK: - session use

    /// Run an operation on the session. On `badSession` the session is
    /// renewed once (shared by all requests failing at the same time) and the
    /// operation repeated – on the same client only: if the session was
    /// replaced meanwhile (other line or PBX), it is not repeated.
    public func withSession<T: Sendable>(_ operation: @Sendable (Client) async throws -> T) async throws -> T {
        guard state == .connected, let client else { throw OxoError.notLoggedIn }
        let seen = epoch
        do {
            return try await operation(client)
        } catch OxoError.badSession {
            return try await operation(try await renewSession(of: client, seen: seen))
        }
    }

    private func renewSession(of failed: Client, seen: Int) async throws -> Client {
        guard self.client === failed else { throw OxoError.notLoggedIn }
        if let relogin { return try await relogin.value }
        guard state == .connected, let client else { throw OxoError.notLoggedIn }
        // Someone else already renewed it while this request was underway.
        if epoch != seen { return client }
        let recent = lastLogin.map { now().timeIntervalSince($0) < Self.takeOverWindow } ?? false
        // Without the event channel a take-over shows up only as
        // `badSession`; a re-login would take the line back unnoticed.
        if recent || !reportsTakeOver() {
            let reason = recent ? "right after login" : "no live events"
            OxoLog.session.notice("session lost (\(reason, privacy: .public)): not renewed")
            drop()
            stopRetrying()
            state = .sessionLost
            throw OxoError.badSession
        }
        guard let credentials = credentials() else { throw OxoError.notLoggedIn }
        OxoLog.session.notice("session expired: re-login")
        let gen = generation
        let task = Task { @MainActor [weak self] () throws -> Client in
            do {
                try await client.login(line: credentials.line, password: credentials.pin)
            } catch {
                if let self, gen == self.generation {
                    self.relogin = nil
                    self.drop()
                    self.failed(error)
                }
                throw error
            }
            guard let self, gen == self.generation else {
                // Dropped meanwhile: end the session it just took over.
                await client.logout()
                throw OxoError.notLoggedIn
            }
            self.relogin = nil
            self.loggedIn()
            self.onLogin?(client, .relogin)
            return client
        }
        relogin = task
        return try await task.value
    }

    // MARK: - state

    private func loggedIn() {
        lastLogin = now()
        epoch += 1
    }

    private func failed(_ error: Error) {
        OxoLog.session.error("login failed: \(error.diagnosticKind, privacy: .public)")
        settle(after: error)
    }

    /// State after a failed login or a lost connection: retried, unless the
    /// user has to act first.
    private func settle(after error: Error) {
        switch error {
        case OxoError.badPassword:
            stopRetrying()
            state = .badPin
        case OxoError.untrustedCertificate(let fingerprint):
            stopRetrying()
            state = .untrustedCertificate(fingerprint)
        default:
            state = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    /// Forget the current session and invalidate all work started for it.
    private func drop() {
        generation += 1
        attempt = nil
        if let relogin { droppedRelogin = relogin }
        relogin = nil
        let had = client != nil
        client = nil
        logon = nil
        if had { onDisconnect?() }
    }

    // MARK: - retry loop

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self, sleep = self.sleep] in
            while !Task.isCancelled {
                guard let delay = self?.nextRetryDelay() else { return }
                OxoLog.session.notice("retry in \(delay.components.seconds, privacy: .public) s")
                do { try await sleep(delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.connect()
                guard !Task.isCancelled else { return }
                // Success, a rejected PIN etc. stop the loop via stopRetrying().
                switch self.state {
                case .failed, .connecting: continue
                default: return
                }
            }
        }
    }

    private func nextRetryDelay() -> Duration {
        let delays = Self.retryDelays
        defer { retryCount += 1 }
        return delays[min(retryCount, delays.count - 1)]
    }

    private func stopRetrying() {
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
    }
}
