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

    /// Collects observer calls; the observers may run off the main thread.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _listings: [Set<String>] = []
        private var _flags: [String: Bool] = [:]
        var listings: [Set<String>] { lock.lock(); defer { lock.unlock() }; return _listings }
        var flags: [String: Bool] { lock.lock(); defer { lock.unlock() }; return _flags }
        func listing(_ uuids: Set<String>) { lock.lock(); _listings.append(uuids); lock.unlock() }
        func flag(_ uuid: String, _ value: Bool) { lock.lock(); _flags[uuid] = value; lock.unlock() }
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
        XCTAssertEqual(recorder.listings.last, uuids)
        XCTAssertEqual(recorder.flags[record.uuid], true)
    }

    func testAListingThatArrivesAfterRetirementIsNotRecorded() async throws {
        let (api, keys, recorder) = try await stack()
        let record = try await keys.registerLocalProfile(profileId: "Default", displayName: "D", isDefault: true)
        let before = recorder.listings.count
        // The account changes while the listing is on the wire.
        api.beforeListProfilesOnce = { keys.retireTelemetry() }
        let uuids = try await keys.accountProfileUuids()
        XCTAssertEqual(uuids, [record.uuid], "The caller still gets its answer")
        XCTAssertEqual(recorder.listings.count, before, "The retired account's listing writes nothing")

        // Every later flag read of the retired manager is dropped too.
        let flagsBefore = recorder.flags
        _ = try await keys.remoteProfile(uuid: record.uuid)
        _ = try await keys.accountProfiles()
        XCTAssertEqual(recorder.flags, flagsBefore)
    }
}
