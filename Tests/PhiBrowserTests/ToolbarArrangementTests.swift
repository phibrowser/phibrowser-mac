// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ToolbarArrangementTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ToolbarArrangementTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testTheStandardArrangementIsTodaysToolbar() {
        let a = ToolbarArrangement.standard
        XCTAssertEqual(a.placements(in: .left).map(\.item), [.sidebarToggle, .back, .forward, .reload])
        XCTAssertEqual(a.placements(in: .addressLeading), [])
        XCTAssertEqual(a.placements(in: .addressTrailing).map(\.item), [.readerView, .siteMemories, .copyURL, .siteMenu])
        XCTAssertTrue(a.placements(in: .addressTrailing).allSatisfy { $0.visibility == .onHover })
        XCTAssertEqual(a.placements(in: .right).map(\.item), [.extensionsButton, .memory, .downloads, .feedback, .chat])
        XCTAssertEqual(a.addressBarStyle, .standard)
        XCTAssertTrue(a.showsAddressBar)
    }

    func testAnArrangementSavedBeforeTheAddressBarCouldBeRemovedShowsIt() throws {
        let json = #"{"addressBarStyle":"standard","zones":{"left":[{"item":"back","visibility":"always"}],"addressLeading":[],"addressTrailing":[],"right":[]}}"#
        let a = try JSONDecoder().decode(ToolbarArrangement.self, from: Data(json.utf8))
        XCTAssertTrue(a.showsAddressBar)
        XCTAssertEqual(a.placements(in: .left).map(\.item), [.back])
    }

    func testARemovedAddressBarRoundTripsWithItsButtons() throws {
        var a = ToolbarArrangement.standard
        a.place(.copyURL, in: .addressLeading, at: 0)
        a.showsAddressBar = false
        let decoded = try JSONDecoder().decode(ToolbarArrangement.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
        XCTAssertFalse(decoded.showsAddressBar)
        XCTAssertEqual(decoded.zone(of: .copyURL), .addressLeading)
        XCTAssertFalse(decoded.drawsAddressZones)
    }

    func testPlacingMovesAnItemThatIsAlreadyPlaced() {
        var a = ToolbarArrangement.standard
        XCTAssertTrue(a.place(.copyURL, in: .addressLeading, at: 0))
        XCTAssertEqual(a.zone(of: .copyURL), .addressLeading)
        XCTAssertFalse(a.placements(in: .addressTrailing).contains { $0.item == .copyURL })
    }

    func testChatCannotGoIntoTheAddressBar() {
        var a = ToolbarArrangement.standard
        XCTAssertFalse(a.place(.chat, in: .addressTrailing, at: 0))
        XCTAssertEqual(a.zone(of: .chat), .right)
    }

    func testVisibilityFollowsTheZone() {
        var a = ToolbarArrangement.standard
        a.place(.back, in: .addressLeading, at: 0)
        XCTAssertEqual(a.placements(in: .addressLeading).first?.visibility, .onHover)
        a.setVisibility(.always, for: .back)
        a.place(.back, in: .addressTrailing, at: 0)
        XCTAssertEqual(a.placements(in: .addressTrailing).first?.visibility, .always, "moving between address zones keeps it")
        a.place(.back, in: .left, at: 0)
        XCTAssertEqual(a.placements(in: .left).first?.visibility, .always)
        a.setVisibility(.onHover, for: .back)
        XCTAssertEqual(a.placements(in: .left).first?.visibility, .always, "side zones are always visible")
    }

    func testOnHoverButtonsShowOnlyWhileHoveredOrCustomizing() {
        let p = ToolbarPlacement(item: .copyURL, visibility: .onHover)
        XCTAssertFalse(WebContentAddressBarView.isShown(p, isHovering: false, isMenuShown: false, isCustomizing: false))
        XCTAssertTrue(WebContentAddressBarView.isShown(p, isHovering: true, isMenuShown: false, isCustomizing: false))
        XCTAssertTrue(WebContentAddressBarView.isShown(p, isHovering: false, isMenuShown: true, isCustomizing: false))
        XCTAssertTrue(WebContentAddressBarView.isShown(p, isHovering: false, isMenuShown: false, isCustomizing: true))
        XCTAssertTrue(WebContentAddressBarView.isShown(.init(item: .copyURL, visibility: .always), isHovering: false, isMenuShown: false, isCustomizing: false))
    }

    func testIndexesBeyondTheEndAppend() {
        var a = ToolbarArrangement.standard
        a.place(.copyURL, in: .left, at: 99)
        XCTAssertEqual(a.placements(in: .left).last?.item, .copyURL)
    }

    func testItRoundTripsThroughJSON() throws {
        var a = ToolbarArrangement.standard
        a.place(.extensionAction("abc"), in: .left, at: 1)
        a.addressBarStyle = .minimal
        let decoded = try JSONDecoder().decode(ToolbarArrangement.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
    }

    func testDecodingSkipsUnknownItems() throws {
        let json = #"{"addressBarStyle":"standard","zones":{"left":[{"item":"back","visibility":"always"},{"item":"futureThing","visibility":"always"}],"addressLeading":[],"addressTrailing":[],"right":[]}}"#
        let a = try JSONDecoder().decode(ToolbarArrangement.self, from: Data(json.utf8))
        XCTAssertEqual(a.placements(in: .left).map(\.item), [.back])
    }

    func testAStyleFromALaterBuildKeepsTheArrangement() throws {
        // A downgrade must not lose the user's buttons to a style this build does not know.
        let json = #"{"addressBarStyle":"floating","zones":{"left":[{"item":"copyURL","visibility":"always"}],"addressLeading":[],"addressTrailing":[],"right":[]}}"#
        let a = try JSONDecoder().decode(ToolbarArrangement.self, from: Data(json.utf8))
        XCTAssertEqual(a.addressBarStyle, .standard)
        XCTAssertEqual(a.placements(in: .left).map(\.item), [.copyURL])
        defaults.set(Data(json.utf8), forKey: PhiPreferences.GeneralSettings.toolbarArrangementKey)
        XCTAssertFalse(PhiPreferences.GeneralSettings.hasUnreadableToolbarArrangement(in: defaults))
    }

    func testAFreshProfileGetsTheStandardArrangement() {
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults), .standard)
    }

    func testTheOldComfortableSwitchesAreConvertedOnce() {
        defaults.set(false, forKey: PhiPreferences.GeneralSettings.topBarShowsDownloads.rawValue)
        let first = PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults)
        XCTAssertNil(first.zone(of: .downloads))
        XCTAssertEqual(first.zone(of: .memory), .right)
        defaults.set(true, forKey: PhiPreferences.GeneralSettings.topBarShowsDownloads.rawValue)
        XCTAssertNil(PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults).zone(of: .downloads),
                     "after the first load the arrangement is the only source")
    }

    func testSavedArrangementsLoadBack() {
        var a = ToolbarArrangement.standard
        a.place(.copyURL, in: .left, at: 0)
        PhiPreferences.GeneralSettings.saveToolbarArrangement(a, to: defaults)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults), a)
    }

    func testANewlyPinnedExtensionJoinsTheRightZone() {
        var a = ToolbarArrangement.standard
        a.place(.extensionAction("x"), in: .right, at: 0)
        let r = a.reconciled(pinnedExtensionIDs: ["x", "y"], pendingPinIDs: [])
        XCTAssertEqual(r.placements(in: .right).prefix(3).map(\.item), [.extensionAction("x"), .extensionAction("y"), .extensionsButton])
    }

    func testAnUnpinnedExtensionLeaves() {
        var a = ToolbarArrangement.standard
        a.place(.extensionAction("x"), in: .left, at: 0)
        XCTAssertNil(a.reconciled(pinnedExtensionIDs: [], pendingPinIDs: []).zone(of: .extensionAction("x")))
    }

    func testAPendingPinSurvivesReconcile() {
        var a = ToolbarArrangement.standard
        a.place(.extensionAction("x"), in: .addressLeading, at: 0)
        XCTAssertEqual(a.reconciled(pinnedExtensionIDs: [], pendingPinIDs: ["x"]).zone(of: .extensionAction("x")), .addressLeading)
    }

    func testStoringNewPinsKeepsExtensionsOtherWindowsDoNotSee() {
        var a = ToolbarArrangement.standard
        a.place(.extensionAction("x"), in: .left, at: 0)
        // A window that has not loaded its extensions, or a profile without "x", must not erase it.
        XCTAssertEqual(a.addingNewPins([]), a)
        let added = a.addingNewPins(["y"])
        XCTAssertEqual(added.zone(of: .extensionAction("x")), .left)
        XCTAssertEqual(added.placements(in: .right).first?.item, .extensionAction("y"))
    }

    func testWindowsWithDifferentPinsAgreeOnWhatToStore() {
        // Two windows (say two profiles) that each store their reconcile must settle, not take turns.
        var stored = ToolbarArrangement.standard
        for pinned in [["x"], ["y"], ["x"], ["y"]] {
            stored = stored.addingNewPins(pinned)
        }
        XCTAssertEqual(stored.addingNewPins(["x"]), stored)
        XCTAssertEqual(stored.addingNewPins(["y"]), stored)
    }

    func testBothStylesDrawTheAddressZonesOfAShownBar() {
        var a = ToolbarArrangement.standard
        XCTAssertTrue(a.drawsAddressZones)
        a.addressBarStyle = .minimal
        XCTAssertTrue(a.drawsAddressZones, "Minimal draws them around the centered address")
        a.showsAddressBar = false
        XCTAssertFalse(a.drawsAddressZones)
    }

    // MARK: - Placed by the user

    func testNoItemOfTheStandardArrangementIsPlacedByTheUser() {
        let a = ToolbarArrangement.standard
        for item in [ToolbarItemID.downloads, .memory, .feedback, .back, .copyURL] {
            XCTAssertFalse(a.isPlacedByUser(item))
        }
    }

    func testAnArrangementSavedBeforeTheMarkHasNoItemPlacedByTheUser() throws {
        let json = #"{"addressBarStyle":"standard","showsAddressBar":true,"zones":{"left":[],"addressLeading":[],"addressTrailing":[],"right":[{"item":"downloads","visibility":"always"}]}}"#
        let a = try JSONDecoder().decode(ToolbarArrangement.self, from: Data(json.utf8))
        XCTAssertEqual(a.placements(in: .right).map(\.item), [.downloads])
        XCTAssertFalse(a.isPlacedByUser(.downloads))
    }

    func testAMarkThatCannotBeReadKeepsTheArrangement() throws {
        let json = #"{"addressBarStyle":"standard","zones":{"left":[],"addressLeading":[],"addressTrailing":[],"right":[{"item":"downloads","visibility":"always"}]},"placedByUser":"downloads"}"#
        let a = try JSONDecoder().decode(ToolbarArrangement.self, from: Data(json.utf8))
        XCTAssertEqual(a.placements(in: .right).map(\.item), [.downloads])
        XCTAssertFalse(a.isPlacedByUser(.downloads))
    }

    func testMarksForUnknownOrUnplacedItemsAreDropped() throws {
        let json = #"{"addressBarStyle":"standard","zones":{"left":[],"addressLeading":[],"addressTrailing":[],"right":[{"item":"downloads","visibility":"always"}]},"placedByUser":["downloads","memory","futureThing"]}"#
        let a = try JSONDecoder().decode(ToolbarArrangement.self, from: Data(json.utf8))
        XCTAssertTrue(a.isPlacedByUser(.downloads))
        XCTAssertFalse(a.isPlacedByUser(.memory), "not placed")
    }

    func testPlacingByTheUserMarksTheItemAndRoundTrips() throws {
        var a = ToolbarArrangement.standard
        a.place(.downloads, in: .right, at: 0, byUser: true)
        XCTAssertTrue(a.isPlacedByUser(.downloads))
        XCTAssertFalse(a.isPlacedByUser(.memory))
        XCTAssertNotEqual(a, .standard)
        let decoded = try JSONDecoder().decode(ToolbarArrangement.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
        XCTAssertTrue(decoded.isPlacedByUser(.downloads))
    }

    func testPlacingOtherwiseNeitherMarksNorClearsTheItem() {
        var a = ToolbarArrangement.standard
        a.place(.memory, in: .left, at: 0)
        XCTAssertFalse(a.isPlacedByUser(.memory))
        a.place(.memory, in: .right, at: 0, byUser: true)
        a.place(.memory, in: .addressLeading, at: 0)
        XCTAssertTrue(a.isPlacedByUser(.memory))
    }

    func testRemovingAnItemClearsItsMark() {
        var a = ToolbarArrangement.standard
        a.place(.feedback, in: .left, at: 0, byUser: true)
        a.remove(.feedback)
        XCTAssertFalse(a.isPlacedByUser(.feedback))
        a.place(.feedback, in: .right, at: 0)
        XCTAssertFalse(a.isPlacedByUser(.feedback), "placed again by the default set or migration, not the user")
    }

    // MARK: - Sidebar toggle follows the sidebar

    func testTheDefaultSidebarToggleSitsLastInRightWithTheSidebarOnTheRight() {
        let mirrored = ToolbarArrangement.standard.placingDefaultSidebarToggle(sidebarOnRight: true)
        XCTAssertEqual(mirrored.zone(of: .sidebarToggle), .right)
        XCTAssertEqual(mirrored.placements(in: .right).last?.item, .sidebarToggle)
        XCTAssertEqual(mirrored.placements(in: .left).map(\.item), [.back, .forward, .reload])
        XCTAssertFalse(mirrored.isPlacedByUser(.sidebarToggle), "still the default, so it follows the sidebar back")

        let back = mirrored.placingDefaultSidebarToggle(sidebarOnRight: false)
        XCTAssertEqual(back, .standard, "with the sidebar on the left it is first in Left again")
    }

    func testASidebarToggleTheUserPlacedStaysWhereTheyPutIt() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.sidebarToggle, in: .left, at: 2, byUser: true)
        XCTAssertEqual(arrangement.placingDefaultSidebarToggle(sidebarOnRight: true), arrangement)
    }

    func testARemovedSidebarToggleStaysRemoved() {
        var arrangement = ToolbarArrangement.standard
        arrangement.remove(.sidebarToggle)
        XCTAssertNil(arrangement.placingDefaultSidebarToggle(sidebarOnRight: true).zone(of: .sidebarToggle))
    }

    func testLoadingPutsTheDefaultSidebarToggleOnTheSidebarsSideOutsideComfortable() {
        PhiPreferences.GeneralSettings.saveToolbarArrangement(.standard, to: defaults)
        PhiPreferences.GeneralSettings.saveSidebarPosition(.right, to: defaults)
        defaults.set(LayoutMode.balanced.rawValue, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults).zone(of: .sidebarToggle), .right)

        defaults.set(LayoutMode.comfortable.rawValue, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults).placements(in: .left).first?.item,
                       .sidebarToggle, "Comfortable keeps its sidebar on the left")
    }
}
