import Testing
import OxoKit
@testable import Fernsprecher

struct ForwardTests {
    /// The test runner has no translations: these are the English texts.
    @Test func forwardStates() {
        func directory(_ number: String?) -> String? { number == "28" ? "Example B" : nil }
        #expect(ForwardState.off.text(name: directory) == "No forward")
        #expect(ForwardState(kind: .immediate, targetNumber: "11", targetName: "Reception", toVoiceMail: false)
                    .text(name: directory) == "Forwarded to 11 · Reception")
        #expect(ForwardState(kind: .immediate, targetNumber: "28", targetName: nil, toVoiceMail: false)
                    .text(name: directory) == "Forwarded to 28 · Example B")
        #expect(ForwardState(kind: .onBusy, targetNumber: "01230000003", targetName: nil, toVoiceMail: false)
                    .text(name: directory) == "When busy to 01230000003")
        #expect(ForwardState(kind: .onNoAnswer, targetNumber: "729", targetName: nil, toVoiceMail: true)
                    .text(name: directory) == "On no answer to voicemail")
    }
}
