// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
class InsetTableRowView: NSTableRowView {
    private let insets: NSEdgeInsets
    private var cellConstraints: [NSLayoutConstraint] = []
    
    init(insets: NSEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview is NSTableCellView else { return }
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        ])
    }
}
