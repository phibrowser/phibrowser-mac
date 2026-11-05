// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class TabDoubleClickCloseTests: XCTestCase {
    private let preference = PhiPreferences.GeneralSettings.doubleClickToCloseTabs
    private var originalPreference: Any?
    private var directories: [URL] = []

    override func setUpWithError() throws {
        originalPreference = UserDefaults.standard.object(forKey: preference.rawValue)
        UserDefaults.standard.set(true, forKey: preference.rawValue)
    }

    override func tearDownWithError() throws {
        if let originalPreference {
            UserDefaults.standard.set(originalPreference, forKey: preference.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: preference.rawValue)
        }
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
    }

    func testPreferenceDefaultsOffAndPersistsAcrossReaders() throws {
        let suite = "TabDoubleClickCloseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(preference.loadValue(from: defaults))
        defaults.set(true, forKey: preference.rawValue)
        XCTAssertTrue(preference.loadValue(from: try XCTUnwrap(UserDefaults(suiteName: suite))))
    }

    func testCloseActionReadsToggleImmediatelyAndPreservesPinnedTabsAndModifiedClicks() {
        let tab = makeTab(1)
        for flags: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            XCTAssertFalse(tab.closeOnDoubleClick(modifierFlags: flags))
        }
        tab.isPinned = true
        XCTAssertFalse(tab.closeOnDoubleClick(modifierFlags: []))
        tab.isPinned = false
        UserDefaults.standard.set(false, forKey: preference.rawValue)
        XCTAssertFalse(tab.closeOnDoubleClick(modifierFlags: []))
        XCTAssertEqual(tab.closeCount, 0)
        UserDefaults.standard.set(true, forKey: preference.rawValue)
        XCTAssertTrue(tab.closeOnDoubleClick(modifierFlags: [.capsLock]))
        XCTAssertEqual(tab.closeCount, 1)
    }

    func testHorizontalDoubleClickClosesOnReleaseAndHonorsLiveToggle() throws {
        let tab = makeTab(1)
        let state = try makeState(tabs: [tab, makeTab(2)])
        let strip = TabStrip(browserState: state)
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: 48)
        let window = host(strip)
        strip.setActive(true)
        defer { strip.setActive(false); window.close() }
        strip.setActive(true)
        strip.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(descendants(of: strip, as: TabItemView.self).first {
            $0.accessibilityLabel() == tab.title
        })
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        view.mouseDown(with: try event(.leftMouseDown, at: point, count: 2, window: window))
        XCTAssertEqual(tab.closeCount, 0)
        view.mouseUp(with: try event(.leftMouseUp, at: point, count: 2, window: window))
        XCTAssertEqual(tab.closeCount, 1)
        UserDefaults.standard.set(false, forKey: preference.rawValue)
        view.mouseDown(with: try event(.leftMouseDown, at: point, count: 2, window: window))
        view.mouseUp(with: try event(.leftMouseUp, at: point, count: 2, window: window))
        XCTAssertEqual(tab.closeCount, 1)
    }

    func testHorizontalSplitDoubleClickClosesOnlyClickedPane() throws {
        let left = makeTab(1)
        let right = makeTab(2)
        let state = try makeState(tabs: [left, right])
        state.splits = [SplitGroup(id: "double-click-split", primaryTabId: 1,
                                   secondaryTabId: 2, layout: .vertical, ratio: 0.5)]
        let strip = TabStrip(browserState: state)
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: 48)
        let window = host(strip)
        strip.setActive(true)
        defer { strip.setActive(false); window.close() }
        strip.setActive(true)
        strip.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(descendants(of: strip, as: TabItemView.self).first {
            !$0.isHidden && $0.frame.width > 0 && $0.onSecondaryDoubleSelect != nil
        })
        for (fraction, expectedLeft, expectedRight) in [(0.25, 1, 0), (0.75, 1, 1)] {
            let point = view.convert(NSPoint(x: view.bounds.width * fraction, y: view.bounds.midY), to: nil)
            view.mouseDown(with: try event(.leftMouseDown, at: point, count: 2, window: window))
            view.mouseUp(with: try event(.leftMouseUp, at: point, count: 2, window: window))
            XCTAssertEqual(left.closeCount, expectedLeft)
            XCTAssertEqual(right.closeCount, expectedRight)
        }
    }

    func testSidebarDoubleClickUsesNormalTabMousePath() throws {
        let tab = makeTab(1)
        let state = try makeState(tabs: [tab, makeTab(2)])
        let controller = SidebarTabListViewController(state: state)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = host(controller.view)
        controller.setActive(true)
        defer { controller.setActive(false); window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(of: controller.view, as: SideBarOutlineView.self).first)
        let row = try XCTUnwrap((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? Tab) === tab
        })
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for enabled in [false, true] {
            UserDefaults.standard.set(enabled, forKey: preference.rawValue)
            outline.mouseDown(with: try event(.leftMouseDown, at: point, count: 2, window: window))
            XCTAssertEqual(tab.closeCount, 0)
            outline.mouseUp(with: try event(.leftMouseUp, at: point, count: 2, window: window))
        }
        XCTAssertEqual(tab.closeCount, 1)
    }

    func testGroupedTabDoubleClickUsesInnerTableMousePath() throws {
        let tab = makeTab(1)
        let cell = TabGroupCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        cell.applyMembers([tab, makeTab(2)], animated: false)
        let window = host(cell)
        defer { window.close() }
        cell.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(of: cell, as: GroupTabsTableView.self).first)
        let rect = table.rect(ofRow: 0)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        table.mouseDown(with: try event(.leftMouseDown, at: point, count: 2, window: window))
        XCTAssertEqual(tab.closeCount, 0)
        table.mouseUp(with: try event(.leftMouseUp, at: point, count: 2, window: window))
        XCTAssertEqual(tab.closeCount, 1)
    }

    func testSidebarSplitDoubleClickClosesOnlyClickedPane() throws {
        let left = makeTab(1)
        let right = makeTab(2)
        let pair = SplitPairSidebarItem(groupId: "double-click-split", leftTab: left,
                                       rightTab: right, browserState: nil)
        let cell = SidebarSplitPairCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        cell.configure(with: pair)
        let window = host(cell)
        defer { window.close() }
        cell.layoutSubtreeIfNeeded()
        let panes = descendants(of: cell, as: HoverableView.self)
            .filter { $0.shouldClickOnMouseDown != nil }
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(panes.count, 2)
        for (index, pane) in panes.enumerated() {
            let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
            pane.mouseDown(with: try event(.leftMouseDown, at: point, count: 2, window: window))
            pane.mouseUp(with: try event(.leftMouseUp, at: point, count: 2, window: window))
            XCTAssertEqual(left.closeCount, 1)
            XCTAssertEqual(right.closeCount, index)
        }
    }

    func testDraggingSecondClickDoesNotDispatchHoverableDoubleClick() throws {
        let view = HoverableView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let window = host(view)
        defer { window.close() }
        var doubleClicks = 0
        view.doubleClickAction = { _ in doubleClicks += 1 }
        for distance in [5.0, 6.0] {
            view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 20, y: 20), count: 2, window: window))
            let point = NSPoint(x: 20 + distance, y: 20)
            view.mouseDragged(with: try event(.leftMouseDragged, at: point, count: 2, window: window))
            view.mouseUp(with: try event(.leftMouseUp, at: point, count: 2, window: window))
        }
        XCTAssertEqual(doubleClicks, 1, "Movement beyond the existing five-point drag threshold must suppress closing")
    }

    func testForwardedSplitDoubleClickIsNotRepeatedByChildMouseUp() throws {
        let left = makeTab(1)
        let right = makeTab(2)
        let pair = SplitPairSidebarItem(groupId: "forwarded-split", leftTab: left,
                                       rightTab: right, browserState: nil)
        let cell = SidebarSplitPairCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        cell.configure(with: pair)
        let window = host(cell)
        defer { window.close() }
        cell.layoutSubtreeIfNeeded()
        let panes = descendants(of: cell, as: HoverableView.self)
            .filter { $0.shouldClickOnMouseDown != nil }
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(panes.count, 2)
        for (index, pane) in panes.enumerated() {
            let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
            pane.mouseDown(with: try event(.leftMouseDown, at: point, count: 2, window: window))
            let release = try event(.leftMouseUp, at: point, count: 2, window: window)
            XCTAssertTrue(cell.handleDoubleClick(with: release))
            pane.mouseUp(with: release)
            XCTAssertEqual(left.closeCount, 1)
            XCTAssertEqual(right.closeCount, index)
        }
    }

    func testOutlineTrackingLoopForwardsSplitDoubleClickToClickedPane() throws {
        let left = makeTab(1)
        let right = makeTab(2)
        let state = try makeState(tabs: [left, right])
        state.splits = [SplitGroup(id: "tracked-split", primaryTabId: 1,
                                   secondaryTabId: 2, layout: .vertical, ratio: 0.5)]
        let controller = SidebarTabListViewController(state: state)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = host(controller.view)
        window.styleMask = [.titled]
        window.makeKeyAndOrderFront(nil)
        controller.setActive(true)
        defer { controller.setActive(false); window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(of: controller.view, as: SideBarOutlineView.self).first)
        let row = try XCTUnwrap((0..<outline.numberOfRows).first {
            outline.item(atRow: $0) is SplitPairSidebarItem
        })
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? SidebarSplitPairCellView)
        controller.view.layoutSubtreeIfNeeded()
        let panes = descendants(of: cell, as: HoverableView.self)
            .filter { $0.shouldClickOnMouseDown != nil }
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(panes.count, 2)
        for (index, pane) in panes.enumerated() {
            let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
            for count in [1, 2] {
                NSApp.postEvent(try event(.leftMouseUp, at: point, count: count, window: window), atStart: true)
                NSApp.postEvent(try event(.leftMouseDown, at: point, count: count, window: window), atStart: true)
                while let queued = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                                                   until: Date().addingTimeInterval(0.05),
                                                   inMode: .default, dequeue: true) {
                    NSApp.sendEvent(queued)
                }
            }
            XCTAssertEqual(left.closeCount, 1)
            XCTAssertEqual(right.closeCount, index)
        }
    }

    private func makeTab(_ guid: Int) -> CloseRecordingTab {
        CloseRecordingTab(guid: guid, url: "https://example.com/\(guid)", isActive: false,
                          index: guid - 1, title: "Tab \(guid)")
    }

    private func makeState(tabs: [Tab]) throws -> BrowserState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 745, localStore: store, profileId: "Default")
        state.tabs = tabs
        state.updateNormalTabs()
        return state
    }

    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            ((child as? T).map { [$0] } ?? []) + descendants(of: child, as: type)
        }
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, count: Int,
                       window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                        timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }
}

private final class CloseRecordingTab: Tab {
    var closeCount = 0

    override func close() {
        closeCount += 1
    }
}
