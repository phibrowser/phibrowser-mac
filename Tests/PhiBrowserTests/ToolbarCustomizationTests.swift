// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
import Combine
import SwiftUI
@testable import Phi

/// Every controller stores into a per-test suite, never `UserDefaults.standard`.
@MainActor
final class ToolbarCustomizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var pins: FakePins!

    override func setUp() {
        super.setUp()
        suiteName = "ToolbarCustomizationTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        pins = FakePins()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        pins = nil
        super.tearDown()
    }

    private func makeController() -> ToolbarCustomizationController {
        ToolbarCustomizationController(defaults: defaults, extensions: pins.pinning)
    }

    private var stored: ToolbarArrangement {
        PhiPreferences.GeneralSettings.loadToolbarArrangement(from: defaults)
    }

    private func store(_ arrangement: ToolbarArrangement) {
        PhiPreferences.GeneralSettings.saveToolbarArrangement(arrangement, to: defaults)
    }

    // MARK: - Drop index and payload

    func testDropIndexFollowsMidpoints() {
        XCTAssertEqual(ToolbarDropIndex.index(forX: 5, itemMidXs: [10, 40, 70]), 0)
        XCTAssertEqual(ToolbarDropIndex.index(forX: 50, itemMidXs: [10, 40, 70]), 2)
        XCTAssertEqual(ToolbarDropIndex.index(forX: 99, itemMidXs: [10, 40, 70]), 3)
        XCTAssertEqual(ToolbarDropIndex.index(forX: 99, itemMidXs: []), 0)
    }

    func testADrawnIndexLandsBeforeTheSameItemInTheArrangement() {
        // Reader View is placed but not drawn: a drop before Copy URL lands right before Copy URL.
        let arranged: [ToolbarItemID] = [.readerView, .siteMemories, .copyURL, .siteMenu]
        let drawn: [ToolbarItemID] = [.siteMemories, .copyURL, .siteMenu]
        XCTAssertEqual(ToolbarDropIndex.arrangementIndex(drawnIndex: 1, drawn: drawn, arranged: arranged), 2)
        XCTAssertEqual(ToolbarDropIndex.arrangementIndex(drawnIndex: 3, drawn: drawn, arranged: arranged), 4)
        XCTAssertEqual(ToolbarDropIndex.arrangementIndex(drawnIndex: 0, drawn: [], arranged: arranged), 4)
    }

    func testPayloadsRoundTrip() {
        for p in [ToolbarDragPayload.item(.copyURL), .item(.extensionAction("abc")), .defaultSet, .addressBar] {
            XCTAssertEqual(ToolbarDragPayload(string: p.string), p)
        }
        XCTAssertNil(ToolbarDragPayload(string: "item:nope"))
        XCTAssertNil(ToolbarDragPayload(string: ""))
        XCTAssertEqual(ToolbarDragPayload.pasteboardType.rawValue, "com.phibrowser.toolbar-item")
    }

    // MARK: - Controller

    // MARK: - Dragging from the toolbar

    private var storedData: Data? {
        defaults.data(forKey: PhiPreferences.GeneralSettings.toolbarArrangementKey)
    }

    func testAnItemDraggedFromTheToolbarHidesUntilTheDragEndsAndNothingIsSaved() {
        let controller = makeController()
        store(.standard)
        let before = storedData
        var changes = 0
        controller.onChange = { changes += 1 }

        controller.dragBegan(.item(.reload))
        XCTAssertEqual(controller.draggedPayload, .item(.reload), "the header lays out without it")
        XCTAssertEqual(changes, 1, "the header redraws")
        XCTAssertEqual(storedData, before, "nothing is saved until it lands or leaves")

        // Cancelled, or let go over the toolbar off every zone.
        controller.dragEnded()
        XCTAssertNil(controller.draggedPayload, "it shows where it was")
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(storedData, before)
        controller.dragEnded()
        XCTAssertEqual(changes, 2, "ends once")
    }

    func testAnItemDraggedFromTheToolbarAndDroppedOnAZoneIsPlacedThere() {
        let controller = makeController()
        store(.standard)
        controller.dragBegan(.item(.reload))
        XCTAssertTrue(controller.drop(.item(.reload), in: .right, at: 0))
        XCTAssertNil(controller.draggedPayload, "drawn in its new place as the drop saves")
        XCTAssertEqual(stored.placements(in: .right).first?.item, .reload)
        XCTAssertFalse(stored.placements(in: .left).contains { $0.item == .reload })

        var changes = 0
        controller.onChange = { changes += 1 }
        controller.dragEnded()
        XCTAssertEqual(changes, 0, "the drag's end has nothing left to do")
    }

    func testAnItemDraggedBackToItsOwnZoneKeepsItsPlace() {
        let controller = makeController()
        store(.standard)
        controller.dragBegan(.item(.forward))
        // Dropped between Back and Reload, counted without Forward.
        let index = controller.arrangementIndex(for: .item(.forward), in: .left, drawnIndex: 2, drawn: [.sidebarToggle, .back, .reload])
        XCTAssertTrue(controller.drop(.item(.forward), in: .left, at: index))
        XCTAssertEqual(stored.placements(in: .left).map(\.item), [.sidebarToggle, .back, .forward, .reload])
    }

    func testAnItemDraggedOutOfTheToolbarLeavesIt() {
        let controller = makeController()
        store(.standard)
        controller.dragBegan(.item(.copyURL))
        XCTAssertTrue(controller.dragEndedOutside(.copyURL))
        XCTAssertNil(controller.draggedPayload, "it never shows again")
        XCTAssertNil(stored.zone(of: .copyURL))
        controller.dragEnded()
        XCTAssertNil(stored.zone(of: .copyURL))
    }

    func testAForcePinnedExtensionDraggedOutComesBackWhereItWas() {
        let controller = makeController()
        pins.pinned = ["ext"]
        pins.forcePinned = ["ext"]
        var arrangement = ToolbarArrangement.standard
        _ = arrangement.place(.extensionAction("ext"), in: .right, at: 1)
        store(arrangement)
        let before = storedData
        controller.dragBegan(.item(.extensionAction("ext")))
        XCTAssertFalse(controller.dragEndedOutside(.extensionAction("ext")))
        XCTAssertEqual(controller.draggedPayload, .item(.extensionAction("ext")), "still hidden until the drag ends")
        controller.dragEnded()
        XCTAssertNil(controller.draggedPayload)
        XCTAssertEqual(storedData, before)
        XCTAssertEqual(pins.unpinCalls, [])
    }

    func testTheAddressBarDraggedFromTheToolbarHidesUntilItLeavesOrComesBack() {
        let controller = makeController()
        store(.standard)
        let before = storedData
        controller.dragBegan(.addressBar)
        XCTAssertEqual(controller.draggedPayload, .addressBar)
        XCTAssertEqual(storedData, before)
        XCTAssertTrue(controller.canDrop(.addressBar, in: .left), "a zone takes the bar dragged from the toolbar back")
        var changes = 0
        controller.onChange = { changes += 1 }
        XCTAssertTrue(controller.dropOverToolbar(.addressBar), "so does the toolbar: let go over it, it is back at once")
        XCTAssertNil(controller.draggedPayload, "drawn again by the drop's own redraw")
        XCTAssertEqual(changes, 1)
        controller.dragEnded()
        XCTAssertEqual(changes, 1, "the drag's end has nothing left to do")
        XCTAssertTrue(stored.showsAddressBar)
        XCTAssertEqual(storedData, before, "nothing stored changes")

        controller.dragBegan(.addressBar)
        controller.dragEnded()
        XCTAssertNil(controller.draggedPayload, "a cancelled drag puts it back too")
        XCTAssertEqual(storedData, before)

        controller.dragBegan(.addressBar)
        XCTAssertTrue(controller.addressBarDraggedOut())
        XCTAssertNil(controller.draggedPayload)
        XCTAssertFalse(stored.showsAddressBar)
    }

    func testNothingHidesOutsideCustomizingOrForTheDefaultSet() {
        let controller = makeController()
        controller.dragBegan(.defaultSet)
        XCTAssertNil(controller.draggedPayload, "the default set is never in the toolbar")
        controller.isCustomizing = { false }
        controller.dragBegan(.item(.back))
        XCTAssertNil(controller.draggedPayload)
    }

    func testDroppingTheDefaultSetRestoresTheStandardArrangement() {
        let controller = makeController()
        controller.drop(.item(.copyURL), in: .addressLeading, at: 0)
        controller.drop(.item(.back), in: .right, at: 0)
        var minimal = stored
        minimal.addressBarStyle = .minimal
        store(minimal)
        XCTAssertNotEqual(stored, .standard)

        XCTAssertTrue(controller.drop(.defaultSet, in: .left, at: 0))
        XCTAssertEqual(stored, .standard)
    }

    func testTheDefaultSetIsTakenAnywhereOverTheToolbar() {
        let controller = makeController()
        controller.drop(.item(.back), in: .right, at: 0)
        XCTAssertTrue(ToolbarCustomizationController.isAcceptedOverToolbar(.defaultSet, showsAddressBar: true))
        XCTAssertTrue(controller.dropOverToolbar(.defaultSet))
        XCTAssertEqual(stored, .standard)
    }

    func testAnItemOverTheToolbarOutsideEveryZoneIsRefused() {
        let controller = makeController()
        controller.drop(.item(.back), in: .right, at: 0)
        let before = stored
        XCTAssertFalse(ToolbarCustomizationController.isAcceptedOverToolbar(.item(.copyURL), showsAddressBar: false))
        XCTAssertFalse(controller.dropOverToolbar(.item(.copyURL)))
        XCTAssertEqual(stored, before)
    }

    // MARK: - Address bar

    func testDraggingTheAddressBarOutRemovesItAndKeepsItsButtons() {
        let controller = makeController()
        controller.drop(.item(.back), in: .addressLeading, at: 0)
        let leading = stored.placements(in: .addressLeading)
        let trailing = stored.placements(in: .addressTrailing)

        XCTAssertTrue(controller.addressBarDraggedOut())
        XCTAssertFalse(stored.showsAddressBar)
        XCTAssertEqual(stored.placements(in: .addressLeading), leading, "its buttons stay stored")
        XCTAssertEqual(stored.placements(in: .addressTrailing), trailing)

        XCTAssertTrue(controller.dropOverToolbar(.addressBar))
        XCTAssertTrue(stored.showsAddressBar)
        XCTAssertEqual(stored.placements(in: .addressLeading), leading, "adding it back brings them back")
        XCTAssertEqual(stored.placements(in: .addressTrailing), trailing)
    }

    func testTheAddressBarIsNotRemovedOnceCustomizingHasEnded() {
        let controller = makeController()
        controller.isCustomizing = { false }
        XCTAssertFalse(controller.addressBarDraggedOut())
        XCTAssertTrue(stored.showsAddressBar)
    }

    func testARemovedAddressBarIsTakenAnywhereOverTheToolbar() {
        XCTAssertTrue(ToolbarCustomizationController.isAcceptedOverToolbar(.addressBar, showsAddressBar: false))
        XCTAssertFalse(ToolbarCustomizationController.isAcceptedOverToolbar(.addressBar, showsAddressBar: true),
                       "a shown bar dragged from elsewhere (the sheet) lands nowhere")
        XCTAssertTrue(ToolbarCustomizationController.isAcceptedOverToolbar(.addressBar, showsAddressBar: true, isDraggedFromToolbar: true),
                      "the bar dragged from the toolbar is taken back anywhere over it")
        XCTAssertFalse(ToolbarCustomizationController.isAcceptedOverToolbar(.item(.back), showsAddressBar: true, isDraggedFromToolbar: true),
                       "an item still needs a zone")
        XCTAssertTrue(ToolbarCustomizationController.isAcceptedOverToolbar(.defaultSet, showsAddressBar: false))
        XCTAssertFalse(ToolbarCustomizationController.isAcceptedOverToolbar(.item(.back), showsAddressBar: true))

        let controller = makeController()
        XCTAssertFalse(controller.canDrop(.addressBar, in: .left), "shown: nothing to add")
        controller.addressBarDraggedOut()
        for zone in [ToolbarZone.left, .right] {
            XCTAssertTrue(controller.canDrop(.addressBar, in: zone), "over \(zone) too")
        }
        // Dropped on Left, it still goes back between Left and Right.
        let left = stored.placements(in: .left)
        XCTAssertTrue(controller.drop(.addressBar, in: .left, at: 0))
        XCTAssertTrue(stored.showsAddressBar)
        XCTAssertEqual(stored.placements(in: .left), left)
    }

    func testARemovedAddressBarTakesNoButtons() {
        let controller = makeController()
        controller.addressBarDraggedOut()
        XCTAssertFalse(controller.canDrop(.item(.back), in: .addressLeading))
        XCTAssertFalse(controller.drop(.item(.back), in: .addressTrailing, at: 0))
        XCTAssertNil(controller.visibilityMenu(for: .copyURL), "its buttons are not drawn")
        XCTAssertTrue(controller.canDrop(.item(.back), in: .right))
    }

    func testTheDefaultSetBringsTheAddressBarBack() {
        let controller = makeController()
        controller.addressBarDraggedOut()
        XCTAssertTrue(controller.dropOverToolbar(.defaultSet))
        XCTAssertTrue(stored.showsAddressBar)
        XCTAssertEqual(stored, .standard)
    }

    func testThePaletteGreysTheAddressTileWhileTheBarIsShown() {
        var arrangement = ToolbarArrangement.standard
        XCTAssertTrue(ToolbarPalette.isAddressBarPlaced(in: arrangement))
        XCTAssertTrue(ToolbarPalette.isPlaced(.copyURL, in: arrangement, isDrawn: true))

        arrangement.showsAddressBar = false
        XCTAssertFalse(ToolbarPalette.isAddressBarPlaced(in: arrangement))
        XCTAssertFalse(ToolbarPalette.isPlaced(.copyURL, in: arrangement, isDrawn: true), "a removed bar draws none of its buttons")
        XCTAssertFalse(ToolbarPalette.isPlaced(.siteMenu, in: arrangement, isDrawn: true))
        XCTAssertTrue(ToolbarPalette.isPlaced(.back, in: arrangement, isDrawn: true))

        arrangement.addressBarStyle = .minimal
        XCTAssertFalse(ToolbarPalette.isPlaced(.copyURL, in: arrangement, isDrawn: true), "nor does a removed Minimal bar")
        XCTAssertFalse(ToolbarPalette.isPlaced(.siteMenu, in: arrangement, isDrawn: true))
    }

    func testThePaletteListsTheAddressTileAfterTheLeftButtons() {
        let split = ToolbarPalette.splitAroundAddressBar(ToolbarPalette.phiItems)
        XCTAssertEqual(split.before, [.sidebarToggle, .back, .forward, .reload])
        XCTAssertEqual(split.before + split.after, ToolbarPalette.phiItems)
    }

    func testTheDefaultSetIsNotTakenOnceCustomizingHasEnded() {
        let controller = makeController()
        controller.drop(.item(.back), in: .right, at: 0)
        controller.isCustomizing = { false }
        XCTAssertFalse(controller.dropOverToolbar(.defaultSet))
        XCTAssertEqual(stored.zone(of: .back), .right)
    }

    func testAnEmptyZonesTargetLiesOverTheSpaceBesideIt() {
        // Over the start or end of the address text, never a reserved gap.
        XCTAssertEqual(ToolbarCustomizationLayout.emptyZoneAlignment(.addressLeading), .leading)
        XCTAssertEqual(ToolbarCustomizationLayout.emptyZoneAlignment(.addressTrailing), .trailing)
        XCTAssertEqual(ToolbarCustomizationLayout.emptyZoneAlignment(.right), .trailing)
        XCTAssertEqual(ToolbarCustomizationLayout.emptyZoneAlignment(.left), .center)
    }

    func testMovingWithinAZoneCountsTheZoneWithoutTheDraggedItem() {
        let controller = makeController()
        // Back dropped between Forward and Reload: index 2 of [Toggle Sidebar, Forward, Reload].
        XCTAssertTrue(controller.drop(.item(.back), in: .left, at: 2))
        XCTAssertEqual(stored.placements(in: .left).map(\.item), [.sidebarToggle, .forward, .back, .reload])
    }

    func testCopyURLMovesToTheFrontOfTheAddress() {
        let controller = makeController()
        XCTAssertTrue(controller.drop(.item(.copyURL), in: .addressLeading, at: 0))
        XCTAssertEqual(stored.placements(in: .addressLeading), [ToolbarPlacement(item: .copyURL, visibility: .onHover)])
        XCTAssertNil(stored.placements(in: .addressTrailing).first { $0.item == .copyURL })
    }

    func testADropIndexIsMappedPastItemsThatAreNotDrawn() {
        let controller = makeController()
        let index = controller.arrangementIndex(
            for: .item(.siteMenu), in: .addressTrailing,
            drawnIndex: 0, drawn: [.copyURL]
        )
        // Before Copy URL, after the undrawn Reader View and Site Memories.
        XCTAssertEqual(index, 2)
    }

    func testChatIsRefusedInTheAddressZones() {
        let controller = makeController()
        XCTAssertFalse(controller.canDrop(.item(.chat), in: .addressLeading))
        XCTAssertFalse(controller.drop(.item(.chat), in: .addressTrailing, at: 0))
        XCTAssertEqual(stored.zone(of: .chat), .right)
        XCTAssertTrue(controller.canDrop(.item(.chat), in: .left))
    }

    func testTheAddressZonesAreDroppableInMinimal() {
        var minimal = ToolbarArrangement.standard
        minimal.addressBarStyle = .minimal
        store(minimal)
        let controller = makeController()
        XCTAssertTrue(controller.canDrop(.item(.back), in: .addressLeading))
        XCTAssertTrue(controller.canDrop(.item(.back), in: .addressTrailing))
        XCTAssertFalse(controller.canDrop(.item(.chat), in: .addressLeading), "Chat stays out in Minimal too")
        XCTAssertTrue(controller.drop(.item(.back), in: .addressLeading, at: 0))
        XCTAssertEqual(stored.zone(of: .back), .addressLeading)
        XCTAssertEqual(stored.addressBarStyle, .minimal)
        XCTAssertNotNil(controller.visibilityMenu(for: .back), "Always / On Hover applies in Minimal")
    }

    func testARemovedMinimalAddressBarTakesNoButtons() {
        var minimal = ToolbarArrangement.standard
        minimal.addressBarStyle = .minimal
        minimal.showsAddressBar = false
        store(minimal)
        let controller = makeController()
        XCTAssertFalse(controller.canDrop(.item(.back), in: .addressTrailing))
        XCTAssertNil(controller.visibilityMenu(for: .copyURL))
        XCTAssertTrue(controller.canDrop(.item(.back), in: .right))
    }

    func testDraggingAnItemOutRemovesIt() {
        let controller = makeController()
        XCTAssertTrue(controller.dragEndedOutside(.downloads))
        XCTAssertNil(stored.zone(of: .downloads))
    }

    func testDraggingAForcePinnedExtensionOutIsRefused() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.extensionAction("x"), in: .right, at: 0)
        store(arrangement)
        pins.pinned = ["x"]
        pins.forcePinned = ["x"]

        XCTAssertFalse(makeController().dragEndedOutside(.extensionAction("x")))
        XCTAssertEqual(stored.zone(of: .extensionAction("x")), .right)
        XCTAssertEqual(pins.unpinCalls, [])
    }

    func testDraggingAnExtensionOutUnpinsAndRemovesIt() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.extensionAction("x"), in: .left, at: 0)
        store(arrangement)
        pins.pinned = ["x"]

        XCTAssertTrue(makeController().dragEndedOutside(.extensionAction("x")))
        XCTAssertNil(stored.zone(of: .extensionAction("x")), "storage never drops an extension on its own")
        XCTAssertEqual(pins.unpinCalls, ["x"])
    }

    /// Wires the controller the way `WebContentHeader` does: every change
    /// redraws from `chromiumPinned` (Chromium's list, which lags behind pins
    /// and unpins) and stores `addingNewPins`.
    private func wireLikeTheHeader(_ controller: ToolbarCustomizationController, chromiumPinned: @escaping () -> [String]) -> () -> ToolbarArrangement {
        var drawn = ToolbarArrangement.standard
        let apply = { [unowned controller] in
            drawn = controller.drawnArrangement(pinnedIDs: chromiumPinned())
        }
        controller.onChange = apply
        apply()
        return { drawn }
    }

    /// Chromium's pinned list changed: what the header's pinned-list sink does.
    private func chromiumReports(_ pinned: [String], to controller: ToolbarCustomizationController) {
        controller.pinnedExtensionsDidChange(pinned)
        controller.onChange?()
    }

    func testTheHeaderStoresNewPinsIntoTheArrangementAsItIsNow() {
        let controller = makeController()
        // What a header would have read before another window's change landed.
        let earlier = stored
        var moved = earlier
        moved.place(.copyURL, in: .left, at: 0)
        store(moved)

        let drawn = controller.drawnArrangement(pinnedIDs: ["x"])
        XCTAssertEqual(stored.zone(of: .copyURL), .left, "the change made in between survives the save")
        XCTAssertEqual(stored.zone(of: .extensionAction("x")), .right)
        XCTAssertEqual(drawn.zone(of: .copyURL), .left)
    }

    func testAnUnreadableStoredArrangementIsNeverWrittenOver() {
        // Say a later build's: this build draws the standard arrangement but keeps the data for it.
        let data = Data(#"{"zones":5}"#.utf8)
        defaults.set(data, forKey: PhiPreferences.GeneralSettings.toolbarArrangementKey)
        XCTAssertTrue(PhiPreferences.GeneralSettings.hasUnreadableToolbarArrangement(in: defaults))

        let drawn = makeController().drawnArrangement(pinnedIDs: ["x"])
        XCTAssertEqual(drawn.zone(of: .extensionAction("x")), .right, "a pinned extension still shows")
        XCTAssertEqual(defaults.data(forKey: PhiPreferences.GeneralSettings.toolbarArrangementKey), data)
    }

    func testAnExtensionDraggedOutStaysOutWhileItsUnpinIsInFlight() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.extensionAction("x"), in: .left, at: 0)
        store(arrangement)
        pins.pinned = ["x"]
        var chromiumPinned = ["x"]
        let controller = makeController()
        let drawn = wireLikeTheHeader(controller) { chromiumPinned }

        XCTAssertTrue(controller.dragEndedOutside(.extensionAction("x")))
        XCTAssertEqual(pins.unpinCalls, ["x"])
        XCTAssertNil(stored.zone(of: .extensionAction("x")), "the stale pinned list must not store it again")
        XCTAssertNil(drawn().zone(of: .extensionAction("x")))

        chromiumReports(["x"], to: controller) // an unrelated update before the unpin lands
        XCTAssertNil(stored.zone(of: .extensionAction("x")))

        chromiumPinned = []
        chromiumReports([], to: controller)
        XCTAssertNil(stored.zone(of: .extensionAction("x")))
        XCTAssertEqual(controller.pendingUnpinIDs, [])
    }

    func testAnExtensionDraggedOutBeforeItsPinLandsIsUnpinnedWhenItDoes() {
        var chromiumPinned: [String] = []
        let controller = makeController()
        let drawn = wireLikeTheHeader(controller) { chromiumPinned }

        XCTAssertTrue(controller.drop(.item(.extensionAction("y")), in: .left, at: 0))
        XCTAssertEqual(pins.pinCalls, ["y"])
        XCTAssertTrue(controller.dragEndedOutside(.extensionAction("y")))
        XCTAssertEqual(pins.unpinCalls, [], "nothing to unpin until the pin lands")
        XCTAssertNil(stored.zone(of: .extensionAction("y")))

        chromiumPinned = ["y"]
        chromiumReports(["y"], to: controller)
        XCTAssertEqual(pins.unpinCalls, ["y"])
        XCTAssertNil(stored.zone(of: .extensionAction("y")), "the late pin must not put it back in Right")
        XCTAssertNil(drawn().zone(of: .extensionAction("y")))

        chromiumPinned = []
        chromiumReports([], to: controller)
        XCTAssertNil(stored.zone(of: .extensionAction("y")))
        XCTAssertEqual(controller.pendingUnpinIDs, [])
        XCTAssertEqual(controller.pendingPinIDs, [])
    }

    func testAnExtensionPlacedAgainWhileItsUnpinIsInFlightIsPinnedAgainWhenTheUnpinLands() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.extensionAction("x"), in: .left, at: 0)
        store(arrangement)
        pins.pinned = ["x"]
        var chromiumPinned = ["x"]
        let controller = makeController()
        let drawn = wireLikeTheHeader(controller) { chromiumPinned }

        XCTAssertTrue(controller.dragEndedOutside(.extensionAction("x")))
        XCTAssertEqual(pins.unpinCalls, ["x"])
        // Dragged back in from the sheet before Chromium reports the unpin.
        XCTAssertTrue(controller.drop(.item(.extensionAction("x")), in: .right, at: 0))
        XCTAssertEqual(pins.pinCalls, [], "still pinned as far as Chromium knows: nothing to pin yet")
        XCTAssertEqual(stored.zone(of: .extensionAction("x")), .right)
        XCTAssertEqual(drawn().zone(of: .extensionAction("x")), .right)

        chromiumReports(["x"], to: controller) // an unrelated update before the unpin lands
        XCTAssertEqual(drawn().zone(of: .extensionAction("x")), .right)

        pins.pinned = []
        chromiumPinned = []
        chromiumReports([], to: controller)
        XCTAssertEqual(pins.pinCalls, ["x"], "the landed unpin is undone")
        XCTAssertEqual(drawn().zone(of: .extensionAction("x")), .right, "kept drawn while the pin is in flight")

        pins.pinned = ["x"]
        chromiumPinned = ["x"]
        chromiumReports(["x"], to: controller)
        XCTAssertEqual(controller.pendingPinIDs, [], "no stale pending pin")
        XCTAssertEqual(controller.pendingUnpinIDs, [])
        XCTAssertEqual(stored.zone(of: .extensionAction("x")), .right)
        XCTAssertEqual(pins.unpinCalls, ["x"])
    }

    func testAnExtensionDraggedOutAgainBeforeItsUnpinLandsStaysUnpinned() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.extensionAction("x"), in: .left, at: 0)
        store(arrangement)
        pins.pinned = ["x"]
        var chromiumPinned = ["x"]
        let controller = makeController()
        let drawn = wireLikeTheHeader(controller) { chromiumPinned }

        XCTAssertTrue(controller.dragEndedOutside(.extensionAction("x")))
        XCTAssertTrue(controller.drop(.item(.extensionAction("x")), in: .right, at: 0))
        XCTAssertTrue(controller.dragEndedOutside(.extensionAction("x")))
        XCTAssertEqual(pins.unpinCalls, ["x"], "its first unpin is still on its way")

        pins.pinned = []
        chromiumPinned = []
        chromiumReports([], to: controller)
        XCTAssertEqual(pins.pinCalls, [])
        XCTAssertNil(stored.zone(of: .extensionAction("x")))
        XCTAssertNil(drawn().zone(of: .extensionAction("x")))
        XCTAssertEqual(controller.pendingPinIDs, [])
        XCTAssertEqual(controller.pendingUnpinIDs, [])
    }

    func testTheAddressBarStyleIsSavedWithTheArrangement() {
        let controller = makeController()
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.drop(.item(.copyURL), in: .addressLeading, at: 0)

        controller.setAddressBarStyle(.minimal)
        XCTAssertEqual(stored.addressBarStyle, .minimal)
        XCTAssertEqual(stored.zone(of: .copyURL), .addressLeading, "the arrangement is kept")
        controller.setAddressBarStyle(.standard)
        XCTAssertEqual(stored.addressBarStyle, .standard)
        XCTAssertEqual(changes, 3)
    }

    func testADragThatOutlivesCustomizingRemovesNothing() {
        let controller = makeController()
        controller.isCustomizing = { false }
        XCTAssertFalse(controller.dragEndedOutside(.downloads))
        XCTAssertEqual(stored.zone(of: .downloads), .right)
    }

    func testPlacingAnUnpinnedExtensionPinsItAndKeepsItWhileThePinIsPending() {
        let controller = makeController()
        var changes = 0
        controller.onChange = { changes += 1 }

        XCTAssertTrue(controller.drop(.item(.extensionAction("y")), in: .left, at: 0))
        XCTAssertEqual(pins.pinCalls, ["y"])
        XCTAssertEqual(controller.pendingPinIDs, ["y"])
        XCTAssertEqual(stored.zone(of: .extensionAction("y")), .left)
        XCTAssertEqual(
            stored.reconciled(pinnedExtensionIDs: [], pendingPinIDs: controller.pendingPinIDs).zone(of: .extensionAction("y")),
            .left
        )
        XCTAssertEqual(changes, 1)

        controller.pinnedExtensionsDidChange(["y"])
        XCTAssertEqual(controller.pendingPinIDs, [])
    }

    func testMovingAPinnedExtensionDoesNotPinItAgain() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.extensionAction("x"), in: .right, at: 0)
        store(arrangement)
        pins.pinned = ["x"]

        XCTAssertTrue(makeController().drop(.item(.extensionAction("x")), in: .left, at: 0))
        XCTAssertEqual(pins.pinCalls, [])
        XCTAssertEqual(stored.zone(of: .extensionAction("x")), .left)
    }

    func testVisibilityIsSetOnlyInTheAddressZones() {
        let controller = makeController()
        controller.setVisibility(.always, for: .copyURL)
        XCTAssertEqual(stored.placements(in: .addressTrailing).first { $0.item == .copyURL }?.visibility, .always)
        controller.setVisibility(.onHover, for: .back)
        XCTAssertEqual(stored.placements(in: .left).first { $0.item == .back }?.visibility, .always)
    }

    func testAReorderOfAdjacentExtensionsUpdatesTheArrangement() {
        var arrangement = ToolbarArrangement.standard
        for id in ["c", "b", "a"] { arrangement.place(.extensionAction(id), in: .right, at: 0) }
        store(arrangement)

        makeController().reorderExtensions(["c", "a", "b"])
        XCTAssertEqual(
            stored.placements(in: .right).map(\.item).prefix(4),
            [.extensionAction("c"), .extensionAction("a"), .extensionAction("b"), .extensionsButton]
        )
    }

    // MARK: - Arrangement

    func testReorderingKeepsTheSlotsTheItemsHeld() {
        var a = ToolbarArrangement.standard
        a.place(.extensionAction("x"), in: .addressLeading, at: 0)
        a.place(.extensionAction("y"), in: .addressLeading, at: 1)
        a.setVisibility(.always, for: .extensionAction("x"))
        a.reorder([.extensionAction("y"), .extensionAction("x")])
        XCTAssertEqual(a.placements(in: .addressLeading), [
            ToolbarPlacement(item: .extensionAction("y"), visibility: .onHover),
            ToolbarPlacement(item: .extensionAction("x"), visibility: .always),
        ])
    }

    // MARK: - What shows while customizing

    func testEveryPlacedItemShowsWhileCustomizing() {
        let state = WebContentHeaderState()
        state.showSidebarButton = false
        state.showDownloadButton = false
        state.sidebarKeepsBottomBarItems = false
        state.isInPlaceholderMode = false
        XCTAssertFalse(ToolbarItemView.isShown(.sidebarToggle, state: state, visibleExtensionIDs: []))
        XCTAssertFalse(ToolbarItemView.isShown(.downloads, state: state, visibleExtensionIDs: []))

        state.isCustomizing = true
        XCTAssertTrue(ToolbarItemView.isShown(.downloads, state: state, visibleExtensionIDs: []))
        XCTAssertTrue(ToolbarItemView.isShown(.readerView, state: state, visibleExtensionIDs: []))
        XCTAssertFalse(ToolbarItemView.isShown(.extensionAction("x"), state: state, visibleExtensionIDs: []),
                       "an extension without a pinned model has nothing to draw")
    }

    func testItemsShownOnlyForCustomizingAreToldApart() {
        let state = WebContentHeaderState()
        state.showDownloadButton = false
        state.sidebarKeepsBottomBarItems = false
        state.showNavigationButtons = true
        state.isInPlaceholderMode = false
        state.isCustomizing = true
        XCTAssertTrue(ToolbarItemView.isShown(.downloads, state: state, visibleExtensionIDs: []))
        XCTAssertFalse(ToolbarItemView.isShownWhileBrowsing(.downloads, state: state, visibleExtensionIDs: []),
                       "drawn only for customizing")
        XCTAssertTrue(ToolbarItemView.isShownWhileBrowsing(.back, state: state, visibleExtensionIDs: []))
        XCTAssertTrue(ToolbarItemView.isShownWhileBrowsing(.copyURL, state: state, visibleExtensionIDs: []))
    }

    func testToggleSidebarShowsWhileCustomizingOnlyWhereTheViewShowsIt() {
        let state = WebContentHeaderState()
        state.isInPlaceholderMode = false
        state.isCustomizing = true
        state.showSidebarButton = false
        XCTAssertFalse(ToolbarItemView.isShown(.sidebarToggle, state: state, visibleExtensionIDs: []),
                       "customizing does not push Back, Forward and Reload aside")
        state.showSidebarButton = true
        XCTAssertTrue(ToolbarItemView.isShown(.sidebarToggle, state: state, visibleExtensionIDs: []),
                      "Balanced with the sidebar collapsed")
    }

    func testAToggleSidebarTheUserPlacedShowsWithTheSidebarDocked() {
        let state = WebContentHeaderState()
        state.isInPlaceholderMode = false
        state.showSidebarButton = false
        state.sidebarKeepsBottomBarItems = true
        var arrangement = ToolbarArrangement.standard
        XCTAssertFalse(ToolbarItemView.isShownWhileBrowsing(.sidebarToggle, state: state, visibleExtensionIDs: [], arrangement: arrangement),
                       "the default copy waits for the sidebar to collapse")
        arrangement.place(.sidebarToggle, in: .right, at: 0, byUser: true)
        XCTAssertTrue(ToolbarItemView.isShownWhileBrowsing(.sidebarToggle, state: state, visibleExtensionIDs: [], arrangement: arrangement),
                      "placed by the user, it shows next to the docked sidebar")
        state.isCustomizing = true
        XCTAssertTrue(ToolbarItemView.isShown(.sidebarToggle, state: state, visibleExtensionIDs: [], arrangement: arrangement))
        state.sidebarKeepsBottomBarItems = false
        XCTAssertFalse(ToolbarItemView.isShown(.sidebarToggle, state: state, visibleExtensionIDs: [], arrangement: arrangement),
                       "Comfortable has no sidebar to toggle")
    }

    // MARK: - The sheet's default row

    private func defaultRowState(docked: Bool, phiAI: Bool, guest: Bool = false) -> WebContentHeaderState {
        let state = WebContentHeaderState()
        state.isCustomizing = true
        state.isInPlaceholderMode = false
        state.showNavigationButtons = true
        state.showChatButton = phiAI
        state.showDownloadButton = true
        state.showMemoryButton = phiAI
        state.showFeedbackButton = !guest
        state.isPhiAIAvailable = phiAI
        state.isGuest = guest
        state.showSidebarButton = !docked
        state.sidebarKeepsBottomBarItems = docked
        return state
    }

    private func defaultRow(_ state: WebContentHeaderState) -> [ToolbarItemID] {
        ToolbarZone.allCases.flatMap { ToolbarPalette.defaultSetItems(in: $0, state: state) }
    }

    func testDefaultRowWithTheSidebarDockedLeavesOutWhatTheBottomBarKeeps() {
        let row = defaultRow(defaultRowState(docked: true, phiAI: true))
        XCTAssertEqual(row, [.back, .forward, .reload, .readerView, .siteMemories, .copyURL, .siteMenu, .extensionsButton, .chat])
    }

    func testDefaultRowPutsTheSidebarToggleOnTheSidebarsSide() {
        let state = defaultRowState(docked: false, phiAI: true)
        XCTAssertEqual(ToolbarPalette.defaultSetItems(in: .left, state: state, sidebarOnRight: false).first, .sidebarToggle)
        XCTAssertFalse(ToolbarPalette.defaultSetItems(in: .left, state: state, sidebarOnRight: true).contains(.sidebarToggle))
        XCTAssertEqual(ToolbarPalette.defaultSetItems(in: .right, state: state, sidebarOnRight: true).last, .sidebarToggle,
                       "with the sidebar on the right the default set shows the toggle where dropping it puts it")
    }

    func testDroppingTheDefaultSetPutsTheSidebarToggleOnTheSidebarsSide() {
        XCTAssertEqual(ToolbarArrangement.defaultSet(sidebarOnRight: true).placements(in: .right).last?.item, .sidebarToggle)
        XCTAssertEqual(ToolbarArrangement.defaultSet(sidebarOnRight: false), .standard)
    }

    func testDefaultRowIgnoresWhatTheUserPlacedInTheStoredArrangement() {
        let state = defaultRowState(docked: true, phiAI: true)
        var arrangement = ToolbarArrangement.standard
        arrangement.remove(.downloads)
        _ = arrangement.place(.downloads, in: .right, at: 0, byUser: true)
        state.arrangement = arrangement
        XCTAssertFalse(defaultRow(state).contains(.downloads))
    }

    func testDefaultRowWithTheSidebarCollapsedShowsToggleAndBottomBarItems() {
        let row = defaultRow(defaultRowState(docked: false, phiAI: true))
        XCTAssertEqual(row, [.sidebarToggle, .back, .forward, .reload, .readerView, .siteMemories, .copyURL, .siteMenu,
                             .extensionsButton, .memory, .downloads, .feedback, .chat])
    }

    func testDefaultRowWithoutPhiAIOrAsGuest() {
        let noAI = defaultRow(defaultRowState(docked: false, phiAI: false))
        XCTAssertFalse(noAI.contains(.memory))
        XCTAssertFalse(noAI.contains(.chat))
        XCTAssertFalse(noAI.contains(.siteMemories))
        XCTAssertTrue(noAI.contains(.downloads))
        let guest = defaultRow(defaultRowState(docked: false, phiAI: true, guest: true))
        XCTAssertFalse(guest.contains(.feedback))
        XCTAssertTrue(guest.contains(.memory))
    }

    // MARK: - Downloads, Memory and Feedback placed by the user

    func testADropFromTheSheetMarksTheItem() {
        var arrangement = ToolbarArrangement.standard
        arrangement.remove(.downloads)
        store(arrangement)
        XCTAssertTrue(makeController().drop(.item(.downloads), in: .right, at: 0))
        XCTAssertTrue(stored.isPlacedByUser(.downloads))
        XCTAssertFalse(stored.isPlacedByUser(.memory))
    }

    func testAMoveWithinAZoneMarksTheItem() {
        XCTAssertTrue(makeController().drop(.item(.memory), in: .right, at: 3))
        XCTAssertTrue(stored.isPlacedByUser(.memory))
    }

    func testAMoveBetweenZonesMarksTheItem() {
        XCTAssertTrue(makeController().drop(.item(.feedback), in: .addressLeading, at: 0))
        XCTAssertTrue(stored.isPlacedByUser(.feedback))
    }

    func testDraggingAnItemOutClearsItsMark() {
        let controller = makeController()
        controller.drop(.item(.downloads), in: .left, at: 0)
        XCTAssertTrue(controller.dragEndedOutside(.downloads))
        XCTAssertFalse(stored.isPlacedByUser(.downloads))
    }

    func testTheDefaultSetClearsEveryMark() {
        let controller = makeController()
        controller.drop(.item(.downloads), in: .left, at: 0)
        controller.drop(.item(.memory), in: .right, at: 0)
        XCTAssertTrue(controller.drop(.defaultSet, in: .left, at: 0))
        XCTAssertEqual(stored, .standard)
        XCTAssertFalse(stored.isPlacedByUser(.downloads))
        XCTAssertFalse(stored.isPlacedByUser(.memory))
    }

    /// A header state whose Downloads, Memory and Feedback exist in the
    /// window, in `layoutMode` with the sidebar docked or collapsed, and
    /// Downloads placed by the user.
    private func bottomBarItemsState(_ layoutMode: LayoutMode, sidebarCollapsed: Bool) -> WebContentHeaderState {
        let state = WebContentHeaderState()
        state.isCustomizing = false
        state.isInPlaceholderMode = false
        state.showDownloadButton = true
        state.showMemoryButton = true
        state.showFeedbackButton = true
        state.sidebarKeepsBottomBarItems = WebContentHeaderState.sidebarKeepsBottomBarItems(
            layoutMode: layoutMode,
            sidebarCollapsed: sidebarCollapsed
        )
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.downloads, in: .right, at: 0, byUser: true)
        state.arrangement = arrangement
        return state
    }

    func testBalancedWithTheSidebarDockedShowsOnlyItemsPlacedByTheUser() {
        let state = bottomBarItemsState(.balanced, sidebarCollapsed: false)
        XCTAssertTrue(ToolbarItemView.isShown(.downloads, state: state, visibleExtensionIDs: []), "placed by the user")
        XCTAssertFalse(ToolbarItemView.isShown(.memory, state: state, visibleExtensionIDs: []), "the default arrangement's")
        XCTAssertFalse(ToolbarItemView.isShown(.feedback, state: state, visibleExtensionIDs: []), "the default arrangement's")
    }

    func testBalancedWithTheSidebarCollapsedShowsThemAll() {
        let state = bottomBarItemsState(.balanced, sidebarCollapsed: true)
        for item in [ToolbarItemID.downloads, .memory, .feedback] {
            XCTAssertTrue(ToolbarItemView.isShown(item, state: state, visibleExtensionIDs: []), "\(item)")
        }
    }

    func testComfortableShowsThemAll() {
        for collapsed in [false, true] {
            let state = bottomBarItemsState(.comfortable, sidebarCollapsed: collapsed)
            for item in [ToolbarItemID.downloads, .memory, .feedback] {
                XCTAssertTrue(ToolbarItemView.isShown(item, state: state, visibleExtensionIDs: []), "\(item)")
            }
        }
    }

    func testAnItemPlacedByTheUserStillNeedsItsOwnConditions() {
        let state = bottomBarItemsState(.balanced, sidebarCollapsed: false)
        var arrangement = state.arrangement
        arrangement.place(.memory, in: .right, at: 0, byUser: true)
        arrangement.place(.feedback, in: .right, at: 0, byUser: true)
        state.arrangement = arrangement
        XCTAssertTrue(ToolbarItemView.isShown(.memory, state: state, visibleExtensionIDs: []))
        state.showMemoryButton = false  // Phi AI off or incognito
        state.showFeedbackButton = false  // a guest
        state.showDownloadButton = false  // the empty-window placeholder
        XCTAssertFalse(ToolbarItemView.isShown(.memory, state: state, visibleExtensionIDs: []))
        XCTAssertFalse(ToolbarItemView.isShown(.feedback, state: state, visibleExtensionIDs: []))
        XCTAssertFalse(ToolbarItemView.isShown(.downloads, state: state, visibleExtensionIDs: []))
    }

    func testAnItemPlacedByTheUserIsNotCustomizeOnlyInBalanced() {
        let state = bottomBarItemsState(.balanced, sidebarCollapsed: false)
        state.isCustomizing = true
        XCTAssertTrue(ToolbarItemView.isShownWhileBrowsing(.downloads, state: state, visibleExtensionIDs: []),
                      "it stays when customizing ends, so Minimal centers it")
        XCTAssertFalse(ToolbarItemView.isShownWhileBrowsing(.memory, state: state, visibleExtensionIDs: []),
                       "drawn only for customizing")
    }

    func testTheAddressBarDoesNotDragTheWindowWhileCustomizing() {
        let state = WebContentHeaderState()
        state.allowsWindowDrag = true
        XCTAssertTrue(state.allowsAddressBarWindowDrag)
        state.isCustomizing = true
        XCTAssertFalse(state.allowsAddressBarWindowDrag)
    }

    // MARK: - Menus

    func testEscapeIsLeftToTextBeingEdited() {
        // The omnibox or the find bar closes on Escape first; a second Escape ends customizing.
        XCTAssertFalse(WebContentHeader.escapeEndsCustomizing(firstResponder: NSTextView()))
        XCTAssertTrue(WebContentHeader.escapeEndsCustomizing(firstResponder: NSView()))
        XCTAssertTrue(WebContentHeader.escapeEndsCustomizing(firstResponder: nil))
    }

    func testTheVisibilityMenuChecksTheCurrentSetting() throws {
        var picked: ToolbarItemVisibility?
        let menu = ToolbarCustomizationMenu.visibilityMenu(current: .onHover) { picked = $0 }
        let always = try XCTUnwrap(menu.items.first { $0.identifier == ToolbarCustomizationMenu.visibilityAlwaysItemIdentifier })
        let onHover = try XCTUnwrap(menu.items.first { $0.identifier == ToolbarCustomizationMenu.visibilityOnHoverItemIdentifier })
        XCTAssertEqual(always.state, .off)
        XCTAssertEqual(onHover.state, .on)

        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex(of: always)))
        XCTAssertEqual(picked, .always)
    }

    // MARK: - Palette

    func testThePaletteListsWhatThisProfileCanUse() {
        let plain = ToolbarPalette.items(isPhiAIEnabled: false, isGuest: true, isIncognito: false, extensionIDs: ["e"])
        XCTAssertFalse(plain.contains(.memory)); XCTAssertFalse(plain.contains(.chat)); XCTAssertFalse(plain.contains(.siteMemories))
        XCTAssertFalse(plain.contains(.feedback))
        XCTAssertEqual(plain.last, .extensionAction("e"), "extensions come last, in their own section")
        XCTAssertTrue(ToolbarPalette.items(isPhiAIEnabled: true, isGuest: false, isIncognito: false, extensionIDs: []).contains(.chat))
    }

    func testThePaletteOffersToggleSidebarOnlyWithASidebar() {
        XCTAssertTrue(ToolbarPalette.items(isPhiAIEnabled: false, isGuest: true, isIncognito: false, extensionIDs: []).contains(.sidebarToggle))
        XCTAssertFalse(ToolbarPalette.items(isPhiAIEnabled: false, isGuest: true, isIncognito: false, hasSidebar: false, extensionIDs: []).contains(.sidebarToggle),
                       "Comfortable has no sidebar to toggle")
    }

    func testThePaletteListsEveryButtonOnceForASignedInProfileWithPhiAI() {
        let items = ToolbarPalette.items(isPhiAIEnabled: true, isGuest: false, isIncognito: false, extensionIDs: ["a", "b"])
        XCTAssertEqual(Set(items).count, items.count)
        XCTAssertEqual(items.count, 15)
        XCTAssertEqual(Array(items.suffix(2)), [.extensionAction("a"), .extensionAction("b")])
        let incognito = ToolbarPalette.items(isPhiAIEnabled: true, isGuest: false, isIncognito: true, extensionIDs: [])
        XCTAssertFalse(incognito.contains(.memory), "Phi AI's buttons do not exist in an incognito window")
        XCTAssertFalse(incognito.contains(.chat))
        XCTAssertFalse(incognito.contains(.siteMemories))
    }

    func testThePaletteListsExtensionsByName() {
        // Pinned first would move a tile every time one is dragged in or out.
        XCTAssertEqual(
            ToolbarPalette.extensionOrder([(id: "p", name: "uBlock"), (id: "q", name: "Bitwarden"), (id: "r", name: "dark reader"), (id: "s", name: "Bitwarden")]),
            ["q", "s", "r", "p"]
        )
    }

    func testMinimalGreysItsPlacedAddressButtons() {
        var arrangement = ToolbarArrangement.standard
        arrangement.place(.extensionAction("x"), in: .addressLeading, at: 0)
        XCTAssertTrue(ToolbarPalette.isPlaced(.siteMenu, in: arrangement, isDrawn: true))
        XCTAssertTrue(ToolbarPalette.isPlaced(.extensionAction("x"), in: arrangement, isDrawn: true))

        arrangement.addressBarStyle = .minimal
        XCTAssertTrue(ToolbarPalette.isPlaced(.siteMenu, in: arrangement, isDrawn: true), "Minimal draws the address zones")
        XCTAssertTrue(ToolbarPalette.isPlaced(.extensionAction("x"), in: arrangement, isDrawn: true))
        XCTAssertTrue(ToolbarPalette.isPlaced(.copyURL, in: arrangement, isDrawn: true))
        XCTAssertTrue(ToolbarPalette.isPlaced(.back, in: arrangement, isDrawn: true))
        var removed = ToolbarArrangement.standard
        removed.remove(.chat)
        XCTAssertFalse(ToolbarPalette.isPlaced(.chat, in: removed, isDrawn: true))
    }

    func testThePaletteOffersAToggleSidebarTheViewHidesAgain() {
        let arrangement = ToolbarArrangement.standard
        XCTAssertTrue(ToolbarPalette.isPlaced(.sidebarToggle, in: arrangement, isDrawn: true))
        XCTAssertFalse(ToolbarPalette.isPlaced(.sidebarToggle, in: arrangement, isDrawn: false),
                       "placed but not drawn in this view")
        XCTAssertFalse(ToolbarPalette.isPlaced(.back, in: arrangement, isDrawn: false), "whatever is not drawn is available")
        var removed = ToolbarArrangement.standard
        removed.remove(.sidebarToggle)
        XCTAssertFalse(ToolbarPalette.isPlaced(.sidebarToggle, in: removed, isDrawn: true))
    }

    func testDroppingAHiddenToggleSidebarFromThePaletteMovesIt() {
        let controller = makeController()
        // Toggle Sidebar is placed first in Left but not drawn: dropped
        // between Forward and Reload, it lands right before Reload.
        let index = controller.arrangementIndex(
            for: .item(.sidebarToggle), in: .left,
            drawnIndex: 2, drawn: [.back, .forward, .reload]
        )
        XCTAssertEqual(index, 2)
        XCTAssertTrue(controller.drop(.item(.sidebarToggle), in: .left, at: index))
        XCTAssertEqual(stored.placements(in: .left).map(\.item), [.back, .forward, .sidebarToggle, .reload])

        // Dropped on Right, it moves there.
        XCTAssertTrue(controller.drop(.item(.sidebarToggle), in: .right, at: 0))
        XCTAssertEqual(stored.zone(of: .sidebarToggle), .right)
        XCTAssertFalse(stored.placements(in: .left).contains { $0.item == .sidebarToggle })
    }

    private func paletteGreysOut(_ item: ToolbarItemID, state: WebContentHeaderState) -> Bool {
        let isDrawn = ToolbarItemView.isShown(item, state: state, visibleExtensionIDs: [])
        return ToolbarPalette.isPlaced(item, in: state.arrangement, isDrawn: isDrawn)
    }

    func testThePaletteOffersDownloadsTheDockedBalancedLayoutHides() {
        let state = WebContentHeaderState()
        state.isCustomizing = true
        state.isInPlaceholderMode = false
        state.showDownloadButton = true
        state.arrangement = .standard

        state.sidebarKeepsBottomBarItems = true
        XCTAssertFalse(paletteGreysOut(.downloads, state: state), "in the arrangement but not drawn with the sidebar docked")
        XCTAssertTrue(paletteGreysOut(.back, state: state))
        XCTAssertFalse(ToolbarItemView.isShown(.downloads, state: state, visibleExtensionIDs: []), "not drawn as a preview either")

        state.sidebarKeepsBottomBarItems = false
        XCTAssertTrue(paletteGreysOut(.downloads, state: state), "drawn once the sidebar collapses")
    }

    func testADroppedDownloadsIsDrawnAndGreyedWithTheSidebarDocked() {
        let state = WebContentHeaderState()
        state.isCustomizing = true
        state.isInPlaceholderMode = false
        state.showDownloadButton = true
        state.sidebarKeepsBottomBarItems = true
        state.arrangement = .standard
        XCTAssertFalse(paletteGreysOut(.downloads, state: state))

        let controller = makeController()
        let zone = ToolbarArrangement.standard.zone(of: .downloads)!
        let drawn = ToolbarArrangement.standard.placements(in: zone).map(\.item).filter { $0 != .downloads }
        let index = controller.arrangementIndex(for: .item(.downloads), in: zone, drawnIndex: 0, drawn: drawn)
        XCTAssertTrue(controller.drop(.item(.downloads), in: zone, at: index))
        state.arrangement = stored
        XCTAssertTrue(state.layoutShowsBottomBarItem(.downloads))
        XCTAssertTrue(ToolbarItemView.isShownWhileBrowsing(.downloads, state: state, visibleExtensionIDs: []))
        XCTAssertTrue(paletteGreysOut(.downloads, state: state))
    }

    func testThePaletteStillOffersAToggleSidebarTheStateHides() {
        let state = WebContentHeaderState()
        state.isCustomizing = true
        state.isInPlaceholderMode = false
        state.arrangement = .standard
        state.showSidebarButton = false
        XCTAssertFalse(paletteGreysOut(.sidebarToggle, state: state))
        state.showSidebarButton = true
        XCTAssertTrue(paletteGreysOut(.sidebarToggle, state: state))
    }

    func testDroppingAMinimalAddressButtonOnASideZoneMovesItThere() {
        var minimal = ToolbarArrangement.standard
        minimal.addressBarStyle = .minimal
        store(minimal)
        XCTAssertTrue(makeController().drop(.item(.siteMenu), in: .right, at: 0))
        XCTAssertEqual(stored.zone(of: .siteMenu), .right)
        XCTAssertEqual(stored.placements(in: .addressTrailing).filter { $0.item == .siteMenu }, [])
    }

    func testEveryPaletteButtonHasAName() {
        for item in ToolbarPalette.items(isPhiAIEnabled: true, isGuest: false, isIncognito: false, extensionIDs: []) {
            XCTAssertFalse(ToolbarPalette.name(of: item).isEmpty, "\(item)")
        }
    }

    func testTheSheetSitsUnderTheToolbar() {
        let header = NSRect(x: 300, y: 700, width: 900, height: 40)
        let frame = ToolbarCustomizationSheet.frame(under: header, contentSize: NSSize(width: 600, height: 280))
        XCTAssertEqual(frame.maxY, header.minY, "its top meets the toolbar's bottom")
        XCTAssertEqual(frame.midX, header.midX)
        XCTAssertEqual(frame.height, 280)
        XCTAssertEqual(frame.width, 600)

        let narrow = ToolbarCustomizationSheet.frame(under: NSRect(x: 0, y: 700, width: 400, height: 40), contentSize: NSSize(width: 600, height: 280))
        XCTAssertEqual(narrow.width, 400 - 2 * ToolbarCustomizationSheet.horizontalInset, "never wider than the toolbar")
        XCTAssertEqual(narrow.midX, 200)
    }

    func testTheSheetHangsUnderItsToolbarAndLeavesWithIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let header = NSView(frame: NSRect(x: 240, y: 660, width: 760, height: 40))
        try XCTUnwrap(window.contentView).addSubview(header)
        var done = 0
        let sheet = ToolbarCustomizationSheet(content: ToolbarCustomizationSheetView(
            state: WebContentHeaderState(),
            extensionManager: nil,
            customization: makeController(),
            onDone: { done += 1 }
        ))

        sheet.present(under: header, contentDidChange: Empty().eraseToAnyPublisher())
        let headerOnScreen = window.convertToScreen(header.convert(header.bounds, to: nil))
        XCTAssertTrue(window.childWindows?.contains(sheet.window) == true)
        XCTAssertEqual(sheet.window.frame.maxY, headerOnScreen.minY, accuracy: 0.5)
        XCTAssertEqual(sheet.window.frame.midX, headerOnScreen.midX, accuracy: 0.5)
        XCTAssertEqual(sheet.window.frame.width, ToolbarCustomizationSheet.preferredWidth)
        XCTAssertGreaterThan(sheet.window.frame.height, 150, "sized to its content")

        sheet.close()
        XCTAssertFalse(window.childWindows?.contains(sheet.window) == true)
        XCTAssertFalse(sheet.window.isVisible)
        XCTAssertEqual(done, 0)
    }

    // MARK: - Drag source

    func testTheDragSourceKeepsItsPressesOffTheWindowDrag() {
        let source = ToolbarItemDragSourceView()
        XCTAssertFalse(source.mouseDownCanMoveWindow)
        XCTAssertTrue(source.acceptsFirstResponder,
                      "in the titlebar band AppKit honors the veto only for a view that accepts first responder")
        XCTAssertFalse(source.canBecomeKeyView)
        XCTAssertTrue(source.acceptsFirstMouse(for: nil))
    }

    func testAPressOnTheDragSourceLeavesKeyboardFocusWhereItWas() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = content
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        let reference = FocusTakingView(frame: NSRect(x: 130, y: 10, width: 40, height: 40))
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 200, y: 10, width: 40, height: 40))
        source.payload = .item(.reload)
        [field, reference, source].forEach(content.addSubview)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        guard window.isKeyWindow else { throw XCTSkip("the test host's window cannot become key here") }

        // A plain view that accepts first responder takes focus on a press:
        // AppKit's click-to-focus path is live in this window.
        window.makeFirstResponder(field)
        Self.press(window, at: NSPoint(x: 150, y: 30))
        guard window.firstResponder === reference else { throw XCTSkip("AppKit's click-to-focus path did not run here") }

        window.makeFirstResponder(field)
        let editing = window.firstResponder
        Self.press(window, at: NSPoint(x: 220, y: 30))
        XCTAssertTrue(content.hitTest(NSPoint(x: 220, y: 30)) === source, "the press went to the drag source")
        XCTAssertTrue(window.firstResponder === editing, "the field keeps editing")
        XCTAssertTrue(source.acceptsFirstResponder, "accepting again once the press is dispatched")
    }

    func testTheDragSourceRefusesFirstResponderOnlyWhileItsPressIsDispatched() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = content
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 200, y: 10, width: 40, height: 40))
        source.payload = .item(.reload)
        content.addSubview(source)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // A left press elsewhere in the window: the drag region keeps the source out.
        let elsewhere = try XCTUnwrap(Self.dequeue(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window))
        XCTAssertNil(content.hitTest(NSPoint(x: 20, y: 20)) as? ToolbarItemDragSourceView)
        XCTAssertTrue(source.acceptsFirstResponder)

        // AppKit hit-tests the press, asks whether to focus the view, then sends mouseDown.
        let press = try XCTUnwrap(Self.dequeue(.leftMouseDown, at: NSPoint(x: 220, y: 30), in: window))
        XCTAssertTrue(content.hitTest(NSPoint(x: 220, y: 30)) === source)
        XCTAssertFalse(source.acceptsFirstResponder, "the window does not move focus to it")
        source.mouseDown(with: press)
        XCTAssertTrue(source.acceptsFirstResponder, "back in the drag region's terms right after")
        source.mouseUp(with: try XCTUnwrap(Self.dequeue(.leftMouseUp, at: NSPoint(x: 220, y: 30), in: window)))
        _ = elsewhere
    }

    func testLeavingOneDragSourceForAnotherKeepsTheHand() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = content
        let first = ToolbarItemDragSourceView(frame: NSRect(x: 100, y: 10, width: 24, height: 24))
        let second = ToolbarItemDragSourceView(frame: NSRect(x: 126, y: 10, width: 24, height: 24))
        first.payload = .item(.back)
        second.payload = .item(.forward)
        [first, second].forEach(content.addSubview)

        XCTAssertTrue(ToolbarItemDragSourceView.isOverDragSource(NSPoint(x: 130, y: 20), in: window), "the next item")
        XCTAssertFalse(ToolbarItemDragSourceView.isOverDragSource(NSPoint(x: 125, y: 20), in: window), "the 2pt gap between them")
        XCTAssertFalse(ToolbarItemDragSourceView.isOverDragSource(NSPoint(x: 20, y: 20), in: window), "empty toolbar")
        second.payload = nil
        XCTAssertFalse(ToolbarItemDragSourceView.isOverDragSource(NSPoint(x: 130, y: 20), in: window), "nothing to drag")

        let entered = try XCTUnwrap(Self.enterExitEvent(.mouseEntered))
        first.mouseEntered(with: entered)
        NSCursor.openHand.set()
        first.mouseExited(with: try XCTUnwrap(Self.enterExitEvent(.mouseExited, at: NSPoint(x: 20, y: 20), in: window)))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "the arrow over empty toolbar")

        second.payload = .item(.forward)
        first.mouseEntered(with: entered)
        NSCursor.openHand.set()
        first.mouseExited(with: try XCTUnwrap(Self.enterExitEvent(.mouseExited, at: NSPoint(x: 130, y: 20), in: window)))
        XCTAssertTrue(NSCursor.current === NSCursor.openHand, "still over something to drag")
    }

    func testADragSourceRemovedUnderThePointerDropsTheHand() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 100, y: 10, width: 24, height: 24))
        source.payload = .item(.reload)
        window.contentView?.addSubview(source)
        var reports: [Bool] = []
        source.onHoverChange = { reports.append($0) }

        source.mouseEntered(with: try XCTUnwrap(Self.enterExitEvent(.mouseEntered)))
        XCTAssertTrue(NSCursor.current === NSCursor.openHand)
        source.removeFromSuperview()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "Done or Escape removed it with no exit event")
        XCTAssertEqual(reports, [true, false])
    }

    func testTheDragSourceTracksThePointerAsSoonAsItIsInAWindow() {
        // AppKit does not call updateTrackingAreas for an overlay SwiftUI adds,
        // so the source installs its own area, over its bounds.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 100, y: 10, width: 24, height: 24))
        XCTAssertTrue(source.trackingAreas.isEmpty, "nothing to track outside a window")
        window.contentView?.addSubview(source)
        XCTAssertEqual(source.trackingAreas.count, 1)
        XCTAssertEqual(source.trackingAreas.first?.rect, source.bounds)
        XCTAssertTrue(source.trackingAreas.first?.options.contains([.mouseEnteredAndExited, .cursorUpdate]) == true)
        XCTAssertFalse(source.trackingAreas.first?.options.contains(.inVisibleRect) == true,
                       "a SwiftUI-hosted view's visible rect can span the window")

        source.setFrameSize(NSSize(width: 58, height: 26))
        XCTAssertEqual(source.trackingAreas.count, 1, "replaced, not added")
        XCTAssertEqual(source.trackingAreas.first?.rect, NSRect(x: 0, y: 0, width: 58, height: 26))

        source.removeFromSuperview()
        XCTAssertTrue(source.trackingAreas.isEmpty)
    }

    // MARK: - Drag image

    func testTheDragImageCoversTheItemsHoverFill() {
        let fill = ToolbarCustomizationHoverFill.maxHeight
        XCTAssertEqual(ToolbarItemDragSourceView.dragImageFrame(for: .capsule(maxHeight: fill), in: NSRect(x: 0, y: 0, width: 24, height: 24)),
                       NSRect(x: 0, y: 0, width: 24, height: 24), "a button: its circle")
        XCTAssertEqual(ToolbarItemDragSourceView.dragImageFrame(for: .capsule(maxHeight: fill), in: NSRect(x: 0, y: 0, width: 58, height: 26)),
                       NSRect(x: 0, y: 1, width: 58, height: 24), "a wider, taller item: its capsule, centered")
        XCTAssertEqual(ToolbarItemDragSourceView.dragImageFrame(for: .region, in: NSRect(x: 0, y: 0, width: 72, height: 60)),
                       NSRect(x: 0, y: 0, width: 72, height: 60), "a sheet entry: all of it")
    }

    func testAToolbarItemsDragImageIsTheItemAloneOnAClearBackground() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let header = WebContentHeader(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        window.contentView = header
        // The toolbar's background, which the header's own layer paints.
        header.layer?.backgroundColor = NSColor.systemPink.cgColor
        // Stands in for the header's SwiftUI content: the item, with a zone
        // outline over it and the drag source on top.
        let content = NSView(frame: header.bounds)
        header.addSubview(content)
        let itemFrame = NSRect(x: 100, y: 14, width: 40, height: 24)
        let item = NSView(frame: itemFrame)
        item.wantsLayer = true
        item.layer?.backgroundColor = NSColor.blue.cgColor
        let outline = ToolbarZoneDropView(frame: itemFrame)
        outline.zone = .left
        let source = ToolbarItemDragSourceView(frame: itemFrame)
        source.payload = .item(.reload)
        source.dragImageShape = .capsule(maxHeight: ToolbarCustomizationHoverFill.maxHeight)
        [item, outline, source].forEach(content.addSubview)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        header.layoutSubtreeIfNeeded()

        let (image, frame) = source.dragImage()
        XCTAssertEqual(frame, source.bounds, "dragged from where it is drawn")
        XCTAssertEqual(image.size, frame.size, "at its real size")
        let pixels = try XCTUnwrap(Self.rasterize(image))
        XCTAssertEqual(pixels.pixelsWide, Int(frame.width * 2))
        XCTAssertEqual(pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01, "clear outside the capsule, not the toolbar's background")
        XCTAssertEqual(pixels.colorAt(x: pixels.pixelsWide - 1, y: pixels.pixelsHigh - 1)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        // Along the outline's bottom edge, a point and a half up: the item, not the outline.
        for x in stride(from: 30, through: 50, by: 2) {
            let color = try XCTUnwrap(pixels.colorAt(x: x, y: pixels.pixelsHigh - 3)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(color.blueComponent, 0.8, "the zone outline is left out (x \(x))")
            XCTAssertLessThan(color.redComponent, 0.2)
        }
        XCTAssertFalse(outline.isHidden, "the outline is back once the image is taken")
    }

    func testAToolbarItemsDragImageDrawsItsHoverFillWhetherOrNotItShows() throws {
        for isHovered in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let header = WebContentHeader(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
            window.contentView = header
            header.layer?.backgroundColor = NSColor.systemPink.cgColor
            let content = NSView(frame: header.bounds)
            header.addSubview(content)
            let itemFrame = NSRect(x: 100, y: 14, width: 40, height: 24)
            // The live fill, in a color the image must not show: the image
            // draws its own, whatever the pointer did (a fast flick starts
            // the drag before the fill shows).
            let liveFill = ToolbarCustomizationHoverFillView(frame: itemFrame)
            liveFill.color = .red
            liveFill.isHovered = isHovered
            // A small icon in the middle of the item.
            let icon = NSView(frame: NSRect(x: 116, y: 22, width: 8, height: 8))
            icon.wantsLayer = true
            icon.layer?.backgroundColor = NSColor.blue.cgColor
            let source = ToolbarItemDragSourceView(frame: itemFrame)
            source.payload = .item(.reload)
            source.dragImageShape = .capsule(maxHeight: ToolbarCustomizationHoverFill.maxHeight)
            source.dragImageFill = .green
            [liveFill, icon, source].forEach(content.addSubview)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            header.layoutSubtreeIfNeeded()

            let (image, _) = source.dragImage()
            let pixels = try XCTUnwrap(Self.rasterize(image))
            let fill = try XCTUnwrap(pixels.colorAt(x: 8, y: pixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(fill.greenComponent, 0.8, "the fill is drawn (hovered \(isHovered))")
            XCTAssertLessThan(fill.redComponent, 0.2, "the live fill is left out (hovered \(isHovered))")
            XCTAssertGreaterThan(fill.alphaComponent, 0.9)
            let center = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(center.blueComponent, 0.8, "the icon on top of it")
            XCTAssertEqual(pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01, "clear outside the capsule")
            XCTAssertFalse(liveFill.isHidden, "the live fill is back once the image is taken")
        }
    }

    func testTheDragImageKeepsItsOrientation() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = content
        let tileFrame = NSRect(x: 20, y: 20, width: 80, height: 60)
        // Top left red, top right green, bottom left blue, bottom right yellow.
        let quadrants: [(NSRect, NSColor)] = [
            (NSRect(x: 20, y: 50, width: 40, height: 30), .red),
            (NSRect(x: 60, y: 50, width: 40, height: 30), .green),
            (NSRect(x: 20, y: 20, width: 40, height: 30), .blue),
            (NSRect(x: 60, y: 20, width: 40, height: 30), .yellow),
        ]
        for (frame, color) in quadrants {
            let view = NSView(frame: frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = color.cgColor
            content.addSubview(view)
        }
        let source = ToolbarItemDragSourceView(frame: tileFrame)
        source.payload = .item(.back)
        content.addSubview(source)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let pixels = try XCTUnwrap(Self.rasterize(source.dragImage().image))
        func color(_ x: Int, _ y: Int) throws -> NSColor {
            try XCTUnwrap(pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let (w, h) = (pixels.pixelsWide, pixels.pixelsHigh)
        // `colorAt` counts rows from the top.
        let topLeft = try color(10, 10), topRight = try color(w - 10, 10)
        let bottomLeft = try color(10, h - 10), bottomRight = try color(w - 10, h - 10)
        XCTAssertGreaterThan(topLeft.redComponent, 0.8); XCTAssertLessThan(topLeft.greenComponent, 0.2)
        XCTAssertGreaterThan(topRight.greenComponent, 0.8); XCTAssertLessThan(topRight.redComponent, 0.2)
        XCTAssertGreaterThan(bottomLeft.blueComponent, 0.8); XCTAssertLessThan(bottomLeft.redComponent, 0.2)
        XCTAssertGreaterThan(bottomRight.redComponent, 0.8); XCTAssertGreaterThan(bottomRight.greenComponent, 0.8)
    }

    // MARK: - Address bar drag token

    func testTheAddressBarTokenFitsItsTextBetweenItsMinimumAndMaximumWidth() {
        XCTAssertEqual(ToolbarAddressBarDragToken.width(textWidth: 0), ToolbarAddressBarDragToken.minWidth)
        XCTAssertEqual(ToolbarAddressBarDragToken.width(textWidth: 150), 170, "padding and text")
        XCTAssertEqual(ToolbarAddressBarDragToken.width(textWidth: 1000), ToolbarAddressBarDragToken.maxWidth, "longer text truncates")
        XCTAssertEqual(ToolbarAddressBarDragToken.minWidth, 120)
        XCTAssertEqual(ToolbarAddressBarDragToken.maxWidth, 320)

        let short = makeToken("https://x.com")
        XCTAssertEqual(short.size, CGSize(width: 120, height: HeaderTrailingLayout.rowHeight))
        let long = makeToken("https://a-very-long-subdomain-name.of-a-rather-long-domain-name.example.com/path")
        XCTAssertEqual(long.size.width, 320)
        let medium = makeToken("https://developer.apple.com/documentation")
        XCTAssertGreaterThan(medium.size.width, 120)
        XCTAssertLessThan(medium.size.width, 320)
    }

    func testTheAddressBarTokenMakesRoomForTheBarsSections() {
        typealias Token = ToolbarAddressBarDragToken
        // Each section, Standard's gap beside it, then the text.
        let gap = WebContentAddressBarView.textPaddingBesideButtons
        XCTAssertEqual(Token.width(textWidth: 100, leadingSectionWidth: 50, trailingSectionWidth: 76), 50 + gap + 100 + gap + 76)
        XCTAssertEqual(Token.width(textWidth: 100, leadingSectionWidth: 0, trailingSectionWidth: 76), 10 + 100 + gap + 76,
                       "no leading buttons: the plain end padding")
        XCTAssertEqual(Token.width(textWidth: 1000, leadingSectionWidth: 50, trailingSectionWidth: 76), Token.maxWidth,
                       "the domain truncates first")
        XCTAssertEqual(Token.width(textWidth: 1000, leadingSectionWidth: 200, trailingSectionWidth: 200), 200 + gap + gap + 200,
                       "sections never truncate: they widen the token")

        var token = makeToken("https://x.com")
        token.leadingSection = NSImage(size: NSSize(width: 50, height: 26))
        token.trailingSection = NSImage(size: NSSize(width: 76, height: 26))
        let textWidth = ("x.com" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Token.fontSize)]).width
        XCTAssertEqual(token.size.width, Token.width(textWidth: textWidth, leadingSectionWidth: 50, trailingSectionWidth: 76))
    }

    func testEachAddressSectionRunsFromTheBarsEndToItsInnermostButton() {
        let bar = NSRect(x: 0, y: 0, width: 400, height: 26)
        let rects = ToolbarItemDragSourceView.addressSectionRects(
            in: bar,
            leading: [NSRect(x: 26, y: 1, width: 24, height: 24), NSRect(x: 0, y: 1, width: 24, height: 24)],
            trailing: [NSRect(x: 350, y: 1, width: 24, height: 24), NSRect(x: 376, y: 1, width: 24, height: 24)]
        )
        XCTAssertEqual(rects.leading, NSRect(x: 0, y: 0, width: 50, height: 26), "with the bar's rounded end and full height")
        XCTAssertEqual(rects.trailing, NSRect(x: 350, y: 0, width: 50, height: 26))
        let empty = ToolbarItemDragSourceView.addressSectionRects(in: bar, leading: [], trailing: [])
        XCTAssertNil(empty.leading, "a section without buttons brings nothing")
        XCTAssertNil(empty.trailing)
    }

    func testTheAddressBarTokenDrawsTheSectionsAtItsEnds() throws {
        func filled(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 40, height: 26), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
        }
        var token = makeToken("https://www.wikipedia.org")
        token.leadingSection = filled(.red)
        token.trailingSection = filled(.blue)
        let image = try XCTUnwrap(token.image(scale: 2))
        XCTAssertEqual(image.size, token.size)
        let pixels = try XCTUnwrap(Self.rasterize(image))
        let (w, h) = (pixels.pixelsWide, pixels.pixelsHigh)
        let leading = try XCTUnwrap(pixels.colorAt(x: 40, y: h / 2)?.usingColorSpace(.sRGB))
        let trailing = try XCTUnwrap(pixels.colorAt(x: w - 40, y: h / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(leading.redComponent, 0.8, "the leading section first")
        XCTAssertGreaterThan(trailing.blueComponent, 0.8, "the trailing section last")
        XCTAssertEqual(pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01, "clear corners")
        XCTAssertEqual(pixels.colorAt(x: w - 1, y: h - 1)?.alphaComponent ?? 1, 0, accuracy: 0.01)
    }

    func testDragImagesLeaveOutWhatOnlyCustomizingDrawsOverTheItems() {
        typealias Source = ToolbarItemDragSourceView
        XCTAssertTrue(Source.isLeftOutOfDragImages(ToolbarZoneDropView()))
        XCTAssertTrue(Source.isLeftOutOfDragImages(ToolbarCustomizationHoverFillView()))
        XCTAssertTrue(Source.isLeftOutOfDragImages(ToolbarAddressBarOutlineView()))
        XCTAssertTrue(Source.isLeftOutOfDragImages(ToolbarVisibilityBadgeView()))
        XCTAssertFalse(Source.isLeftOutOfDragImages(NSView()), "the items themselves")
    }

    func testTheAddressBarTokenShowsTheDomainOrAPlaceholder() {
        XCTAssertEqual(ToolbarAddressBarDragToken.domain(of: "https://www.wikipedia.org/wiki/Berlin?x=1"), "wikipedia.org",
                       "the domain only, as with Always Show URL Path off")
        XCTAssertEqual(ToolbarAddressBarDragToken.domain(of: "http://localhost:8080/a/"), "localhost")
        XCTAssertNil(ToolbarAddressBarDragToken.domain(of: nil))
        XCTAssertNil(ToolbarAddressBarDragToken.domain(of: ""))

        let page = makeToken("https://www.wikipedia.org/wiki/Berlin")
        XCTAssertEqual(page.text, "wikipedia.org")
        XCTAssertFalse(page.isPlaceholder)
        let none = makeToken(nil)
        XCTAssertEqual(none.text, "Address")
        XCTAssertTrue(none.isPlaceholder)
    }

    func testTheAddressBarTokenIsACapsuleOnAClearBackground() throws {
        let token = makeToken("https://www.wikipedia.org")
        let image = try XCTUnwrap(token.image(scale: 2))
        XCTAssertEqual(image.size, token.size)
        let pixels = try XCTUnwrap(Self.rasterize(image))
        XCTAssertEqual(pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01, "clear corners")
        XCTAssertEqual(pixels.colorAt(x: pixels.pixelsWide - 1, y: pixels.pixelsHigh - 1)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertGreaterThan(pixels.colorAt(x: pixels.pixelsWide - 30, y: pixels.pixelsHigh / 2)?.alphaComponent ?? 0, 0.9,
                             "the bar's fill inside")
    }

    func testTheAddressBarTokenStartsUnderThePress() {
        let bar = NSRect(x: 0, y: 0, width: 790, height: 26)
        let size = NSSize(width: 200, height: 26)
        XCTAssertEqual(ToolbarItemDragSourceView.dragImageFrame(size: size, pressedAt: NSPoint(x: 40, y: 10), in: bar),
                       NSRect(x: 0, y: 0, width: 200, height: 26), "near the bar's start: the token starts where the bar does")
        XCTAssertEqual(ToolbarItemDragSourceView.dragImageFrame(size: size, pressedAt: NSPoint(x: 700, y: 10), in: bar),
                       NSRect(x: 513, y: 0, width: 200, height: 26), "far along: clamped, the pointer near the token's end")
        XCTAssertEqual(ToolbarItemDragSourceView.dragImageFrame(size: size, pressedAt: NSPoint(x: 4, y: 10), in: bar),
                       NSRect(x: -9, y: 0, width: 200, height: 26), "on the rounded end: the pointer stays clear of it")
        // A taller image is centered on the source but keeps the press inside.
        let tall = ToolbarItemDragSourceView.dragImageFrame(size: NSSize(width: 120, height: 10), pressedAt: NSPoint(x: 60, y: 24), in: bar)
        XCTAssertEqual(tall.minY, 14)
        XCTAssertTrue(tall.contains(NSPoint(x: 60, y: 24)) || tall.maxY == 24)
    }

    private func makeToken(_ urlString: String?) -> ToolbarAddressBarDragToken {
        ToolbarAddressBarDragToken(urlString: urlString, colorScheme: .light, background: .white, textColor: .black, placeholderColor: .gray)
    }

    func testASheetEntrysDragImageKeepsItsWholeRegion() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = content
        let tileFrame = NSRect(x: 20, y: 20, width: 72, height: 60)
        let tile = NSView(frame: tileFrame)
        tile.wantsLayer = true
        tile.layer?.backgroundColor = NSColor.blue.cgColor
        let source = ToolbarItemDragSourceView(frame: tileFrame)
        source.payload = .item(.back)
        [tile, source].forEach(content.addSubview)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let (image, frame) = source.dragImage()
        XCTAssertEqual(frame, source.bounds)
        XCTAssertEqual(image.size, tileFrame.size)
        let pixels = try XCTUnwrap(Self.rasterize(image))
        XCTAssertGreaterThan(pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 0, 0.9, "nothing is cut away")
    }

    /// `image` drawn at twice its size, as on a Retina screen.
    private static func rasterize(_ image: NSImage) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return rep
    }

    // MARK: - Visibility badge

    func testTheVisibilityBadgeShowsTheSettingAndNamesWhatAClickDoes() {
        XCTAssertEqual(ToolbarVisibilityBadge.symbolName(for: .always), "eye")
        XCTAssertEqual(ToolbarVisibilityBadge.symbolName(for: .onHover), "eye.slash")
        XCTAssertEqual(ToolbarVisibilityBadge.toggled(.always), .onHover)
        XCTAssertEqual(ToolbarVisibilityBadge.toggled(.onHover), .always)
        XCTAssertEqual(ToolbarVisibilityBadge.accessibilityLabel(for: .always, itemName: "Copy URL"), "Show Copy URL on Hover",
                       "what the press does, to which button")
        XCTAssertEqual(ToolbarVisibilityBadge.accessibilityLabel(for: .onHover, itemName: "Copy URL"), "Always Show Copy URL")
        XCTAssertEqual(ToolbarVisibilityBadge.tooltip(for: .always), "Always shown. Click to show only on hover.")
        XCTAssertEqual(ToolbarVisibilityBadge.tooltip(for: .onHover), "Shown on hover. Click to always show.")
    }

    func testOnlyAddressZoneButtonsGetABadge() {
        XCTAssertTrue(ToolbarVisibilityBadge.isOffered(in: .addressLeading))
        XCTAssertTrue(ToolbarVisibilityBadge.isOffered(in: .addressTrailing))
        XCTAssertFalse(ToolbarVisibilityBadge.isOffered(in: .left), "always visible")
        XCTAssertFalse(ToolbarVisibilityBadge.isOffered(in: .right), "always visible")
    }

    func testTheBadgeStaysWithItsButtonWhileThePointerMovesOntoIt() {
        typealias Badge = ToolbarVisibilityBadge
        let drawn: [ToolbarItemID] = [.readerView, .copyURL, .siteMenu]
        XCTAssertNil(Badge.item(drawnItems: drawn, hoveredItems: [], badgeHoveredItem: nil, isDragging: false))
        XCTAssertEqual(Badge.item(drawnItems: drawn, hoveredItems: [.copyURL], badgeHoveredItem: nil, isDragging: false), .copyURL)
        XCTAssertEqual(Badge.item(drawnItems: drawn, hoveredItems: [], badgeHoveredItem: .copyURL, isDragging: false), .copyURL,
                       "on the badge past the button's edge")
        XCTAssertEqual(Badge.item(drawnItems: drawn, hoveredItems: [.siteMenu], badgeHoveredItem: .copyURL, isDragging: false), .copyURL,
                       "the badge under the pointer wins over the next button it overlaps")
        XCTAssertEqual(Badge.item(drawnItems: drawn, hoveredItems: [.siteMenu, .copyURL], badgeHoveredItem: nil, isDragging: false), .copyURL,
                       "two buttons reported at once: the first drawn")
        XCTAssertNil(Badge.item(drawnItems: drawn, hoveredItems: [.copyURL], badgeHoveredItem: .copyURL, isDragging: true), "hidden while dragging")
        XCTAssertNil(Badge.item(drawnItems: drawn, hoveredItems: [.back], badgeHoveredItem: nil, isDragging: false), "not a button of the bar")
    }

    func testTheBadgeSitsAtItsButtonsTopRightWithoutReachingTheNextButton() {
        let button = CGRect(x: 100, y: 1, width: 24, height: 24)
        let center = ToolbarVisibilityBadge.center(in: button)
        let half = ToolbarVisibilityBadge.size / 2
        XCTAssertEqual(center.x + half, button.maxX, "its right edge on the button's")
        XCTAssertLessThan(center.x + half, button.maxX + WebContentAddressBarView.itemSpacing, "clear of the next button")
        XCTAssertGreaterThan(center.x - half, button.minX)
        XCTAssertGreaterThan(center.x, button.midX, "on the button's right half")
        XCTAssertEqual(center.y - half, button.minY - 4, "sticks out 4pt above the button")
    }

    func testTheBadgeTogglesTheStoredVisibility() {
        let controller = makeController()
        var changes = 0
        controller.onChange = { changes += 1 }
        XCTAssertEqual(controller.visibility(of: .copyURL), .onHover)

        controller.toggleVisibility(of: .copyURL)
        XCTAssertEqual(stored.placements(in: .addressTrailing).first { $0.item == .copyURL }?.visibility, .always)
        XCTAssertEqual(controller.visibility(of: .copyURL), .always)
        XCTAssertEqual(changes, 1, "redrawn at once")

        controller.toggleVisibility(of: .copyURL)
        XCTAssertEqual(controller.visibility(of: .copyURL), .onHover)

        XCTAssertNil(controller.visibility(of: .back), "Left is always visible")
        controller.toggleVisibility(of: .back)
        XCTAssertEqual(stored.placements(in: .left).first { $0.item == .back }?.visibility, .always)

        var removed = stored
        removed.showsAddressBar = false
        store(removed)
        XCTAssertNil(controller.visibility(of: .copyURL), "its zone is not drawn")
    }

    func testTheBadgeKeepsItsPressesOffTheWindowDragAndFocus() {
        let badge = ToolbarVisibilityBadgeView()
        XCTAssertFalse(badge.mouseDownCanMoveWindow)
        XCTAssertTrue(badge.acceptsFirstResponder,
                      "in the titlebar band AppKit honors the veto only for a view that accepts first responder")
        XCTAssertFalse(badge.canBecomeKeyView)
        XCTAssertTrue(badge.acceptsFirstMouse(for: nil))
    }

    func testAPressOnTheBadgeTogglesAndNeverDragsItsButton() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = content
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 200, y: 10, width: 24, height: 24))
        source.payload = .item(.copyURL)
        var dragBegan = false
        source.onDragBegan = { dragBegan = true }
        // At the button's top right (AppKit's y grows up), drawn above it.
        let badge = ToolbarVisibilityBadgeView(frame: NSRect(x: 210, y: 24, width: 14, height: 14))
        var toggles = 0
        badge.onToggle = { toggles += 1 }
        [source, badge].forEach(content.addSubview)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let onBadge = NSPoint(x: 220, y: 30)
        XCTAssertTrue(content.hitTest(onBadge) === badge, "the badge takes the press where it overlaps the button")
        XCTAssertTrue(content.hitTest(NSPoint(x: 205, y: 15)) === source, "the rest of the button stays draggable")

        // AppKit hit-tests the press, asks whether to focus the view, then sends mouseDown.
        let press = try XCTUnwrap(Self.dequeue(.leftMouseDown, at: onBadge, in: window))
        XCTAssertTrue(content.hitTest(onBadge) === badge)
        XCTAssertFalse(badge.acceptsFirstResponder, "the window does not move focus to it")
        badge.mouseDown(with: press)
        XCTAssertTrue(badge.acceptsFirstResponder, "back in the drag region's terms right after")
        badge.mouseDragged(with: try XCTUnwrap(Self.dequeue(.leftMouseDragged, at: NSPoint(x: 120, y: 30), in: window)))
        badge.mouseUp(with: try XCTUnwrap(Self.dequeue(.leftMouseUp, at: NSPoint(x: 120, y: 30), in: window)))
        XCTAssertEqual(toggles, 0, "let go off the badge: no click")
        XCTAssertFalse(dragBegan, "a press on the badge never drags the button")

        badge.mouseDown(with: try XCTUnwrap(Self.dequeue(.leftMouseDown, at: onBadge, in: window)))
        badge.mouseUp(with: try XCTUnwrap(Self.dequeue(.leftMouseUp, at: onBadge, in: window)))
        XCTAssertEqual(toggles, 1)
        XCTAssertFalse(dragBegan)

        badge.onToggle = nil
        XCTAssertTrue(content.hitTest(onBadge) === source, "a badge with nothing to do takes no clicks")
    }

    func testTheBadgeShowsAPointingHandAndHandsTheOpenHandBack() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = content
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 200, y: 10, width: 24, height: 24))
        source.payload = .item(.copyURL)
        let badge = ToolbarVisibilityBadgeView(frame: NSRect(x: 210, y: 24, width: 14, height: 14))
        badge.onToggle = {}
        var reports: [Bool] = []
        badge.onHoverChange = { reports.append($0) }
        [source, badge].forEach(content.addSubview)

        XCTAssertTrue(ToolbarItemDragSourceView.isOverDragSource(NSPoint(x: 217, y: 36), in: window),
                      "leaving the button for the badge keeps the badge's cursor")

        badge.mouseEntered(with: try XCTUnwrap(Self.enterExitEvent(.mouseEntered)))
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand)
        badge.mouseExited(with: try XCTUnwrap(Self.enterExitEvent(.mouseExited, at: NSPoint(x: 205, y: 15), in: window)))
        XCTAssertTrue(NSCursor.current === NSCursor.openHand, "back on its button")

        badge.mouseEntered(with: try XCTUnwrap(Self.enterExitEvent(.mouseEntered)))
        badge.mouseExited(with: try XCTUnwrap(Self.enterExitEvent(.mouseExited, at: NSPoint(x: 20, y: 20), in: window)))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "off both")
        XCTAssertEqual(reports, [true, false, true, false])
    }

    func testComingBackFromTheBadgesOuterPartKeepsThePointingHand() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = content
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 200, y: 10, width: 24, height: 24))
        source.payload = .item(.copyURL)
        let badge = ToolbarVisibilityBadgeView(frame: NSRect(x: 210, y: 24, width: 14, height: 14))
        badge.onToggle = {}
        [source, badge].forEach(content.addSubview)

        // From the badge's part above the button down into the part over it:
        // the button's source sees the pointer enter, the badge sees nothing.
        NSCursor.pointingHand.set()
        source.mouseEntered(with: try XCTUnwrap(Self.enterExitEvent(.mouseEntered, at: NSPoint(x: 217, y: 30), in: window)))
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand, "still on the badge")
        source.mouseEntered(with: try XCTUnwrap(Self.enterExitEvent(.mouseEntered, at: NSPoint(x: 205, y: 15), in: window)))
        XCTAssertTrue(NSCursor.current === NSCursor.openHand, "on the button itself")
        XCTAssertTrue(ToolbarItemDragSourceView.isOverVisibilityBadge(NSPoint(x: 217, y: 30), in: window))
        XCTAssertFalse(ToolbarItemDragSourceView.isOverVisibilityBadge(NSPoint(x: 205, y: 15), in: window))
    }

    func testAPressDraggedOffTheBadgeSettlesItsHoverAndCursor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = content
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 200, y: 10, width: 24, height: 24))
        source.payload = .item(.copyURL)
        let badge = ToolbarVisibilityBadgeView(frame: NSRect(x: 210, y: 24, width: 14, height: 14))
        var toggles = 0
        badge.onToggle = { toggles += 1 }
        [source, badge].forEach(content.addSubview)
        var reports: [Bool] = []
        badge.onHoverChange = { reports.append($0) }
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        badge.mouseEntered(with: try XCTUnwrap(Self.enterExitEvent(.mouseEntered)))
        badge.mouseDown(with: try XCTUnwrap(Self.dequeue(.leftMouseDown, at: NSPoint(x: 217, y: 30), in: window)))
        badge.mouseUp(with: try XCTUnwrap(Self.dequeue(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: window)))
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(reports.last, false, "no longer hovered")
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "off the badge and its button")

        badge.mouseEntered(with: try XCTUnwrap(Self.enterExitEvent(.mouseEntered)))
        badge.mouseDown(with: try XCTUnwrap(Self.dequeue(.leftMouseDown, at: NSPoint(x: 217, y: 30), in: window)))
        badge.mouseUp(with: try XCTUnwrap(Self.dequeue(.leftMouseUp, at: NSPoint(x: 205, y: 15), in: window)))
        XCTAssertEqual(reports.last, false)
        XCTAssertTrue(NSCursor.current === NSCursor.openHand, "back on its button")
        XCTAssertEqual(toggles, 0)
    }

    func testTheBadgeIsAPressableButtonForAccessibility() {
        let badge = ToolbarVisibilityBadgeView()
        XCTAssertFalse(badge.accessibilityPerformPress(), "nothing to do")
        var toggles = 0
        badge.onToggle = { toggles += 1 }
        badge.visibility = .onHover
        badge.itemName = ToolbarPalette.name(of: .readerView)
        XCTAssertTrue(badge.isAccessibilityElement())
        XCTAssertEqual(badge.accessibilityRole(), .button)
        XCTAssertEqual(badge.accessibilityLabel(), "Always Show Reader View")
        XCTAssertEqual(badge.toolTip, ToolbarVisibilityBadge.tooltip(for: .onHover))
        XCTAssertTrue(badge.accessibilityPerformPress())
        XCTAssertEqual(toggles, 1)
        badge.visibility = .always
        XCTAssertEqual(badge.toolTip, ToolbarVisibilityBadge.tooltip(for: .always))
    }

    // MARK: - Minimal section dividers

    func testAnEmptySectionHasTheSameTextPaddingOnBothSidesInBothStyles() {
        typealias Bar = WebContentAddressBarView
        XCTAssertEqual(Bar.textPadding(sectionShowsButtons: false), 12, "beside an empty section")
        XCTAssertEqual(Bar.textPadding(sectionShowsButtons: false), Bar.textPaddingAtEnd)
        XCTAssertEqual(Bar.textPadding(sectionShowsButtons: true), 8, "beside buttons, as Phi has it")
        XCTAssertEqual(Bar.sectionPaddingAtEnd, 0, "a bar end next to buttons")
        // Leading and trailing both reserve the same.
        XCTAssertEqual(Bar.sectionReserve(isEmpty: true, isCustomizing: true), ToolbarCustomizationLayout.addressSectionReserve)
    }

    func testThePaddingGoesByTheLatestMeasureWhileBrowsingAndTheSnapshotWhileCustomizing() {
        typealias Bar = WebContentAddressBarView
        // A row rebuilt while customizing and drawn at the same width after
        // Done reports nothing new: the latest measure is still right.
        XCTAssertEqual(Bar.measuredBrowsingWidth(rowWidth: 28, widthWhenCustomizingBegan: 0, isCustomizing: false), 28)
        XCTAssertEqual(Bar.measuredBrowsingWidth(rowWidth: 0, widthWhenCustomizingBegan: 28, isCustomizing: false), 0)
        // Customizing draws hidden buttons too: entering it moves nothing.
        XCTAssertEqual(Bar.measuredBrowsingWidth(rowWidth: 54, widthWhenCustomizingBegan: 0, isCustomizing: true), 0)
        XCTAssertNil(Bar.measuredBrowsingWidth(rowWidth: 54, widthWhenCustomizingBegan: nil, isCustomizing: true))
        XCTAssertNil(Bar.measuredBrowsingWidth(rowWidth: nil, widthWhenCustomizingBegan: 28, isCustomizing: false))
    }

    func testASectionWithOneVisibleButtonIsNeverEmptyWhateverWasMeasured() {
        typealias Bar = WebContentAddressBarView
        for measured: CGFloat? in [nil, 0, 24] {
            XCTAssertTrue(Bar.drawsButtonsWhileBrowsing(shownItems: [.siteMemories, .siteMenu], measuredWidth: measured))
            XCTAssertTrue(Bar.drawsButtonsWhileBrowsing(shownItems: [.readerView, .copyURL], measuredWidth: measured))
            XCTAssertFalse(Bar.drawsButtonsWhileBrowsing(shownItems: [], measuredWidth: measured))
        }
        // Only buttons that can draw nothing: the measure decides.
        XCTAssertFalse(Bar.drawsButtonsWhileBrowsing(shownItems: [.siteMemories], measuredWidth: 0))
        XCTAssertFalse(Bar.drawsButtonsWhileBrowsing(shownItems: [.siteMemories, .readerView], measuredWidth: 0))
        XCTAssertTrue(Bar.drawsButtonsWhileBrowsing(shownItems: [.siteMemories], measuredWidth: 24))
        XCTAssertTrue(Bar.drawsButtonsWhileBrowsing(shownItems: [.siteMemories], measuredWidth: nil))
    }

    func testMinimalWithBothSidesEmptyIsSymmetricAndTheTextStaysPutWhileCustomizing() {
        typealias Bar = WebContentAddressBarView
        let padding = Bar.textPaddingAtEnd
        let reserve = Bar.sectionReserve(isEmpty: true, isCustomizing: true)
        XCTAssertGreaterThan(reserve, 0)
        let glyphs: CGFloat = 120
        for (freeMinX, freeMaxX): (CGFloat, CGFloat) in [(0, 800), (380, 800), (300, 500)] {
            let browsing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: glyphs + 2 * padding, trailingWidth: 0,
                                                     centerX: 400, freeMinX: freeMinX, freeMaxX: freeMaxX)
            let customizing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: glyphs + 2 * padding, trailingWidth: 0,
                                                        centerX: 400, freeMinX: freeMinX, freeMaxX: freeMaxX,
                                                        leadingMinimumWidth: reserve, trailingMinimumWidth: reserve)
            let message = "free \(freeMinX)...\(freeMaxX)"
            XCTAssertEqual(customizing.textMinX, browsing.textMinX, message)
            XCTAssertEqual(customizing.trailingMinX, browsing.trailingMinX, message)
            XCTAssertEqual(customizing.textWidth, browsing.textWidth, message)
            XCTAssertEqual(customizing.leadingWidth, customizing.trailingWidth, "both reserves equal")
            XCTAssertEqual(customizing.textMinX - customizing.minX, customizing.minX + customizing.width - customizing.trailingMinX,
                           "symmetric around the text, \(message)")
        }
    }

    func testAnEmptyMinimalSectionReservesAsStandardsDoes() {
        // From the outline to the divider's far edge, at the text region's
        // start, an empty section looks as wide as an empty side zone.
        let reserve = WebContentAddressBarView.sectionReserve(isEmpty: true, isCustomizing: true)
        XCTAssertEqual(reserve, ToolbarCustomizationLayout.addressSectionReserve)
        XCTAssertEqual(reserve + ToolbarCustomizationLayout.outlineStroke.lineWidth, ToolbarCustomizationLayout.emptyZoneVisibleWidth)
    }

    // MARK: - Empty zones

    func testEveryEmptyZoneLooksTheSameWidth() {
        let visible = ToolbarCustomizationLayout.emptyZoneVisibleWidth
        // A side zone's outline: its target inset by a point, stroked a point wide.
        XCTAssertEqual(ToolbarCustomizationLayout.emptyZoneWidth - 2 * 1 + ToolbarCustomizationLayout.outlineStroke.lineWidth, visible)
        // An address section: from the bar's outline to its divider's far
        // edge, the divider starting the text region.
        let reserve = ToolbarCustomizationLayout.addressSectionReserve
        XCTAssertEqual(reserve + ToolbarCustomizationLayout.outlineStroke.lineWidth, visible)
        XCTAssertEqual(reserve, 26)
    }

    func testOnlyAnEmptySideZoneReservesAndOnlyWhileCustomizing() {
        XCTAssertEqual(ToolbarCustomizationLayout.sideZoneReserve(isEmpty: true, isCustomizing: true), ToolbarCustomizationLayout.emptyZoneWidth)
        XCTAssertNil(ToolbarCustomizationLayout.sideZoneReserve(isEmpty: false, isCustomizing: true), "a zone with items hugs them")
        XCTAssertNil(ToolbarCustomizationLayout.sideZoneReserve(isEmpty: true, isCustomizing: false), "browsing")
    }

    func testNoDragSlidesBack() {
        XCTAssertFalse(ToolbarItemDragSourceView.animatesBackOnCancel,
                       "a cancelled or refused drag, from the toolbar or the sheet, ends at once")
    }

    func testTheDragSourceShowsAnOpenHandAndAClosedOneWhileHeld() {
        XCTAssertTrue(ToolbarItemDragSourceView.cursor(isPressed: false) === NSCursor.openHand)
        XCTAssertTrue(ToolbarItemDragSourceView.cursor(isPressed: true) === NSCursor.closedHand)
    }

    func testTheDragSourceReportsHoverOnlyWhenItHasSomethingToDrag() throws {
        let source = ToolbarItemDragSourceView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var reports: [Bool] = []
        source.onHoverChange = { reports.append($0) }
        let entered = try XCTUnwrap(Self.enterExitEvent(.mouseEntered))
        let exited = try XCTUnwrap(Self.enterExitEvent(.mouseExited))

        source.mouseEntered(with: entered)
        source.mouseExited(with: exited)
        XCTAssertEqual(reports, [], "no payload: nothing to drag, no hover fill")

        source.payload = .item(.reload)
        source.mouseEntered(with: entered)
        source.mouseEntered(with: entered)
        source.mouseExited(with: exited)
        XCTAssertEqual(reports, [true, false], "each change reported once")
    }

    private static func enterExitEvent(_ type: NSEvent.EventType, at location: NSPoint = .zero, in window: NSWindow? = nil) -> NSEvent? {
        NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                               windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
    }

    /// A mouse event at `point` (window coordinates), made the application's
    /// current event as a real one would be, without dispatching it.
    private static func dequeue(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return nil }
        NSApp.postEvent(event, atStart: true)
        return NSApp.nextEvent(matching: NSEvent.EventTypeMask(type: type), until: Date(), inMode: .default, dequeue: true)
    }

    /// A left click at `point` (window coordinates), dispatched as AppKit
    /// dispatches a real one, so it is the application's current event.
    private static func press(_ window: NSWindow, at point: NSPoint) {
        for (type, mask) in [(NSEvent.EventType.leftMouseDown, NSEvent.EventTypeMask.leftMouseDown), (.leftMouseUp, .leftMouseUp)] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.postEvent(event, atStart: true)
            if let dequeued = NSApp.nextEvent(matching: mask, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(dequeued)
            }
        }
    }

    func testBarHoverFillStepsAsideForAHoveredInnerItemWhileCustomizing() {
        typealias Bar = WebContentAddressBarView
        XCTAssertTrue(Bar.showsBarHoverFill(isHovered: true, isCustomizing: true, isInnerItemHovered: false))
        XCTAssertFalse(Bar.showsBarHoverFill(isHovered: true, isCustomizing: true, isInnerItemHovered: true))
        XCTAssertTrue(Bar.showsBarHoverFill(isHovered: true, isCustomizing: false, isInnerItemHovered: true))
        XCTAssertFalse(Bar.showsBarHoverFill(isHovered: false, isCustomizing: true, isInnerItemHovered: false))
    }
}

private final class FakePins {
    var pinned: Set<String> = []
    var forcePinned: Set<String> = []
    var pinCalls: [String] = []
    var unpinCalls: [String] = []

    var pinning: ToolbarCustomizationController.ExtensionPinning {
        ToolbarCustomizationController.ExtensionPinning(
            isPinned: { [unowned self] in self.pinned.contains($0) },
            pin: { [unowned self] in self.pinCalls.append($0) },
            unpin: { [unowned self] in self.unpinCalls.append($0) },
            isForcePinned: { [unowned self] in self.forcePinned.contains($0) }
        )
    }
}

/// A view that, like most AppKit controls, takes keyboard focus on a click.
private final class FocusTakingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}
}
