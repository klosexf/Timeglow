import Foundation
import SQLite3

final class SegmentStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var knownQuotas: Set<String> = []

    struct StoreError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    init(url: URL, readOnly: Bool = false) throws {
        if !readOnly { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let access = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &database, access | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 1500)
            if readOnly { return }
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS segments (id TEXT PRIMARY KEY, kind TEXT NOT NULL, value TEXT NOT NULL, label TEXT NOT NULL, browser TEXT, started REAL NOT NULL, ended REAL NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS segments_range ON segments(started, ended)")
            try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS reminders (key TEXT PRIMARY KEY)")
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func upsert(_ segments: [TrackingSegment]) throws {
        guard !segments.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO segments(id,kind,value,label,browser,started,ended) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,value=excluded.value,label=excluded.label,browser=excluded.browser,started=excluded.started,ended=excluded.ended")
            defer { sqlite3_finalize(statement) }
            for row in segments {
                guard row.start.timeIntervalSince1970.isFinite, row.end.timeIntervalSince1970.isFinite, row.end >= row.start else {
                    throw StoreError(message: "记录的时间区间无效。")
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(row.id.uuidString, at: 1, to: statement)
                try bind(row.kind.rawValue, at: 2, to: statement)
                try bind(row.value, at: 3, to: statement)
                try bind(row.label, at: 4, to: statement)
                if let browser = row.browserBundleID { try bind(browser, at: 5, to: statement) }
                guard sqlite3_bind_double(statement, 6, row.start.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_double(statement, 7, row.end.timeIntervalSince1970) == SQLITE_OK else { throw failure() }
                try finish(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func segments(from: Date, to: Date) throws -> [TrackingSegment] {
        let statement = try prepare("SELECT id,kind,value,label,browser,started,ended FROM segments WHERE started < ? AND ended > ? AND ended > started ORDER BY started")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, to.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, from.timeIntervalSince1970)
        var rows: [TrackingSegment] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)), let kind = SegmentKind(rawValue: text(statement, 1)) else {
                throw StoreError(message: "本地记录格式无效，未忽略已有数据。")
            }
            rows.append(.init(id: id, kind: kind, value: text(statement, 2), label: text(statement, 3), browserBundleID: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : text(statement, 4), start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return rows
    }

    func data(forKey key: String) throws -> Data? {
        let statement = try prepare("SELECT value FROM settings WHERE key=?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func setData(_ data: Data, forKey key: String) throws {
        let statement = try prepare("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard result == SQLITE_OK else { throw failure() }
        try finish(statement)
        if key.hasPrefix("quota:") { knownQuotas.insert(key) }
    }

    func ensureQuota(_ minutes: Int, forKey key: String) throws {
        guard !knownQuotas.contains(key) else { return }
        if try data(forKey: key) == nil { try setData(JSONEncoder().encode(minutes), forKey: key) }
        knownQuotas.insert(key)
    }

    func savePreferences(_ preferences: MonitoringPreferences, quotaKey: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try setData(JSONEncoder().encode(preferences), forKey: "preferences")
            try setData(JSONEncoder().encode(preferences.quotaMinutes), forKey: quotaKey)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            knownQuotas.remove(quotaKey)
            throw error
        }
    }

    func claimReminder(_ key: String) throws -> Bool {
        let statement = try prepare("INSERT OR IGNORE INTO reminders(key) VALUES(?)")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try finish(statement)
        return sqlite3_changes(database) == 1
    }

    func releaseReminder(_ key: String) throws {
        let statement = try prepare("DELETE FROM reminders WHERE key=?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try finish(statement)
    }

    func firstRecordDate() throws -> Date? {
        let statement = try prepare("SELECT MIN(started) FROM segments WHERE kind='application' AND ended>started")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw failure() }
    }

    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> StoreError {
        StoreError(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开本地数据库。")
    }
}
