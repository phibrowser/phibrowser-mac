// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

private final class OutlineAnimationItem: NSObject {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
        super.init()
    }
}

private struct OutlineAnimationModel {
    let roots: [OutlineAnimationItem]
    let childrenByID: [String: [OutlineAnimationItem]]

    func children(of item: Any?) -> [OutlineAnimationItem] {
        guard let item = item as? OutlineAnimationItem else { return roots }
        return childrenByID[item.id] ?? []
    }

    func snapshot(reloadIDs: Set<String> = []) -> DiffableOutlineSnapshot<AnyHashable> {
        var nodes: [AnyHashable: DiffableOutlineSnapshot<AnyHashable>.Node] = [:]

        func append(_ item: OutlineAnimationItem, parentID: String?) {
            let children = childrenByID[item.id] ?? []
            nodes[AnyHashable(item.id)] = .init(
                id: AnyHashable(item.id),
                item: item,
                parentID: parentID.map(AnyHashable.init),
                childIDs: children.map { AnyHashable($0.id) }
            )

            for child in children {
                append(child, parentID: item.id)
            }
        }

        for root in roots {
            append(root, parentID: nil)
        }

        return DiffableOutlineSnapshot(
            rootIDs: roots.map { AnyHashable($0.id) },
            nodes: nodes,
            reloadIDs: Set(reloadIDs.map(AnyHashable.init))
        )
    }
}

private final class AnimatingDiffableOutlineView: DiffableOutlineView {
    enum Mutation: Equatable {
        case insert(parentID: String?, indexes: [Int], animated: Bool)
        case remove(parentID: String?, indexes: [Int], animated: Bool)
        case move(parentID: String?, from: Int, to: Int)
        case reloadData
        case reloadRows([Int])
    }

    private(set) var mutations: [Mutation] = []

    func clearMutations() {
        mutations.removeAll()
    }

    override func reloadData() {
        mutations.append(.reloadData)
        super.reloadData()
    }

    override func applyInsert(
        at indexes: IndexSet,
        inParent parent: Any?,
        animation: NSOutlineView.AnimationOptions
    ) {
        mutations.append(
            .insert(parentID: parentID(parent), indexes: Array(indexes), animated: !animation.isEmpty)
        )
        super.applyInsert(at: indexes, inParent: parent, animation: animation)
    }

    override func applyRemove(
        at indexes: IndexSet,
        inParent parent: Any?,
        animation: NSOutlineView.AnimationOptions
    ) {
        mutations.append(
            .remove(parentID: parentID(parent), indexes: Array(indexes), animated: !animation.isEmpty)
        )
        super.applyRemove(at: indexes, inParent: parent, animation: animation)
    }

    override func applyMove(
        from fromIndex: Int,
        inParent oldParent: Any?,
        to toIndex: Int,
        inParent newParent: Any?
    ) {
        mutations.append(.move(parentID: parentID(oldParent), from: fromIndex, to: toIndex))
        super.applyMove(from: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    override func applyReload(rowIndexes: IndexSet) {
        mutations.append(.reloadRows(Array(rowIndexes)))
        super.applyReload(rowIndexes: rowIndexes)
    }

    private func parentID(_ parent: Any?) -> String? {
        (parent as? OutlineAnimationItem)?.id
    }
}

private final class DiffableOutlineAnimationFixture: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Identifier {
        static let column = NSUserInterfaceItemIdentifier("diffable-outline-animation-column")
        static let cell = NSUserInterfaceItemIdentifier("diffable-outline-animation-cell")
    }

    let outlineView = AnimatingDiffableOutlineView()

    private let window: NSWindow
    private var model = OutlineAnimationModel(roots: [], childrenByID: [:])

    override init() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        super.init()

        let column = NSTableColumn(identifier: Identifier.column)
        column.width = scrollView.bounds.width
        window.isReleasedWhenClosed = false

        outlineView.frame = scrollView.bounds
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        window.contentView = scrollView
        layout()
        outlineView.clearMutations()
    }

    deinit {
        outlineView.dataSource = nil
        outlineView.delegate = nil
        window.close()
    }

    func apply(_ nextModel: OutlineAnimationModel, animated: Bool, reloadIDs: Set<String> = []) -> Bool {
        let snapshot = nextModel.snapshot(reloadIDs: reloadIDs)
        var completed = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outlineView.reloadWith(
                snapshot,
                animated: animated,
                updateDataSource: {
                    self.model = nextModel
                },
                completion: {
                    completed = true
                }
            )
        }

