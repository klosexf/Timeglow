import Foundation
import Testing
@testable import MonitoringCore

struct SegmentStoreTests {
    @Test func checkpointsUpdateInsteadOfDuplicatingAndSurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var row = TrackingSegment(kind: .application, value: "test", label: "Test", start: start, end: start.addingTimeInterval(10))
        do {
            let store = try SegmentStore(url: url)
            try store.upsert([row])
            row.end = start.addingTimeInterval(20)
            try store.upsert([row])
            try store.setData(Data("settings".utf8), forKey: "preferences")
            #expect(try store.claimReminder("2026-11-12:percent:20"))
        }
        let reopened = try SegmentStore(url: url)
        let saved = try reopened.segments(from: start, to: start.addingTimeInterval(100))
        #expect(saved.count == 1)
        #expect(saved.first?.end == row.end)
        #expect(try reopened.data(forKey: "preferences") == Data("settings".utf8))
        #expect(try !reopened.claimReminder("2026-11-12:percent:20"))
        #expect(try reopened.claimReminder("2026-11-13:percent:20"))
    }

    @Test func backdatedZeroLengthCheckpointRetractsProvisionalTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SegmentStore(url: directory.appendingPathComponent("usage.sqlite"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var row = TrackingSegment(kind: .presence, value: "active", label: "active", start: start, end: start.addingTimeInterval(100))
        try store.upsert([row])
        row.end = start
        try store.upsert([row])
        #expect(try store.segments(from: start, to: start.addingTimeInterval(200)).isEmpty)
    }
}
