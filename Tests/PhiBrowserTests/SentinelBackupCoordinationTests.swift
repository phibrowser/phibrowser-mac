// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelBackupCoordinationTests: XCTestCase {
    func testExportContractNamesAndPayload() {
        XCTAssertEqual(
            SentinelAIDataExport.requestName.rawValue,
            "com.phibrowser.sentinel.exportAIData.request"
        )
        XCTAssertEqual(
            SentinelAIDataExport.responseName.rawValue,
            "com.phibrowser.sentinel.exportAIData.response"
        )

        XCTAssertEqual(
            SentinelAIDataExport.requestUserInfo(
                requestID: "request-1",
                destinationPath: "/tmp/ai-data.tar.gz"
            ),
            [
                "requestID": "request-1",
                "destinationPath": "/tmp/ai-data.tar.gz"
            ]
        )

        XCTAssertEqual(
            SentinelAIDataExport.parseResponse([
                "status": "completed",
                "path": "/tmp/ai-data.tar.gz"
            ]),
            .init(
                status: .completed,
                path: "/tmp/ai-data.tar.gz",
                error: nil
            )
        )
        XCTAssertNil(SentinelAIDataExport.parseResponse(["status": "unknown"]))
    }

    func testClientRoutesRequestAndInjectsBrowserBundleID() async {
        let transport = TestSentinelNotificationTransport()
        transport.onPost = { posted in
            transport.deliver(
                name: SentinelAIDataExport.responseName,
                object: posted.object,
                userInfo: [
                    "requestID": posted.userInfo["requestID"] ?? "",
                    "status": "completed",
                    "path": posted.userInfo["destinationPath"] ?? ""
                ]
            )
        }
        let client = SentinelBackupCoordinationClient(
            transport: transport,
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            retryDelays: [0]
        )

        let result = await client.requestExportAIData(
            requestID: "request-1",
            destinationPath: "/tmp/ai-data.tar.gz",
            timeout: 1
        )

        guard case .response(let response) = result else {
            return XCTFail("Expected completed response")
        }
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(
            transport.posts.first?.userInfo["browserBundleID"],
            "com.phibrowser.Mac"
        )
        XCTAssertEqual(
            transport.observedObjects,
            ["com.phibrowser.Sentinel"]
        )
        XCTAssertEqual(transport.activeSubscriptionCount, 0)
    }

    func testClientIgnoresMismatchedRequestID() async {
        let transport = TestSentinelNotificationTransport()
        transport.onPost = { posted in
            transport.deliver(
                name: SentinelAIDataExport.responseName,
                object: posted.object,
                userInfo: [
                    "requestID": "another-request",
                    "status": "completed",
                    "path": "/tmp/ai-data.tar.gz"
                ]
            )
        }
        let client = SentinelBackupCoordinationClient(
            transport: transport,
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            retryDelays: [0]
        )

        let result = await client.requestExportAIData(
            requestID: "request-1",
            destinationPath: "/tmp/ai-data.tar.gz",
            timeout: 0.01
        )

        guard case .timedOut = result else {
            return XCTFail("Expected timeout")
        }
        XCTAssertEqual(transport.activeSubscriptionCount, 0)
    }

    func testClientRetriesUntilSentinelResponds() async {
        let transport = TestSentinelNotificationTransport()
        transport.onPost = { posted in
            guard transport.posts.count == 3 else {
                return
            }
            transport.deliver(
                name: SentinelAIDataExport.responseName,
                object: posted.object,
                userInfo: [
                    "requestID": posted.userInfo["requestID"] ?? "",
                    "status": "completed",
                    "path": posted.userInfo["destinationPath"] ?? ""
                ]
            )
        }
        let client = SentinelBackupCoordinationClient(
            transport: transport,
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            retryDelays: [0, 0.01, 0.02]
        )

        let result = await client.requestExportAIData(
            requestID: "request-1",
            destinationPath: "/tmp/ai-data.tar.gz",
            timeout: 1
        )

        guard case .response(let response) = result else {
            return XCTFail("Expected completed response after retries")
        }
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(transport.posts.count, 3)
        XCTAssertEqual(transport.activeSubscriptionCount, 0)
    }

    func testClientCancellationStopsWaitingAndRetries() async {
        let transport = TestSentinelNotificationTransport()
        let client = SentinelBackupCoordinationClient(
            transport: transport,
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            retryDelays: [0, 1]
        )

        let requestTask = Task {
            await client.requestExportAIData(
                requestID: "request-1",
                destinationPath: "/tmp/ai-data.tar.gz",
                timeout: 60
            )
        }
        for _ in 0..<100 where transport.posts.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(transport.activeSubscriptionCount, 1)

        requestTask.cancel()
        let result = await requestTask.value
        guard case .cancelled = result else {
            return XCTFail("Expected cancellation")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(transport.activeSubscriptionCount, 0)
    }
}

final class AIDataExportCoordinatorTests: XCTestCase {
    func testUnavailableSentinelSkipsExport() async {
        let coordinator = makeCoordinator(
            ensureSentinelRunning: { false },
            response: .timedOut,
            isRegularFile: { _ in true }
        )

        let result = await coordinator.coordinate(
            requestID: "request-1",
            destinationTarURL: URL(fileURLWithPath: "/tmp/ai-data.tar.gz")
        )

        XCTAssertEqual(result, .skipped(reason: .sentinelUnavailable))
    }

