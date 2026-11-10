import Foundation
import Testing
@testable import OxoKit

func space(_ host: String, method: String = NSURLAuthenticationMethodServerTrust) -> URLProtectionSpace {
    URLProtectionSpace(host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
                       authenticationMethod: method)
}

let pbxCert = String(repeating: "ab", count: 32)
let otherCert = String(repeating: "cd", count: 32)

extension TrustDelegate {
    func verdict(host: String = "192.168.1.10", _ fingerprint: String? = pbxCert,
                 systemTrusted: Bool = false) -> Verdict {
        verdict(space(host), fingerprint: fingerprint, systemTrusted: { systemTrusted })
    }
}

struct TrustTests {
    let any = TrustDelegate(host: "192.168.1.10", policy: .any)

    @Test func appliesOnlyToTheConfiguredHost() {
        #expect(any.verdict(host: "192.168.1.10") == .accept)
        #expect(any.verdict(host: "192.168.1.11") == .systemDefault)
        #expect(any.verdict(host: "192.168.1.100") == .systemDefault)
        #expect(any.verdict(host: "192.168.1.10.example.com") == .systemDefault)
        #expect(any.verdict(host: "example.com") == .systemDefault)
    }

    @Test func onlyServerTrustChallenges() {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodClientCertificate] {
            let verdict = any.verdict(space("192.168.1.10", method: method), fingerprint: pbxCert,
                                      systemTrusted: { false })
            #expect(verdict == .systemDefault)
        }
    }

    @Test func anyAcceptsEveryCertificate() {
        #expect(any.verdict(otherCert) == .accept)
        #expect(any.acceptedFingerprint == otherCert)
        #expect(any.rejectedFingerprint == nil)
    }

    @Test func systemFollowsMacOS() {
        let system = TrustDelegate(host: "192.168.1.10", policy: .system)
        #expect(system.verdict(pbxCert, systemTrusted: true) == .systemDefault)
        #expect(system.acceptedFingerprint == pbxCert)
        #expect(system.verdict(otherCert, systemTrusted: false) == .reject)
        #expect(system.rejectedFingerprint == otherCert)
    }

    @Test func pinnedAcceptsOnlyThePin() {
        let pinned = TrustDelegate(host: "192.168.1.10", policy: .pinned(pbxCert))
        #expect(pinned.verdict(otherCert, systemTrusted: true) == .reject)   // a CA does not help
        #expect(pinned.rejectedFingerprint == otherCert)
        #expect(pinned.verdict(pbxCert) == .accept)
        #expect(pinned.acceptedFingerprint == pbxCert)
        #expect(pinned.verdict(nil) == .reject)
    }

    @Test func firstUsePinsTheFirstCertificate() {
        let firstUse = TrustDelegate(host: "192.168.1.10", policy: .pinned(nil))
        #expect(firstUse.acceptedFingerprint == nil)
        #expect(firstUse.verdict(pbxCert) == .accept)
        #expect(firstUse.acceptedFingerprint == pbxCert)
        #expect(firstUse.verdict(otherCert) == .reject)   // later connections must match
        #expect(firstUse.rejectedFingerprint == otherCert)
        #expect(firstUse.verdict(pbxCert) == .accept)
    }
}

struct CertificateFingerprintTests {
    @Test func sha256OfDER() {
        #expect(CertificateFingerprint.sha256(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func normalizesCommonNotations() {
        let colons = "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD"
        let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(CertificateFingerprint.normalized(colons) == hex)
        #expect(CertificateFingerprint.normalized("sha256 Fingerprint=\(colons)\n") == hex)
        #expect(CertificateFingerprint.normalized(hex.uppercased()) == hex)
        #expect(CertificateFingerprint.normalized("BA 78 16 BF 8F 01 CF EA 41 41 40 DE 5D AE 22 23 "
                                                  + "B0 03 61 A3 96 17 7A 9C B4 10 FF 61 F2 00 15 AD") == hex)
    }

    @Test func rejectsAnythingElse() {
        #expect(CertificateFingerprint.normalized("") == nil)
        #expect(CertificateFingerprint.normalized(String(repeating: "a", count: 40)) == nil)   // SHA-1
        #expect(CertificateFingerprint.normalized(String(repeating: "a", count: 66)) == nil)
        #expect(CertificateFingerprint.normalized("xy" + String(repeating: "a", count: 64)) == nil)
    }

    @Test func displaysPairs() {
        #expect(CertificateFingerprint.display("ab01cd") == "AB:01:CD")
        #expect(CertificateFingerprint.display("") == "")
    }
}
