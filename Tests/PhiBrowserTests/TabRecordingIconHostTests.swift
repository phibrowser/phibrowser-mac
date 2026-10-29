// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import XCTest
@testable import Phi

/// The recording badge pulses with a `repeatForever` animation, and SwiftUI
/// keeps that animation running inside a hidden `NSHostingView`. A tab cell
/// that is not recording must therefore carry no badge at all rather than a
/// hidden one, or every tab in every window re-renders it on every frame.
@MainActor
final class TabRecordingIconHostTests: XCTestCase {
    func test_tabItemThatIsNotRecordingCarriesNoRecordingIcon() {
        let view = makeCompactTabItem(guid: 1, recording: false)

        XCTAssertEqual(
            recordingIconHosts(in: view).count,
            0,
            "A tab that is not recording must not keep a hidden, animating "
                + "recording icon."
        )
    }

    func test_recordingCompactTabItemShowsItsRecordingIcon() throws {
        let view = makeCompactTabItem(guid: 1, recording: true)

        let hosts = recordingIconHosts(in: view)
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertFalse(host.isHidden)
        XCTAssertFalse(host.frame.isEmpty)
    }

    func test_tabItemReusedForATabThatIsNotRecordingDropsTheIcon() {
        let view = makeCompactTabItem(guid: 1, recording: true)
        XCTAssertEqual(recordingIconHosts(in: view).count, 1, "Precondition.")

        configure(view, guid: 2, recording: false)

        XCTAssertEqual(recordingIconHosts(in: view).count, 0)
    }

    func test_compactTabItemShowingTheRecordingIconRendersNoFaviconBadge() throws {
        let view = makeCompactTabItem(guid: 1, recording: true)

        XCTAssertFalse(
            try faviconRendersRecordingBadge(in: view),
            "The centred recording icon stands in for the badge; the hidden "
                + "favicon must not keep an animating copy of it."
        )
    }

    func test_normalTabItemThatIsRecordingKeepsItsFaviconBadge() throws {
        let view = makeTabItem(
            width: TabStripMetrics.Content.compactModeThreshold + 1,
            guid: 1,
            recording: true
        )

        XCTAssertTrue(try faviconRendersRecordingBadge(in: view))
    }

    /// The strip lays out the cells it leaves out (a collapsed group's
    /// members, the second tab of a split pair) at `.zero`, favicons hidden.
    func test_tabItemLaidOutAtZeroRendersNoFaviconBadge() throws {
        let view = makeTabItem(
            width: TabStripMetrics.Content.compactModeThreshold + 1,
            guid: 1,
            recording: true
        )
        XCTAssertTrue(try faviconRendersRecordingBadge(in: view), "Precondition.")

        view.frame = .zero
        view.layout()

        XCTAssertFalse(try faviconRendersRecordingBadge(in: view))
    }

    func test_tabItemLaidOutAgainAfterZeroRendersItsFaviconBadge() throws {
        let width = TabStripMetrics.Content.compactModeThreshold + 1
        let view = makeTabItem(width: width, guid: 1, recording: true)
        view.frame = .zero
        view.layout()

        view.frame = CGRect(x: 0, y: 0, width: width, height: TabStripMetrics.Strip.tabHeight)
        view.layout()

        XCTAssertTrue(try faviconRendersRecordingBadge(in: view))
    }

    func test_compactSplitCellShowingTheRecordingIconRendersNeitherFaviconBadge() throws {
        let view = makeCompactSplitCell(primaryRecording: true, partnerRecording: true)

        XCTAssertFalse(try faviconRendersRecordingBadge(in: view))
        XCTAssertFalse(
            try faviconRendersRecordingBadge(in: view, viewModel: "secondaryFaviconViewModel")
        )
    }

    /// Only the primary pane's recording takes the centred icon; a partner
    /// recording alone keeps both favicons up, and its badge is then the
    /// cell's only recording sign.
    func test_compactSplitCellKeepsTheRecordingPartnersFaviconBadge() throws {
        let view = makeCompactSplitCell(primaryRecording: false, partnerRecording: true)

        XCTAssertTrue(
            try faviconRendersRecordingBadge(in: view, viewModel: "secondaryFaviconViewModel")
        )
    }

