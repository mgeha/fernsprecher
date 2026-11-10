/// The part of the PBX call log shown in the menu: the newest page, kept
/// current by polling, plus older pages the user loaded on purpose.
///
/// The PBX pages by offset (newest first), so a new call shifts every page by
/// one; entries are matched by ``CallLogItemId`` to avoid duplicates.
public struct CallLogList: Sendable, Equatable {
    public static let pageSize = 50

    public private(set) var entries: [CallLogEntry] = []
    /// Entries in the whole PBX call log, if the PBX reported it.
    public private(set) var total: Int?

    public init() {}

    public var hasOlder: Bool {
        guard let total else { return false }
        return entries.count < total
    }

    /// PBX offset of the next older page.
    public var nextIndex: Int { entries.count }

    /// Missed calls among the loaded entries that are not acknowledged yet.
    public var unacknowledgedMissed: [CallLogItemId] {
        entries.filter { $0.missed && !$0.acknowledged }.map(\.id)
    }

    /// Replace the newest page (offset 0). Older pages the user loaded stay;
    /// entries pushed off the newest page by new calls move down into them.
    public mutating func updateNewest(_ page: [CallLogEntry], total: Int?) {
        self.total = total
        guard entries.count > Self.pageSize else {
            entries = page
            return
        }
        let ids = Set(page.map(\.id))
        entries = page + entries.filter { !ids.contains($0.id) }
    }

    /// Append the page loaded from ``nextIndex``.
    public mutating func appendOlder(_ page: [CallLogEntry], total: Int?) {
        self.total = total
        let ids = Set(entries.map(\.id))
        entries += page.filter { !ids.contains($0.id) }
    }

    public mutating func markAcknowledged(_ ids: Set<CallLogItemId>) {
        for index in entries.indices where ids.contains(entries[index].id) {
            entries[index].acknowledged = true
        }
    }
}
