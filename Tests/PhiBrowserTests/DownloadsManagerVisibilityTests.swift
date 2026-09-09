// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import XCTest
@testable import Phi

@MainActor
final class DownloadsManagerVisibilityTests: XCTestCase {
    func testLocalAttemptCancelledWithoutTargetNeverAppears() async {
        let manager = DownloadsManager()
        let living = LivingDownloadsManager(downloadsManager: manager)
        var events: [DownloadEventType] = []
        let subscription = manager.downloadEventPublisher.sink { events.append($0.eventType) }
        defer { subscription.cancel() }
        let wrapper = DownloadVisibilityTestWrapper()

        await send(.created, wrapper, to: manager)
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertTrue(living.livingItems.isEmpty)
        XCTAssertEqual(manager.activeDownloadCount, 0)

        wrapper.state = DownloadState.cancelled.rawValue
        await send(.cancelled, wrapper, to: manager)
        manager.applyDownloadSnapshot([wrapper])

        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertTrue(living.livingItems.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(manager.totalDownloadProgress, 0)
    }

    func testLocalTargetBecomingAvailablePublishesCreationOnce() async {
        let manager = DownloadsManager()
        let living = LivingDownloadsManager(downloadsManager: manager)
        var events: [DownloadEventType] = []
        let subscription = manager.downloadEventPublisher.sink { events.append($0.eventType) }
        defer { subscription.cancel() }
        let wrapper = DownloadVisibilityTestWrapper()

        await send(.created, wrapper, to: manager)
        wrapper.targetFilePath = "/tmp/saved.zip"
        await send(.updated, wrapper, to: manager)
        await send(.updated, wrapper, to: manager)

        XCTAssertEqual(manager.downloads.map(\.id), [wrapper.guid])
        XCTAssertEqual(living.livingItems.map(\.id), [wrapper.guid])
        XCTAssertEqual(events, [.created, .updated])
        XCTAssertEqual(manager.activeDownloadCount, 1)
        XCTAssertEqual(manager.totalDownloadProgress, 0.5)

        wrapper.state = DownloadState.cancelled.rawValue
        await send(.cancelled, wrapper, to: manager)
        XCTAssertEqual(manager.downloads.first?.state, .cancelled)
        XCTAssertEqual(events.last, .cancelled)
    }

    func testLocalCompletionCanBeFirstVisibleEvent() async {
        let manager = DownloadsManager()
        let living = LivingDownloadsManager(downloadsManager: manager)
        let wrapper = DownloadVisibilityTestWrapper()
        await send(.created, wrapper, to: manager)

        wrapper.targetFilePath = "/tmp/saved.zip"
        wrapper.state = DownloadState.complete.rawValue
        await send(.completed, wrapper, to: manager)

        XCTAssertEqual(manager.downloads.first?.state, .complete)
        XCTAssertEqual(living.livingItems.map(\.id), [wrapper.guid])
        XCTAssertEqual(manager.activeDownloadCount, 0)
    }

    func testRemoteDownloadWithoutTargetStillAppearsAndKeepsCancellation() async {
        let manager = DownloadsManager()
        let living = LivingDownloadsManager(downloadsManager: manager)
        let wrapper = DownloadVisibilityTestWrapper()
        wrapper.url = "https://example.com/archive.zip"
        await send(.created, wrapper, to: manager)
        XCTAssertEqual(manager.downloads.count, 1)
        XCTAssertEqual(living.livingItems.count, 1)

        wrapper.state = DownloadState.cancelled.rawValue
        await send(.cancelled, wrapper, to: manager)
        XCTAssertEqual(manager.downloads.first?.state, .cancelled)
        XCTAssertEqual(manager.activeDownloadCount, 0)
    }

    func testSnapshotFiltersOnlyPendingAndCancelledLocalDownloadsWithoutTargets() {
        let manager = DownloadsManager()
        var wrappers: [DownloadVisibilityTestWrapper] = []
        var expectedIDs = Set<String>()
        for isLocal in [false, true] {
            for hasTarget in [false, true] {
                for state in [DownloadState.inProgress, .complete, .cancelled, .interrupted] {
                    let wrapper = DownloadVisibilityTestWrapper()
                    wrapper.url = isLocal ? "file:///tmp/source.zip" : "https://example.com/source.zip"
                    wrapper.targetFilePath = hasTarget ? "/tmp/saved.zip" : ""
                    wrapper.state = state.rawValue
                    wrappers.append(wrapper)
                    if !isLocal || hasTarget || state == .complete || state == .interrupted {
                        expectedIDs.insert(wrapper.guid)
                    }
                }
            }
        }

        manager.applyDownloadSnapshot(wrappers)
        XCTAssertEqual(Set(manager.downloads.map(\.id)), expectedIDs)
    }

    func testFilteredUpdateRemovesExistingNativeAndFloatingItems() async {
        await assertExistingItemIsRemoved(useSnapshot: false)
    }

    func testFilteredSnapshotRemovesExistingNativeAndFloatingItems() async {
        await assertExistingItemIsRemoved(useSnapshot: true)
    }

    private func assertExistingItemIsRemoved(useSnapshot: Bool) async {
        let manager = DownloadsManager()
        let living = LivingDownloadsManager(downloadsManager: manager)
        let wrapper = DownloadVisibilityTestWrapper()
        wrapper.targetFilePath = "/tmp/saved.zip"
        await send(.created, wrapper, to: manager)
        XCTAssertEqual(living.livingItems.count, 1)

        wrapper.targetFilePath = ""
        wrapper.state = DownloadState.cancelled.rawValue
        if useSnapshot {
            manager.applyDownloadSnapshot([wrapper])
            await drainMainQueue()
        } else {
            await send(.cancelled, wrapper, to: manager)
        }

        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertTrue(living.livingItems.isEmpty)
        XCTAssertEqual(manager.totalDownloadProgress, 0)
    }

    private func send(_ event: DownloadEventType,
                      _ wrapper: DownloadVisibilityTestWrapper,
                      to manager: DownloadsManager) async {
        manager.handleDownloadEvent(eventType: event, guid: wrapper.guid, wrapper: wrapper)
        // The manager and its floating-list subscriber each schedule on main.
        await drainMainQueue()
        await drainMainQueue()
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class DownloadVisibilityTestWrapper: NSObject, DownloadItemWrapper {
    var guid = UUID().uuidString
    var url = "file:///tmp/source.zip"
    var mimeType = "application/zip"
    var state = DownloadState.inProgress.rawValue
    var totalBytes: Int64 = 100
    var receivedBytes: Int64 = 50
    var percentComplete = 50
    var currentSpeed: Int64 = 0
    var startTime = Int64(Date().timeIntervalSince1970 * 1000)
    var endTime: Int64 = 0
    var canShowInFolder = false
    var canOpenDownload = false
    var fileExternallyRemoved = false
    var shouldOpenFileBasedOnExtension = false
    var canResume = false
    var isPaused = false
    var isDone = false
    var isTemporary = false
    var isDangerous = false
    var dangerType = 0
    var isInsecure = false
    var insecureDownloadStatus = 0
    var allDataSaved = false
    var totalBytesKnown = true
    var isSavePackageDownload = false
    var downloadSource = 0
    var remoteAddress = ""
    var targetFilePath = ""
    var fileNameToReportUser = "source.zip"
    var currentPath = ""

    func toDictionary() -> [AnyHashable: Any] { [:] }
}
