// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Drives the real sidebar outline with random model changes and checks that
/// every realized row sits where the outline's own geometry says it is.
@MainActor
final class SidebarOutlineLayoutFuzzTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var rng = SeededGenerator(seed: 1)
    private var nextGuid = 9000
    private var nextGroup = 0

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// `TEST_RUNNER_SIDEBAR_FUZZ_SEED`, `_SEEDS` and `_STEPS` widen the run.
    func testRandomOperationsKeepRowLayoutConsistent() throws {
        let env = ProcessInfo.processInfo.environment
        let firstSeed = UInt64(env["SIDEBAR_FUZZ_SEED"] ?? "") ?? 1
        let seedCount = Int(env["SIDEBAR_FUZZ_SEEDS"] ?? "") ?? 2
        let steps = Int(env["SIDEBAR_FUZZ_STEPS"] ?? "") ?? 40
        var failures: [String] = []
        for seed in firstSeed..<(firstSeed + UInt64(seedCount)) {
            if let failure = try run(seed: seed, steps: steps) {
                failures.append(failure)
                print("SIDEBAR_FUZZ_FAILURE\n\(failure)")
            } else {
                print("SIDEBAR_FUZZ_OK seed=\(seed)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) seeds broke the row layout:\n" + failures.joined(separator: "\n\n"))
    }

    private func run(seed: UInt64, steps: Int) throws -> String? {
        rng = SeededGenerator(seed: seed)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 900 + Int(seed % 50), localStore: store,
                                 profileId: "Default", spaceId: UUID().uuidString)
        state.tabs = (0..<10).map { index in
            nextGuid += 1
            return Tab(guid: nextGuid, url: "https://tab.example/\(nextGuid)", isActive: index == 0,
                       index: index, title: "Tab \(nextGuid)")
        }
        state.updateNormalTabs()
        state.focuseTab(state.tabs[0])
        let folderID = UUID().uuidString
        state.bookmarkManager.addFolder(title: "Folder", guid: folderID)
        for index in 0..<8 {
            store.createBookmark(url: "https://bookmark.example/\(seed)/\(index)", title: "Bookmark \(index)",
                                 profileId: state.profileId, parentId: index < 3 ? folderID : nil,
                                 spaceId: state.spaceId)
        }

        let controller = SidebarTabListViewController(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            controller.setActive(false)
            window.close()
        }
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 320, height: 520))
        controller.setActive(true)
        window.orderFrontRegardless()
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let outline = try XCTUnwrap(scroll.documentView as? SideBarOutlineView)
        let loaded = Date().addingTimeInterval(5)
        while !(outline.item(atRow: 0) is SpaceRootSidebarItem), Date() < loaded { spin(0.05) }
        spin(1.0)
        if let problem = layoutProblem(controller: controller, outline: outline) {
            return "seed=\(seed) broken before any operation: \(problem)"
        }

        var sinceCheck: [String] = []
        for step in 0..<steps {
            let description = performRandomOperation(state: state, controller: controller,
                                                     outline: outline, window: window)
            let pauses: [TimeInterval] = [0, 0, 0.01, 0.03, 0.08, 0.15, 0.3]
            let pause = pauses.randomElement(using: &rng) ?? 0
            sinceCheck.append("#\(step) \(description) +\(pause)s")
            if pause > 0 { spin(pause) }
            guard Int.random(in: 0..<3, using: &rng) == 0 || step == steps - 1 else { continue }
            spin(1.2)
            if let problem = layoutProblem(controller: controller, outline: outline) {
                return "seed=\(seed) step=\(step)\n\(problem)\noperations since the last clean check:\n"
                    + sinceCheck.joined(separator: "\n") + "\nrows:\n" + dump(controller: controller, outline: outline)
            }
            sinceCheck.removeAll()
        }
        return nil
    }

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            autoreleasepool {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }
    }

    private func performRandomOperation(state: BrowserState, controller: SidebarTabListViewController,
                                        outline: SideBarOutlineView, window: NSWindow) -> String {
        let normal = state.normalTabs
        let ungrouped = normal.filter { $0.groupToken == nil }
        let tokens = Array(state.groups.keys).sorted()
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<22:
            nextGuid += 1
            let tab = Tab(guid: nextGuid, url: "https://tab.example/\(nextGuid)", isActive: false,
                          index: state.tabs.count, title: "Tab \(nextGuid)")
            state.tabs.append(tab)
            state.updateNormalTabs()
            let target = Int.random(in: 0...state.normalTabs.count, using: &rng)
            if Bool.random(using: &rng), let from = state.normalTabs.firstIndex(where: { $0 === tab }) {
                state.moveNormalTabLocally(from: from, to: target, syncChromiumOrder: false)
            }
            let focus = Bool.random(using: &rng)
            if focus { state.focuseTab(tab) }
            return "open \(tab.guid) target=\(target) focus=\(focus)"
        case 22..<40:
            guard state.tabs.count > 2, let tab = normal.randomElement(using: &rng) else { return "close skipped" }
            let wasFocused = state.focusingTab === tab
            state.tabs.removeAll { $0 === tab }
            if wasFocused, let next = state.tabs.first { state.focuseTab(next) }
            state.updateNormalTabs()
            return "close \(tab.guid) focused=\(wasFocused)"
        case 40..<48:
            guard normal.count > 1 else { return "move skipped" }
            let from = Int.random(in: 0..<normal.count, using: &rng)
            let to = Int.random(in: 0...normal.count, using: &rng)
            state.moveNormalTabLocally(from: from, to: to, syncChromiumOrder: false)
            return "move \(from)->\(to)"
        case 48..<58:
            guard let tab = normal.randomElement(using: &rng) else { return "focus skipped" }
            state.focuseTab(tab)
            return "focus \(tab.guid)"
        case 58..<64:
            guard let tab = ungrouped.randomElement(using: &rng) else { return "group skipped" }
            nextGroup += 1
            let token = "group-\(nextGroup)"
            let collapsed = Int.random(in: 0..<4, using: &rng) == 0
            state.handleTabGroupCreated(token: token, title: token, color: .blue,
                                        isCollapsed: collapsed, initialTabIds: [tab.guid])
            state.updateNormalTabs()
            return "create \(token) with \(tab.guid) collapsed=\(collapsed)"
        case 64..<72:
            guard let token = tokens.randomElement(using: &rng),
                  let tab = ungrouped.randomElement(using: &rng) else { return "join skipped" }
            state.handleTabJoinedGroup(tabId: tab.guid, token: token)
            state.updateNormalTabs()
            return "join \(tab.guid) -> \(token)"
        case 72..<77:
            guard let tab = normal.filter({ $0.groupToken != nil }).randomElement(using: &rng),
                  let token = tab.groupToken else { return "leave skipped" }
            state.handleTabLeftGroup(tabId: tab.guid, token: token)
            state.updateNormalTabs()
            return "leave \(tab.guid) <- \(token)"
        case 77..<84:
            guard let token = tokens.randomElement(using: &rng), let info = state.groups[token] else {
                return "collapse skipped"
            }
            state.handleTabGroupVisualDataChanged(token: token, title: info.title, color: info.color,
                                                  isCollapsed: !info.isCollapsed)
            return "collapse \(token) -> \(!info.isCollapsed)"
        case 84..<87:
            guard let token = tokens.randomElement(using: &rng) else { return "ungroup skipped" }
            state.handleTabGroupClosed(token: token)
            state.updateNormalTabs()
            return "ungroup \(token)"
        case 87..<91:
            guard let root = outline.item(atRow: 0) as? SpaceRootSidebarItem else { return "root skipped" }
            controller.toggleItemExpanded(root)
            return "toggle space root"
        case 91..<94:
            let folders = state.bookmarkManager.getAllBookmarks().filter { $0.isFolder && outline.row(forItem: $0) >= 0 }
            guard let folder = folders.randomElement(using: &rng) else { return "folder skipped" }
            controller.toggleItemExpanded(folder)
            return "toggle folder"
        case 94..<96:
            state.bookmarkManager.addBookmark(title: "Added \(nextGuid)", url: "https://added.example/\(nextGuid)/\(UInt64.random(in: 0..<1_000_000, using: &rng))")
            return "add bookmark"
        case 96..<97:
            let leaves = state.bookmarkManager.getAllBookmarks().filter { !$0.isFolder }
            guard leaves.count > 2, let bookmark = leaves.randomElement(using: &rng) else { return "remove bookmark skipped" }
            state.bookmarkManager.removeBookmark(bookmark)
            return "remove bookmark"
        case 97..<99:
            guard let scroll = outline.enclosingScrollView else { return "scroll skipped" }
            let maxY = max(0, outline.frame.height - scroll.contentView.bounds.height)
            let offsets: [CGFloat] = [0, maxY, CGFloat.random(in: 0...max(1, maxY), using: &rng)]
            let y = offsets.randomElement(using: &rng) ?? 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            return "scroll \(Int(y))/\(Int(maxY))"
        default:
            let heights: [CGFloat] = [360, 520, 700]
            let height = heights.randomElement(using: &rng) ?? 520
            window.setContentSize(NSSize(width: 320, height: height))
            return "resize \(Int(height))"
        }
    }

    private func layoutProblem(controller: SidebarTabListViewController, outline: SideBarOutlineView) -> String? {
        outline.layoutSubtreeIfNeeded()
        var problems: [String] = []
        let spacing = outline.intercellSpacing.height
        var expectedMinY: CGFloat = 0
        let visible = outline.visibleRect
        var rowViews = Set<ObjectIdentifier>()
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) else {
                problems.append("row \(row) has no item")
                continue
            }
            let rect = outline.rect(ofRow: row)
            let expectedHeight = controller.outlineView(outline, heightOfRowByItem: item) + spacing
            if abs(rect.height - expectedHeight) > 0.5 {
                problems.append("row \(row) cached height \(rect.height), delegate says \(expectedHeight)")
            }
            if abs(rect.minY - expectedMinY) > 0.5 {
                problems.append("row \(row) rect starts at \(rect.minY), previous row ends at \(expectedMinY)")
            }
            expectedMinY = rect.maxY
            let rowView = outline.rowView(atRow: row, makeIfNecessary: false)
            if let rowView {
                rowViews.insert(ObjectIdentifier(rowView))
                if abs(rowView.frame.minY - rect.minY) > 0.5 || abs(rowView.frame.height - rect.height) > 0.5 {
                    problems.append("row \(row) view frame \(rowView.frame) but rect \(rect)")
                }
                if rowView.isHidden || rowView.alphaValue < 0.99 || (rowView.layer?.opacity ?? 1) < 0.99 {
                    problems.append("row \(row) view hidden=\(rowView.isHidden) alpha=\(rowView.alphaValue)")
                }
                if rowView.superview !== outline {
                    problems.append("row \(row) view is still inside \(String(describing: rowView.superview.map { type(of: $0) }))")
                }
                // A group cell configures itself through the window registry, which a test window is not in.
                if let cell = rowView.view(atColumn: 0) as? NSView, !(cell is TabGroupCellView),
                   abs(cell.frame.height - (rect.height - spacing)) > 2.5 || cell.frame.minY < -0.5 {
                    problems.append("row \(row) cell frame \(cell.frame) in row of height \(rect.height)")
                }
            } else if rect.intersection(visible).height > 1 {
                problems.append("visible row \(row) has no row view")
            }
        }
        func collectGhosts(_ view: NSView) {
            for subview in view.subviews {
                if let rowView = subview as? NSTableRowView {
                    if !rowViews.contains(ObjectIdentifier(rowView)), !rowView.isHiddenOrHasHiddenAncestor,
                       rowView.alphaValue > 0.01, rowView.convert(rowView.bounds, to: outline).intersects(visible) {
                        problems.append("stray row view at \(rowView.convert(rowView.bounds, to: outline))")
                    }
                } else {
                    collectGhosts(subview)
                }
            }
        }
        collectGhosts(outline)
        if !outline.hiddenRowIndexes.isEmpty {
            problems.append("hidden rows \(Array(outline.hiddenRowIndexes))")
        }
        if let scroll = outline.enclosingScrollView {
            let clip = scroll.contentView.bounds
            let maxY = max(0, outline.frame.height - clip.height)
            if clip.minY < -0.5 || clip.minY > maxY + 0.5 {
                problems.append("clip origin \(clip.minY) outside 0...\(maxY)")
            }
            if outline.frame.height + 0.5 < expectedMinY {
                problems.append("document height \(outline.frame.height) shorter than rows \(expectedMinY)")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private func dump(controller: SidebarTabListViewController, outline: SideBarOutlineView) -> String {
        (0..<outline.numberOfRows).map { row -> String in
            let item = outline.item(atRow: row) as? SidebarItem
            let rect = outline.rect(ofRow: row)
            let frame = outline.rowView(atRow: row, makeIfNecessary: false)?.frame
            return "  \(row) \(item.map { "\($0.itemType) \($0.title)" } ?? "?") rect=\(Int(rect.minY))+\(Int(rect.height))"
                + " view=\(frame.map { "\(Int($0.minY))+\(Int($0.height))" } ?? "-")"
        }.joined(separator: "\n") + "\n  visible=\(outline.visibleRect) frame=\(outline.frame)"
    }
}
