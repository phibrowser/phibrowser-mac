// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// How one Space lays out its pinned tabs in the sidebar: how many tiles
/// share a row and how far apart they sit. Stored per Space by
/// `SpaceManager.pinnedTabGridStyle(forSpaceId:)`; a Space without an entry
/// uses `automatic`, the grid as it has always been.
struct PinnedTabGridStyle: Codable, Equatable {
    /// The gap between tiles, across and down.
    enum Spacing: String, Codable, CaseIterable {
        case standard
        case compact

        var points: CGFloat {
            switch self {
            case .standard: return 8
            case .compact: return 4
            }
        }
    }

    /// The tile counts a Space can fix its rows at.
    static let columnChoices = 3...6
    static let automatic = PinnedTabGridStyle()

    /// The settings one Space can copy to every other Space.
    struct Parts: OptionSet {
        let rawValue: Int
        static let columns = Parts(rawValue: 1 << 0)
        static let spacing = Parts(rawValue: 1 << 1)
    }

    /// Tiles per row. Nil follows the sidebar's width.
    var columns: Int?
    var spacing: Spacing = .standard

    /// This style with `parts` taken from `source` and the rest kept.
    func copying(_ parts: Parts, from source: PinnedTabGridStyle) -> PinnedTabGridStyle {
        var copy = self
        if parts.contains(.columns) { copy.columns = source.columns }
        if parts.contains(.spacing) { copy.spacing = source.spacing }
        return copy
    }
}

