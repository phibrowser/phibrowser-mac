// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class BrowserImportAnalyticsTests: XCTestCase {
    private struct Event {
        let name: String
        let properties: [String: Any]
    }

    private final class Recorder {
        var events: [Event] = []
    }

    func testMenuPresentationUsesTheOnlySupportedEntryPoint() {
        let recorder = Recorder()
        let analytics = makeAnalytics(recorder: recorder)

        analytics.captureMenuPresentation()

        XCTAssertEqual(recorder.events.first?.name, "import_viewed")
        XCTAssertEqual(
            recorder.events.first?.properties["entry_point"] as? String,
            "menu"
        )
    }

    func testSelectionsNormalizeSourcesAndWireTypes() {
        let recorder = Recorder()
        let analytics = makeAnalytics(recorder: recorder)

        analytics.captureSelections(
            sources: [.safari, .file, .chrome, .chrome],
            dataTypesPerBrowser: [
                .chrome: ["history", "favorites", "history", "unsupported"],
                .safari: ["favorites"],
            ]
        )

        XCTAssertEqual(
            recorder.events.map {
                $0.properties["source_browser"] as? String
            },
            ["chrome", "file", "safari"]
        )
        XCTAssertEqual(
            recorder.events[0].properties["types"] as? [String],
            ["bookmarks", "history"]
        )
        XCTAssertEqual(
            recorder.events[1].properties["types"] as? [String],
            []
        )
        XCTAssertEqual(
            recorder.events[2].properties["types"] as? [String],
            ["bookmarks"]
        )
    }

    func testRunEventsUseDeterministicAggregateProperties() {
        let recorder = Recorder()
        let analytics = makeAnalytics(recorder: recorder)

        analytics.captureStarted(sources: [.safari, .arc, .chrome])
        analytics.captureFinished(
            sources: [.safari, .arc, .chrome],
            failedSources: [.safari],
            duration: 4.25,
            errorCode: .sourceImportFailed
        )

        XCTAssertEqual(
            recorder.events[0].properties["source_browsers"] as? [String],
            ["arc", "chrome", "safari"]
        )
        let finished = recorder.events[1]
        XCTAssertEqual(finished.name, "import_finished")
        XCTAssertEqual(finished.properties["success"] as? Bool, false)
        XCTAssertEqual(
            finished.properties["failed_sources"] as? [String],
            ["safari"]
        )
        XCTAssertEqual(
            finished.properties["duration_seconds"] as? TimeInterval,
            4.25
        )
        XCTAssertEqual(
            finished.properties["error_code"] as? String,
            "source_import_failed"
        )
    }

    func testSuccessfulRunOmitsErrorCodeAndClampsDuration() {
        let recorder = Recorder()
        let analytics = makeAnalytics(recorder: recorder)

        analytics.captureFinished(
            sources: [.file],
            failedSources: [],
            duration: -1,
            errorCode: nil
        )

        let properties = recorder.events[0].properties
        XCTAssertEqual(properties["success"] as? Bool, true)
        XCTAssertEqual(
            properties["duration_seconds"] as? TimeInterval,
            0
        )
        XCTAssertNil(properties["error_code"])
    }

    /// Dia imports are counted beside Chrome, Arc, Safari and file imports
    /// under a source name of their own.
    func testDiaReportsItsOwnSourceName() {
        XCTAssertEqual(BrowserImportAnalytics.sourceName(.dia), "dia")
    }

    private func makeAnalytics(
        recorder: Recorder
    ) -> BrowserImportAnalytics {
        BrowserImportAnalytics { name, properties in
            recorder.events.append(Event(name: name, properties: properties))
        }
    }
}
