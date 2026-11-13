import Foundation

/// The store is transferred here after bootstrap and is never used outside this queue.
/// Enqueuing is synchronous, so event order does not depend on Task scheduling.
final class SegmentWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Timeglow.database-writer", qos: .utility)
    private let store: SegmentStore

    init(store: SegmentStore) { self.store = store }

    func enqueue<Value: Sendable>(_ operation: @escaping @Sendable (SegmentStore) throws -> Value,
                                 completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try operation(store) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Only lifecycle boundaries wait: the process must not exit with queued writes.
    func drain() { queue.sync {} }
}
