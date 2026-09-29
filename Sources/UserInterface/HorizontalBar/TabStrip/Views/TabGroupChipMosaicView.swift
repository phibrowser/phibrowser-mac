// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Describes what goes in one of the four 2×2 mosaic slots of a
/// collapsed tab-group chip. Pure data; computed from `memberCount` by
/// `TabGroupChipMosaicView.fillCells(memberCount:)` and consumed by the
/// view to decide per-slot rendering.
///
/// - `favicon(index:)`: render the favicon at `memberFavicons[index]`,
///   falling back to the empty placeholder when the data is nil.
/// - `empty`: render the light-grey placeholder.
/// - `overflow(count:)`: render the "+count" count cell (only ever
///   appears in slot 3, only when `memberCount >= 5`).
enum MosaicCellContent: Equatable, Sendable {
    case favicon(index: Int)
    case empty
    case overflow(count: Int)
}

/// 2×2 favicon mosaic shown inside a collapsed tab-group chip in
/// full mode.
///
/// The view is purely presentational: it accepts `memberFavicons`
/// (`[Data?]` of length `min(memberCount, 4)`) and `memberCount`
/// via `configure(memberFavicons:memberCount:)`, and uses
/// `fillCells(memberCount:)` to decide what goes in each of the
/// four slots.
final class TabGroupChipMosaicView: NSView {

    // MARK: - Metrics

    /// Outer mosaic frame: 28×28, replacing the count-badge slot in
    /// the 32pt collapsed chip. Cells are inset by `cellMargin` so the
    /// 2×2 grid of 10×10 cells sits cleanly inside.
    static let mosaicSize: CGFloat = 28
    static let cellSize: CGFloat = 10
    static let cellGap: CGFloat = 2
    static let cellMargin: CGFloat = 3
    /// Soft-corner cell clipping so favicons read as unified mosaic
    /// tiles rather than a grid of disparate logos.
    static let cellCornerRadius: CGFloat = 2

    // MARK: - Pure fill model

    /// Maps a group's `memberCount` to the four-slot content
    /// descriptor used to render the mosaic. Position 0 is
    /// top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    ///
    /// Rules:
    /// - `memberCount == 0`: all empty.
    /// - `1 ≤ memberCount ≤ 4`: fill slots `0..<memberCount` with
    ///   `.favicon(index:)`, remainder `.empty`.
    /// - `memberCount ≥ 5`: slots 0–2 are favicons, slot 3 is
    ///   `.overflow(count: memberCount - 3)`.
    static func fillCells(memberCount: Int) -> [MosaicCellContent] {
        precondition(memberCount >= 0, "memberCount must be non-negative")
        guard memberCount > 0 else {
            return [.empty, .empty, .empty, .empty]
        }
        if memberCount <= 4 {
            return (0..<4).map { i in
                i < memberCount ? .favicon(index: i) : .empty
            }
        }
        return [
            .favicon(index: 0),
            .favicon(index: 1),
            .favicon(index: 2),
            .overflow(count: memberCount - 3),
        ]
    }

    // MARK: - Subviews / sublayers

    /// Four cell layers, indexed 0..3 matching slot positions
    /// (TL, TR, BL, BR). Each layer either renders a favicon
    /// (via `contents = CGImage`) or the empty-placeholder grey
    /// (via `backgroundColor`).
    private let cellLayers: [CALayer] = (0..<4).map { _ in
        let layer = CALayer()
        layer.cornerRadius = cellCornerRadius
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspectFill
        // Suppress implicit animations for properties we manage.
        layer.actions = [
            "contents": NSNull(),
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
        ]
        return layer
    }

    /// Overflow text layer rendered in slot 3 when
    /// `memberCount >= 5`. Hidden otherwise.
    ///
    /// Implemented as `CATextLayer` rather than `NSTextField` because
    /// at the mosaic's small dimensions (8pt font in a 10pt cell),
    /// `NSTextField`'s cell-baseline rendering clips the glyphs to
    /// zero height. `CATextLayer` draws text directly without
    /// `NSTextField`'s cell baseline / padding constraints.
    private let overflowLayer: CATextLayer = {
        let layer = CATextLayer()
        let font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        // Both `font` (used for metric calculations) and `fontSize`
        // (used for rendering) must be set.
        layer.font = font
        layer.fontSize = 8
        layer.alignmentMode = .center
        layer.truncationMode = .none
        layer.isWrapped = false
        // Suppress implicit animations for properties we manage.
        layer.actions = [
            "contents": NSNull(),
            "string": NSNull(),
            "foregroundColor": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
        ]
        return layer
    }()

    /// Cache: decoded `CGImage` keyed by favicon `Data` value.
    /// Swift `Data` conforms to `Hashable` based on content, so
    /// looking up by the `Data` itself gives us a content-keyed
    /// cache for free. Avoids re-decoding the same favicon bytes
    /// on every layout pass / appearance change.
    ///
    /// Growth is bounded by the number of distinct favicon
    /// payloads the user encounters; favicons are small (typically
    /// <2 KB) and uncached on session end (held only by this
    /// view), so unbounded growth is not a practical concern for
    /// v1. Revisit if profiling shows memory pressure.
    private var decodedCache: [Data: CGImage] = [:]

    // MARK: - State (set by configure)

