// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The peek appear flight's pure rule: the panel shrunk to a link-sized card
/// sitting on the press that opened the peek, clamped to stay inside the
/// panel (the window clips whatever leaves its frame), and refused outright
/// for geometry that can't produce a sane flight.
final class PeekPanelAppearFlightTests: XCTestCase {
    private let panel = CGRect(x: 100, y: 200, width: 1200, height: 800)
    private let startWidth: CGFloat = 44
    private lazy var scale = startWidth / panel.width
    private lazy var cardSize = CGSize(width: startWidth, height: panel.height * scale)

    /// What `NSViewBackingLayer` actually reports — the layer's bottom-left,
    /// not the UIKit-familiar centre. The default here on purpose: these
    /// assertions have to describe the anchor the panel really flies about.
    private static let appKitAnchor = CGPoint.zero

    private func transform(pressAt press: CGPoint,
                           panelFrame: CGRect? = nil,
                           startWidth: CGFloat? = nil,
                           anchorPoint: CGPoint = appKitAnchor) -> CATransform3D? {
        PeekPanelController.appearFlightTransform(
            originScreenPoint: press,
            cardScreenFrame: panelFrame ?? panel,
            startWidth: startWidth ?? self.startWidth,
            anchorPoint: anchorPoint
        )
    }

    /// The card the flight starts from, in the panel's own coordinates —
    /// Core Animation's own mapping of a bounds point, `position + M·(p - a)`
    /// with `a` the anchor in bounds coordinates, so the assertions below
    /// measure what the render server will actually draw.
    private func startCard(_ transform: CATransform3D,
                           panelSize: CGSize,
                           anchorPoint: CGPoint) -> CGRect {
        let affine = CATransform3DGetAffineTransform(transform)
        let anchor = CGPoint(x: anchorPoint.x * panelSize.width,
                             y: anchorPoint.y * panelSize.height)
        func map(_ point: CGPoint) -> CGPoint {
            let mapped = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
                .applying(affine)
            return CGPoint(x: mapped.x + anchor.x, y: mapped.y + anchor.y)
        }
        let lowerLeft = map(.zero)
        let upperRight = map(CGPoint(x: panelSize.width, y: panelSize.height))
        return CGRect(x: lowerLeft.x,
                      y: lowerLeft.y,
                      width: upperRight.x - lowerLeft.x,
                      height: upperRight.y - lowerLeft.y)
    }

    private func assertCard(_ transform: CATransform3D?,
                            centredAt expected: CGPoint,
                            anchorPoint: CGPoint = appKitAnchor,
                            line: UInt = #line) {
        guard let transform else {
            return XCTFail("expected a flight", line: line)
        }
        let card = startCard(transform, panelSize: panel.size, anchorPoint: anchorPoint)
        XCTAssertEqual(card.width, cardSize.width, accuracy: 0.001, line: line)
        XCTAssertEqual(card.height, cardSize.height, accuracy: 0.001, line: line)
        XCTAssertEqual(card.midX, expected.x, accuracy: 0.001, line: line)
        XCTAssertEqual(card.midY, expected.y, accuracy: 0.001, line: line)
    }

    /// The regression this rule was rewritten for: `NSViewBackingLayer`
    /// anchors at (0, 0), so a rule written for a centred anchor left every
    /// flight starting from the card's bottom corner instead of the press.
    /// The card must land on the press under whichever anchor the layer
    /// reports, so the assertions above cannot silently encode the wrong one.
    func testLandsOnThePressWhicheverAnchorTheLayerReports() {
        let press = CGPoint(x: 400, y: 500)
        let centre = CGPoint(x: 0.5, y: 0.5)
        assertCard(transform(pressAt: press),
                   centredAt: CGPoint(x: 300, y: 300))
        assertCard(transform(pressAt: press, anchorPoint: centre),
                   centredAt: CGPoint(x: 300, y: 300),
                   anchorPoint: centre)
        // And the two are genuinely different transforms — the parameter is
        // load-bearing, not decoration.
        XCTAssertFalse(CATransform3DEqualToTransform(
            transform(pressAt: press)!,
            transform(pressAt: press, anchorPoint: centre)!))
    }

    func testStartsAsALinkSizedCardOnThePress() {
        // Screen (400, 500) is (300, 300) inside a panel pinned at (100, 200).
        assertCard(transform(pressAt: CGPoint(x: 400, y: 500)),
                   centredAt: CGPoint(x: 300, y: 300))
    }

    func testACentrePressIsAPureShrink() {
        assertCard(transform(pressAt: CGPoint(x: panel.midX, y: panel.midY)),
                   centredAt: CGPoint(x: panel.width / 2, y: panel.height / 2))
    }

    /// The panel is inset from the page pane, so a press near the pane's edge
    /// lands outside it — the card has to be pulled back in whole, or the
    /// panel window clips its first frames.
    func testClampsAPressOutsideThePanel() {
        assertCard(transform(pressAt: CGPoint(x: panel.minX - 40, y: panel.minY - 40)),
                   centredAt: CGPoint(x: cardSize.width / 2, y: cardSize.height / 2))
        assertCard(transform(pressAt: CGPoint(x: panel.maxX + 40, y: panel.maxY + 40)),
                   centredAt: CGPoint(x: panel.width - cardSize.width / 2,
                                      y: panel.height - cardSize.height / 2))
    }

    /// A press funds the peek it opened and nothing else. Mounting content in
    /// the panel happens both for a peek the user just opened and for
    /// switching to another opener's existing peek; only the former may fly,
    /// or a peek revealed minutes later flies out of an unrelated click.
    func testOnlyAFreshlyOpenedPeekMayFly() {
        // Nothing under this opener before: the user just opened it.
        XCTAssertTrue(MainBrowserWindowController.isFreshlyOpenedPeek(
            previousPeekTabIdsByOpener: [:], openerTabId: 1, peekTabId: 10))
        // Another opener's peek existing changes nothing for this one.
        XCTAssertTrue(MainBrowserWindowController.isFreshlyOpenedPeek(
            previousPeekTabIdsByOpener: [2: 20], openerTabId: 1, peekTabId: 10))
        // Switching back to a peek that was already mounted under its opener.
        XCTAssertFalse(MainBrowserWindowController.isFreshlyOpenedPeek(
            previousPeekTabIdsByOpener: [1: 10, 2: 20], openerTabId: 1, peekTabId: 10))
        // Same opener, different peek — the old one ended and a new one
        // opened, so this one is fresh.
        XCTAssertTrue(MainBrowserWindowController.isFreshlyOpenedPeek(
            previousPeekTabIdsByOpener: [1: 10], openerTabId: 1, peekTabId: 11))
    }

    func testRefusesGeometryThatCannotFly() {
        let press = CGPoint(x: 400, y: 500)
        XCTAssertNil(transform(pressAt: press, panelFrame: .zero))
        XCTAssertNil(transform(pressAt: press,
                               panelFrame: CGRect(x: 100, y: 200, width: 1200, height: 0)))
        XCTAssertNil(transform(pressAt: press, startWidth: 0))
        XCTAssertNil(transform(pressAt: press, startWidth: -10))
        // Not a shrink: a card as wide as the panel has nothing to fly out of.
        XCTAssertNil(transform(pressAt: press, startWidth: panel.width))
    }
}
