// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class PhiIconCatalogTests: XCTestCase {
    func testCatalogUsesUniqueSemanticAssetNames() {
        XCTAssertEqual(PhiIconCatalog.all.count, 88)
        XCTAssertEqual(Set(PhiIconCatalog.allIds).count, PhiIconCatalog.all.count)
        XCTAssertEqual(PhiIconCatalog.all.first?.assetName, "phi-icon-mail")
        XCTAssertEqual(PhiIconCatalog.all.last?.assetName, "phi-icon-backtick")
    }

    func testCatalogMapsFigmaNamesToFileSafeAssetNames() {
        XCTAssertEqual(PhiIconCatalog.icon(named: "mail")?.assetName, "phi-icon-mail")
        XCTAssertEqual(PhiIconCatalog.icon(named: "1")?.assetName, "phi-icon-number-1")
        XCTAssertEqual(PhiIconCatalog.icon(named: "A")?.assetName, "phi-icon-letter-a")
        XCTAssertEqual(PhiIconCatalog.icon(named: "?")?.assetName, "phi-icon-question-mark")
    }

    func testLegacyNumberedIdsResolveByArtwork() {
        XCTAssertEqual(PhiIconCatalog.canonicalId(for: "phi-icon-1"), "phi-icon-rss")
        XCTAssertEqual(PhiIconCatalog.canonicalId(for: "phi-icon-22"), "phi-icon-view-grid-add")
        XCTAssertEqual(PhiIconCatalog.canonicalId(for: "phi-icon-47"), "phi-icon-mail")
        XCTAssertEqual(PhiIconCatalog.canonicalId(for: "phi-icon-48"), "phi-icon-map")

        for legacyNumber in 1 ... 48 {
            XCTAssertNotNil(PhiIconCatalog.canonicalId(for: "phi-icon-\(legacyNumber)"))
        }
    }

    func testSelectionRestoresLegacyAndSemanticIdsAsCanonicalValues() {
        XCTAssertEqual(
            IconPickerSelection.fromStorageValue("phi:phi-icon-1"),
            .phiIcon(id: "phi-icon-rss")
        )
        XCTAssertEqual(
            IconPickerSelection.fromStorageValue("phi:phi-icon-mail"),
            .phiIcon(id: "phi-icon-mail")
        )
        XCTAssertNil(IconPickerSelection.fromStorageValue("phi:phi-icon-unknown"))
    }

    func testAgentIconInputNormalizesToRenderableStorageValues() {
        let normalize = AgentSpaceRouter.normalizedIconStorageValue
        XCTAssertEqual(normalize("phi:phi-icon-mail"), "phi:phi-icon-mail")
        XCTAssertEqual(normalize("mail"), "phi:phi-icon-mail")
        XCTAssertEqual(normalize("phi-icon-mail"), "phi:phi-icon-mail")
        XCTAssertEqual(normalize("phi:mail"), "phi:phi-icon-mail")
        XCTAssertEqual(normalize("A"), "phi:phi-icon-letter-a")
        XCTAssertEqual(normalize("phi:phi-icon-22"), "phi:phi-icon-view-grid-add")
        XCTAssertEqual(normalize("emoji:1F600"), "emoji:1F600")
        XCTAssertEqual(normalize("emoji:1f600"), "emoji:1F600")
        XCTAssertEqual(normalize("😀"), "emoji:1F600")
        XCTAssertEqual(normalize("emoji:😀"), "emoji:1F600")

        for value in ["", "  ", "rocket-ship", "phi:phi-icon-unknown", "emoji:ZZZZ", "star.fill"] {
            XCTAssertNil(normalize(value), value)
        }
        for value in ["mail", "A", "😀", "emoji:1f600"] {
            XCTAssertNotNil(normalize(value).flatMap { IconPickerSelection.fromStorageValue($0) }, value)
        }
    }
}
