// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The launch snapshot observers (docs/sync.md, "Launch snapshot caches") report only for a live
/// account: a response that arrives after the owning controller retired writes nothing.
final class ProfileKeyManagerTelemetryTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// Collects observer calls and the thread each one ran on. The tests read it off the main
    /// thread while the observers run on it.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _listings: [Set<String>] = []
        private var _flags: [String: Bool] = [:]
        private var _offMainCalls = 0
        var listings: [Set<String>] { lock.lock(); defer { lock.unlock() }; return _listings }
        var flags: [String: Bool] { lock.lock(); defer { lock.unlock() }; return _flags }
        var offMainCalls: Int { lock.lock(); defer { lock.unlock() }; return _offMainCalls }
        func listing(_ uuids: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            _listings.append(uuids)
            if !Thread.isMainThread { _offMainCalls += 1 }
        }
        func flag(_ uuid: String, _ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            _flags[uuid] = value
            if !Thread.isMainThread { _offMainCalls += 1 }
        }
    }

    /// Observer calls made off the main thread are queued to it; one main-actor turn runs every
    /// call queued so far.
    private func deliverQueuedTelemetry() async {
        await MainActor.run {}
    }

    private func stack() async throws -> (FakeAPI, ProfileKeyManager, Recorder) {
        let api = FakeAPI()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await manager.bootstrap()
        let keys = ProfileKeyManager(api: api, keyManager: manager, mappingStore: MemoryMappingStore())
        let recorder = Recorder()
        keys.onAccountListing = { recorder.listing($0) }
        keys.onDefaultFlag = { recorder.flag($0, $1) }
        return (api, keys, recorder)
    }

    func testACurrentListingAndEnvelopeReadAreRecorded() async throws {
        let (_, keys, recorder) = try await stack()
        let record = try await keys.registerLocalProfile(profileId: "Default", displayName: "D", isDefault: true)
        let uuids = try await keys.accountProfileUuids()
        _ = try await keys.remoteProfile(uuid: record.uuid)
        await deliverQueuedTelemetry()
        XCTAssertEqual(recorder.listings.last, uuids)
        XCTAssertEqual(recorder.flags[record.uuid], true)
    }

    /// PHI-2211: the observers write `UserDefaults.standard`, which blocks an off-main writer on
    /// the main queue. An envelope read that finishes off the main thread must not call them there.
    func testObserversRunOnTheMainThread() async throws {
        let (_, keys, recorder) = try await stack()
        let record = try await keys.registerLocalProfile(profileId: "Default", displayName: "D", isDefault: true)
        _ = try await keys.accountProfileUuids()
        _ = try await keys.remoteProfile(uuid: record.uuid)
        _ = try await keys.accountProfiles()
        _ = try await keys.backfillDefaultFlag(profileId: "Default", isDefault: true, isCurrent: { true })
        await deliverQueuedTelemetry()
        XCTAssertFalse(recorder.listings.isEmpty)
        XCTAssertEqual(recorder.flags[record.uuid], true)
        XCTAssertEqual(recorder.offMainCalls, 0)
    }

    func testAListingThatArrivesAfterRetirementIsNotRecorded() async throws {
        let (api, keys, recorder) = try await stack()
        let record = try await keys.registerLocalProfile(profileId: "Default", displayName: "D", isDefault: true)
        let before = recorder.listings.count
        // The account changes while the listing is on the wire.
        api.beforeListProfilesOnce = { keys.retireTelemetry() }
        let uuids = try await keys.accountProfileUuids()
        await deliverQueuedTelemetry()
        XCTAssertEqual(uuids, [record.uuid], "The caller still gets its answer")
        XCTAssertEqual(recorder.listings.count, before, "The retired account's listing writes nothing")

        // Every later flag read of the retired manager is dropped too.
        let flagsBefore = recorder.flags
        _ = try await keys.remoteProfile(uuid: record.uuid)
        _ = try await keys.accountProfiles()
        await deliverQueuedTelemetry()
        XCTAssertEqual(recorder.flags, flagsBefore)
    }
}
