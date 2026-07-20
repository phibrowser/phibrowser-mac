// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AIDataImportCoordinatorTests: XCTestCase {
    func testNeedsAttentionDeepLinksBackupRestoreSection() async {
        var openedSections: [String] = []
        let coordinator = AIDataImportCoordinator(
            requestImport: { _ in .response(.init(status: .completed, needsAttention: true)) },
            openDashboard: { openedSections.append($0) }
        )
        let outcome = await coordinator.coordinate(archivePath: "/tmp/ai-data.tar.gz")
        XCTAssertEqual(outcome, .coordinated(needsAttention: true))
        XCTAssertEqual(openedSections, ["backup"])
    }

    func testCleanImportDoesNotDeepLink() async {
        var openedSections: [String] = []
        let coordinator = AIDataImportCoordinator(
            requestImport: { _ in .response(.init(status: .completed, needsAttention: false)) },
            openDashboard: { openedSections.append($0) }
        )
        let outcome = await coordinator.coordinate(archivePath: "/tmp/ai-data.tar.gz")
        XCTAssertEqual(outcome, .coordinated(needsAttention: false))
        XCTAssertTrue(openedSections.isEmpty)
    }

    func testTimeoutDegradesWithoutDeepLink() async {
        var openedSections: [String] = []
        let coordinator = AIDataImportCoordinator(
            requestImport: { _ in .timedOut },
            openDashboard: { openedSections.append($0) }
        )
        let outcome = await coordinator.coordinate(archivePath: "/tmp/ai-data.tar.gz")
        XCTAssertEqual(outcome, .degraded(reason: .timedOut))
        XCTAssertTrue(openedSections.isEmpty)
    }

    func testErrorStatusDegradesWithoutDeepLink() async {
        var openedSections: [String] = []
        let coordinator = AIDataImportCoordinator(
            requestImport: { _ in .response(.init(status: .error, needsAttention: false)) },
            openDashboard: { openedSections.append($0) }
        )
        let outcome = await coordinator.coordinate(archivePath: "/tmp/ai-data.tar.gz")
        XCTAssertEqual(outcome, .degraded(reason: .failed))
        XCTAssertTrue(openedSections.isEmpty)
    }
}