    func testCompletedExportRequiresExactExpectedPath() async {
        let coordinator = makeCoordinator(
            response: .response(.init(
                status: .completed,
                path: "/tmp/unexpected.tar.gz",
                error: nil
            )),
            isRegularFile: { _ in true }
        )

        let result = await coordinator.coordinate(
            requestID: "request-1",
            destinationTarURL: URL(fileURLWithPath: "/tmp/ai-data.tar.gz")
        )

        XCTAssertEqual(result, .skipped(reason: .invalidResponsePath))
    }

    func testCompletedExportRejectsNormalizedEquivalentPath() async {
        let coordinator = makeCoordinator(
            response: .response(.init(
                status: .completed,
                path: "/tmp/subdirectory/../ai-data.tar.gz",
                error: nil
            )),
            isRegularFile: { _ in true }
        )

        let result = await coordinator.coordinate(
            requestID: "request-1",
            destinationTarURL: URL(fileURLWithPath: "/tmp/ai-data.tar.gz")
        )

        XCTAssertEqual(result, .skipped(reason: .invalidResponsePath))
    }

    func testCompletedExportRequiresRegularFile() async {
        let coordinator = makeCoordinator(
            response: .response(.init(
                status: .completed,
                path: "/tmp/ai-data.tar.gz",
                error: nil
            )),
            isRegularFile: { _ in false }
        )

        let result = await coordinator.coordinate(
            requestID: "request-1",
            destinationTarURL: URL(fileURLWithPath: "/tmp/ai-data.tar.gz")
        )

        XCTAssertEqual(result, .skipped(reason: .exportFailed))
    }

    func testCompletedExportReturnsExpectedArchive() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/ai-data.tar.gz")
        let coordinator = makeCoordinator(
            response: .response(.init(
                status: .completed,
                path: expectedURL.path,
                error: nil
            )),
            isRegularFile: { $0 == expectedURL }
        )

        let result = await coordinator.coordinate(
            requestID: "request-1",
            destinationTarURL: expectedURL
        )

        XCTAssertEqual(result, .packed(tarURL: expectedURL))
    }

    func testCancelledRequestSkipsExport() async {
        let coordinator = makeCoordinator(
            response: .cancelled,
            isRegularFile: { _ in true }
        )

        let result = await coordinator.coordinate(
            requestID: "request-1",
            destinationTarURL: URL(fileURLWithPath: "/tmp/ai-data.tar.gz")
        )

        XCTAssertEqual(result, .skipped(reason: .cancelled))
    }

    private func makeCoordinator(
        ensureSentinelRunning: @escaping () async -> Bool = { true },
        response: SentinelCoordinationResult<SentinelAIDataExport.Response>,
        isRegularFile: @escaping (URL) -> Bool
    ) -> AIDataExportCoordinator {
        AIDataExportCoordinator(
            ensureSentinelRunning: ensureSentinelRunning,
            requestExport: { _, _ in response },
            isRegularFile: isRegularFile,
            isCancelled: { false }
        )
    }
}

private final class TestSentinelNotificationTransport:
    SentinelNotificationTransport
{
    struct Posted {
        let name: Notification.Name
        let object: String
        let userInfo: [String: String]
    }

    private final class Registration {
        let name: Notification.Name
        let object: String
        let handler: ([String: String]) -> Void
        var isCancelled = false

        init(
            name: Notification.Name,
            object: String,
            handler: @escaping ([String: String]) -> Void
        ) {
            self.name = name
            self.object = object
            self.handler = handler
        }
    }

    private final class Subscription: SentinelNotificationSubscription {
        private let onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            onCancel()
        }
    }

    private let lock = NSLock()
    private var storedPosts: [Posted] = []
    private var storedObservedObjects: [String] = []
    private var registrations: [Registration] = []
    var onPost: ((Posted) -> Void)?

    var posts: [Posted] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedPosts
    }

    var observedObjects: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedObservedObjects
    }

    var activeSubscriptionCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return registrations.filter { !$0.isCancelled }.count
    }

    func post(
        name: Notification.Name,
        object: String,
        userInfo: [String: String]
    ) {
        let posted = Posted(
            name: name,
            object: object,
            userInfo: userInfo
        )
        lock.lock()
        storedPosts.append(posted)
        let onPost = onPost
        lock.unlock()
        onPost?(posted)
    }

    func observe(
        name: Notification.Name,
        object: String,
        handler: @escaping ([String: String]) -> Void
    ) -> SentinelNotificationSubscription {
        let registration = Registration(
            name: name,
            object: object,
            handler: handler
        )
        lock.lock()
        registrations.append(registration)
        storedObservedObjects.append(object)
        lock.unlock()
        return Subscription {
            self.lock.lock()
            registration.isCancelled = true
            self.lock.unlock()
        }
    }

    func deliver(
        name: Notification.Name,
        object: String,
        userInfo: [String: String]
    ) {
        lock.lock()
        let handlers: [([String: String]) -> Void] =
            registrations.compactMap { registration in
                guard !registration.isCancelled,
                      registration.name == name,
                      registration.object == object else {
                    return nil
                }
                return registration.handler
            }
        lock.unlock()
        for handler in handlers {
            handler(userInfo)
        }
    }
}