    func test_splitPairCellShowsOnlyTheRecordingPanesIcon() {
        let leftTab = Tab(
            guid: 1,
            url: "https://example.com/1",
            isActive: false,
            index: 0
        )
        leftTab.setCaptureStateForTesting(video: true)
        let rightTab = Tab(
            guid: 2,
            url: "https://example.com/2",
            isActive: false,
            index: 1
        )
        let cell = SidebarSplitPairCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 36)
        )
        cell.configure(with: SplitPairSidebarItem(
            groupId: "split-1-2",
            leftTab: leftTab,
            rightTab: rightTab,
            browserState: nil
        ))

        XCTAssertTrue(cell.isRecordingIndicatorVisible(isLeft: true))
        XCTAssertFalse(cell.isRecordingIndicatorVisible(isLeft: false))
        XCTAssertEqual(
            recordingIconHosts(in: cell).count,
            1,
            "The pane that is not recording must not keep a hidden, "
                + "animating recording icon."
        )
    }

    func test_mirroredTabFaviconBadgeShowsBeingSharedIconNotMicDot() throws {
        let tab = Tab(
            guid: 2,
            url: "https://example.com/2",
            isActive: true,
            index: 1
        )
        tab.setCaptureStateForTesting(sharingScreen: true, beingMirrored: true)
        let viewModel = TabViewModel()
        viewModel.configure(with: tab, in: nil)

        let body = String(describing: SideTabView(model: viewModel).body)
        let rowOutline = String(describing: TabBeingSharedSidebarRowOutline.self)
        let faviconOutline = String(describing: TabBeingSharedFaviconOutline.self)
        let recording = String(describing: UnifiedTabRecordingIcon.self)
        XCTAssertTrue(body.contains("\(rowOutline)("))
        XCTAssertFalse(body.contains("\(faviconOutline)("))
        XCTAssertFalse(body.contains("\(recording)("))
    }

    // MARK: - Helpers

    /// Compact, because that is where a tab item shows the centred
    /// recording icon; a normal-width item shows a badge on its favicon.
    private func makeCompactTabItem(guid: Int, recording: Bool) -> TabItemView {
        makeTabItem(
            width: TabStripMetrics.Content.compactModeThreshold - 1,
            guid: guid,
            recording: recording
        )
    }

    private func makeTabItem(width: CGFloat, guid: Int, recording: Bool) -> TabItemView {
        let view = TabItemView()
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: TabStripMetrics.Strip.tabHeight
        )
        configure(view, guid: guid, recording: recording)
        return view
    }

    /// A split-merged cell narrow enough for the compact layout.
    private func makeCompactSplitCell(
        primaryRecording: Bool,
        partnerRecording: Bool
    ) -> TabItemView {
        let primary = Tab(guid: 1, url: "https://example.com/1", isActive: false, index: 0)
        primary.setCaptureStateForTesting(video: primaryRecording)
        let partner = Tab(guid: 2, url: "https://example.com/2", isActive: false, index: 1)
        partner.setCaptureStateForTesting(video: partnerRecording)
        let view = TabItemView()
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: TabStripMetrics.Content.splitCompactModeThreshold - 1,
            height: TabStripMetrics.Strip.tabHeight
        )
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Example",
            url: primary.url ?? "",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            pinnedSplitPartner: partner,
            sourceTab: primary
        ))
        view.layout()
        return view
    }

    /// Configures `view` for a new tab and lays it out. `Tab` stays out of
    /// the signatures: with SwiftUI imported the bare type name is ambiguous.
    private func configure(_ view: TabItemView, guid: Int, recording: Bool) {
        let tab = Tab(
            guid: guid,
            url: "https://example.com/\(guid)",
            isActive: false,
            index: guid
        )
        tab.setCaptureStateForTesting(video: recording)
        view.configure(with: TabRenderData(
            id: "tab-\(tab.guid)",
            title: "Example",
            url: tab.url ?? "",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: tab
        ))
        view.layout()
    }

    /// Hosting views under `root` used for capture indicators (centre or favicon).
    private func recordingIconHosts(in root: NSView) -> [NSView] {
        let markers = [
            String(describing: UnifiedTabRecordingIcon.self),
            String(describing: UnifiedTabCaptureCenterIndicator.self),
            String(describing: UnifiedTabFaviconCaptureBadgesView.self),
            String(describing: UnifiedTabFaviconCaptureBadgesViewFromTab.self),
            String(describing: TabBeingSharedFaviconOutline.self),
        ]
        var hosts: [NSView] = []
        var pending = [root]
        while let view = pending.popLast() {
            if let host = view as? NSHostingView<AnyView> {
                let description = String(describing: host.rootView)
                if markers.contains(where: { description.contains($0) }) {
                    hosts.append(host)
                }
            }
            pending.append(contentsOf: view.subviews)
        }
        return hosts
    }

    /// Whether the item's favicon driven by the view model it stores as
    /// `viewModel` renders the recording corner badge. The badge sits in
    /// `UnifiedTabFaviconView.body`, which the description of the favicon
    /// host's root view never reaches, so this describes that body built on
    /// the item's own view model: a rendered badge shows up as an icon
    /// value, a dropped one as `nil`.
    private func faviconRendersRecordingBadge(
        in view: TabItemView,
        viewModel name: String = "viewModel"
    ) throws -> Bool {
        let viewModel = try XCTUnwrap(
            Mirror(reflecting: view).descendant(name) as? TabViewModel,
            "TabItemView no longer keeps a favicon view model in `\(name)`."
        )
        let iconName = String(describing: UnifiedTabRecordingIcon.self)
        return String(describing: UnifiedTabFaviconView(viewModel: viewModel).body)
            .contains("\(iconName)(")
    }
}
