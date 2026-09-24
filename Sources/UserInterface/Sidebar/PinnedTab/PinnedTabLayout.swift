// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class PinnedTabLayout: NSCollectionViewLayout {
    enum Section: Int {
        case extensions = 0
        case tabs = 1
    }

    private struct SectionMetrics {
        var numberOfItems: Int = 0
        var numberOfColumns: Int = 0
        var numberOfRows: Int = 0
        var itemSize: NSSize = .zero
        var sectionHeight: CGFloat = 0

        static let empty = SectionMetrics()
    }

    private struct LayoutInput: Equatable {
        let contentWidth: CGFloat
        let tabCount: Int
        let extensionCount: Int
    }

    private enum Constants {
        static let spacing: CGFloat = 8
        static let insets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        static let tabHeight: CGFloat = 45
        static let extensionHeight: CGFloat = 28
        static let tabMinimumWidth: CGFloat = 53
        static let extensionMinimumWidth: CGFloat = 26
    }

    private var pendingConfiguredWidth: CGFloat?
    private var lastPreparedInput: LayoutInput?
    private var cachedAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var orderedAttributes: [NSCollectionViewLayoutAttributes] = []
    private var contentSize: NSSize = .zero

    private var tabMetrics: SectionMetrics = .empty
    private var extensionMetrics: SectionMetrics = .empty

    var numberOfRows: Int {
        tabMetrics.numberOfRows
    }

    var currentItemSize: NSSize {
        tabMetrics.itemSize
    }

    var contentHeight: CGFloat {
        contentSize.height
    }

    var tabLayoutInfo: (columns: Int, rows: Int, itemSize: NSSize) {
        (tabMetrics.numberOfColumns, tabMetrics.numberOfRows, tabMetrics.itemSize)
    }

    var extensionLayoutInfo: (columns: Int, rows: Int, itemSize: NSSize) {
        (extensionMetrics.numberOfColumns, extensionMetrics.numberOfRows, extensionMetrics.itemSize)
    }

    func configure(parentWidth: CGFloat, tabCount: Int, extensionCount: Int) {
        let input = LayoutInput(contentWidth: parentWidth, tabCount: tabCount, extensionCount: extensionCount)
        if lastPreparedInput != input {
            pendingConfiguredWidth = parentWidth
            invalidateLayout()
        }
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            return
        }

        let extensionCount = numberOfItems(in: .extensions, collectionView: collectionView)
        let tabCount = numberOfItems(in: .tabs, collectionView: collectionView)
        let contentWidth = pendingConfiguredWidth ?? collectionView.bounds.width
        let input = LayoutInput(contentWidth: contentWidth, tabCount: tabCount, extensionCount: extensionCount)

        guard input != lastPreparedInput else {
            return
        }
        lastPreparedInput = input
        recalculateLayout(using: input)
    }

    override var collectionViewContentSize: NSSize {
        contentSize
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        orderedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > .ulpOfOne
    }
}

// MARK: - Private Helpers
private extension PinnedTabLayout {
    func numberOfItems(in section: Section, collectionView: NSCollectionView) -> Int {
        guard collectionView.numberOfSections > section.rawValue else { return 0 }
        return collectionView.numberOfItems(inSection: section.rawValue)
    }

    private func recalculateLayout(using input: LayoutInput) {
        guard input.contentWidth > 0 else {
            resetLayoutState(withWidth: input.contentWidth)
            return
        }

        pendingConfiguredWidth = nil
        cachedAttributes.removeAll()
        orderedAttributes.removeAll()

        let tabMaxColumns = tabColumnsLimit(for: input.contentWidth)
        let extensionMaxColumns = extensionColumnsLimit(for: input.contentWidth)
        extensionMetrics = metrics(for: input.extensionCount, itemHeight: Constants.extensionHeight, minimumWidth: Constants.extensionMinimumWidth, contentWidth: input.contentWidth, columnLimit: extensionMaxColumns)
        tabMetrics = metrics(for: input.tabCount, itemHeight: Constants.tabHeight, minimumWidth: Constants.tabMinimumWidth, contentWidth: input.contentWidth, columnLimit: tabMaxColumns)

        var yOffset: CGFloat = 0
        let hasContent = (extensionMetrics.numberOfItems > 0 || tabMetrics.numberOfItems > 0)
        if hasContent {
            yOffset = Constants.insets.top
        }

        if extensionMetrics.numberOfItems > 0 {
            layout(section: .extensions, metrics: extensionMetrics, yOffset: &yOffset)
        }

        if tabMetrics.numberOfItems > 0 {
            if extensionMetrics.numberOfItems > 0 {
                yOffset += Constants.spacing
            }
            layout(section: .tabs, metrics: tabMetrics, yOffset: &yOffset)
        }

        if hasContent {
            yOffset += Constants.insets.bottom
        } else {
            yOffset = 0
        }

        contentSize = NSSize(width: input.contentWidth, height: yOffset)
    }

