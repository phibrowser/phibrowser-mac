// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The sidebar's context menu lets the user hide the header's Search Tabs and
/// sidebar buttons, as its Bottom Buttons submenu does for the bottom bar.
/// A hidden button leaves no gap: Search Tabs takes the sidebar button's place.
@MainActor
final class SidebarHeaderButtonVisibilityTests: XCTestCase {
    private typealias Setting = PhiPreferences.GeneralSettings

    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousValues: [Setting: Any?] = [:]
    private var nextWindowId = 423458789
    private var windows: [NSWindow] = []
    /// Menu items hold their target weakly; the sidebar holds its helper.
    private var helpers: [TabAreaContextMenuHelper] = []

    override func setUp() async throws {
        // Only this suite reads these keys, so holding them at other values
        // here cannot reach the suites running in parallel processes.
        for setting in [Setting.sidebarHeaderShowsSearchTabs, .sidebarHeaderShowsSidebarToggle] {
            previousValues[setting] = UserDefaults.standard.object(forKey: setting.rawValue)
            UserDefaults.standard.removeObject(forKey: setting.rawValue)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "sidebar-header-buttons-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        try context.save()
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        helpers.removeAll()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        for (setting, value) in previousValues {
            UserDefaults.standard.set(value, forKey: setting.rawValue)
        }
        try await super.tearDown()
    }

    // MARK: - Header

    func testBothButtonsShowByDefault() throws {
        let (header, _) = makeHeader(layoutMode: .balanced)

        XCTAssertFalse(try button("sidebarHeader.sidebarButton", in: header).isHidden)
        XCTAssertFalse(try button("sidebarHeader.searchTabsButton", in: header).isHidden)
    }

    func testHidingTheSidebarToggleHidesItsButton() throws {
        let (header, _) = makeHeader(layoutMode: .performance)
        let sidebarButton = try button("sidebarHeader.sidebarButton", in: header)

        set(.sidebarHeaderShowsSidebarToggle, false)
        XCTAssertTrue(sidebarButton.isHidden, "unticking Toggle Sidebar hides the button")

        set(.sidebarHeaderShowsSidebarToggle, true)
        XCTAssertFalse(sidebarButton.isHidden, "ticking it again shows the button")
    }

    func testHidingSearchTabsHidesItsButton() throws {
        let (header, state) = makeHeader(layoutMode: .balanced)
        let searchTabs = try button("sidebarHeader.searchTabsButton", in: header)

        set(.sidebarHeaderShowsSearchTabs, false, keeping: state)
        XCTAssertTrue(searchTabs.isHidden, "unticking Search Tabs hides the button")

        set(.sidebarHeaderShowsSearchTabs, true, keeping: state)
        XCTAssertFalse(searchTabs.isHidden, "ticking it again shows the button")
    }

    func testSearchTabsTakesTheSidebarButtonsPlace() throws {
        let (header, state) = makeHeader(layoutMode: .balanced)
        let sidebarButton = try button("sidebarHeader.sidebarButton", in: header)
        let searchTabs = try button("sidebarHeader.searchTabsButton", in: header)
        header.layoutSubtreeIfNeeded()
        let sidebarSlot = sidebarButton.frame
        XCTAssertLessThan(searchTabs.frame.maxX, sidebarSlot.minX, "precondition: Search Tabs sits before it")

        set(.sidebarHeaderShowsSidebarToggle, false, keeping: state)
        header.layoutSubtreeIfNeeded()

        XCTAssertEqual(searchTabs.frame.maxX, sidebarSlot.maxX, accuracy: 0.5,
                       "Search Tabs moves into the hidden button's place")
    }

    // MARK: - Spaces row

    func testTheSpacesRowMovesUpOnceTheControlRowIsEmpty() throws {
        let (header, state) = makeHeader(layoutMode: .balanced)
        let strip = mountSpacesRow(in: header)
        var placements: [Bool] = []
        header.onSpaceSwitchPlacementChanged = { placements.append($0) }
        let sidebarButton = try button("sidebarHeader.sidebarButton", in: header)
        XCTAssertFalse(header.spaceSwitchSitsInControlRow, "precondition: the row sits below the buttons")

        set(.sidebarHeaderShowsSidebarToggle, false, keeping: state)
        XCTAssertFalse(header.spaceSwitchSitsInControlRow, "Search Tabs still holds the control row")

        set(.sidebarHeaderShowsSearchTabs, false, keeping: state)
        header.layoutSubtreeIfNeeded()
        XCTAssertTrue(header.spaceSwitchSitsInControlRow, "the row moves up once both buttons are hidden")
        XCTAssertEqual(strip.frame.midY, sidebarButton.frame.midY, accuracy: 0.5, "it centers on the control row")
        XCTAssertEqual(strip.frame.maxX, header.bounds.maxX, accuracy: 0.5, "it runs to the trailing edge")

        set(.sidebarHeaderShowsSearchTabs, true, keeping: state)
        header.layoutSubtreeIfNeeded()
        XCTAssertFalse(header.spaceSwitchSitsInControlRow, "a returning button sends the row back down")
        XCTAssertGreaterThan(sidebarButton.frame.minY - strip.frame.maxY, 0,
                             "the row sits below the control row again")
        XCTAssertEqual(placements, [true, false], "the owner hears each move once")
    }

    func testThePerformanceControlRowKeepsTheSpacesRowBelowIt() throws {
        let (header, _) = makeHeader(layoutMode: .performance)
        _ = mountSpacesRow(in: header)

        set(.sidebarHeaderShowsSidebarToggle, false)
        set(.sidebarHeaderShowsSearchTabs, false)

        XCTAssertFalse(header.spaceSwitchSitsInControlRow, "back, forward, and reload still hold the row")
    }

    // MARK: - Context menu

    func testTheMenuListsTheSidebarToggleInEveryVerticalLayout() throws {
        let state = makeState(layoutMode: .performance)

        let items = try topButtons(in: menu(for: state))

        XCTAssertEqual(items.compactMap { $0.representedObject as? String },
                       [Setting.sidebarHeaderShowsSidebarToggle.rawValue],
                       "the Performance header has no Search Tabs button to hide")
        XCTAssertEqual(items.first?.state, .on)
    }

    func testTheMenuListsSearchTabsWhereTheHeaderShowsIt() throws {
        let state = makeState(layoutMode: .balanced)

        let items = try topButtons(in: menu(for: state))

        XCTAssertEqual(items.compactMap { $0.representedObject as? String },
                       [Setting.sidebarHeaderShowsSearchTabs.rawValue,
                        Setting.sidebarHeaderShowsSidebarToggle.rawValue])
    }

    func testChoosingAnItemFlipsItsSetting() throws {
        let state = makeState(layoutMode: .balanced)
        let items = try topButtons(in: menu(for: state))
        let toggle = try XCTUnwrap(items.first {
            $0.representedObject as? String == Setting.sidebarHeaderShowsSidebarToggle.rawValue
        })

        toggle.menu?.performActionForItem(at: try XCTUnwrap(toggle.menu?.index(of: toggle)))
        XCTAssertFalse(Setting.sidebarHeaderShowsSidebarToggle.loadValue())

        let reopened = try XCTUnwrap(topButtons(in: menu(for: state)).first {
            $0.representedObject as? String == Setting.sidebarHeaderShowsSidebarToggle.rawValue
        })
        XCTAssertEqual(reopened.state, .off, "the menu shows the button as hidden")
    }

    func testTheHorizontalTabStripMenuHasNoTopButtons() {
        let state = makeState(layoutMode: .comfortable)
        let helper = TabAreaContextMenuHelper(browserState: state, isHorizontalLayout: true)
        helpers.append(helper)
        let menu = NSMenu()
        helper.populate(menu)

        XCTAssertNil(topButtonsSubmenu(in: menu), "the tab strip has its own Toolbar Buttons")
    }

    // MARK: - Helpers

    private func set(_ setting: Setting, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: setting.rawValue)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Writes `setting`, then gives `state` back its layout. A Browser re-reads
    /// the app-wide layout preference whenever a default changes, and this
    /// suite leaves that preference alone because suites in parallel
    /// processes share it.
    private func set(_ setting: Setting, _ value: Bool, keeping state: BrowserState) {
        let layoutMode = state.layoutMode
        set(setting, value)
        state.layoutMode = layoutMode
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func makeState(layoutMode: LayoutMode) -> BrowserState {
        nextWindowId += 1
        let state = BrowserState(windowId: nextWindowId, localStore: store, profileId: "Default")
        state.layoutMode = layoutMode
        return state
    }

    private func makeHeader(layoutMode: LayoutMode) -> (SidebarHeaderView, BrowserState) {
        let state = makeState(layoutMode: layoutMode)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let header = SidebarHeaderView(state: state)
        header.frame = NSRect(x: 0, y: 200, width: 300, height: 100)
        window.contentView?.addSubview(header)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // Some of the header's observers read the app-wide layout preference
        // when they first run, which this suite leaves alone: other suites in
        // parallel processes share it. Re-publish this window's layout last.
        state.layoutMode = layoutMode
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (header, state)
    }

    /// A stand-in for the Spaces strip, shown as if several Spaces existed.
    private func mountSpacesRow(in header: SidebarHeaderView) -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        header.forcesSpaceSwitchVisible = true
        header.mountSpaceSwitch(strip)
        header.layoutSubtreeIfNeeded()
        return strip
    }

    private func button(_ identifier: String, in view: NSView,
                        file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view), "no \(identifier)", file: file, line: line)
    }

    private func menu(for state: BrowserState) -> NSMenu {
        let helper = TabAreaContextMenuHelper(browserState: state)
        helpers.append(helper)
        let menu = NSMenu()
        helper.populate(menu)
        return menu
    }

    /// The Top Buttons submenu's items, found by the settings they toggle so
    /// the test does not depend on the system language.
    private func topButtons(in menu: NSMenu,
                            file: StaticString = #filePath, line: UInt = #line) throws -> [NSMenuItem] {
        try XCTUnwrap(topButtonsSubmenu(in: menu), "no Top Buttons submenu", file: file, line: line).items
    }

    private func topButtonsSubmenu(in menu: NSMenu) -> NSMenu? {
        let keys = Set([Setting.sidebarHeaderShowsSearchTabs, .sidebarHeaderShowsSidebarToggle].map(\.rawValue))
        return menu.items.compactMap(\.submenu).first { submenu in
            submenu.items.contains { keys.contains($0.representedObject as? String ?? "") }
        }
    }
}