extension Notification.Name {
    /// Posted by `SpaceManager` when one or more Spaces get a new pinned tab
    /// grid style. `userInfo["spaceIds"]` lists them.
    static let pinnedTabGridStyleDidChange = Notification.Name("PhiPinnedTabGridStyleDidChangeNotification")
}

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
        let style: PinnedTabGridStyle
    }

    private enum Constants {
        static let insets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        static let tabHeight: CGFloat = 45
        static let extensionHeight: CGFloat = 28
        static let tabMinimumWidth: CGFloat = 53
        static let extensionMinimumWidth: CGFloat = 26
    }

    /// Gaps before the first row and after the last row of the grid.
    let topInset: CGFloat
    let bottomInset: CGFloat

    private var pendingConfiguredWidth: CGFloat?
    private var lastPreparedInput: LayoutInput?
    private var cachedAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var orderedAttributes: [NSCollectionViewLayoutAttributes] = []
    private var contentSize: NSSize = .zero

    private var tabMetrics: SectionMetrics = .empty
    private var extensionMetrics: SectionMetrics = .empty

    /// The Space's row count and spacing. Setting a new style lays the grid
    /// out again on the next pass.
    var style: PinnedTabGridStyle = .automatic {
        didSet {
            guard style != oldValue else { return }
            invalidateLayout()
        }
    }

    init(topInset: CGFloat, bottomInset: CGFloat) {
        self.topInset = topInset
        self.bottomInset = bottomInset
        super.init()
    }

    override convenience init() {
        self.init(topInset: Constants.insets.top, bottomInset: Constants.insets.bottom)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        let input = LayoutInput(contentWidth: parentWidth, tabCount: tabCount, extensionCount: extensionCount, style: style)
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
        let input = LayoutInput(contentWidth: contentWidth, tabCount: tabCount, extensionCount: extensionCount, style: style)

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

    /// Columns and tile width for the pinned tabs. Automatic fits as many
    /// tiles as the sidebar's width allows, up to one per pin. A fixed count
    /// sizes every tile as one of that many columns, so a tile keeps its
    /// width however many pins there are, and lets tiles go narrower than
    /// the automatic minimum.
    static func tabGrid(itemCount: Int, contentWidth: CGFloat, style: PinnedTabGridStyle) -> (columns: Int, itemWidth: CGFloat) {
        let spacing = style.spacing.points
        guard let fixed = style.columns else {
            return grid(itemCount: itemCount, contentWidth: contentWidth, spacing: spacing,
                        columnLimit: tabColumnsLimit(for: contentWidth), minimumWidth: Constants.tabMinimumWidth)
        }
        let columns = max(1, fixed)
        return (columns, max(1, rowWidth(for: contentWidth, columns: columns, spacing: spacing)))
    }

    /// Fits up to `columnLimit` columns of at least `minimumWidth`, never
    /// more than there are items, and widens them to fill the row.
    static func grid(itemCount: Int, contentWidth: CGFloat, spacing: CGFloat,
                     columnLimit: Int, minimumWidth: CGFloat) -> (columns: Int, itemWidth: CGFloat) {
        var columns = max(1, min(columnLimit, itemCount))
        while columns > 1, rowWidth(for: contentWidth, columns: columns, spacing: spacing) < minimumWidth {
            columns -= 1
        }
        return (columns, max(minimumWidth, rowWidth(for: contentWidth, columns: columns, spacing: spacing)))
    }

    /// The width each of `columns` tiles gets inside the grid's insets.
    private static func rowWidth(for contentWidth: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        let availableWidth = max(contentWidth - Constants.insets.left - Constants.insets.right, 0)
        return (availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)
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

        let spacing = input.style.spacing.points
        let extensionMaxColumns = extensionColumnsLimit(for: input.contentWidth)
        extensionMetrics = metrics(for: input.extensionCount, itemHeight: Constants.extensionHeight, spacing: spacing,
                                   grid: Self.grid(itemCount: input.extensionCount, contentWidth: input.contentWidth, spacing: spacing,
                                                   columnLimit: extensionMaxColumns, minimumWidth: Constants.extensionMinimumWidth))
        tabMetrics = metrics(for: input.tabCount, itemHeight: Constants.tabHeight, spacing: spacing,
                             grid: Self.tabGrid(itemCount: input.tabCount, contentWidth: input.contentWidth, style: input.style))

        let hasExtensions = extensionMetrics.numberOfItems > 0
        let hasTabs = tabMetrics.numberOfItems > 0
        var yOffset: CGFloat = 0
        if hasExtensions || hasTabs {
            yOffset = topInset
        }

        if hasExtensions {
            layout(section: .extensions, metrics: extensionMetrics, spacing: spacing, yOffset: &yOffset)
        }

        if hasTabs {
            if hasExtensions {
                yOffset += spacing
            }
            layout(section: .tabs, metrics: tabMetrics, spacing: spacing, yOffset: &yOffset)
        }

        if hasExtensions || hasTabs {
            yOffset += bottomInset
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
    static func columnDecisionWidth(for contentWidth: CGFloat) -> CGFloat {
        max(contentWidth - Constants.insets.right, 0)
    }

    static func tabColumnsLimit(for contentWidth: CGFloat) -> Int {
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
        let width = Self.columnDecisionWidth(for: contentWidth)
        if width <= 250 {
            return 5
        } else if width <= 350 {
            return 7
        } else {
            return 10
        }
    }

    private func metrics(for itemCount: Int, itemHeight: CGFloat, spacing: CGFloat, grid: (columns: Int, itemWidth: CGFloat)) -> SectionMetrics {
        guard itemCount > 0 else {
            return .empty
        }
        let rows = Int(ceil(Double(itemCount) / Double(grid.columns)))
        let sectionHeight = CGFloat(rows) * itemHeight + CGFloat(max(0, rows - 1)) * spacing
        return SectionMetrics(
            numberOfItems: itemCount,
            numberOfColumns: grid.columns,
            numberOfRows: rows,
            itemSize: NSSize(width: grid.itemWidth, height: itemHeight),
            sectionHeight: sectionHeight
        )
    }

    private func layout(section: Section, metrics: SectionMetrics, spacing: CGFloat, yOffset: inout CGFloat) {
        guard metrics.numberOfItems > 0, metrics.numberOfColumns > 0, let collectionView else { return }
        let itemsInSection = min(metrics.numberOfItems, numberOfItems(in: section, collectionView: collectionView))
        guard itemsInSection > 0 else { return }

        for itemIndex in 0..<itemsInSection {
            let row = itemIndex / metrics.numberOfColumns
            let column = itemIndex % metrics.numberOfColumns

            let originX = Constants.insets.left + CGFloat(column) * (metrics.itemSize.width + spacing)
            let originY = yOffset + CGFloat(row) * (metrics.itemSize.height + spacing)

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
