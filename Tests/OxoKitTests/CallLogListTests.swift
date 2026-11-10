import Testing
@testable import OxoKit

/// Call number `n`; higher numbers are newer.
func call(_ n: Int, missed: Bool = false, acknowledged: Bool = false) -> CallLogEntry {
    CallLogEntry(id: CallLogItemId(timeId: "\(n)", diffId: "0"), date: nil, number: "\(n)", name: nil,
                 incoming: true, answered: !missed, acknowledged: acknowledged, outcome: .normal)
}

/// The PBX's page at `index` of a log whose newest call is `newest`.
func page(newest: Int, index: Int, count: Int = CallLogList.pageSize) -> [CallLogEntry] {
    (0..<count).map { newest - index - $0 }.filter { $0 > 0 }.map { call($0) }
}

struct CallLogListTests {
    @Test func pollingKeepsOlderPages() {
        var list = CallLogList()
        list.updateNewest(page(newest: 200, index: 0), total: 200)
        list.appendOlder(page(newest: 200, index: list.nextIndex), total: 200)
        #expect(list.entries.count == 100)

        // Three new calls, then the next poll.
        list.updateNewest(page(newest: 203, index: 0), total: 203)
        #expect(list.entries.map { Int($0.id.timeId)! } == Array((101...203).reversed()))
        #expect(list.hasOlder)
    }

    @Test func withoutOlderPagesTheListStaysOnePage() {
        var list = CallLogList()
        list.updateNewest(page(newest: 200, index: 0), total: 200)
        list.updateNewest(page(newest: 203, index: 0), total: 203)
        #expect(list.entries.count == CallLogList.pageSize)
        #expect(list.entries.first?.id.timeId == "203")
    }

    @Test func shiftedPageAddsNoDuplicates() {
        var list = CallLogList()
        list.updateNewest(page(newest: 200, index: 0), total: 200)   // 200…151
        // Two calls arrive before "Load older": offset 50 now starts at 152.
        list.appendOlder(page(newest: 202, index: list.nextIndex), total: 202)
        let numbers = list.entries.map { Int($0.id.timeId)! }
        #expect(numbers == Array((103...200).reversed()))
        #expect(Set(numbers).count == numbers.count)
    }

    @Test func onlyLoadedMissedCallsAreAcknowledged() {
        var list = CallLogList()
        list.updateNewest([call(5), call(4, missed: true), call(3, missed: true, acknowledged: true)], total: 120)
        #expect(list.unacknowledgedMissed == [CallLogItemId(timeId: "4", diffId: "0")])

        list.markAcknowledged(Set(list.unacknowledgedMissed))
        #expect(list.unacknowledgedMissed.isEmpty)
        #expect(list.hasOlder)   // the other 117 entries were never touched
    }
}
