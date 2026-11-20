// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class WebContentHeaderWidthTests: XCTestCase {
    /// The centered location bar anchor is as wide as an address bar when
    /// the header has room, and narrows with a narrow header. It must not
    /// hold the header open: a split view places its divider below
    /// `defaultHigh`, and the sidebar column could not widen past it.
    func testTheCenteredAnchorNarrowsWithTheHeaderInsteadOfWideningIt() throws {
        let (header, width) = makeHeader(width: 400)
        let anchor = try XCTUnwrap(centeredAnchor(in: header))

        XCTAssertEqual(header.frame.width, 400, accuracy: 0.5, "the header keeps the width it is given")
        XCTAssertEqual(anchor.frame.width, 400 - 2 * WebContentHeader.centeredLocationBarAnchorInset, accuracy: 0.5)

        width.constant = 1000
        header.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(anchor.frame.width, WebContentHeader.centeredLocationBarAnchorWidth, accuracy: 0.5)
    }

    /// A header in a container whose width is held at the priority a split
    /// view's divider has.
    private func makeHeader(width: CGFloat) -> (WebContentHeader, NSLayoutConstraint) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 100))
        let header = WebContentHeader(browserState: nil)
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        let widthConstraint = header.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            widthConstraint,
        ])
        container.layoutSubtreeIfNeeded()
        return (header, widthConstraint)
    }

    private func centeredAnchor(in header: WebContentHeader) -> NSView? {
        header.subviews.first { String(describing: type(of: $0)) == "CenteredLocationBarAnchorView" }
    }
}