    func resetLayoutState(withWidth width: CGFloat) {
        cachedAttributes.removeAll()
        orderedAttributes.removeAll()
        tabMetrics = .empty
        extensionMetrics = .empty
        contentSize = NSSize(width: width, height: 0)
    }

    /// Width used for column-limit breakpoints. Parent width grew by the same
    /// amount as `insets.right` when the sidebar trailing edge was added.
    func columnDecisionWidth(for contentWidth: CGFloat) -> CGFloat {
        max(contentWidth - Constants.insets.right, 0)
    }

    func tabColumnsLimit(for contentWidth: CGFloat) -> Int {
        let width = columnDecisionWidth(for: contentWidth)
        if width < 236 {
            return 3
        } else if width < 294 {
            return 4
        } else if width < 352 {
            return 5
        } else {
            return 6
        }
    }

    func extensionColumnsLimit(for contentWidth: CGFloat) -> Int {
        let width = columnDecisionWidth(for: contentWidth)
        if width <= 250 {
            return 5
        } else if width <= 350 {
            return 7
        } else {
            return 10
        }
    }

    private func metrics(for itemCount: Int, itemHeight: CGFloat, minimumWidth: CGFloat, contentWidth: CGFloat, columnLimit: Int) -> SectionMetrics {
        guard itemCount > 0 else {
            return .empty
        }

        var columns = min(columnLimit, itemCount)
        let availableWidth = max(contentWidth - Constants.insets.left - Constants.insets.right, 0)

        while columns > 1 {
            let itemWidth = (availableWidth - CGFloat(columns - 1) * Constants.spacing) / CGFloat(columns)
            if itemWidth >= minimumWidth {
                break
            }
            columns -= 1
        }

        var itemWidth: CGFloat
        if columns == 0 {
            columns = 1
        }

        let calculatedWidth = (availableWidth - CGFloat(columns - 1) * Constants.spacing) / CGFloat(columns)
        itemWidth = max(minimumWidth, calculatedWidth)

        let rows = Int(ceil(Double(itemCount) / Double(columns)))
        let sectionHeight = CGFloat(rows) * itemHeight + CGFloat(max(0, rows - 1)) * Constants.spacing
        return SectionMetrics(
            numberOfItems: itemCount,
            numberOfColumns: columns,
            numberOfRows: rows,
            itemSize: NSSize(width: itemWidth, height: itemHeight),
            sectionHeight: sectionHeight
        )
    }

    private func layout(section: Section, metrics: SectionMetrics, yOffset: inout CGFloat) {
        guard metrics.numberOfItems > 0, metrics.numberOfColumns > 0, let collectionView else { return }
        let itemsInSection = min(metrics.numberOfItems, numberOfItems(in: section, collectionView: collectionView))
        guard itemsInSection > 0 else { return }

        for itemIndex in 0..<itemsInSection {
            let row = itemIndex / metrics.numberOfColumns
            let column = itemIndex % metrics.numberOfColumns

            let originX = Constants.insets.left + CGFloat(column) * (metrics.itemSize.width + Constants.spacing)
            let originY = yOffset + CGFloat(row) * (metrics.itemSize.height + Constants.spacing)

            let indexPath = IndexPath(item: itemIndex, section: section.rawValue)
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: originX, y: originY, width: metrics.itemSize.width, height: metrics.itemSize.height)
            cachedAttributes[indexPath] = attributes
            orderedAttributes.append(attributes)
        }

        yOffset += metrics.sectionHeight
    }
}

/// Root view for every item in a `PinnedTabLayout` grid. The layout gives
/// each item an exact frame and never takes a preferred size back (it keeps
/// `shouldInvalidateLayout(forPreferredLayoutAttributes:withOriginalAttributes:)`
/// at its default, false), but `NSCollectionView` still asks each visible
/// item to fit itself — a full Auto Layout fitting pass per item — every
/// time the grid lays out, which is every frame of a sidebar resize. The
/// layout's attributes are returned as they are. (`NSView` answers the
/// `NSCollectionViewElement` requirement in a category Swift does not see, so
/// this implements it through the conformance rather than an `override`.)
class PinnedGridItemView: NSView, NSCollectionViewElement {
    func preferredLayoutAttributesFitting(
        _ layoutAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }
}