    private(set) var memberFavicons: [Data?] = []
    private(set) var memberCount: Int = 0

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        cellLayers.forEach { layer?.addSublayer($0) }
        layer?.addSublayer(overflowLayer)
        overflowLayer.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `CATextLayer` does not auto-pick the screen scale; without
    /// this the "+N" glyph renders blurry on retina displays. Update
    /// every time the view moves to a window (which may have a
    /// different backing scale factor than the previous one).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            overflowLayer.contentsScale = scale
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.mosaicSize, height: Self.mosaicSize)
    }

    // MARK: - Configuration

    /// Pushes new render state. `memberFavicons` is the favicon
    /// `Data?` for the first `min(memberCount, 4)` members; index
    /// `i` in this array maps to slot `i` for `.favicon(index: i)`
    /// content. Called by `TabGroupChipView` once per chip
    /// configure pass, plus by `TabStrip.refreshChipMosaic(for:)`
    /// when a member's favicon data changes.
    func configure(memberFavicons: [Data?], memberCount: Int) {
        self.memberFavicons = memberFavicons
        self.memberCount = memberCount
        applyAppearance()
        needsLayout = true
    }

    // MARK: - Appearance

    /// Colors resolved per-call (re-runs on `viewDidChangeEffectiveAppearance`).
    private static let emptySlotLight = NSColor(calibratedWhite: 0, alpha: 0.04)
    private static let emptySlotDark = NSColor(calibratedWhite: 1, alpha: 0.04)
    private static let overflowTextLight = NSColor(calibratedWhite: 0, alpha: 0.3)
    private static let overflowTextDark = NSColor(calibratedWhite: 1, alpha: 0.3)

    private func currentEmptySlotColor() -> NSColor {
        isDarkAppearance() ? Self.emptySlotDark : Self.emptySlotLight
    }
    private func currentOverflowTextColor() -> NSColor {
        isDarkAppearance() ? Self.overflowTextDark : Self.overflowTextLight
    }

    private func isDarkAppearance() -> Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Drives per-slot rendering based on `MosaicCellContent`.
    /// Idempotent — safe to re-call on every configure / appearance
    /// change.
    private func applyAppearance() {
        let cells = Self.fillCells(memberCount: memberCount)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (i, content) in cells.enumerated() {
            let layer = cellLayers[i]
            layer.isHidden = false
            switch content {
            case .favicon(let dataIndex):
                let data = (dataIndex < memberFavicons.count) ? memberFavicons[dataIndex] : nil
                if let image = decodedImage(for: data) {
                    layer.contents = image
                    layer.backgroundColor = NSColor.clear.cgColor
                } else {
                    layer.contents = nil
                    layer.backgroundColor = currentEmptySlotColor().cgColor
                }
            case .empty:
                layer.contents = nil
                layer.backgroundColor = currentEmptySlotColor().cgColor
            case .overflow:
                // No cell background — the "+N" text in overflowLayer
                // alone carries the overflow signal. Clears any stale
                // background from previous .empty / .favicon states.
                layer.contents = nil
                layer.backgroundColor = NSColor.clear.cgColor
            }
        }

        // Overflow text layer: only visible when slot 3 is `.overflow`.
        // ≤9 renders the exact "+N" (e.g., "+5"); ≥10 collapses to an
        // ellipsis to signal "many more" without a misleading precise
        // number in the 10pt slot.
        if case .overflow(let count) = cells[3] {
            overflowLayer.string = count <= 9 ? "+\(count)" : "..."
            overflowLayer.foregroundColor = currentOverflowTextColor().cgColor
            overflowLayer.isHidden = false
        } else {
            overflowLayer.isHidden = true
            overflowLayer.string = nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Decode favicon `Data` → `CGImage` with a content-keyed
    /// cache. Swift `Data` conforms to `Hashable` based on the
    /// byte sequence, so the same favicon bytes always hit the
    /// same cache entry — no need for a separate fingerprint or
    /// `Tab` identity tracking.
    ///
    /// Returns nil for nil/empty data or when `NSImage` fails to
    /// decode (e.g., truncated or unrecognized format) so the
    /// caller falls back to the empty-slot placeholder.
    private func decodedImage(for data: Data?) -> CGImage? {
        guard let data, !data.isEmpty else { return nil }
        if let cached = decodedCache[data] { return cached }
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        decodedCache[data] = cgImage
        return cgImage
    }

    // MARK: - Layout

    /// Frame for slot `i` (0=TL, 1=TR, 2=BL, 3=BR) inside our
    /// `bounds`. Cells form a 2×2 grid with `cellGap` between them
    /// and `cellMargin` inset from the outer edges.
    /// AppKit's default coordinate system is unflipped (Y=0 at
    /// bottom), so slots 0/1 (visually top) get the LARGER Y.
    static func frameForSlot(_ i: Int, in bounds: CGRect) -> CGRect {
        let originX = bounds.minX + cellMargin
            + (i % 2 == 0 ? 0 : cellSize + cellGap)
        let originY = bounds.minY + cellMargin
            + (i < 2 ? cellSize + cellGap : 0)
        return CGRect(x: originX, y: originY,
                      width: cellSize, height: cellSize)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            cellLayers[i].frame = Self.frameForSlot(i, in: bounds)
        }
        // Overflow text layer overlays slot 3 at its native frame.
        // The 8pt glyph in a 10pt-tall layer falls close enough to the
        // visual center via `CATextLayer`'s default top-anchored
        // rendering — no extra Y shift needed.
        let slot3 = Self.frameForSlot(3, in: bounds)
        overflowLayer.frame = slot3
        CATransaction.commit()
    }
}
