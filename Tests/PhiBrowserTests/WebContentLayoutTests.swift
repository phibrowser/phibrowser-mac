// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class WebContentLayoutTests: XCTestCase {
    func testSidebarInsetsMirrorAndComfortableIgnoresPosition() {
        let left = WebContentLayout(sidebarPosition: .left, layoutMode: .performance, edgeToEdgeEnabled: false)
        let right = WebContentLayout(sidebarPosition: .right, layoutMode: .balanced, edgeToEdgeEnabled: false)
        XCTAssertFalse(left.sidebarOnRight)
        XCTAssertTrue(right.sidebarOnRight)
        XCTAssertEqual(left.pageInsets(sidebarCollapsed: false).leading, 0)
        XCTAssertEqual(left.pageInsets(sidebarCollapsed: false).trailing, 8)
        XCTAssertEqual(right.pageInsets(sidebarCollapsed: false).leading, 8)
        XCTAssertEqual(right.pageInsets(sidebarCollapsed: false).trailing, 0)
        for layout in [left, right, WebContentLayout(sidebarPosition: .right, layoutMode: .comfortable, edgeToEdgeEnabled: false)] {
            XCTAssertEqual(layout.pageInsets(sidebarCollapsed: true).leading, 8)
            XCTAssertEqual(layout.pageInsets(sidebarCollapsed: true).trailing, 8)
        }
        let horizontal = WebContentLayout(sidebarPosition: .right, layoutMode: .comfortable, edgeToEdgeEnabled: false)
        XCTAssertFalse(horizontal.sidebarOnRight)
        XCTAssertEqual(horizontal.pageInsets(sidebarCollapsed: false).leading, 8)
        XCTAssertEqual(horizontal.pageInsets(sidebarCollapsed: false).trailing, 8)
    }

    func testPreferenceDefaultsOffAndPersists() throws {
        let name = "edge-to-edge-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let setting = PhiPreferences.GeneralSettings.edgeToEdgeWebContent
        XCTAssertFalse(setting.loadValue(from: defaults))
        defaults.set(true, forKey: setting.rawValue)
        XCTAssertTrue(setting.loadValue(from: defaults))
    }

    func testDisabledPreservesAllLayoutsIncludingFullscreen() {
        for mode in LayoutMode.allCases {
            for fullscreen in [false, true] {
                let layout = WebContentLayout(layoutMode: mode, edgeToEdgeEnabled: false,
                                              isFullScreen: fullscreen)
                XCTAssertEqual(layout.edgeSpacing, 8)
                XCTAssertEqual(layout.topEdgeSpacing, 8)
                XCTAssertEqual(layout.containerCornerRadius, LiquidGlassCompatible.webContentContainerCornerRadius)
                XCTAssertEqual(layout.innerCornerRadius, LiquidGlassCompatible.webContentInnerComponentsCornerRadius)
                XCTAssertEqual(layout.titleAwareAreaHeight, mode == .performance ? 8 : 12)
            }
        }
        XCTAssertEqual(WebContentConstant.edgesSpacing, 8, "Sidebar chrome keeps its existing spacing")
    }

    func testEnabledRemovesOuterMarginsButPreservesComfortableTopUntilFullscreen() {
        for mode in LayoutMode.allCases {
            var layout = WebContentLayout(layoutMode: mode, edgeToEdgeEnabled: true)
            XCTAssertEqual(layout.edgeSpacing, 0)
            XCTAssertEqual(layout.topEdgeSpacing, mode == .comfortable ? 8 : 0)
            XCTAssertGreaterThan(layout.containerCornerRadius, 0)
            XCTAssertEqual(layout.titleAwareAreaHeight, mode == .comfortable ? 12 : 0)
            layout.isFullScreen = true
            XCTAssertEqual(layout.edgeSpacing, 0)
            XCTAssertEqual(layout.topEdgeSpacing, 0)
            XCTAssertEqual(layout.containerCornerRadius, 0)
            XCTAssertEqual(layout.innerCornerRadius, 0)
            XCTAssertEqual(layout.titleAwareAreaHeight, 0)
            layout.isFullScreen = false
            XCTAssertEqual(layout.edgeSpacing, 0)
            XCTAssertGreaterThan(layout.containerCornerRadius, 0)
        }
    }
}
