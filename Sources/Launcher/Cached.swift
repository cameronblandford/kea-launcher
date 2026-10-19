import Foundation

/// A slow reading (a command-line tool, the sensors): read off the main thread, and the rows
/// come from the last answer. It is read again when it is older than `maxAge` seconds.
/// Use it from the main thread only. One read runs at a time.
final class Cached<T> {
    private var value: T?
    private var readAt = Date.distantPast
    private var reading = false
    /// The newest query's refresh. An answer that arrives late must update the rows on
    /// screen now, not the rows of the query that started the read.
    private var latestRefresh: () -> Void = {}
    private var refreshing = false
    private let maxAge: TimeInterval
    private let read: () -> T

    init(maxAge: TimeInterval = 2, _ read: @escaping () -> T) {
        self.maxAge = maxAge
        self.read = read
    }

    /// nil until the first answer; `refresh` runs when a new answer is in.
    func get(refresh: @escaping () -> Void) -> T? {
        // The coordinator answers a refresh with a call that has an empty refresh; keep ours.
        if !refreshing { latestRefresh = refresh }
        if !reading, Date().timeIntervalSince(readAt) > maxAge {
            reading = true
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let found = read()
                DispatchQueue.main.async { [self] in
                    value = found
                    readAt = Date()
                    reading = false
                    refreshing = true
                    latestRefresh()
                    refreshing = false
                }
            }
        }
        return value
    }
}
