// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The floating history panel groups visits into day sections, newest first,
/// and paints the cached opening view at once.
@MainActor
final class HistoryPanelModelTests: XCTestCase {
    private let windowId: Int64 = -9001

    override func tearDown() async throws {
        HistoryPanelService.release(windowId: windowId)
        try await super.tearDown()
    }

    private func entry(_ path: String, _ time: Date) -> HistoryPanelEntry {
        HistoryPanelEntry(url: "https://example.com/\(path)", title: path, domain: "example.com",
                          time: time, timeOfDay: "", fallbackLetter: "E")
    }

    func testCachedOpeningViewIsGroupedByDayNewestFirst() throws {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let today = max(startOfToday, now.addingTimeInterval(-60))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .hour, value: -12, to: startOfToday))
        let older = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: startOfToday))
        let service = HistoryPanelService.service(windowId: windowId, profileId: "history-panel-tests")
        service.lastOpeningResults = [entry("a", today), entry("b", today), entry("c", yesterday), entry("d", older)]

        let model = HistoryPanelModel(service: service, onOpen: { _, _ in }, onShowFullHistory: {}, onClose: {})

        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.sections.map(\.entries.count), [2, 1, 1])
        XCTAssertEqual(model.sections[0].title, HistoryPanelModel.Range.today.title)
        XCTAssertEqual(model.sections[1].title, HistoryPanelModel.Range.yesterday.title)
        XCTAssertEqual(model.sections[2].entries.first?.url, "https://example.com/d")
    }

    func testKeyboardSelectionMovesWithinTheListAndStopsAtItsEnds() {
        let service = HistoryPanelService.service(windowId: windowId, profileId: "history-panel-tests")
        let now = Date()
        service.lastOpeningResults = [entry("a", now), entry("b", now.addingTimeInterval(-1))]
        var opened: [String] = []
        let model = HistoryPanelModel(service: service, onOpen: { entry, _ in opened.append(entry.url) },
                                      onShowFullHistory: {}, onClose: {})

        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.openSelection(.current)
        model.moveSelection(by: -5)
        model.openSelection(.current)

        XCTAssertEqual(opened, ["https://example.com/b", "https://example.com/a"])
    }

    func testOpensWithNoFilter() {
        let service = HistoryPanelService.service(windowId: windowId, profileId: "history-panel-tests")
        let model = HistoryPanelModel(service: service, onOpen: { _, _ in }, onShowFullHistory: {}, onClose: {})

        XCTAssertNil(model.range)
    }

    func testTypingFiltersTheLoadedRowsAtOnce() {
        let service = HistoryPanelService.service(windowId: windowId, profileId: "history-panel-tests")
        let now = Date()
        service.lastOpeningResults = [entry("swift-docs", now), entry("weather", now.addingTimeInterval(-1)),
                                      entry("swiftui-guide", now.addingTimeInterval(-2))]
        let model = HistoryPanelModel(service: service, onOpen: { _, _ in }, onShowFullHistory: {}, onClose: {})

        // Before any query could answer, the list already shows the matches.
        model.searchText = "swift"

        XCTAssertEqual(model.sections.flatMap(\.entries).map(\.title), ["swift-docs", "swiftui-guide"])
    }
}
