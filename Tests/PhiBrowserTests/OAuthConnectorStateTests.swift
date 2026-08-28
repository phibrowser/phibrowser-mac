// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class OAuthConnectorStateTests: XCTestCase {
    func testUnassignedConnectionUsesAssignAction() {
        let state = ConnectorItemState(template: .google)
        state.updateConnection(
            OAuthConnection(
                provider: "google",
                connected: true,
                profileId: nil,
                connectedAt: "2026-08-24T00:00:00Z",
                expiresAt: nil,
                scope: nil
            ),
            isUnassigned: true
        )

        XCTAssertTrue(state.status.isConnected)
        XCTAssertTrue(state.isUnassigned)
        XCTAssertEqual(
            state.actionTitle,
            NSLocalizedString(
                "settings.ai.connectors.assignButton",
                value: "Assign",
                comment: "AI settings - Button that assigns an existing unassigned connector to the selected browser Profile"
            )
        )
    }

    func testClearingConnectionClearsUnassignedState() {
        let state = ConnectorItemState(template: .notion)
        state.updateConnection(
            OAuthConnection(
                provider: "notion",
                connected: true,
                profileId: nil,
                connectedAt: nil,
                expiresAt: nil,
                scope: nil
            ),
            isUnassigned: true
        )

        state.updateConnection(nil)

        XCTAssertFalse(state.status.isConnected)
        XCTAssertFalse(state.isUnassigned)
    }

    func testAllProfileResponseSeparatesSelectedAndUnassignedConnections() {
        let selected = OAuthConnection(
            provider: "google",
            connected: true,
            profileId: "Work",
            connectedAt: nil,
            expiresAt: nil,
            scope: nil
        )
        let other = OAuthConnection(
            provider: "notion",
            connected: true,
            profileId: "Personal",
            connectedAt: nil,
            expiresAt: nil,
            scope: nil
        )
        let unassigned = OAuthConnection(
            provider: "slack",
            connected: true,
            profileId: nil,
            connectedAt: nil,
            expiresAt: nil,
            scope: nil
        )

        let result = AISettingsConnectorViewModel.selectConnections(
            [selected, other, unassigned],
            forProfile: "Work"
        )

        XCTAssertEqual(result.scoped.map(\.provider), ["google"])
        XCTAssertEqual(result.unassigned.map(\.provider), ["slack"])
    }
}
