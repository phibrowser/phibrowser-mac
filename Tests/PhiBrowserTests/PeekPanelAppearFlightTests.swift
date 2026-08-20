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

    private func transform(pressAt press: CGPoint,
                           panelFrame: CGRect? = nil,
                           startWidth: CGFloat? = nil) -> CATransform3D? {
        PeekPanelController.appearFlightTransform(
            originScreenPoint: press,
            panelScreenFrame: panelFrame ?? panel,
            startWidth: startWidth ?? self.startWidth
        )
    }

    /// The card the flight starts from, in the panel's own coordinates: the
    /// panel's bounds mapped through the transform about the layer's centre
    /// anchor, the way Core Animation applies it.
    private func startCard(_ transform: CATransform3D, panelSize: CGSize) -> CGRect {
        let affine = CATransform3DGetAffineTransform(transform)
        let centre = CGPoint(x: panelSize.width / 2, y: panelSize.height / 2)
        let lowerLeft = CGPoint(x: -centre.x, y: -centre.y).applying(affine)
        let upperRight = centre.applying(affine)
        return CGRect(x: lowerLeft.x + centre.x,
                      y: lowerLeft.y + centre.y,
                      width: upperRight.x - lowerLeft.x,
                      height: upperRight.y - lowerLeft.y)
    }

    private func assertCard(_ transform: CATransform3D?,
                            centredAt expected: CGPoint,
                            line: UInt = #line) {
        guard let transform else {
            return XCTFail("expected a flight", line: line)
        }
        let card = startCard(transform, panelSize: panel.size)
        XCTAssertEqual(card.width, cardSize.width, accuracy: 0.001, line: line)
        XCTAssertEqual(card.height, cardSize.height, accuracy: 0.001, line: line)
        XCTAssertEqual(card.midX, expected.x, accuracy: 0.001, line: line)
        XCTAssertEqual(card.midY, expected.y, accuracy: 0.001, line: line)
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
