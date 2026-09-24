import Foundation

struct ChromiumProfileSyncSnapshot {
    let status: SyncContextSnapshot
    let enabledCategories: [String]
}

/// SyncHelper-owned adapter; querying status never creates a profile or starts a service.
@MainActor
final class ChromiumSyncStatus {
    private var revisions: [String: UInt64] = [:]

    static func decode(_ payload: [String: Any]?, profileID: String, revision: UInt64) -> ChromiumProfileSyncSnapshot {
        let unknown = ChromiumProfileSyncSnapshot(status: SyncContextSnapshot(id: profileID,
            phase: .checking, lastSuccess: nil, revision: revision), enabledCategories: [])
        guard let payload, (payload["version"] as? NSNumber)?.intValue == 1,
              let raw = payload["phase"] as? String, let phase = SyncContextPhase(rawValue: raw),
              let categories = payload["enabled_categories"] as? [String] else { return unknown }
        let timestamp = (payload["last_success_ms"] as? NSNumber)?.doubleValue
        let date = timestamp.flatMap { $0.isFinite && $0 > 0 && $0 <= Date().timeIntervalSince1970 * 1000 + 60_000
            ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        let supported = Set(["history", "preferences", "bookmarks", "tabs"])
        return ChromiumProfileSyncSnapshot(status: SyncContextSnapshot(id: profileID,
            phase: phase == .upToDate && date == nil ? .checking : phase,
            lastSuccess: date, revision: revision), enabledCategories: categories.filter { supported.contains($0) })
    }

    func read(profileID: String) async -> ChromiumProfileSyncSnapshot {
        let revision = (revisions[profileID] ?? 0) &+ 1
        revisions[profileID] = revision
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.getProfileSyncStatus(_:completion:))) else {
            return Self.decode(nil, profileID: profileID, revision: revision)
        }
        let payload: [String: Any]? = await withCheckedContinuation { continuation in
            let result = ChromiumStatusReply(continuation)
            bridge.getProfileSyncStatus?(profileID) { payload, error in
                Task { @MainActor in result.finish(error == nil ? payload : nil) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                result.finish(nil)
            }
        }
        guard revisions[profileID] == revision else {
            return Self.decode(nil, profileID: profileID, revision: revision)
        }
        return Self.decode(payload, profileID: profileID, revision: revision)
    }
}

@MainActor
private final class ChromiumStatusReply {
    private var continuation: CheckedContinuation<[String: Any]?, Never>?
    init(_ continuation: CheckedContinuation<[String: Any]?, Never>) { self.continuation = continuation }
    func finish(_ payload: [String: Any]?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: payload)
    }
}
