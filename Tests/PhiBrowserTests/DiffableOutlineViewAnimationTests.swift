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

    func snapshot() -> DiffableOutlineSnapshot<AnyHashable> {
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
            nodes: nodes
        )
    }
}

private final class AnimatingDiffableOutlineView: DiffableOutlineView {
    enum Mutation: Equatable {
        case insert(parentID: String?, indexes: [Int], animated: Bool)
        case remove(parentID: String?, indexes: [Int], animated: Bool)
        case move(parentID: String?, from: Int, to: Int)
        case reloadData
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
    }

    deinit {
        outlineView.dataSource = nil
        outlineView.delegate = nil
        window.close()
    }

    func apply(_ nextModel: OutlineAnimationModel, animated: Bool) -> Bool {
        let snapshot = nextModel.snapshot()
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

final class DiffableOutlineViewAnimationTests: XCTestCase {
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

    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}
