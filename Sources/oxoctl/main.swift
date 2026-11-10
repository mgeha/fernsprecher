// oxoctl – developer CLI to test OxoKit against a real PBX.
//
//   swift run oxoctl <host> --line <extension> --password-file ~/.oxoctl-pin <command>
//
// Commands: version | login | calllog [count] | missed | phonebook [name] | call <number>
//           userstate [loginName]   (read only: getOXOUserState, session id redacted)
//           forward <number>|off    (XmlPhone setForwardState)
//           shell                   (one session, events printed meanwhile; commands on stdin:
//                                    probe|tree <method>, fwd <TYPE> <number|-> [TARGETTYPE],
//                                    dnd on|off, noanswer vm|<number> [delay] | off, call <number>,
//                                    callop <method> <InvokeType> <callRef>, sleep <s>, quit)
//           monitor [--raw file]   (prints events until Ctrl+C; --raw appends the
//                                   envelopes with the session id redacted)
// The password is read from the file's first line (or prompted, hidden);
// oxoctl does not print it.
// Certificate: macOS validation by default; --fingerprint <sha256> accepts only
// that certificate, --insecure any (and prints its fingerprint).
import Foundation
import OxoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

let line = option("--line")
let rawFile = option("--raw")
let passwordFile = option("--password-file")
let port = option("--port").flatMap(Int.init) ?? 443
let fingerprint = option("--fingerprint")
let insecure = args.contains("--insecure")
args.removeAll { $0 == "--insecure" }
guard args.count >= 2 else {
    fail("usage: oxoctl <host> --line <extension>[--password-file f] [--fingerprint sha256 | --insecure] <version|login|calllog|missed|phonebook|call|userstate|forward|monitor|shell> …")
}
let host = args[0]
let command = args[1]
let rest = Array(args.dropFirst(2))

