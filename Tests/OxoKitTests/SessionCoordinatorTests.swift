import Foundation
import Testing
@testable import OxoKit

/// Suspends callers until opened.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// The PBX's one session per line: the latest login holds it.
actor Pbx {
    private(set) var owner: FakeSession?

    func login(_ session: FakeSession) { owner = session }

    func logout(_ session: FakeSession) {
        if owner === session { owner = nil }
    }
}

/// Scriptable client: logins can block on a gate or fail; `request()` fails
/// with `badSession` until the session was renewed.
actor FakeSession: LineSession {
    var logins = 0
    var logouts = 0
    var badSessions = 0
    var requests = 0
    private let loginGates: [Int: Gate]
    private let loginError: Error?
    private let requestGate: Gate?
    private let pbx: Pbx?

    init(loginGates: [Int: Gate] = [:], loginError: Error? = nil, requestGate: Gate? = nil,
         pbx: Pbx? = nil) {
        self.loginGates = loginGates
        self.loginError = loginError
        self.requestGate = requestGate
        self.pbx = pbx
    }

    func login(line: String, password: String) async throws -> LogonResult {
        logins += 1
        let number = logins
        await loginGates[number]?.wait()
        if let loginError { throw loginError }
        await pbx?.login(self)
        return LogonResult(sessionId: "s\(number)", userName: line, name: nil, firstName: nil, lineNumber: line)
    }

    func logout() async {
        logouts += 1
        await pbx?.logout(self)
    }

    func request() async throws -> Int {
        requests += 1
        let session = logins
        await requestGate?.wait()
        if session < 2 {
            badSessions += 1
            throw OxoError.badSession
        }
        return session
    }
}

/// Hands out the given clients in order (the last one repeatedly).
@MainActor
final class Clients {
    private var queue: [FakeSession]
    private(set) var made = 0

    init(_ clients: [FakeSession]) {
        queue = clients
    }

    func next() -> FakeSession {
        made += 1
        return queue.count > 1 ? queue.removeFirst() : queue[0]
    }
}

@MainActor
final class Clock {
    var now = Date(timeIntervalSince1970: 0)
}

/// Records each requested delay; returns at once for the first `limit`, then
/// blocks until cancelled.
final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var delays: [Duration] { lock.withLock { recorded } }

    func sleep(_ delay: Duration) async throws {
        let count = lock.withLock { recorded.append(delay); return recorded.count }
        if count > limit { try await Task.sleep(for: .seconds(3600)) }
    }
}

@MainActor
func coordinator(_ clients: Clients, sleeps: Sleeps = Sleeps(limit: 0),
                 clock: Clock = Clock()) -> SessionCoordinator<FakeSession> {
    let coordinator = SessionCoordinator<FakeSession>(
        makeClient: { _ in clients.next() },
        sleep: { try await sleeps.sleep($0) },
        now: { clock.now })
    coordinator.credentials = { Credentials(host: "pbx", port: 443, line: "51", pin: "1234") }
    return coordinator
}

/// Let other tasks run until `condition` holds (or give up after ~2 s).
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
struct SessionCoordinatorTests {
    @Test func wakeAfterSessionLostDoesNotLogin() async throws {
        let client = FakeSession()
        let clock = Clock()
        let session = coordinator(Clients([client]), clock: clock)
        await session.connect()
        clock.now += 10   // lost right after login: probably taken over
        await #expect(throws: OxoError.badSession) {
            try await session.withSession { try await $0.request() }
        }
        #expect(session.state == .sessionLost)

