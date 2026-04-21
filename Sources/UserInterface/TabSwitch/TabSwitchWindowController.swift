// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

protocol TabSwitchWindowControllerDelegate: AnyObject {
    func tabSwitchWindowDidClickItem(tabID: Int)
    func tabSwitchWindowDidHoverItem(tabID: Int)
}

final class TabSwitchWindowController: NSWindowController {
    weak var selectionDelegate: TabSwitchWindowControllerDelegate?
    private var cellViews: [TabSwitchCellView] = []
    private let containerView = NSView()
    private weak var themeProvider: ThemeStateProvider?
    private var displayedTabIDs: [Int] = []

    init(parentWindow: NSWindow) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear

        super.init(window: panel)

        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = TabSwitchMetrics.windowCornerRadius
        containerView.layer?.masksToBounds = true

        panel.contentView = containerView
        parentWindow.addChildWindow(panel, ordered: .above)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [TabSwitchItem], selectedTabID: Int, themeProvider: ThemeStateProvider) {
        self.themeProvider = themeProvider
        applyTheme(themeProvider)

        cellViews.forEach { $0.removeFromSuperview() }
        cellViews.removeAll()
        displayedTabIDs.removeAll()

        guard let parentWindow = window?.parent else { return }
        let metrics = TabSwitchMetrics.self

        let cellWidth = metrics.cellWidth
        let spacing = metrics.cellSpacing
        let count = items.count

        displayedTabIDs = items.map(\.tabID)

        let windowWidth = CGFloat(count) * cellWidth
            + CGFloat(max(0, count - 1)) * spacing
            + metrics.windowHorizontalInset * 2
        let windowHeight = metrics.cellHeight + metrics.windowVerticalInset * 2
        let windowX = parentWindow.frame.midX - windowWidth / 2
        let windowY = parentWindow.frame.midY - windowHeight / 2

        window?.setFrame(
            NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight),
            display: false
        )
        containerView.frame = NSRect(origin: .zero, size: NSSize(width: windowWidth, height: windowHeight))

        var x = metrics.windowHorizontalInset
        for item in items {
            let isSelected = item.tabID == selectedTabID
            let cell = TabSwitchCellView(frame: NSRect(
                x: x,
                y: metrics.windowVerticalInset,
                width: cellWidth,
                height: metrics.cellHeight
            ))
            cell.configure(with: item, themeProvider: themeProvider)
            cell.setHighlighted(isSelected, themeProvider: themeProvider)

            let tabID = item.tabID
            cell.onClicked = { [weak self] in
                self?.selectionDelegate?.tabSwitchWindowDidClickItem(tabID: tabID)
            }
            cell.onHovered = { [weak self] hovered in
                if hovered {
                    self?.selectionDelegate?.tabSwitchWindowDidHoverItem(tabID: tabID)
                }
            }
            containerView.addSubview(cell)
            cellViews.append(cell)
            x += cellWidth + spacing
        }
    }

    func updateSelection(selectedTabID: Int) {
        guard let provider = themeProvider else { return }
        for (i, cell) in cellViews.enumerated() {
            let isSelected = (i < displayedTabIDs.count && displayedTabIDs[i] == selectedTabID)
            cell.setHighlighted(isSelected, themeProvider: provider)
        }
    }

    private func applyTheme(_ provider: ThemeStateProvider) {
        let appearance = provider.currentAppearance
        let bgColor: NSColor = appearance.isDark ? .black : .white
        containerView.layer?.backgroundColor = bgColor.cgColor
        window?.appearance = appearance.nsAppearance
    }

    func dismiss() {
        if let panel = window, let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        window?.orderOut(nil)
    }
}