@MainActor func password() -> String {
    if let passwordFile {
        let path = (passwordFile as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let first = text.split(whereSeparator: \.isNewline).first else {
            fail("cannot read password file")
        }
        return String(first)
    }
    guard let entered = getpass("PIN for line \(line ?? "?"): ") else { fail("no PIN") }
    return String(cString: entered)
}

let timeFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

let trust: TrustPolicy
if insecure {
    trust = .any
} else if let fingerprint {
    guard let pin = CertificateFingerprint.normalized(fingerprint) else {
        fail("--fingerprint: expected a SHA-256 fingerprint (64 hex digits)")
    }
    trust = .pinned(pin)
} else {
    trust = .system
}
let client = OxoClient(host: host, port: port, trust: trust)

/// With --insecure, show which certificate was taken (on stderr).
@MainActor func showCertificate() {
    guard insecure, let seen = client.certificateFingerprint else { return }
    FileHandle.standardError.write(Data("certificate SHA-256 \(CertificateFingerprint.display(seen))\n".utf8))
}

do {
    if command == "version" {
        print("API version:", try await client.apiVersion() ?? "?")
        showCertificate()
        exit(0)
    }
    guard let line else { fail("--line is required") }
    let logon = try await client.login(line: line, password: password())
    showCertificate()
    switch command {
    case "login":
        print("Logged in: line=\(logon.lineNumber ?? "?") name=\(logon.name ?? "")")
    case "calllog":
        let log = try await client.callLog(count: rest.first.flatMap(Int.init) ?? 20)
        print("\(log.total.map(String.init) ?? "?") entries total; showing \(log.entries.count):")
        for entry in log.entries {
            let date = entry.date.map(timeFormat.string(from:)) ?? "?"
            let direction = entry.incoming ? "in " : "out"
            let state = entry.answered ? "answered" : (entry.acknowledged ? "missed  " : "MISSED  ")
            let number = entry.number ?? "?"
            print("  \(date)  \(direction) \(state)  \(String(repeating: " ", count: max(0, 14 - number.count)))\(number)  \(entry.name ?? "")")
        }
    case "missed":
        print("Unacknowledged missed calls:", try await client.unansweredCount())
    case "phonebook":
        let book = try await client.phoneBook(name: rest.first ?? "")
        print("\(book.count) entries:")
        for entry in book {
            print("  \(String(repeating: " ", count: max(0, 14 - entry.number.count)))\(entry.number)  \(entry.displayName)")
        }
    case "monitor":
        print("Listening for events on line \(line) (Ctrl+C to stop)…")
        let sessionId = await client.sessionId ?? ""
        let raw = rawFile.map { (($0 as NSString).expandingTildeInPath) }
        if let raw, !FileManager.default.fileExists(atPath: raw) {
            FileManager.default.createFile(atPath: raw, contents: nil)
        }
        let rawHandle = raw.flatMap { FileHandle(forWritingAtPath: $0) }
        rawHandle?.seekToEndOfFile()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        for try await event in client.events() {
            if let rawHandle {
                let redacted = event.raw.replacingOccurrences(of: sessionId, with: "SID")
                rawHandle.write(Data("<!-- \(clock.string(from: .now)) -->\n\(redacted)\n".utf8))
            }
            if event.name == "e_ping" { continue }
            var fields = ["state", "number", "name", "callRef", "cause", "changeFlag", "subscribeId",
                          "isCurrentCall", "callIsRedirect", "initialCalledNumber", "initialCalledName",
                          "groupName", "groupNumber"]
                .compactMap { key in event.payload.find(key).map { "\(key)=\($0.text)" } }
            if let sid = event.payload.find("sessionId")?.text, !sid.isEmpty {
                fields.append(sid == sessionId ? "session=own" : "session=other")
            }
            print("\(clock.string(from: .now))  \(event.name)  \(fields.joined(separator: " "))")
        }
        print("Event stream closed by the PBX.")
    case "userstate":
        let loginName = rest.first ?? line
        let state = try await client.userState(loginName: loginName)
        let sessionId = await client.sessionId ?? ""
        func show(_ node: OxoKit.XMLNode, depth: Int) {
            let text = sessionId.isEmpty ? node.text : node.text.replacingOccurrences(of: sessionId, with: "SID")
            print(String(repeating: "  ", count: depth) + node.name + (text.isEmpty ? "" : " = \(text)"))
            node.children.forEach { show($0, depth: depth + 1) }
        }
        print("getOXOUserState loginName=\(loginName) (login: userName=\(logon.userName ?? "?"))")
        show(state, depth: 0)
    case "forward":
        guard let target = rest.first else {
            await client.logout()
            fail("forward needs a number or 'off'")
        }
        print("before: \(try await client.forwardState())")
        // Listen on the event channel meanwhile, to see whether the PBX reports the change.
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let listener = Task {
            for try await event in client.events() {
                if ["e_ping", "e_callState", "e_nomadeState"].contains(event.name) { continue }
                print("  event \(clock.string(from: .now)) \(event.name)")
                if let forward = event.payload.find("forwardState") {
                    print("    forwardState: " + forward.children.map { "\($0.name)=\($0.text)" }.joined(separator: " "))
                }
            }
        }
        try await Task.sleep(for: .seconds(4))   // subscribe and initial state events first
        print("setForwardState \(target == "off" ? "NO_FORWARD" : "IMMEDIATE \(target)") …")
        if target == "off" {
            try await client.cancelForward()
        } else {
            try await client.forward(to: target)
        }
        print("  sent, no error")
        try await Task.sleep(for: .seconds(6))
        print("after:  \(try await client.forwardState())")
        listener.cancel()
    case "shell":
        let sessionId = await client.sessionId ?? ""
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        func flat(_ node: OxoKit.XMLNode, _ path: String = "") -> [String] {
            let key = path.isEmpty ? node.name : path + "." + node.name
            if node.children.isEmpty {
                let text = node.text.replacingOccurrences(of: sessionId, with: "SID")
                return text.isEmpty ? [] : ["\(key)=\(text)"]
            }
            return node.children.flatMap { flat($0, path.isEmpty ? "" : key) }
        }
        func say(_ text: String) { print("\(clock.string(from: .now))  \(text)"); fflush(stdout) }
        let listener = Task {
            for try await event in client.events() {
                if event.name == "e_ping" { continue }
                say("EVENT \(event.name)  " + flat(event.payload).joined(separator: " "))
            }
            say("EVENT stream closed")
        }
        // Verbs that index into their arguments: minimum count and usage line.
        let required: [String: (count: Int, usage: String)] = [
            "probe": (1, "probe <operation>"),
            "tree": (1, "tree <operation>"),
            "fwd": (1, "fwd <type> [number|-] [targetType]"),
            "noanswer": (1, "noanswer <number|vm|off> [delay]"),
            "call": (1, "call <number>"),
            "callop": (3, "callop <operation> <type> <callRef>"),
        ]
        say("ready (line \(line))")
        for try await input in FileHandle.standardInput.bytes.lines {
            let words = input.split(separator: " ").map(String.init)
            guard let verb = words.first else { continue }
            let arg = Array(words.dropFirst())
            say("> " + input)
            if let need = required[verb], arg.count < need.count {
                say("usage: " + need.usage)
                continue
            }
            do {
                switch verb {
                case "sleep": try await Task.sleep(for: .seconds(Double(arg.first ?? "1") ?? 1))
                case "quit": break
                case "probe": say(flat(try await client.probe(arg[0])).joined(separator: " "))
                case "tree":
                    func tree(_ node: OxoKit.XMLNode, _ depth: Int) {
                        print(String(repeating: "  ", count: depth) + node.name + (node.text.isEmpty ? "" : " = \(node.text)"))
                        node.children.forEach { tree($0, depth + 1) }
                    }
                    tree(try await client.probe(arg[0]), 0)
                case "fwd":
                    try await client.probeForward(type: arg[0], number: arg.count > 1 && arg[1] != "-" ? arg[1] : "",
                                                  targetType: arg.count > 2 ? arg[2] : "NUMBER")
                    say("sent")
                case "dnd": say(flat(try await client.probeDoNotDisturb(arg.first == "on")).joined(separator: " "))
                case "noanswer":
                    let response = arg.first == "off" ? try await client.probe("cancelDynamicRouting")
                        : try await client.probeDynamicRouting(toVM: arg[0] == "vm", number: arg[0] == "vm" ? "" : arg[0],
                                                              delay: Int(arg.count > 1 ? arg[1] : "20") ?? 20)
                    say(flat(response).joined(separator: " "))
                case "call": try await client.makeCall(arg[0]); say("makeCall OK")
                case "callop":
                    say(flat(try await client.probeCall(arg[0], type: arg[1], callRef: arg[2])).joined(separator: " "))
                default: say("?")
                }
            } catch {
                say("ERROR \(error.localizedDescription)")
            }
            if verb == "quit" { break }
        }
        listener.cancel()
    case "call":
        guard let number = rest.first else {
            await client.logout()
            fail("call needs a number")
        }
        try await client.makeCall(number)
        print("makeCall \(number): OK")
    default:
        await client.logout()
        fail("unknown command \(command)")
    }
    await client.logout()
} catch OxoError.untrustedCertificate(let seen) {
    fail("""
        Error: certificate refused, SHA-256 \(CertificateFingerprint.display(seen))
        Check it, then pass --fingerprint \(seen) (or --insecure to skip the check).
        """)
} catch {
    await client.logout()
    fail("Error: \(error.localizedDescription)")
}
