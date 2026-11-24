// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

/// What the shell window's sidebar | page split does. First recorded against
/// the NSSplitView it was built on, then kept by the custom split, with the
/// changes agreed in docs/architecture/custom-shell-split.md: the width the
/// user chose is the one remembered, the collapsed state and each side's
/// width are stored explicitly, and the comfortable layout does not write
/// them.
///
/// The shell is built bare, in a plain window with no Space presented: the
/// split's geometry does not depend on its residents. The account's defaults
/// are a store of the test's own.
@MainActor
final class ShellSplitCharacterizationTests: XCTestCase {
    @MainActor
    private struct Shell {
        let window: NSWindow
        let split: ShellSplitViewController

        var width: CGFloat { window.contentView?.bounds.width ?? 0 }

        func layout() { window.contentView?.layoutSubtreeIfNeeded() }

        /// The column's rect in the window, hidden or not.
        var column: NSRect {
            layout()
            return split.sidebarHost.view.convert(split.sidebarHost.view.bounds, to: nil)
        }

        var page: NSRect {
            layout()
            return split.contentHost.view.convert(split.contentHost.view.bounds, to: nil)
        }

        func resize(toWidth width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: ShellSplitCharacterizationTests.height))
            layout()
        }
    }

    /// Counts the writes of one key of the app's defaults.
    private final class DefaultsWriteCounter: NSObject {
        private(set) var count = 0
        private let key: String

        init(key: String) {
            self.key = key
            super.init()
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }

        func stop() {
            UserDefaults.standard.removeObserver(self, forKeyPath: key)
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            count += 1
        }
    }

    private static let height: CGFloat = 700
    private static let autosaveKeys = [
        SidebarPosition.left: "NSSplitView Subview Frames phiMainBrowserSplitView",
        SidebarPosition.right: "NSSplitView Subview Frames phiMainBrowserSplitViewRight",
    ]
    private let minWidth = MainSplitViewController.leftItemMinWidth
    private let maxWidth = MainSplitViewController.leftItemMaxWidth
    private let pageMinWidth: CGFloat = 200

    private var savedDefaults: [String: Any] = [:]
    private var shells: [Shell] = []
    private var accountDefaults: AccountUserDefaults?
    private var accountDefaultsDirectory: URL?

    private var touchedDefaultsKeys: [String] {
        [PhiPreferences.GeneralSettings.layoutModeKey, PhiPreferences.GeneralSettings.sidebarPositionKey,
         PhiPreferences.GeneralSettings.sidebarCollapsedKey] + Self.autosaveKeys.values
    }

    override func setUp() async throws {
        for key in touchedDefaultsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        accountDefaultsDirectory = directory
        accountDefaults = AccountUserDefaults(account: Account(userID: "shell-split-test-\(UUID().uuidString)"),
                                              storeURL: directory.appendingPathComponent("defaults.plist"))
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        startOver(on: .left)
    }

    override func tearDown() async throws {
        closeShells()
        for key in touchedDefaultsKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults.removeAll()
        accountDefaults = nil
        if let accountDefaultsDirectory {
            try? FileManager.default.removeItem(at: accountDefaultsDirectory)
        }
        try await super.tearDown()
    }

    private func isDivider(_ view: NSView?) -> Bool {
        view is ShellSplitDividerView
    }

    /// What a shell launched now would open with: the collapsed state the
    /// user left, and each side's width.
    private func storedCollapsed() -> Bool? {
        PhiPreferences.GeneralSettings.loadSidebarCollapsed()
    }

    private func storedWidth(on side: SidebarPosition) -> CGFloat {
        accountDefaults?.lastKnownSidebarWidth(for: side) ?? 0
    }

    /// The split stores its geometry once it has been still for a moment.
    private func waitForStorage() {
        spin(0.45)
    }

    /// What NSSplitView autosaved for a shell `containerWidth` wide: the
    /// state a shell from before the custom split left behind.
    private func leaveAutosavedFrames(on side: SidebarPosition, columnWidth: CGFloat, collapsed: Bool,
                                      containerWidth: CGFloat = 1000) {
        guard let key = Self.autosaveKeys[side] else { return }
        func frame(x: CGFloat, width: CGFloat, hidden: Bool) -> String {
            String(format: "%f, %f, %f, %f, %@, NO", x, 0.0, width, Self.height, hidden ? "YES" : "NO")
        }
        let pageWidth = collapsed ? containerWidth : containerWidth - columnWidth
        let column = frame(x: side == .left ? 0 : pageWidth, width: columnWidth, hidden: collapsed)
        let page = frame(x: side == .left && !collapsed ? columnWidth : 0, width: pageWidth, hidden: false)
        UserDefaults.standard.set(side == .left ? [column, page] : [page, column], forKey: key)
    }

    private func clearStoredGeometry() {
        for key in Self.autosaveKeys.values + [PhiPreferences.GeneralSettings.sidebarCollapsedKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for key in [AccountUserDefaults.DefaultsKey.lastKnownSidebarWidth,
                    AccountUserDefaults.DefaultsKey.lastKnownRightSidebarWidth] {
            _ = accountDefaults?.removeObject(forKey: key.rawValue)
        }
    }

    private func startOver(on side: SidebarPosition) {
        closeShells()
        clearStoredGeometry()
        PhiPreferences.GeneralSettings.saveSidebarPosition(side)
    }

    private func makeShell(width: CGFloat = 1000, onScreen: Bool = false) -> Shell {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: Self.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let split = ShellSplitViewController()
        split.accountDefaults = { [accountDefaults] in accountDefaults }
        split.view.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        window.contentViewController = split
        let shell = Shell(window: window, split: split)
        shell.layout()
        if onScreen {
            window.orderFront(nil)
            spin(0.05)
        }
        shells.append(shell)
        return shell
    }

    /// Closes the shells as their windows do: what they have to store is
    /// written first, and they stop following the app's defaults.
    private func closeShells() {
        for shell in shells {
            shell.split.windowWillClose()
            shell.window.contentViewController = nil
            shell.window.close()
        }
        shells.removeAll()
    }

    /// Ends the app session as far as the split can tell, and starts another.
    private func relaunch(width: CGFloat = 1000) -> Shell {
        closeShells()
        return makeShell(width: width)
    }

    private func spin(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    /// Lets a defaults change reach the shells, which follow it on the main queue.
    private func deliverDefaultsChange() {
        spin(0.05)
    }

    private func waitForToggleAnimation() {
        spin(SidebarToggleAnimation.duration * 4)
    }

    /// The column is `width` wide, flush with its window edge, and the page
    /// takes the rest with no gap or overlap.
    private func assertExpanded(_ shell: Shell, width: CGFloat, on side: SidebarPosition,
                                _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let context = "\(side.rawValue) \(message)"
        XCTAssertFalse(shell.split.isSidebarCollapsed, context, file: file, line: line)
        XCTAssertEqual(shell.split.sidebarWidth, width, accuracy: 0.5, context, file: file, line: line)
        let column = shell.column
        let page = shell.page
        XCTAssertEqual(column.width, width, accuracy: 0.5, context, file: file, line: line)
        XCTAssertEqual(page.width, shell.width - width, accuracy: 0.5, context, file: file, line: line)
        XCTAssertEqual(column.minX, side == .left ? 0 : shell.width - width, accuracy: 0.5, context,
                       file: file, line: line)
        XCTAssertEqual(page.minX, side == .left ? width : 0, accuracy: 0.5, context, file: file, line: line)
        XCTAssertFalse(shell.split.sidebarHost.view.isHiddenOrHasHiddenAncestor, context, file: file, line: line)
    }

    private func assertCollapsed(_ shell: Shell, _ message: String = "",
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(shell.split.isSidebarCollapsed, message, file: file, line: line)
        XCTAssertEqual(shell.split.sidebarWidth, 0, message, file: file, line: line)
        let page = shell.page
        XCTAssertEqual(page.minX, 0, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(page.width, shell.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertTrue(shell.split.sidebarHost.view.isHiddenOrHasHiddenAncestor, message, file: file, line: line)
    }

    /// Where the divider is for a column `sidebarWidth` wide, in the window.
    private func dividerX(in shell: Shell, on side: SidebarPosition, sidebarWidth: CGFloat) -> CGFloat {
        side == .left ? sidebarWidth : shell.width - sidebarWidth
    }

    private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint,
                            clickCount: Int) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clickCount, pressure: 1)
    }

    /// Presses the mouse `grabOffset` points from the divider, moves it so the
    /// column would be each of `widths` wide in turn, and releases. Returns
    /// false, sending nothing, when no divider is under the press.
    ///
    /// The moves and the release are queued before the press: a divider that
    /// tracks the mouse in a loop of its own takes them from the queue, and
    /// one that implements `mouseDragged` / `mouseUp` gets what is left.
    @discardableResult
    private func dragDivider(of shell: Shell, on side: SidebarPosition, grabOffset: CGFloat = 0,
                             atHeight y: CGFloat = 350, through widths: [CGFloat] = [],
                             clickCount: Int = 1) -> Bool {
        let startWidth = shell.split.isSidebarCollapsed ? 0 : shell.column.width
        let start = NSPoint(x: dividerX(in: shell, on: side, sidebarWidth: startWidth) + grabOffset, y: y)
        let points = widths.map {
            NSPoint(x: dividerX(in: shell, on: side, sidebarWidth: $0) + grabOffset, y: y)
        }
        let window = shell.window
        guard let view = window.contentView?.hitTest(start), isDivider(view),
              let down = mouseEvent(.leftMouseDown, in: window, at: start, clickCount: clickCount),
              let up = mouseEvent(.leftMouseUp, in: window, at: points.last ?? start, clickCount: clickCount)
        else { return false }
        for point in points {
            if let move = mouseEvent(.leftMouseDragged, in: window, at: point, clickCount: clickCount) {
                NSApp.postEvent(move, atStart: false)
            }
        }
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: nil,
                                          inMode: .default, dequeue: true) {
            guard event.windowNumber == window.windowNumber else { continue }
            if event.type == .leftMouseDragged {
                view.mouseDragged(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
        shell.layout()
        return true
    }

    func testAFreshShellOpensExpandedAtTheMinimumWidth() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            assertExpanded(shell, width: minWidth, on: side)
            XCTAssertEqual(storedCollapsed(), false, "the first shell stores the state it starts from")
        }
    }

    /// A pane ends at its own frame: a view in the column, however wide, is
    /// visible only as far as the column is. The sidebar's hover controls and
    /// every `.inVisibleRect` tracking area go by that, so without it a
    /// pointer over the page counts as over the sidebar.
    func testEachPaneIsVisibleOnlyWithinItsOwnFrame() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            let inColumn = NSView(frame: NSRect(x: -1000, y: 0, width: 3000, height: 100))
            let inPage = NSView(frame: NSRect(x: -1000, y: 0, width: 3000, height: 100))
            shell.split.sidebarHost.view.addSubview(inColumn)
            shell.split.contentHost.view.addSubview(inPage)
            shell.layout()
            XCTAssertEqual(inColumn.visibleRect.width, 300, accuracy: 0.5, side.rawValue)
            XCTAssertEqual(inPage.visibleRect.width, 700, accuracy: 0.5, side.rawValue)

            shell.resize(toWidth: 400)
            XCTAssertEqual(inColumn.visibleRect.width, 200, accuracy: 0.5, "\(side.rawValue), squeezed")
            XCTAssertEqual(inPage.visibleRect.width, 200, accuracy: 0.5, "\(side.rawValue), squeezed")
            inColumn.removeFromSuperview()
            inPage.removeFromSuperview()
        }
    }

    func testAWindowResizeLeavesTheSidebarWidthAloneWhileThePageFits() {
        for side in SidebarPosition.allCases {
            for width in [minWidth, 250, maxWidth] {
                startOver(on: side)
                let shell = makeShell()
                shell.split.setSidebarGeometry(width: width, collapsed: false)
                for windowWidth in [1600, 1000, width + pageMinWidth, 800, 2560, 1000] where windowWidth >= width + pageMinWidth {
                    shell.resize(toWidth: windowWidth)
                    XCTAssertEqual(shell.width, windowWidth, accuracy: 0.5)
                    assertExpanded(shell, width: width, on: side, "window \(windowWidth)")
                }
            }
        }
    }

    /// The page never goes below its minimum: a window too narrow for both
    /// takes the difference from the sidebar, down to the sidebar's own
    /// minimum, and gives it back as the window grows.
    func testANarrowWindowSqueezesTheSidebarAndAWiderOneRestoresIt() {
        for side in SidebarPosition.allCases {
            for width in [minWidth, 250, maxWidth] {
                startOver(on: side)
                let shell = makeShell()
                shell.split.setSidebarGeometry(width: width, collapsed: false)
                var reported: [CGFloat] = []
                let subscription = shell.split.sidebarWidthPublisher.sink { reported.append($0) }
                for windowWidth: CGFloat in [1000, 700, 699, 600, 500, 450, 400, 393, 400, 450, 500, 600, 699, 700, 1000] {
                    shell.resize(toWidth: windowWidth)
                    let expected = max(minWidth, min(width, windowWidth - pageMinWidth))
                    assertExpanded(shell, width: expected, on: side, "window \(windowWidth), sidebar set to \(width)")
                    XCTAssertEqual(reported.last ?? -1, expected, accuracy: 0.5, "the squeezed width is reported")
                }
                subscription.cancel()
            }
        }
    }

    /// A squeeze changes what shows, not what is remembered: the stored
    /// width stays the user's, and a relaunch in a wide window opens at it.
    /// The floating panel takes the squeezed width, as the column does.
    func testASqueezedWidthIsNotRemembered() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: maxWidth, collapsed: false)
            XCTAssertEqual(shell.split.lastExpandedSidebarWidth, maxWidth, accuracy: 0.5)

            shell.resize(toWidth: 500)
            assertExpanded(shell, width: 300, on: side)
            XCTAssertEqual(shell.split.lastExpandedSidebarWidth, 300, accuracy: 0.5)
            XCTAssertEqual(shell.split.floatingSidebarHost.currentFloatingWidth, 300, accuracy: 0.5)
            waitForStorage()
            XCTAssertEqual(storedWidth(on: side), maxWidth, accuracy: 0.5)

            let relaunched = relaunch(width: 1400)
            assertExpanded(relaunched, width: maxWidth, on: side, "relaunched wide")
        }
    }

    /// The split sets no floor on its container: the shell window's minimum
    /// size keeps the page at its minimum, and below that the page gives way
    /// before the sidebar's minimum does.
    func testBelowBothMinimumsThePageGivesWay() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.resize(toWidth: 300)
            XCTAssertEqual(shell.width, 300, accuracy: 0.5)
            assertExpanded(shell, width: minWidth, on: side)

            shell.split.setSidebarCollapsed(true, animated: false)
            shell.resize(toWidth: 100)
            XCTAssertEqual(shell.width, 100, accuracy: 0.5)
            assertCollapsed(shell)
        }
    }

    func testCollapseAndExpandWithoutAnimation() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            var collapsedStates: [Bool] = []
            var widths: [CGFloat] = []
            var expansionsFinished = 0
            var subscriptions = Set<AnyCancellable>()
            shell.split.sidebarCollapsedPublisher.sink { collapsedStates.append($0) }.store(in: &subscriptions)
            shell.split.sidebarWidthPublisher.sink { widths.append($0) }.store(in: &subscriptions)
            shell.split.sidebarExpansionDidFinish.sink { expansionsFinished += 1 }.store(in: &subscriptions)

            shell.split.setSidebarCollapsed(true, animated: false)
            assertCollapsed(shell)
            XCTAssertEqual(shell.column.width, 300, accuracy: 0.5, "the hidden column keeps its width")
            XCTAssertEqual(shell.split.lastExpandedSidebarWidth, 300, accuracy: 0.5)
            XCTAssertFalse(shell.split.isSidebarExpanding)

            shell.split.setSidebarCollapsed(false, animated: false)
            assertExpanded(shell, width: 300, on: side)
            XCTAssertFalse(shell.split.isSidebarExpanding)

            XCTAssertEqual(collapsedStates, [false, true, false])
            XCTAssertEqual(widths, [300, 0, 300])
            XCTAssertEqual(expansionsFinished, 0, "only an animated expansion reports its end")
        }
    }

    func testToggleSidebarFlipsTheCollapsedState() {
        let shell = makeShell(onScreen: true)
        shell.split.setSidebarGeometry(width: 300, collapsed: false)
        shell.split.toggleSidebar()
        waitForToggleAnimation()
        assertCollapsed(shell)
        shell.split.toggleSidebar()
        waitForToggleAnimation()
        assertExpanded(shell, width: 300, on: .left)
        shell.split.toggleSidebar(false)
        assertExpanded(shell, width: 300, on: .left, "already expanded")
        shell.split.toggleSidebar(true)
        waitForToggleAnimation()
        assertCollapsed(shell)
    }

    /// The collapsed state and the reported width change once, when the
    /// animation starts. `isSidebarExpanding` covers an animated expansion
    /// until `sidebarExpansionDidFinish`; a collapse reports neither.
    func testAnAnimatedToggleChangesStateAtItsStartAndReportsAnExpansionsEnd() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            var collapsedStates: [Bool] = []
            var widths: [CGFloat] = []
            var expansionsFinished = 0
            var subscriptions = Set<AnyCancellable>()
            shell.split.sidebarCollapsedPublisher.dropFirst().sink { collapsedStates.append($0) }
                .store(in: &subscriptions)
            shell.split.sidebarWidthPublisher.dropFirst().sink { widths.append($0) }.store(in: &subscriptions)
            shell.split.sidebarExpansionDidFinish.sink { expansionsFinished += 1 }.store(in: &subscriptions)

            shell.split.setSidebarCollapsed(true, animated: true)
            XCTAssertTrue(shell.split.isSidebarCollapsed)
            XCTAssertEqual(shell.split.sidebarWidth, 0)
            XCTAssertFalse(shell.split.isSidebarExpanding)
            XCTAssertEqual(collapsedStates, [true])
            XCTAssertEqual(widths, [0])
            waitForToggleAnimation()
            assertCollapsed(shell)
            XCTAssertEqual(expansionsFinished, 0)

            shell.split.setSidebarCollapsed(false, animated: true)
            XCTAssertFalse(shell.split.isSidebarCollapsed)
            XCTAssertEqual(shell.split.sidebarWidth, 300, accuracy: 0.5)
            XCTAssertTrue(shell.split.isSidebarExpanding)
            XCTAssertEqual(expansionsFinished, 0)
            waitForToggleAnimation()
            assertExpanded(shell, width: 300, on: side)
            XCTAssertFalse(shell.split.isSidebarExpanding)
            XCTAssertEqual(expansionsFinished, 1)
            XCTAssertEqual(collapsedStates, [true, false])
            XCTAssertEqual(widths, [0, 300], "one width per toggle, none per frame")
        }
    }

    /// The column keeps its full width through a toggle: nothing in it is
    /// laid out anew.
    func testTheColumnKeepsItsWidthThroughAToggle() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            var widths = Set<CGFloat>()
            let column = shell.split.sidebarHost.view
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: column, queue: nil
            ) { _ in widths.insert(column.frame.width) }

            for collapsing in [true, false] {
                shell.split.setSidebarCollapsed(collapsing, animated: true)
                waitForToggleAnimation()
            }
            NotificationCenter.default.removeObserver(observer)
            XCTAssertTrue(widths.isSubset(of: [300]), "\(side.rawValue): \(widths)")
        }
    }

    /// The page in the card is never laid out short of the column, which
    /// would bare a strip of card between them. A collapse lays it out at
    /// the landing's width as it starts; an expansion a few times on its
    /// way, each no further than the column shows. The page area keeps
    /// spanning the container meanwhile.
    func testAnAnimatedToggleKeepsThePageUnderTheColumn() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            let splitView = shell.split.splitView
            let container = NSRect(x: 0, y: 0, width: 1000, height: Self.height)
            var insets: [CGFloat] = []
            var columnShown: [CGFloat] = []
            var pages: [NSRect] = []
            let forward = splitView.onPageInsetInFlight
            splitView.onPageInsetInFlight = { inset in
                insets.append(inset)
                columnShown.append(splitView.shownColumnFraction * 300)
                pages.append(shell.split.contentHost.view.frame)
                forward?(inset)
            }

            shell.split.setSidebarCollapsed(true, animated: true)
            shell.layout()
            XCTAssertEqual(shell.page, container, "\(side.rawValue) collapse")
            waitForToggleAnimation()
            XCTAssertEqual(insets, [], "\(side.rawValue) collapse")

            shell.split.setSidebarCollapsed(false, animated: true)
            waitForToggleAnimation()
            let label = "\(side.rawValue) expand"
            // Landing puts the page beside the column and the inset back to 0.
            XCTAssertEqual(insets.last, 0, label)
            let steps = Array(insets.dropLast())
            XCTAssertFalse(steps.isEmpty, label)
            XCTAssertEqual(steps, steps.sorted(), label)
            for (inset, shown) in zip(insets, columnShown) {
                XCTAssertLessThanOrEqual(inset, shown + 0.5, label)
            }
            for page in pages.dropLast() {
                XCTAssertEqual(page, container, label)
            }
        }
    }

    func testReversingACollapseInFlightEndsExpandedAtTheSameWidth() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            var expansionsFinished = 0
            let subscription = shell.split.sidebarExpansionDidFinish.sink { expansionsFinished += 1 }

            shell.split.setSidebarCollapsed(true, animated: true)
            shell.split.setSidebarCollapsed(false, animated: true)
            XCTAssertTrue(shell.split.isSidebarExpanding)
            waitForToggleAnimation()

            assertExpanded(shell, width: 300, on: side)
            XCTAssertFalse(shell.split.isSidebarExpanding)
            XCTAssertEqual(expansionsFinished, 1)
            subscription.cancel()
        }
    }

    func testReversingAnExpansionInFlightEndsCollapsedAndKeepsTheWidth() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.split.setSidebarCollapsed(true, animated: false)
            shell.layout()
            var expansionsFinished = 0
            let subscription = shell.split.sidebarExpansionDidFinish.sink { expansionsFinished += 1 }

            shell.split.setSidebarCollapsed(false, animated: true)
            XCTAssertTrue(shell.split.isSidebarExpanding)
            shell.split.setSidebarCollapsed(true, animated: true)
            XCTAssertFalse(shell.split.isSidebarExpanding)
            waitForToggleAnimation()

            assertCollapsed(shell)
            XCTAssertEqual(expansionsFinished, 0, "a superseded expansion never reports its end")
            subscription.cancel()

            shell.split.setSidebarCollapsed(false, animated: false)
            assertExpanded(shell, width: 300, on: side)
        }
    }

    private func slide(on view: NSView) -> CABasicAnimation? {
        view.layer.flatMap { slide(on: $0) }
    }

    private func slide(on layer: CALayer) -> CABasicAnimation? {
        layer.animation(forKey: ShellSplitView.slideAnimationKey) as? CABasicAnimation
    }

    private func offset(_ value: Any?) -> CGFloat {
        CGFloat((value as? NSNumber)?.doubleValue ?? .nan)
    }

    /// The column's slide, and the page area staying put, for a toggle between
    /// `from` and `to` (the fraction of the column showing), 300 wide.
    private func assertSlides(in shell: Shell, on side: SidebarPosition, from: CGFloat, to: CGFloat,
                              duration: TimeInterval, accuracy: CGFloat = 0.5,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let outward: CGFloat = side == .left ? -1 : 1
        let column = try XCTUnwrap(slide(on: shell.split.sidebarHost.view), "the column slides", file: file, line: line)
        XCTAssertEqual(column.keyPath, "transform.translation.x", file: file, line: line)
        XCTAssertEqual(offset(column.fromValue), outward * (1 - from) * 300, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(offset(column.toValue), outward * (1 - to) * 300, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(column.duration, duration, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(column.timingFunction, SidebarToggleAnimation.timingFunction, file: file, line: line)
        XCTAssertEqual(column.fillMode, .both, file: file, line: line)
        XCTAssertFalse(column.isRemovedOnCompletion, file: file, line: line)

        XCTAssertNil(slide(on: shell.split.contentHost.view), "the page area stays put", file: file, line: line)
    }

    /// The page area spanning the container, the page in its card no
    /// further in from the column's side than the column shows.
    private func assertPageInFlight(_ shell: Shell, on side: SidebarPosition,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(shell.page, NSRect(x: 0, y: 0, width: 1000, height: Self.height), file: file, line: line)
        let splitView = shell.split.splitView
        XCTAssertLessThanOrEqual(splitView.pageInsetInFlight, splitView.shownColumnFraction * 300 + 0.5,
                                 file: file, line: line)
    }

    private func assertNoSlides(in shell: Shell, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(slide(on: shell.split.sidebarHost.view), message, file: file, line: line)
        XCTAssertNil(slide(on: shell.split.contentHost.view), message, file: file, line: line)
    }

    /// A toggle is a layer animation over frames that do not move with it:
    /// the column shown at its place and the page area's far side where it
    /// was for the whole flight, then the end state and no animation.
    func testAToggleSlidesTheColumnOverFramesThatStayPut() throws {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            let duration = SidebarToggleAnimation.duration
            // The slide's own end lands the toggle, well before the fallback
            // that would land it anyway.
            let landing = duration + 0.15

            shell.split.setSidebarCollapsed(true, animated: true)
            try assertSlides(in: shell, on: side, from: 1, to: 0, duration: duration)
            XCTAssertEqual(shell.column.width, 300, accuracy: 0.5)
            XCTAssertEqual(shell.column.minX, side == .left ? 0 : 700, accuracy: 0.5)
            XCTAssertFalse(shell.split.sidebarHost.view.isHidden, "shown until it has slid out")
            assertPageInFlight(shell, on: side)
            spin(landing)
            assertNoSlides(in: shell, "collapsed")
            assertCollapsed(shell)

            shell.split.setSidebarCollapsed(false, animated: true)
            try assertSlides(in: shell, on: side, from: 0, to: 1, duration: duration)
            XCTAssertFalse(shell.split.sidebarHost.view.isHidden)
            assertPageInFlight(shell, on: side)
            spin(landing)
            assertNoSlides(in: shell, "expanded")
            assertExpanded(shell, width: 300, on: side)
        }
    }

    /// A mask draws the card's near edge beside the column: at the card's
    /// margin with the column away, at the column's inner edge with it in,
    /// and gone once the toggle lands.
    func testAToggleMasksThePageToTheCardBesideTheColumn() throws {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            let page = NSView(frame: shell.split.contentHost.view.bounds)
            page.wantsLayer = true
            shell.split.contentHost.view.addSubview(page)
            let card = NSRect(x: 0, y: 8, width: 992, height: Self.height - 8)
            shell.split.splitView.pageCard = {
                ShellSplitView.SlidingPageCard(view: page, frame: card, cornerRadius: 10, margin: 8)
            }
            func edge(_ inset: CGFloat) -> CGFloat { side == .left ? inset : 1000 - inset }

            shell.split.setSidebarCollapsed(true, animated: true)
            let mask = try XCTUnwrap(page.layer?.mask)
            let collapse = try XCTUnwrap(slide(on: mask))
            XCTAssertEqual(offset(collapse.fromValue), edge(300), accuracy: 0.5)
            XCTAssertEqual(offset(collapse.toValue), edge(8), accuracy: 0.5)
            XCTAssertEqual(collapse.timingFunction, SidebarToggleAnimation.timingFunction)
            waitForToggleAnimation()
            XCTAssertNil(page.layer?.mask, "collapsed")

            shell.split.setSidebarCollapsed(false, animated: true)
            let expand = try XCTUnwrap(page.layer?.mask.flatMap { slide(on: $0) })
            XCTAssertEqual(offset(expand.fromValue), edge(8), accuracy: 0.5)
            XCTAssertEqual(offset(expand.toValue), edge(300), accuracy: 0.5)
            waitForToggleAnimation()
            XCTAssertNil(page.layer?.mask, "expanded")
        }
    }

    /// A toggle in flight reverses from where the column is on screen, in
    /// the share of the duration that distance is of the whole.
    func testAReversalInFlightStartsFromWhereTheColumnIsOnScreen() throws {
        for side in SidebarPosition.allCases {
            var reversedInFlight: [CGFloat] = []
            for elapsed in [0.02, 0.05, 0.08] {
                startOver(on: side)
                let shell = makeShell(onScreen: true)
                shell.split.setSidebarGeometry(width: 300, collapsed: false)
                shell.layout()
                var expansionsFinished = 0
                let subscription = shell.split.sidebarExpansionDidFinish.sink { expansionsFinished += 1 }
                var results: [Bool] = []

                shell.split.setSidebarCollapsed(true, animated: true) { results.append($0) }
                spin(elapsed)
                let shown = shell.split.splitView.shownColumnFraction
                guard shown > 0, shown < 1 else {
                    // The run loop ran past the whole slide; nothing to reverse.
                    subscription.cancel()
                    continue
                }
                reversedInFlight.append(shown)
                shell.split.setSidebarCollapsed(false, animated: true) { results.append($0) }
                XCTAssertEqual(results, [false], "the collapse was cut short")
                try assertSlides(in: shell, on: side, from: shown, to: 1,
                                 duration: SidebarToggleAnimation.duration * TimeInterval(1 - shown), accuracy: 6)
                assertPageInFlight(shell, on: side)
                XCTAssertTrue(shell.split.isSidebarExpanding)

                waitForToggleAnimation()
                XCTAssertEqual(results, [false, true])
                XCTAssertEqual(expansionsFinished, 1)
                assertNoSlides(in: shell)
                assertExpanded(shell, width: 300, on: side, "reversed \(elapsed)s in")
                subscription.cancel()
            }
            XCTAssertFalse(reversedInFlight.isEmpty, "\(side.rawValue): no reversal caught the column in flight")
        }
    }

    /// Reversed before the first slide was ever committed, the column has
    /// not moved: the reversal has nowhere to go and is placed.
    func testAReversalInTheSameTurnHasNowhereToSlide() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()

            shell.split.setSidebarCollapsed(true, animated: true)
            XCTAssertEqual(shell.split.splitView.shownColumnFraction, 1, "nothing has moved on screen yet")
            shell.split.setSidebarCollapsed(false, animated: true)
            assertNoSlides(in: shell)
            XCTAssertTrue(shell.split.isSidebarExpanding)
            waitForToggleAnimation()
            assertExpanded(shell, width: 300, on: side)

            shell.split.setSidebarCollapsed(true, animated: false)
            shell.layout()
            shell.split.setSidebarCollapsed(false, animated: true)
            XCTAssertEqual(shell.split.splitView.shownColumnFraction, 0, "still hidden on screen")
            shell.split.setSidebarCollapsed(true, animated: true)
            assertNoSlides(in: shell)
            waitForToggleAnimation()
            assertCollapsed(shell)
        }
    }

    /// With nothing on screen to move, a toggle is placed and lands on the
    /// next turn.
    func testAToggleInAWindowOffScreenIsNotAnimated() {
        let shell = makeShell()
        shell.split.setSidebarGeometry(width: 300, collapsed: false)
        var results: [Bool] = []
        shell.split.setSidebarCollapsed(true, animated: true) { results.append($0) }
        assertNoSlides(in: shell)
        XCTAssertEqual(results, [])
        spin(0.02)
        XCTAssertEqual(results, [true])
        assertCollapsed(shell)
    }

    /// The page's sidebar-side inset follows this: it changes in the turn
    /// the page area's frame does, when a collapse starts and when an
    /// expansion lands, so either lays the page out once.
    func testThePageSpaceSignalChangesWithThePageAreasFrame() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            var signals: [Bool] = []
            let subscription = shell.split.sidebarTakesPageSpacePublisher.sink { signals.append($0) }
            XCTAssertEqual(signals, [true])
            XCTAssertTrue(shell.split.sidebarTakesPageSpace)

            shell.split.setSidebarCollapsed(true, animated: true)
            XCTAssertEqual(signals, [true, false], "with the collapse's start")
            waitForToggleAnimation()
            XCTAssertEqual(signals, [true, false])

            shell.split.setSidebarCollapsed(false, animated: true)
            XCTAssertEqual(signals, [true, false], "not before the expansion lands")
            XCTAssertFalse(shell.split.sidebarTakesPageSpace)
            waitForToggleAnimation()
            XCTAssertEqual(signals, [true, false, true])

            shell.split.setSidebarCollapsed(true, animated: true)
            spin(0.03)
            shell.split.setSidebarCollapsed(false, animated: true)
            spin(0.03)
            shell.split.setSidebarCollapsed(true, animated: true)
            waitForToggleAnimation()
            XCTAssertEqual(signals, [true, false, true, false], "reversals change nothing")
            subscription.cancel()
        }
    }

    /// The window's own full screen transition lands a toggle in flight.
    func testAFullScreenTransitionLandsAToggleInFlight() {
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            startOver(on: .left)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.split.setSidebarCollapsed(true, animated: false)
            shell.layout()
            var results: [Bool] = []
            shell.split.setSidebarCollapsed(false, animated: true) { results.append($0) }
            XCTAssertNotNil(slide(on: shell.split.sidebarHost.view))

            NotificationCenter.default.post(name: name, object: shell.window)
            XCTAssertEqual(results, [true])
            XCTAssertFalse(shell.split.isSidebarExpanding)
            assertNoSlides(in: shell)
            assertExpanded(shell, width: 300, on: .left)
        }
    }

    /// Any number of toggles in a row ends in the state the last one asked
    /// for. Each gets one completion: false for one a later toggle cut
    /// short, true for the one that landed.
    func testRapidTogglesEndInTheLastStateWithOneCompletionEach() {
        for side in SidebarPosition.allCases {
            for count in [2, 3, 6, 7] {
                startOver(on: side)
                let shell = makeShell(onScreen: true)
                shell.split.setSidebarGeometry(width: 300, collapsed: false)
                shell.layout()
                var completions: [[Bool]] = Array(repeating: [], count: count)
                var expansionsFinished = 0
                let subscription = shell.split.sidebarExpansionDidFinish.sink { expansionsFinished += 1 }
                var collapsedStates: [Bool] = []
                let states = shell.split.sidebarCollapsedPublisher.dropFirst().sink { collapsedStates.append($0) }

                for index in 0..<count {
                    shell.split.setSidebarCollapsed(index.isMultiple(of: 2), animated: true) {
                        completions[index].append($0)
                    }
                }
                let endsCollapsed = !count.isMultiple(of: 2)
                XCTAssertEqual(shell.split.isSidebarCollapsed, endsCollapsed)
                XCTAssertEqual(Array(completions.dropLast()), Array(repeating: [false], count: count - 1),
                               "\(count) toggles")
                XCTAssertEqual(completions.last, [], "the last one is still in flight")
                waitForToggleAnimation()

                XCTAssertEqual(completions.last, [true], "\(count) toggles")
                XCTAssertEqual(completions.map(\.count), Array(repeating: 1, count: count))
                XCTAssertEqual(collapsedStates.count, count, "every toggle changes the state once")
                XCTAssertEqual(expansionsFinished, endsCollapsed ? 0 : 1)
                XCTAssertFalse(shell.split.isSidebarExpanding)
                if endsCollapsed {
                    assertCollapsed(shell, "\(count) toggles")
                } else {
                    assertExpanded(shell, width: 300, on: side, "\(count) toggles")
                }
                subscription.cancel()
                states.cancel()
            }
        }
    }

    /// As key repeat sends them: a toggle every few frames.
    func testRepeatedTogglesAtKeyRepeatRateEndInTheLastState() {
        for count in [4, 5] {
            startOver(on: .left)
            let shell = makeShell(onScreen: true)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            var finished = 0
            var cutShort = 0
            for _ in 0..<count {
                shell.split.setSidebarCollapsed(!shell.split.isSidebarCollapsed, animated: true) {
                    if $0 { finished += 1 } else { cutShort += 1 }
                }
                spin(0.03)
            }
            waitForToggleAnimation()
            XCTAssertEqual(finished + cutShort, count)
            if count.isMultiple(of: 2) {
                assertExpanded(shell, width: 300, on: .left)
            } else {
                assertCollapsed(shell)
            }
        }
    }

    func testACompletionComesAtOnceWhenThereIsNothingToAnimate() {
        let shell = makeShell()
        var results: [Bool] = []
        shell.split.setSidebarCollapsed(false, animated: true) { results.append($0) }
        XCTAssertEqual(results, [true], "already expanded")
        shell.split.setSidebarCollapsed(true, animated: false) { results.append($0) }
        XCTAssertEqual(results, [true, true], "not animated")
        shell.split.setSidebarCollapsed(false, animated: true) { results.append($0) }
        XCTAssertEqual(results, [true, true], "in flight")
        shell.split.setSidebarCollapsed(false, animated: false) { results.append($0) }
        XCTAssertEqual(results, [true, true, true, true], "landed at once, then nothing left to do")
        XCTAssertFalse(shell.split.isSidebarExpanding)
        assertExpanded(shell, width: minWidth, on: .left)
    }

    /// A window resize or a side switch during a toggle lands it first.
    func testAResizeOrASideSwitchLandsAToggleInFlight() {
        var shell = makeShell()
        shell.split.setSidebarGeometry(width: 300, collapsed: false)
        shell.split.setSidebarCollapsed(true, animated: false)
        var results: [Bool] = []
        shell.split.setSidebarCollapsed(false, animated: true) { results.append($0) }
        shell.resize(toWidth: 800)
        XCTAssertEqual(results, [true])
        XCTAssertFalse(shell.split.isSidebarExpanding)
        assertExpanded(shell, width: 300, on: .left)

        startOver(on: .left)
        shell = makeShell()
        shell.split.setSidebarGeometry(width: 300, collapsed: false)
        shell.split.setSidebarCollapsed(true, animated: true) { results.append($0) }
        PhiPreferences.GeneralSettings.saveSidebarPosition(.right)
        deliverDefaultsChange()
        XCTAssertEqual(results, [true, true])
        assertCollapsed(shell)
    }

    /// Where the page cannot give the column its width, opening the column
    /// widens the window by the whole column.
    func testExpandingInAWindowTooNarrowWidensTheWindow() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 250, collapsed: false)
            shell.split.setSidebarCollapsed(true, animated: false)
            shell.resize(toWidth: 449)
            assertCollapsed(shell)

            shell.split.setSidebarCollapsed(false, animated: false)
            assertExpanded(shell, width: 250, on: side)
            XCTAssertEqual(shell.width, 449 + 250, accuracy: 0.5)

            shell.split.setSidebarCollapsed(true, animated: false)
            shell.resize(toWidth: 450)
            shell.split.setSidebarCollapsed(false, animated: false)
            assertExpanded(shell, width: 250, on: side, "the page can give 250 at 450")
            XCTAssertEqual(shell.width, 450, accuracy: 0.5)
        }
    }

    /// A drag reports every width it passes through and stops at the limits.
    func testADividerDragIsLiveAndStopsAtTheLimits() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            var widths: [CGFloat] = []
            let subscription = shell.split.sidebarWidthPublisher.dropFirst().sink { widths.append($0) }

            XCTAssertTrue(dragDivider(of: shell, on: side, through: [320, 350]))
            assertExpanded(shell, width: 350, on: side)
            XCTAssertEqual(widths, [320, 350])
            XCTAssertEqual(shell.split.lastExpandedSidebarWidth, 350, accuracy: 0.5)
            subscription.cancel()

            XCTAssertTrue(dragDivider(of: shell, on: side, through: [450, 600]))
            assertExpanded(shell, width: maxWidth, on: side)

            XCTAssertTrue(dragDivider(of: shell, on: side, through: [300, 150]))
            assertExpanded(shell, width: minWidth, on: side)

            XCTAssertTrue(dragDivider(of: shell, on: side, through: [97]))
            assertExpanded(shell, width: minWidth, on: side, "up to half the minimum the column holds")
        }
    }

    func testADragKeepsThePointersOffsetFromTheDivider() {
        for side in SidebarPosition.allCases {
            for grabOffset: CGFloat in [-6, 6] {
                startOver(on: side)
                let shell = makeShell()
                shell.split.setSidebarGeometry(width: 300, collapsed: false)
                shell.layout()
                XCTAssertTrue(dragDivider(of: shell, on: side, grabOffset: grabOffset, through: [340]))
                assertExpanded(shell, width: 340, on: side, "grabbed \(grabOffset) off the divider")
            }
        }
    }

    /// The page's minimum caps a drag in a narrow window, and the width the
    /// drag ends on is the sidebar's from then on.
    func testADragInANarrowWindowStopsAtThePageMinimumAndSticks() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell(width: 600)
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            XCTAssertTrue(dragDivider(of: shell, on: side, through: [450, 500]))
            assertExpanded(shell, width: 400, on: side)

            shell.resize(toWidth: 1000)
            assertExpanded(shell, width: 400, on: side, "the window grew back")
        }
    }

    /// A drag writes nothing on the way; the width it ends on is stored once
    /// it has been still.
    func testADraggedWidthIsStoredOnceTheDragHasSettled() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            waitForStorage()
            XCTAssertEqual(storedWidth(on: side), 300, accuracy: 0.5)

            XCTAssertTrue(dragDivider(of: shell, on: side, through: [320, 350, minWidth]))
            XCTAssertEqual(storedWidth(on: side), 300, accuracy: 0.5, "not during the drag")
            waitForStorage()
            XCTAssertEqual(storedWidth(on: side), minWidth, accuracy: 0.5, "the minimum is stored like any width")
        }
    }

    /// A drag released past half the minimum width slides the column out;
    /// coming back before the release keeps it open.
    func testReleasingPastHalfTheMinimumCollapsesAndComingBackKeepsItOpen() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 250, collapsed: false)
            shell.layout()

            XCTAssertTrue(dragDivider(of: shell, on: side, through: [50, 260]))
            assertExpanded(shell, width: 260, on: side, "back out in the same drag")

            XCTAssertTrue(dragDivider(of: shell, on: side, through: [100, 96]))
            XCTAssertTrue(shell.split.isSidebarCollapsed, "the release collapses")
            spin(SidebarToggleAnimation.dragReleaseDuration + 0.4)
            shell.layout()
            assertCollapsed(shell)
            XCTAssertEqual(shell.split.lastExpandedSidebarWidth, 260, accuracy: 0.5,
                           "the floating panel opens at the width the column will")

            shell.split.setSidebarCollapsed(false, animated: false)
            assertExpanded(shell, width: 260, on: side, "reopens at the width the drag started from")
        }
    }

    func testACollapsedColumnHasNoDividerToDrag() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarCollapsed(true, animated: false)
            shell.layout()
            for inset: CGFloat in [1, 2, 3, 5, 7] {
                let x = side == .left ? inset : shell.width - inset
                XCTAssertFalse(isDivider(shell.window.contentView?.hitTest(NSPoint(x: x, y: 350))),
                               "\(side.rawValue), \(inset) from the edge")
            }
            XCTAssertFalse(dragDivider(of: shell, on: side, through: [250]))
            assertCollapsed(shell)
        }
    }

    func testADoubleClickOnTheDividerChangesNothing() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            XCTAssertTrue(dragDivider(of: shell, on: side, clickCount: 2))
            assertExpanded(shell, width: 300, on: side)
        }
    }

    /// 14 points centred on the column's inner edge, over the whole height
    /// of the window, the titlebar band included.
    func testTheDividerTakesPressesWithinSevenPointsOfTheEdge() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            let edge = dividerX(in: shell, on: side, sidebarWidth: 300)
            for y: CGFloat in [10, 350, Self.height - 10] {
                for offset: CGFloat in [-6.5, -3, 0, 3, 6.5] {
                    XCTAssertTrue(isDivider(shell.window.contentView?.hitTest(NSPoint(x: edge + offset, y: y))),
                                  "\(side.rawValue), \(offset) from the edge at \(y)")
                }
                for offset: CGFloat in [-8, 8] {
                    XCTAssertFalse(isDivider(shell.window.contentView?.hitTest(NSPoint(x: edge + offset, y: y))),
                                   "\(side.rawValue), \(offset) from the edge at \(y)")
                }
            }
            XCTAssertTrue(dragDivider(of: shell, on: side, atHeight: Self.height - 10, through: [360]))
            assertExpanded(shell, width: 360, on: side, "dragged in the titlebar band")
        }
    }

    /// At a limit the divider offers only the way it can still move, as the
    /// floating panel's edge does.
    func testAtItsLimitsTheDividerOnlyOffersTheWayItCanStillMove() throws {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            let directions = try XCTUnwrap(shell.split.splitView.divider.directions)
            let towardThePage: FloatingSidebarResizeHandleView.Directions = side == .left ? .rightOnly : .leftOnly
            let towardTheEdge: FloatingSidebarResizeHandleView.Directions = side == .left ? .leftOnly : .rightOnly

            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            XCTAssertEqual(directions(), .both)
            shell.split.setSidebarGeometry(width: minWidth, collapsed: false)
            XCTAssertEqual(directions(), towardThePage)
            shell.split.setSidebarGeometry(width: maxWidth, collapsed: false)
            XCTAssertEqual(directions(), towardTheEdge)

            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.resize(toWidth: 500)
            XCTAssertEqual(directions(), towardTheEdge, "the page is at its minimum")
        }
    }

    func testAccessibilityExposesOneSplitterAtTheDivider() throws {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            XCTAssertEqual(shell.split.splitView.accessibilityRole(), .splitGroup)
            let splitters = (shell.split.splitView.accessibilitySplitters() ?? [])
                .compactMap { $0 as? NSAccessibilityProtocol }
            XCTAssertEqual(splitters.count, 1)
            let splitter = try XCTUnwrap(splitters.first)
            XCTAssertEqual(splitter.accessibilityRole(), .splitter)
            func number(_ value: Any?) -> CGFloat { CGFloat((value as? NSNumber)?.doubleValue ?? -1) }
            let position = dividerX(in: shell, on: side, sidebarWidth: 300)
            XCTAssertEqual(number(splitter.accessibilityValue()), position, accuracy: 0.5)
            XCTAssertLessThan(number(splitter.accessibilityMinValue()), position)
            XCTAssertGreaterThan(number(splitter.accessibilityMaxValue()), position)

            XCTAssertTrue(splitter.accessibilityPerformIncrement())
            assertExpanded(shell, width: side == .left ? 310 : 290, on: side, "one step toward the maximum")
            XCTAssertTrue(splitter.accessibilityPerformDecrement())
            assertExpanded(shell, width: 300, on: side)

            shell.split.setSidebarCollapsed(true, animated: false)
            XCTAssertEqual(shell.split.splitView.accessibilitySplitters()?.count, 0)
        }
    }

    func testSetSidebarGeometryClampsTheWidthAndSetsTheCollapsedState() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            for (requested, expected) in [(100, minWidth), (320, 320), (800, maxWidth)] as [(CGFloat, CGFloat)] {
                shell.split.setSidebarGeometry(width: requested, collapsed: false)
                assertExpanded(shell, width: expected, on: side, "asked for \(requested)")
            }
            shell.split.setSidebarGeometry(width: 260, collapsed: true)
            assertCollapsed(shell)
            shell.split.setSidebarGeometry(width: nil, collapsed: false)
            assertExpanded(shell, width: maxWidth, on: side, "a width given while collapsing is not kept")
            shell.split.setSidebarCollapsed(true, animated: false)
            shell.split.setSidebarGeometry(width: 260, collapsed: false)
            assertExpanded(shell, width: 260, on: side, "expands at the width given")
        }
    }

    /// The floating panel opens at the width the column would. Resizing it
    /// while the column is collapsed sets the width the column docks at.
    func testAFloatingPanelResizeSetsTheWidthTheColumnDocksAt() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            let panel = shell.split.floatingSidebarHost
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            XCTAssertEqual(panel.currentFloatingWidth, 300, accuracy: 0.5)

            shell.split.adoptFloatingSidebarWidth(420)
            XCTAssertEqual(shell.split.lastExpandedSidebarWidth, 300, accuracy: 0.5, "ignored while expanded")

            shell.split.setSidebarCollapsed(true, animated: false)
            XCTAssertEqual(panel.currentFloatingWidth, 300, accuracy: 0.5)
            for (requested, expected) in [(700, maxWidth), (50, minWidth), (420, 420)] as [(CGFloat, CGFloat)] {
                shell.split.adoptFloatingSidebarWidth(requested)
                XCTAssertEqual(shell.split.lastExpandedSidebarWidth, expected, accuracy: 0.5)
                XCTAssertEqual(panel.currentFloatingWidth, expected, accuracy: 0.5)
            }
            assertCollapsed(shell)
            waitForStorage()
            XCTAssertEqual(storedWidth(on: side), 420, accuracy: 0.5)

            shell.split.setSidebarCollapsed(false, animated: false)
            assertExpanded(shell, width: 420, on: side)
        }
    }

    /// The panel leaves the page its minimum as the column does, and gets
    /// its width back with the window. A resize of the panel in a narrow
    /// window stops where the column would.
    func testTheFloatingPanelWidthFollowsTheWindowWidth() {
        let shell = makeShell()
        let panel = shell.split.floatingSidebarHost
        shell.split.setSidebarGeometry(width: maxWidth, collapsed: false)
        shell.split.setSidebarCollapsed(true, animated: false)
        shell.resize(toWidth: 400)
        XCTAssertEqual(panel.currentFloatingWidth, 200, accuracy: 0.5)
        shell.resize(toWidth: 1000)
        XCTAssertEqual(panel.currentFloatingWidth, maxWidth, accuracy: 0.5)

        shell.resize(toWidth: 600)
        shell.split.adoptFloatingSidebarWidth(480)
        XCTAssertEqual(panel.currentFloatingWidth, 400, accuracy: 0.5)
        shell.resize(toWidth: 1000)
        XCTAssertEqual(panel.currentFloatingWidth, 400, accuracy: 0.5, "the panel's resize set the width")
    }

    func testTheTabDragBoundaryIsTheExpandedColumn() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.layout()
            let column = shell.column
            let inColumn = shell.window.convertPoint(toScreen: NSPoint(x: column.midX, y: column.midY))
            let page = shell.page
            let inPage = shell.window.convertPoint(toScreen: NSPoint(x: page.midX, y: page.midY))
            XCTAssertTrue(shell.split.containsSidebarTabDragBoundary(at: inColumn))
            XCTAssertFalse(shell.split.containsSidebarTabDragBoundary(at: inPage))

            shell.split.setSidebarCollapsed(true, animated: false)
            shell.layout()
            XCTAssertFalse(shell.split.containsSidebarTabDragBoundary(at: inColumn))
        }
    }

    /// A side that never had a width takes the other's along; after that
    /// each keeps its own. The collapsed state crosses with the column.
    func testSwitchingSidesMovesTheColumnAndEachSideKeepsItsWidth() {
        let shell = makeShell()
        shell.split.setSidebarGeometry(width: 300, collapsed: false)
        assertExpanded(shell, width: 300, on: .left)

        PhiPreferences.GeneralSettings.saveSidebarPosition(.right)
        deliverDefaultsChange()
        assertExpanded(shell, width: 300, on: .right)

        shell.split.setSidebarGeometry(width: 420, collapsed: false)
        shell.split.setSidebarCollapsed(true, animated: false)
        PhiPreferences.GeneralSettings.saveSidebarPosition(.left)
        deliverDefaultsChange()
        assertCollapsed(shell, "a collapsed column stays collapsed across the move")

        shell.split.setSidebarCollapsed(false, animated: false)
        assertExpanded(shell, width: 300, on: .left)

        XCTAssertTrue(dragDivider(of: shell, on: .left, through: [350]))
        assertExpanded(shell, width: 350, on: .left, "the divider works after the move")

        PhiPreferences.GeneralSettings.saveSidebarPosition(.right)
        deliverDefaultsChange()
        assertExpanded(shell, width: 420, on: .right)
        XCTAssertTrue(dragDivider(of: shell, on: .right, through: [380]))
        assertExpanded(shell, width: 380, on: .right)

        waitForStorage()
        XCTAssertEqual(storedWidth(on: .left), 350, accuracy: 0.5)
        XCTAssertEqual(storedWidth(on: .right), 380, accuracy: 0.5)
    }

    func testWidthAndCollapsedStateComeBackAfterARelaunch() {
        for side in SidebarPosition.allCases {
            startOver(on: side)
            var shell = makeShell()
            shell.split.setSidebarGeometry(width: 444, collapsed: false)

            shell = relaunch()
            assertExpanded(shell, width: 444, on: side, "relaunched")

            shell = relaunch(width: 600)
            assertExpanded(shell, width: 400, on: side, "relaunched in a narrow window")

            shell = relaunch(width: 1400)
            assertExpanded(shell, width: 444, on: side, "a narrow launch did not change the width")
            shell.split.setSidebarCollapsed(true, animated: false)

            shell = relaunch()
            assertCollapsed(shell, "relaunched collapsed")
            XCTAssertEqual(shell.split.floatingSidebarHost.currentFloatingWidth, 444, accuracy: 0.5)
            shell.split.setSidebarCollapsed(false, animated: false)
            assertExpanded(shell, width: 444, on: side, "reopened after the relaunch")
        }
    }

    /// Shell windows resize and collapse independently while they are open,
    /// and store one state between them: the last change is what a relaunch
    /// opens with.
    func testShellWindowsAreIndependentButShareOneStoredState() {
        let first = makeShell()
        let second = makeShell(width: 900)
        first.split.setSidebarGeometry(width: 300, collapsed: false)
        second.split.setSidebarGeometry(width: 420, collapsed: false)
        assertExpanded(first, width: 300, on: .left)
        assertExpanded(second, width: 420, on: .left)
        waitForStorage()
        XCTAssertEqual(storedCollapsed(), false)

        first.split.setSidebarCollapsed(true, animated: false)
        assertCollapsed(first)
        assertExpanded(second, width: 420, on: .left)
        waitForStorage()
        XCTAssertEqual(storedCollapsed(), true)
    }

    /// A burst of toggles writes the collapsed state once, after the last
    /// one has settled, and nothing when it ends where it began: each write
    /// to the app's defaults reaches every Space's observers.
    func testABurstOfTogglesStoresTheCollapsedStateOnce() {
        let shell = makeShell(onScreen: true)
        waitForStorage()
        XCTAssertEqual(storedCollapsed(), false)
        let writes = DefaultsWriteCounter(key: PhiPreferences.GeneralSettings.sidebarCollapsedKey)
        defer { writes.stop() }

        for _ in 0..<5 {
            shell.split.toggleSidebar()
            spin(0.03)
        }
        XCTAssertEqual(writes.count, 0, "nothing is written while the toggles keep coming")
        XCTAssertEqual(storedCollapsed(), false)
        waitForStorage()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(storedCollapsed(), true)

        for _ in 0..<4 {
            shell.split.toggleSidebar()
        }
        waitForStorage()
        XCTAssertEqual(writes.count, 1, "the burst ended where it began")
        XCTAssertEqual(storedCollapsed(), true)

        shell.split.toggleSidebar()
        waitForStorage()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(storedCollapsed(), false)
    }

    /// The comfortable layout keeps the column collapsed whatever asks, and
    /// leaving it always opens the column.
    func testTheComfortableLayoutKeepsTheColumnCollapsed() {
        let shell = makeShell()
        shell.split.setSidebarGeometry(width: 300, collapsed: false)

        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        deliverDefaultsChange()
        assertCollapsed(shell)
        shell.split.setSidebarCollapsed(false, animated: false)
        assertCollapsed(shell)
        shell.split.toggleSidebar()
        assertCollapsed(shell)
        shell.split.setSidebarGeometry(width: 320, collapsed: false)
        assertCollapsed(shell)

        PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)
        deliverDefaultsChange()
        assertExpanded(shell, width: 300, on: .left)

        shell.split.setSidebarCollapsed(true, animated: false)
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        deliverDefaultsChange()
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        deliverDefaultsChange()
        assertExpanded(shell, width: 300, on: .left, "collapsed before the comfortable layout, open after it")
    }

    /// The comfortable layout's collapse is the layout's, not the user's: it
    /// is never stored, so a relaunch back in a vertical layout opens the
    /// sidebar as the user left it there, at the width it had.
    func testTheComfortableLayoutDoesNotWriteTheStoredState() {
        for leftCollapsed in [false, true] {
            startOver(on: .left)
            PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
            var shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.split.setSidebarCollapsed(leftCollapsed, animated: false)
            waitForStorage()
            XCTAssertEqual(storedCollapsed(), leftCollapsed)

            PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
            deliverDefaultsChange()
            assertCollapsed(shell)
            waitForStorage()
            XCTAssertEqual(storedCollapsed(), leftCollapsed, "the layout's collapse is not stored")

            shell = relaunch()
            assertCollapsed(shell, "launched in the comfortable layout")
            waitForStorage()
            XCTAssertEqual(storedCollapsed(), leftCollapsed)

            PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
            shell = relaunch()
            if leftCollapsed {
                assertCollapsed(shell, "back as the user left it")
                shell.split.setSidebarCollapsed(false, animated: false)
            }
            assertExpanded(shell, width: 300, on: .left, "the width survived the comfortable layout")
        }
    }

    /// Leaving the comfortable layout opens the column, and that is stored.
    func testLeavingTheComfortableLayoutStoresTheOpenColumn() {
        var shell = makeShell()
        shell.split.setSidebarGeometry(width: 300, collapsed: false)
        shell.split.setSidebarCollapsed(true, animated: false)
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        shell = relaunch()
        XCTAssertEqual(storedCollapsed(), true)

        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        deliverDefaultsChange()
        assertExpanded(shell, width: 300, on: .left)
        waitForStorage()
        XCTAssertEqual(storedCollapsed(), false)
    }

    /// The first shell after the NSSplitView one takes over what that one
    /// autosaved for its side: the column's width and whether it was
    /// collapsed.
    func testTheFirstLaunchTakesOverTheAutosavedColumn() {
        for side in SidebarPosition.allCases {
            for collapsed in [false, true] {
                startOver(on: side)
                leaveAutosavedFrames(on: side, columnWidth: 280, collapsed: collapsed)
                var shell = makeShell()
                if collapsed {
                    assertCollapsed(shell, "\(side.rawValue)")
                    XCTAssertEqual(shell.split.floatingSidebarHost.currentFloatingWidth, 280, accuracy: 0.5)
                } else {
                    assertExpanded(shell, width: 280, on: side, "migrated")
                }
                XCTAssertEqual(storedCollapsed(), collapsed)
                waitForStorage()
                XCTAssertEqual(storedWidth(on: side), 280, accuracy: 0.5)

                shell = relaunch()
                if collapsed {
                    assertCollapsed(shell, "\(side.rawValue) relaunched")
                    shell.split.setSidebarCollapsed(false, animated: false)
                }
                assertExpanded(shell, width: 280, on: side, "relaunched")
            }
        }
    }

    /// Only once: standalone windows keep autosaving under the same names,
    /// and what they leave there is not the shell's.
    func testAutosavedFramesAreNotReadAgainOnceTheStateIsStored() {
        var shell = makeShell()
        shell.split.setSidebarGeometry(width: 300, collapsed: false)
        closeShells()
        leaveAutosavedFrames(on: .left, columnWidth: 444, collapsed: true)

        shell = makeShell()
        assertExpanded(shell, width: 300, on: .left)
    }

    /// Frames autosaved in the comfortable layout are collapsed by the
    /// layout; the width is still the user's.
    func testAutosavedFramesFromTheComfortableLayoutDoNotCountAsCollapsed() {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        leaveAutosavedFrames(on: .left, columnWidth: 320, collapsed: true)
        var shell = makeShell()
        assertCollapsed(shell)
        XCTAssertEqual(storedCollapsed(), false)

        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        shell = relaunch()
        assertExpanded(shell, width: 320, on: .left)
    }

    func testAutosavedFramesThatMakeNoSenseAreIgnored() {
        guard let key = Self.autosaveKeys[.left] else { return }
        let page = "0.000000, 0.000000, 1000.000000, 700.000000, NO, NO"
        for frames in [["garbage", page], ["0.000000, 0.000000, 0.000000, 700.000000, NO, NO", page],
                       ["0.000000, 0.000000, 900.000000, 700.000000, NO, NO", page], [page]] {
            startOver(on: .left)
            UserDefaults.standard.set(frames, forKey: key)
            let shell = makeShell()
            assertExpanded(shell, width: minWidth, on: .left, "\(frames)")
            XCTAssertEqual(storedCollapsed(), false)
        }
    }

    func testAClosedShellIsReleased() {
        weak var split: ShellSplitViewController?
        autoreleasepool {
            let shell = makeShell()
            shell.split.setSidebarGeometry(width: 300, collapsed: false)
            shell.split.toggleSidebar()
            split = shell.split
            closeShells()
        }
        spin(0.5)
        XCTAssertNil(split)
    }
}
