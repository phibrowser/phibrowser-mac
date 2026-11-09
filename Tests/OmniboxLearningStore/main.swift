import Foundation

func AppLogInfo(_ message: @autoclosure () -> String) {}
func AppLogWarn(_ message: @autoclosure () -> String) {}

@main
enum OmniboxLearningStoreTests {
    static let day: TimeInterval = 24 * 60 * 60

    @MainActor
    static func main() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phi-omnibox-learning-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = OmniboxLearningStore.Limits()
        limits.saveDelay = .milliseconds(1)
        let now = Date()

        let url = directory.appendingPathComponent("learning.json")
        let store = OmniboxLearningStore(fileURL: url, limits: limits, now: now)
        store.record(text: "1", kind: .pin, entityID: "a", now: now)
        store.record(text: "1", kind: nil, entityID: nil, now: now.addingTimeInterval(1))
        precondition(store.entries.count == 1 && store.entries.first?.kind == nil,
                     "The latest choice for a text replaces the previous one")
        store.record(text: "", kind: .pin, entityID: "a", now: now)
        store.record(text: String(repeating: "x", count: 257), kind: .pin, entityID: "a", now: now)
        store.record(text: "2", kind: .pin, entityID: nil, now: now)
        precondition(store.entries.count == 1, "Empty, oversized or half-specified choices are not recorded")

        for index in 0..<8 {
            store.record(text: "t\(index)", kind: .pin, entityID: index % 2 == 0 ? "a" : "gone",
                         now: now.addingTimeInterval(Double(index + 2)))
        }
        let snapshot = store.snapshotEntries(for: ["pin:a"], now: now)
        precondition(snapshot.count == 5 && !snapshot.contains { $0.entityID == "gone" },
                     "Ordinary choices and choices of present entities are sent")
        precondition(snapshot.first?.text == "t6", "Most recent first")
        var capped = limits
        capped.maxEntries = 3
        let small = OmniboxLearningStore(fileURL: directory.appendingPathComponent("none.json"),
                                         limits: capped, now: now)
        for index in 0..<5 { small.record(text: "q\(index)", kind: nil, entityID: nil,
                                          now: now.addingTimeInterval(Double(index))) }
        precondition(small.entries.map(\.text).sorted() == ["q2", "q3", "q4"], "Oldest choices are evicted")
        var budget = limits
        budget.maxSnapshotBytes = 120
        let budgeted = OmniboxLearningStore(fileURL: directory.appendingPathComponent("none2.json"),
                                            limits: budget, now: now)
        for index in 0..<5 { budgeted.record(text: "q\(index)", kind: nil, entityID: nil, now: now) }
        let fitted = budgeted.snapshotEntries(for: [], now: now)
        precondition(!fitted.isEmpty && fitted.count < 5 &&
                     (try! JSONEncoder().encode(fitted)).count <= 120, "Snapshot stays within its byte budget")
        let keys: Set<String> = ["pin:a"]

        await waitForFile(url, entries: store.entries.count)
        let reloaded = OmniboxLearningStore(fileURL: url, limits: limits, now: now)
        precondition(reloaded.entries == store.entries, "Entries persist across instances")
        let expired = OmniboxLearningStore(fileURL: url, limits: limits, now: now.addingTimeInterval(91 * day))
        precondition(expired.entries.isEmpty, "Entries older than 90 days are dropped on load")
        precondition(store.snapshotEntries(for: keys, now: now.addingTimeInterval(91 * day)).isEmpty,
                     "Expired entries are never sent")

        store.removeEntries(lastUsedFrom: now.timeIntervalSince1970 + 6, to: .infinity)
        precondition(!store.entries.contains { $0.text == "t4" || $0.text == "t7" } &&
                     store.entries.contains { $0.text == "t3" }, "History deletion removes its time range")
        store.removeEntries(lastUsedFrom: 0, to: .infinity)
        precondition(store.entries.isEmpty, "Deleting all history forgets everything")
        await waitForFile(url, entries: 0)

        let corrupt = directory.appendingPathComponent("corrupt.json")
        try! Data("not json".utf8).write(to: corrupt)
        let recovered = OmniboxLearningStore(fileURL: corrupt, limits: limits, now: now)
        precondition(recovered.entries.isEmpty &&
                     FileManager.default.fileExists(atPath: corrupt.appendingPathExtension("corrupt").path) &&
                     !FileManager.default.fileExists(atPath: corrupt.path), "An unreadable file is moved aside")

        let removed = directory.appendingPathComponent("gone", isDirectory: true)
        let orphan = OmniboxLearningStore(fileURL: removed.appendingPathComponent("learning.json"),
                                          limits: limits, now: now)
        orphan.record(text: "fy", kind: .pin, entityID: "a", now: now)
        try? await Task.sleep(for: .milliseconds(100))
        precondition(!FileManager.default.fileExists(atPath: removed.path),
                     "A save never recreates a removed account directory")

        let first = OmniboxLearningStore.store(directory: directory, profileID: "Profile 1")
        precondition(first === OmniboxLearningStore.store(directory: directory, profileID: "Profile 1") &&
                     first.fileURL.lastPathComponent == "OmniboxLearning-Profile_1.json",
                     "One shared cache per account and profile")
        let legacy = directory.appendingPathComponent("legacy.json")
        try! Data(#"{"version":1,"entries":[{"kind":"pin","entityID":"a","text":"1","count":9,"lastUsed":0}]}"#.utf8)
            .write(to: legacy)
        precondition(OmniboxLearningStore(fileURL: legacy, limits: limits, now: now).entries.isEmpty,
                     "Version 1 counts are not reinterpreted as choices")
        print("OmniboxLearningStore: record, limits, persistence, expiry and deletion passed")
    }

    @MainActor
    static func waitForFile(_ url: URL, entries: Int) async {
        struct File: Decodable { let entries: [OmniboxNativeLearningEntry] }
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: url),
               let file = try? JSONDecoder().decode(File.self, from: data), file.entries.count == entries { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Learning file was not saved")
    }
}