        session.wokeUp()
        await eventually { false }   // give a stray attempt time to show up
        #expect(session.state == .sessionLost)
        #expect(await client.logins == 1)
    }

    @Test func untrustedCertificateWaitsForTheUser() async {
        let refused = FakeSession(loginError: OxoError.untrustedCertificate("ab"))
        let sleeps = Sleeps(limit: 1)
        let clients = Clients([refused])
        let session = coordinator(clients, sleeps: sleeps)
        await session.connect()
        #expect(session.state == .untrustedCertificate("ab"))

        session.wokeUp()
        await eventually { false }   // neither a retry nor the wake-up may log in
        #expect(sleeps.delays.isEmpty)
        #expect(clients.made == 1)
    }

    @Test func certificateChangeWhileConnectedStopsRetrying() async {
        let sleeps = Sleeps(limit: 1)
        let session = coordinator(Clients([FakeSession()]), sleeps: sleeps)
        await session.connect()
        session.connectionFailed(OxoError.untrustedCertificate("cd"))
        #expect(session.state == .untrustedCertificate("cd"))
        #expect(session.client == nil)
        await eventually { false }
        #expect(sleeps.delays.isEmpty)
    }

    @Test func retriesBackOffTo120Seconds() async {
        let unreachable = FakeSession(loginError: OxoError.transport("timeout"))
        let sleeps = Sleeps(limit: 4)
        let clients = Clients([unreachable])
        let session = coordinator(clients, sleeps: sleeps)
        await session.connect()
        await eventually { sleeps.delays.count == 5 }
        #expect(sleeps.delays == [.seconds(30), .seconds(60), .seconds(120), .seconds(120), .seconds(120)])
        #expect(clients.made == 5)   // first attempt + four retries
        guard case .failed = session.state else {
            Issue.record("expected .failed, got \(session.state)")
            return
        }
    }

    @Test func failedManualAttemptDoesNotResetBackoff() async {
        let unreachable = FakeSession(loginError: OxoError.transport("timeout"))
        let sleeps = Sleeps(limit: 1)
        let session = coordinator(Clients([unreachable]), sleeps: sleeps)
        await session.connect()
        await eventually { sleeps.delays.count == 2 }
        await session.connect()   // user clicks "Try again"; fails too
        await eventually { false }
        #expect(sleeps.delays == [.seconds(30), .seconds(60)])
    }

    @Test func wakeAndClickShareOneAttempt() async {
        let gate = Gate()
        let client = FakeSession(loginGates: [1: gate])
        let clients = Clients([client])
        let session = coordinator(clients)
        session.wokeUp()   // .unconfigured: ignored
        #expect(clients.made == 0)

        let first = Task { await session.connect() }
        await eventually { await client.logins == 1 }
        session.wokeUp()
        let click = Task { await session.connect() }
        await gate.open()
        await first.value
        await click.value
        #expect(session.state == .connected)
        #expect(clients.made == 1)
        #expect(await client.logins == 1)
    }

    @Test func concurrentSessionLossesShareOneRelogin() async throws {
        let requests = Gate()
        let relogin = Gate()
        let client = FakeSession(loginGates: [2: relogin], requestGate: requests)
        let clock = Clock()
        let session = coordinator(Clients([client]), clock: clock)
        await session.connect()
        clock.now += 600   // well past the take-over window

        let calls = (0..<3).map { _ in
            Task { try await session.withSession { try await $0.request() } }
        }
        await requests.open()
        await eventually { await client.badSessions == 3 }
        await relogin.open()
        for call in calls {
            #expect(try await call.value == 2)
        }
        #expect(await client.logins == 2)   // connect + one re-login
        #expect(session.state == .connected)
    }

    @Test func sessionLostAfterSwitchIsNotRetriedOnNewLine() async {
        let requests = Gate()
        let old = FakeSession(requestGate: requests)
        let new = FakeSession()
        let clock = Clock()
        let session = coordinator(Clients([old, new]), clock: clock)
        await session.connect()
        clock.now += 600   // well past the take-over window

        let call = Task { try await session.withSession { try await $0.request() } }
        await eventually { await old.requests == 1 }
        await session.connect(restart: true)   // other line saved
        #expect(session.client === new)
        await requests.open()   // old line answers late: session invalid

        await #expect(throws: OxoError.notLoggedIn) { try await call.value }
        #expect(await new.requests == 0)
        #expect(await new.logins == 1)   // no re-login either
        #expect(session.state == .connected)
    }

    @Test func reportedTakeOverStopsWithoutRelogin() async {
        let old = FakeSession()
        let new = FakeSession()
        let sleeps = Sleeps(limit: 1)
        let session = coordinator(Clients([old, new]), sleeps: sleeps)
        await session.connect()

        session.takenOver(new)   // not the session's client: ignored
        #expect(session.state == .connected)

        session.takenOver(old)
        #expect(session.state == .sessionLost)
        #expect(session.client == nil)
        session.wokeUp()
        await eventually { false }
        #expect(await old.logins == 1)
        #expect(await new.logins == 0)
        #expect(sleeps.delays.isEmpty)   // no retry loop
    }

    @Test func sessionLossWithoutLiveEventsIsNotRenewed() async throws {
        let client = FakeSession()
        let clock = Clock()
        let sleeps = Sleeps(limit: 1)
        let session = coordinator(Clients([client]), sleeps: sleeps, clock: clock)
        session.reportsTakeOver = { false }
        var states: [ConnectionState] = []
        session.onStateChange = { states.append($0) }
        await session.connect()
        clock.now += 600   // well past the take-over window

        // A take-over would not have been reported: do not take the line back.
        await #expect(throws: OxoError.badSession) {
            try await session.withSession { try await $0.request() }
        }
        #expect(session.state == .sessionLost)
        #expect(states == [.connecting, .connected, .sessionLost])
        await eventually { false }
        #expect(await client.logins == 1)
        #expect(sleeps.delays.isEmpty)   // no retry loop
    }

    @Test func lateOldAttemptDoesNotOverrideNewerConnection() async {
        let gate = Gate()
        let old = FakeSession(loginGates: [1: gate])
        let new = FakeSession()
        let session = coordinator(Clients([old, new]))

        let first = Task { await session.connect() }
        await eventually { await old.logins == 1 }
        let second = Task { await session.connect(restart: true) }   // settings saved
        await gate.open()   // the old login finishes late
        await first.value
        await second.value

        #expect(session.state == .connected)
        #expect(session.client === new)
        #expect(await old.logouts == 1)   // its late session is closed again
        #expect(await new.logins == 1)
    }

    @Test func shutdownWaitsForRunningAttempt() async {
        let pbx = Pbx()
        let gate = Gate()
        let client = FakeSession(loginGates: [1: gate], pbx: pbx)
        let session = coordinator(Clients([client]))

        let connect = Task { await session.connect() }
        await eventually { await client.logins == 1 }
        var done = false
        let shutdown = Task { await session.shutdown(); done = true }
        await eventually { false }
        #expect(!done)   // the login is still underway
        await gate.open()   // it finishes late …
        await shutdown.value
        await connect.value
        #expect(await client.logouts == 1)   // … and was closed before shutdown returned
        #expect(await pbx.owner == nil)
        #expect(session.state == .unconfigured)
    }

    @Test func shutdownWaitsForRunningRelogin() async {
        let pbx = Pbx()
        let relogin = Gate()
        let client = FakeSession(loginGates: [2: relogin], pbx: pbx)
        let clock = Clock()
        let session = coordinator(Clients([client]), clock: clock)
        await session.connect()
        clock.now += 600   // well past the take-over window

        let call = Task { try await session.withSession { try await $0.request() } }
        await eventually { await client.logins == 2 }   // re-login underway
        var done = false
        let shutdown = Task { await session.shutdown(); done = true }
        await eventually { false }
        #expect(!done)
        await relogin.open()
        await shutdown.value
        await #expect(throws: OxoError.notLoggedIn) { try await call.value }
        #expect(await pbx.owner == nil)
        #expect(session.state == .unconfigured)
    }

    @Test func wakeDuringReloginWaitsForIt() async {
        let pbx = Pbx()
        let relogin = Gate()
        let old = FakeSession(loginGates: [2: relogin], pbx: pbx)
        let new = FakeSession(pbx: pbx)
        let clock = Clock()
        let session = coordinator(Clients([old, new]), clock: clock)
        await session.connect()
        clock.now += 600   // well past the take-over window

        let call = Task { try await session.withSession { try await $0.request() } }
        await eventually { await old.logins == 2 }   // re-login underway
        session.wokeUp()
        await eventually { false }   // give a premature login time to show up
        #expect(await new.logins == 0)
        await relogin.open()   // the re-login finishes late

        await #expect(throws: OxoError.notLoggedIn) { try await call.value }
        await eventually { session.state == .connected }
        #expect(session.client === new)
        #expect(await pbx.owner === new)
    }

    @Test func retryAfterFailureDuringReloginWaitsForIt() async {
        let pbx = Pbx()
        let relogin = Gate()
        let old = FakeSession(loginGates: [2: relogin], pbx: pbx)
        let new = FakeSession(pbx: pbx)
        let clock = Clock()
        let session = coordinator(Clients([old, new]), sleeps: Sleeps(limit: 1), clock: clock)
        await session.connect()
        clock.now += 600

        let call = Task { try await session.withSession { try await $0.request() } }
        await eventually { await old.logins == 2 }
        session.connectionFailed(OxoError.transport("timeout"))   // retry starts at once
        await eventually { false }
        #expect(await new.logins == 0)
        await relogin.open()
        await eventually { session.state == .connected }

        await #expect(throws: OxoError.notLoggedIn) { try await call.value }
        #expect(session.client === new)
        #expect(await old.logouts == 1)   // the late re-login's session is closed again
        #expect(await pbx.owner === new)
    }

    @Test func reloginIsAwaitedAcrossMissingCredentials() async {
        let pbx = Pbx()
        let relogin = Gate()
        let old = FakeSession(loginGates: [2: relogin], pbx: pbx)
        let new = FakeSession(pbx: pbx)
        let clock = Clock()
        let session = coordinator(Clients([old, new]), clock: clock)
        await session.connect()
        clock.now += 600

        let call = Task { try await session.withSession { try await $0.request() } }
        await eventually { await old.logins == 2 }   // re-login underway
        let credentials = session.credentials
        session.credentials = { nil }   // line without a stored PIN selected
        await session.connect(restart: true)
        #expect(session.state == .unconfigured)
        session.credentials = credentials   // valid settings saved again
        let reconnect = Task { await session.connect(restart: true) }
        await eventually { false }
        #expect(await new.logins == 0)
        await relogin.open()   // the re-login finishes late
        await reconnect.value

        await #expect(throws: OxoError.notLoggedIn) { try await call.value }
        #expect(session.state == .connected)
        #expect(session.client === new)
        #expect(await pbx.owner === new)
    }
}
