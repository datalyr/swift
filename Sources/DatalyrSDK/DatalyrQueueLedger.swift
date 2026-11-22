import Foundation

/// The dead-letter store and the dropped-event counts, behind ONE lock (review).
///
/// Both are read-modify-write over UserDefaults. Before, two concurrent dead-letter writes
/// could each read the same list and the second write would lose the first's event, and a
/// slower count write could store an older total last. Every operation here runs whole
/// under `lock` with synchronous storage access, so nothing is lost and a count never goes
/// down. One instance per process, because the storage keys are process-wide.
internal final class QueueLedger {
    static let shared = QueueLedger()

    private let lock = NSLock()
    private let storage = DatalyrStorage.shared

    init() {}

    static func dropCountKey(_ reason: DatalyrEventQueue.DropReason) -> String {
        "dropped_events_\(reason.rawValue)"
    }

    // MARK: Drop counts

    /// Adds `n` to the stored count for `reason` and returns the new total.
    @discardableResult
    func countDrop(_ reason: DatalyrEventQueue.DropReason, _ n: Int = 1) -> Int {
        lock.withLock {
            let key = Self.dropCountKey(reason)
            let total = Int(storage.getDoubleSync(key) ?? 0) + max(n, 0)
            storage.setDoubleSync(key, value: Double(total))
            return total
        }
    }

    func dropCounts() -> [String: Int] {
        lock.withLock {
            var out: [String: Int] = [:]
            for reason in DatalyrEventQueue.DropReason.allCases {
                if let n = storage.getDoubleSync(Self.dropCountKey(reason)), n > 0 { out[reason.rawValue] = Int(n) }
            }
            return out
        }
    }

    // MARK: Dead-letter store

    /// Appends `event`. Over `capacity`, drops the oldest entry for which `isCritical` is
    /// false (else the oldest), and counts each drop as `dead_letter_full`. Returns how many
    /// entries were dropped.
    @discardableResult
    func appendDeadLetter(_ event: QueuedEvent, capacity: Int, isCritical: (QueuedEvent) -> Bool) -> Int {
        lock.withLock {
            var dl = storage.getCodableArraySync(StorageKeys.deadLetterQueue, type: QueuedEvent.self) ?? []
            dl.append(event)
            var overflow = 0
            while dl.count > capacity {
                let idx = dl.firstIndex(where: { !isCritical($0) }) ?? 0
                dl.remove(at: idx)
                overflow += 1
            }
            storage.setCodableArraySync(StorageKeys.deadLetterQueue, value: dl)
            if overflow > 0 {
                let key = Self.dropCountKey(.deadLetterFull)
                storage.setDoubleSync(key, value: Double(Int(storage.getDoubleSync(key) ?? 0) + overflow))
            }
            return overflow
        }
    }

    func deadLetterEntries() -> [QueuedEvent] {
        lock.withLock { storage.getCodableArraySync(StorageKeys.deadLetterQueue, type: QueuedEvent.self) ?? [] }
    }

    /// Removes the entries with these event ids, keeping any added since they were read.
    func removeDeadLetters(eventIds: Set<String>) {
        guard !eventIds.isEmpty else { return }
        lock.withLock {
            var dl = storage.getCodableArraySync(StorageKeys.deadLetterQueue, type: QueuedEvent.self) ?? []
            dl.removeAll { eventIds.contains($0.payload.eventId) }
            storage.setCodableArraySync(StorageKeys.deadLetterQueue, value: dl)
        }
    }
}