        drainMainQueue(until: { completed })
        layout()
        return completed
    }

    func expand(_ item: OutlineAnimationItem) {
        outlineView.expandItem(item)
        drainMainQueue()
        layout()
    }

    func visibleTitles() -> [String] {
        layout()
        return (0..<outlineView.numberOfRows).compactMap { row in
            (outlineView.item(atRow: row) as? OutlineAnimationItem)?.title
        }
    }

    func visibleCellTitles() -> [String] {
        layout()
        return (0..<outlineView.numberOfRows).compactMap { row in
            let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
            return cell?.textField?.stringValue
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        model.children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        model.children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !model.children(of: item).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: Identifier.cell, owner: self) as? NSTableCellView
            ?? makeCell()
        cell.textField?.stringValue = (item as? OutlineAnimationItem)?.title ?? ""
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        cell.identifier = Identifier.cell

        let textField = NSTextField(labelWithString: "")
        textField.frame = cell.bounds.insetBy(dx: 4, dy: 2)
        textField.autoresizingMask = [.width, .height]
        cell.addSubview(textField)
        cell.textField = textField

        return cell
    }

    private func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        outlineView.layoutSubtreeIfNeeded()
    }

    private func drainMainQueue(until isDone: (() -> Bool)? = nil) {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if isDone?() == true { break }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}

private final class OutlineLayoutRepairItem: NSObject {
    let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init()
    }
}

private final class RecordingSideBarOutlineView: SideBarOutlineView {
    struct ItemReload {
        let itemID: ObjectIdentifier
        let reloadChildren: Bool
    }

    private(set) var itemReloads: [ItemReload] = []
    private(set) var reloadDataCallCount = 0

    override func reloadData() {
        reloadDataCallCount += 1
        super.reloadData()
    }

    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        if let item {
            itemReloads.append(ItemReload(
                itemID: ObjectIdentifier(item as AnyObject),
                reloadChildren: reloadChildren
            ))
        }
        super.reloadItem(item, reloadChildren: reloadChildren)
    }

    func clearRecordedReloads() {
        itemReloads.removeAll()
        reloadDataCallCount = 0
    }
}

private struct OutlineLayoutRepairResult {
    let realizedSuffixRows: [Int]
    let maximumOriginDeltaBeforeRepair: CGFloat
    let repairedRow: Int?
    let repairedOriginDelta: CGFloat?
    let maximumOriginDeltaAfterRepair: CGFloat
    let maximumOriginDeltaAfterHeightReconciliation: CGFloat
    let selectedRowsBeforeRepair: IndexSet
    let selectedRowsAfterRepair: IndexSet
    let clipOriginBeforeRepair: NSPoint
    let clipOriginAfterRepair: NSPoint
    let secondRepairWasNeeded: Bool
    let repairWasNeededAfterHeightReconciliation: Bool
    let reloadItemCallCount: Int
    let insertedItemReloadCount: Int
    let reloadChildrenValues: [Bool]
    let reloadDataCallCount: Int
}

