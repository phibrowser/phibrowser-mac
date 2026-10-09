// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

@MainActor
final class OmniBoxPresentationTests: XCTestCase {
    func testCenteredReopeningDoesNotReuseAddressBarFrameWhenSizeIsUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let container = OmniBoxContainerViewController(browserState: state)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let anchor = NSView(frame: NSRect(x: 120, y: 540, width: 500, height: 40))
        root.addSubview(anchor)
        root.addSubview(container.view)
        container.view.frame = root.bounds
        let omnibox = try XCTUnwrap(container.omniBoxController)
        await drainUpdates()

        container.showOmniBox(fromAddressBar: false)
        let centeredFrame = omnibox.view.frame
        XCTAssertGreaterThan(centeredFrame.width, 0)
        container.hideOmniBox()
        await drainUpdates()

        var sizes: [NSSize] = []
        let subscription = omnibox.$contentSize.dropFirst().sink { sizes.append($0) }
        for _ in 0..<2 {
            container.showOmniBox(fromAddressBar: true, addressView: anchor)
            XCTAssertTrue(container.isAnchoredToAddressBarForTesting)
            XCTAssertNotEqual(omnibox.view.frame, centeredFrame)
            container.hideOmniBox()
            await drainUpdates()

            container.showOmniBox(fromAddressBar: false)
            XCTAssertFalse(container.isAnchoredToAddressBarForTesting)
            XCTAssertEqual(omnibox.view.frame, centeredFrame)
            container.hideOmniBox()
            await drainUpdates()
        }
        XCTAssertTrue(sizes.isEmpty, "Presentation changes must not require duplicate size publications")
        withExtendedLifetime(subscription) {}
        try await store.closeForAccountDirectoryRemoval()
        try FileManager.default.removeItem(at: directory)
    }

    private func drainUpdates() async {
        let delivered = expectation(description: "View updates delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 1)
    }
}