private final class SideBarOutlineLayoutRepairFixture: NSObject,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    private enum Identifier {
        static let column = NSUserInterfaceItemIdentifier("sidebar-layout-repair-column")
        static let cell = NSUserInterfaceItemIdentifier("sidebar-layout-repair-cell")
    }

    let outlineView = RecordingSideBarOutlineView()

    private let scrollView: NSScrollView
    private let window: NSWindow
    private var items: [OutlineLayoutRepairItem]

    override init() {
        let viewport = NSRect(x: 0, y: 0, width: 193, height: 640)
        scrollView = NSScrollView(frame: viewport)
        window = NSWindow(
            contentRect: viewport,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        items = [
            36, 36, 36, 36, 36, 36, 16, 36,
            260, 36, 260, 36, 36, 36, 36, 36, 36, 36,
        ].map { OutlineLayoutRepairItem(height: $0) }

        super.init()

        let column = NSTableColumn(identifier: Identifier.column)
        column.width = viewport.width
        window.isReleasedWhenClosed = false

        outlineView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: 1_076)
        outlineView.style = .fullWidth
        outlineView.rowSizeStyle = .default
        outlineView.intercellSpacing = .zero
        outlineView.headerView = nil
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.hasVerticalScroller = false
        scrollView.documentView = outlineView
        window.contentView = scrollView
        outlineView.bottomPadding = 130
        window.orderFrontRegardless()

        outlineView.reloadData()
        layout()

        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: 566))
        scrollView.reflectScrolledClipView(clipView)
        drainMainQueue()
        layout()

        _ = outlineView.view(atColumn: 0, row: 10, makeIfNecessary: true)
        _ = outlineView.view(atColumn: 0, row: 11, makeIfNecessary: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for _ in 0..<14 {
                outlineView.noteHeightOfRows(
                    withIndexesChanged: IndexSet([8, 10])
                )
            }
        }
    }

    deinit {
        outlineView.dataSource = nil
        outlineView.delegate = nil
        window.close()
    }

    func insertAndRepair(insertionIndex: Int = 8, insertedCount: Int = 1) -> OutlineLayoutRepairResult {
        let insertedItems = (0..<insertedCount).map { _ in OutlineLayoutRepairItem(height: 36) }
        let insertedItem = insertedItems[0]
        items.insert(contentsOf: insertedItems, at: insertionIndex)
        let suffixStart = insertionIndex + 1
        let groupRows = IndexSet([8, 10].map { $0 >= insertionIndex ? $0 + insertedCount : $0 })

        outlineView.beginUpdates()
        outlineView.insertItems(
            at: IndexSet(integersIn: insertionIndex..<(insertionIndex + insertedCount)),
            inParent: nil,
            withAnimation: []
        )
        outlineView.endUpdates()

        drainMainQueue()
        let rects = (0..<outlineView.numberOfRows).map {
            outlineView.rect(ofRow: $0)
        }
        outlineView.selectRowIndexes(IndexSet(integer: insertionIndex), byExtendingSelection: false)

        let realizedSuffixRows = (suffixStart..<outlineView.numberOfRows).filter { row in
            outlineView.rowView(atRow: row, makeIfNecessary: false) != nil
        }
        let maximumOriginDeltaBeforeRepair = maximumOriginDelta(
            rows: realizedSuffixRows,
            rects: rects
        )
        let selectedRowsBeforeRepair = outlineView.selectedRowIndexes
        let clipOriginBeforeRepair = scrollView.contentView.bounds.origin

        outlineView.clearRecordedReloads()
        let repair = outlineView.repairRealizedRowLayoutIfNeeded(
            afterInserting: insertedItem
        )

        let rectsAfterRepair = (0..<outlineView.numberOfRows).map {
            outlineView.rect(ofRow: $0)
        }
        let realizedRowsAfterRepair = (suffixStart..<outlineView.numberOfRows).filter { row in
            outlineView.rowView(atRow: row, makeIfNecessary: false) != nil
        }
        let maximumOriginDeltaAfterRepair = maximumOriginDelta(
            rows: realizedRowsAfterRepair,
            rects: rectsAfterRepair
        )
        let selectedRowsAfterRepair = outlineView.selectedRowIndexes
        let clipOriginAfterRepair = scrollView.contentView.bounds.origin
        let secondRepairWasNeeded = outlineView.repairRealizedRowLayoutIfNeeded(
            afterInserting: insertedItem
        ) != nil

        DispatchQueue.main.async { [outlineView] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                outlineView.noteHeightOfRows(
                    withIndexesChanged: groupRows
                )
            }
        }
        drainMainQueue()
        layout()

        let finalRects = (0..<outlineView.numberOfRows).map {
            outlineView.rect(ofRow: $0)
        }
        let finalRealizedSuffixRows = (suffixStart..<outlineView.numberOfRows).filter { row in
            outlineView.rowView(atRow: row, makeIfNecessary: false) != nil
        }
        let maximumOriginDeltaAfterHeightReconciliation = maximumOriginDelta(
            rows: finalRealizedSuffixRows,
            rects: finalRects
        )
        let repairWasNeededAfterHeightReconciliation =
            outlineView.repairRealizedRowLayoutIfNeeded(
                afterInserting: insertedItem
            ) != nil
        let insertedItemID = ObjectIdentifier(insertedItem)
        let insertedItemReloads = outlineView.itemReloads.filter {
            $0.itemID == insertedItemID
        }

        return OutlineLayoutRepairResult(
            realizedSuffixRows: realizedSuffixRows,
            maximumOriginDeltaBeforeRepair: maximumOriginDeltaBeforeRepair,
            repairedRow: repair?.row,
            repairedOriginDelta: repair?.originDelta,
            maximumOriginDeltaAfterRepair: maximumOriginDeltaAfterRepair,
            maximumOriginDeltaAfterHeightReconciliation:
                maximumOriginDeltaAfterHeightReconciliation,
            selectedRowsBeforeRepair: selectedRowsBeforeRepair,
            selectedRowsAfterRepair: selectedRowsAfterRepair,
            clipOriginBeforeRepair: clipOriginBeforeRepair,
            clipOriginAfterRepair: clipOriginAfterRepair,
            secondRepairWasNeeded: secondRepairWasNeeded,
            repairWasNeededAfterHeightReconciliation:
                repairWasNeededAfterHeightReconciliation,
            reloadItemCallCount: outlineView.itemReloads.count,
            insertedItemReloadCount: insertedItemReloads.count,
            reloadChildrenValues: insertedItemReloads.map(\.reloadChildren),
            reloadDataCallCount: outlineView.reloadDataCallCount
        )
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? OutlineLayoutRepairItem)?.height ?? 36
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: Identifier.cell, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        cell.identifier = Identifier.cell
        return cell
    }

    private func maximumOriginDelta(rows: [Int], rects: [NSRect]) -> CGFloat {
        rows.reduce(0) { maximum, row in
            guard let rowView = outlineView.rowView(
                atRow: row,
                makeIfNecessary: false
            ) else { return maximum }
            return max(maximum, abs(rowView.frame.minY - rects[row].minY))
        }
    }

    private func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        outlineView.layoutSubtreeIfNeeded()
    }

    private func drainMainQueue() {
        var didAdvance = false
        DispatchQueue.main.async {
            didAdvance = true
        }
        let deadline = Date().addingTimeInterval(0.5)
        while !didAdvance, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

final class DiffableOutlineViewAnimationTests: XCTestCase {
    func testReloadOfInsertedItemUsesCommittedAppKitRowMap() {
        runOnMain {
            let fixture = DiffableOutlineAnimationFixture()
            let first = OutlineAnimationItem(id: "first", title: "First")
            let inserted = OutlineAnimationItem(id: "inserted", title: "Inserted")
            XCTAssertTrue(fixture.apply(.init(roots: [first], childrenByID: [:]), animated: false))
            fixture.outlineView.clearMutations()

            XCTAssertTrue(fixture.apply(
                .init(roots: [inserted, first], childrenByID: [:]),
                animated: false, reloadIDs: ["inserted"]
            ))

            XCTAssertEqual(fixture.visibleCellTitles(), ["Inserted", "First"])
            XCTAssertEqual(fixture.outlineView.mutations, [
                .insert(parentID: nil, indexes: [0], animated: false),
                .reloadRows([0]),
            ])
        }
    }

    func testAppliesCRUDSnapshotsWithRealOutlineViewAnimations() {
        runOnMain {
            let fixture = DiffableOutlineAnimationFixture()
            let folder = OutlineAnimationItem(id: "folder", title: "Folder")
            let alpha = OutlineAnimationItem(id: "alpha", title: "Alpha")
            let beta = OutlineAnimationItem(id: "beta", title: "Beta")
            let gamma = OutlineAnimationItem(id: "gamma", title: "Gamma")

            let initial = OutlineAnimationModel(
                roots: [folder, gamma],
                childrenByID: ["folder": [alpha, beta]]
            )
            XCTAssertTrue(fixture.apply(initial, animated: false))
            fixture.expand(folder)
            XCTAssertEqual(fixture.visibleTitles(), ["Folder", "Alpha", "Beta", "Gamma"])
            XCTAssertEqual(fixture.visibleCellTitles(), ["Folder", "Alpha", "Beta", "Gamma"])
            XCTAssertEqual(fixture.outlineView.mutations, [.reloadData])

            let delta = OutlineAnimationItem(id: "delta", title: "Delta")
            let inserted = OutlineAnimationModel(
                roots: [folder, gamma],
                childrenByID: ["folder": [alpha, delta, beta]]
            )
            fixture.outlineView.clearMutations()
            XCTAssertTrue(fixture.apply(inserted, animated: true))
            XCTAssertEqual(fixture.visibleTitles(), ["Folder", "Alpha", "Delta", "Beta", "Gamma"])
            XCTAssertEqual(
                fixture.outlineView.mutations,
                [.insert(parentID: "folder", indexes: [1], animated: true)]
            )

            let updatedAlpha = OutlineAnimationItem(id: "alpha", title: "Alpha Updated")
            let updated = OutlineAnimationModel(
                roots: [folder, gamma],
                childrenByID: ["folder": [updatedAlpha, delta, beta]]
            )
            fixture.outlineView.clearMutations()
            XCTAssertTrue(fixture.apply(updated, animated: true))
            XCTAssertEqual(fixture.visibleCellTitles(), ["Folder", "Alpha Updated", "Delta", "Beta", "Gamma"])
            XCTAssertEqual(
                fixture.outlineView.mutations,
                [
                    .remove(parentID: "folder", indexes: [0], animated: true),
                    .insert(parentID: "folder", indexes: [0], animated: true),
                ]
            )

            let moved = OutlineAnimationModel(
                roots: [folder, gamma],
                childrenByID: ["folder": [beta, updatedAlpha, delta]]
            )
            fixture.outlineView.clearMutations()
            XCTAssertTrue(fixture.apply(moved, animated: true))
            XCTAssertEqual(fixture.visibleTitles(), ["Folder", "Beta", "Alpha Updated", "Delta", "Gamma"])
            XCTAssertEqual(fixture.outlineView.mutations, [.move(parentID: "folder", from: 2, to: 0)])

            let deleted = OutlineAnimationModel(
                roots: [folder, gamma],
                childrenByID: ["folder": [beta, updatedAlpha]]
            )
            fixture.outlineView.clearMutations()
            XCTAssertTrue(fixture.apply(deleted, animated: true))
            XCTAssertEqual(fixture.visibleTitles(), ["Folder", "Beta", "Alpha Updated", "Gamma"])
            XCTAssertEqual(
                fixture.outlineView.mutations,
                [.remove(parentID: "folder", indexes: [2], animated: true)]
            )
        }
    }

    func testRepairsStaleRealizedRowsAfterInsertionInVariableHeightOutline() {
        runOnMain {
            let fixture = SideBarOutlineLayoutRepairFixture()
            let result = fixture.insertAndRepair()

            XCTAssertFalse(result.realizedSuffixRows.isEmpty)
            XCTAssertGreaterThan(result.maximumOriginDeltaBeforeRepair, 0.5)
            XCTAssertNotNil(result.repairedRow)
            XCTAssertGreaterThan(abs(result.repairedOriginDelta ?? 0), 0.5)
            XCTAssertEqual(result.reloadItemCallCount, 1)
            XCTAssertEqual(result.insertedItemReloadCount, 1)
            XCTAssertEqual(result.reloadChildrenValues, [false])
            XCTAssertEqual(result.reloadDataCallCount, 0)
            XCTAssertLessThanOrEqual(result.maximumOriginDeltaAfterRepair, 0.5)
            XCTAssertLessThanOrEqual(
                result.maximumOriginDeltaAfterHeightReconciliation,
                0.5
            )
            XCTAssertEqual(result.selectedRowsBeforeRepair, IndexSet(integer: 8))
            XCTAssertEqual(result.selectedRowsAfterRepair, result.selectedRowsBeforeRepair)
            XCTAssertEqual(
                result.clipOriginAfterRepair.x,
                result.clipOriginBeforeRepair.x,
                accuracy: 0.5
            )
            XCTAssertEqual(
                result.clipOriginAfterRepair.y,
                result.clipOriginBeforeRepair.y,
                accuracy: 0.5
            )
            XCTAssertFalse(result.secondRepairWasNeeded)
            XCTAssertFalse(result.repairWasNeededAfterHeightReconciliation)
        }
    }

    func testBatchInsertionAroundVariableHeightRowsPreservesGeometry() {
        runOnMain {
            for insertionIndex in [8, 12] {
                let fixture = SideBarOutlineLayoutRepairFixture()
                let result = fixture.insertAndRepair(insertionIndex: insertionIndex, insertedCount: 2)
                XCTAssertFalse(result.realizedSuffixRows.isEmpty)
                XCTAssertLessThanOrEqual(result.maximumOriginDeltaAfterRepair, 0.5)
                XCTAssertLessThanOrEqual(result.maximumOriginDeltaAfterHeightReconciliation, 0.5)
                XCTAssertEqual(result.selectedRowsAfterRepair, result.selectedRowsBeforeRepair)
                XCTAssertEqual(result.reloadDataCallCount, 0)
            }
        }
    }

    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}
