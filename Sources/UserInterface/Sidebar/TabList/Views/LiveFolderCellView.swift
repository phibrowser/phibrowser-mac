// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

private final class LiveFolderIconState: ObservableObject {
    @Published var isExpanded = false
}

private struct LiveFolderIconContent: View {
    @ObservedObject var state: LiveFolderIconState

    var body: some View {
        BookmarkFolderIconView(icon: .github, isExpanded: state.isExpanded)
            .frame(width: 20, height: 20)
            .clipped()
            .allowsHitTesting(false)
    }
}

final class LiveFolderCellView: SidebarCellView {
    private static let unreadDotSize: CGFloat = 6

    private let iconView = NSImageView()
    private let folderIconState = LiveFolderIconState()
    private lazy var folderIconView = ThemedHostingView(rootView: LiveFolderIconContent(state: folderIconState))
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let unreadDot = NSView()
    private let statusView = NSImageView()
    private let spinner = NSProgressIndicator()
    private lazy var removeButton: NSButton = {
        let button = NSButton(image: Self.symbol("xmark"), target: self, action: #selector(removeClicked))
        button.isBordered = false
        button.isHidden = true
        button.toolTip = NSLocalizedString("sidebar.liveFolder.removeRowButton", value: "Remove from Folder", comment: "Sidebar live folder row - Tooltip of the button that hides this pull request")
        return button
    }()

    private var hoverArea: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconView.contentTintColor = .secondaryLabelColor
        statusView.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.phi.setTextColor(.textPrimary)
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.phi.setTextColor(.textTertiary)
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        unreadDot.wantsLayer = true
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        unreadDot.layer?.cornerRadius = Self.unreadDotSize / 2

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusView.image = Self.symbol("exclamationmark.triangle")

        for view in [iconView, folderIconView, textStack, unreadDot, statusView, spinner, removeButton] as [NSView] {
            addSubview(view)
        }
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
        folderIconView.sizingOptions = []
        folderIconView.snp.makeConstraints { make in
            make.center.equalTo(iconView)
            make.size.equalTo(20)
        }
        textStack.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualToSuperview().offset(-28)
            make.centerY.equalToSuperview()
        }
        for view in [statusView, spinner, removeButton] as [NSView] {
            view.snp.makeConstraints { make in
                make.trailing.equalToSuperview().offset(-8)
                make.centerY.equalToSuperview()
                make.size.equalTo(16)
            }
        }
        unreadDot.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
            make.size.equalTo(Self.unreadDotSize)
        }
    }

    override func configure(with item: SidebarItem) {
        cancellables.removeAll()
        super.configure(with: item)
        if let folder = item as? LiveFolderSidebarItem {
            folder.$data.combineLatest(folder.$isRefreshing)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in self?.configureFolder(folder) }
                .store(in: &cancellables)
        } else if let rowItem = item as? LiveFolderRowItem {
            rowItem.$row
                .receive(on: DispatchQueue.main)
                .sink { [weak self] row in self?.configureRow(row) }
                .store(in: &cancellables)
            rowItem.browserState?.$focusingTab
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak rowItem] tab in
                    self?.setRowActive(tab?.guidInLocalDB == rowItem?.row.tabMarker)
                }
                .store(in: &cancellables)
        } else {
            configureSignIn(item)
        }
    }

    private func configureFolder(_ folder: LiveFolderSidebarItem) {
        iconView.isHidden = true
        folderIconView.isHidden = false
        folderIconState.isExpanded = folder.data.isExpanded
        titleLabel.stringValue = folder.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.isHidden = true
        unreadDot.isHidden = true
        removeButton.isHidden = true
        statusView.isHidden = folder.isRefreshing || folder.statusText == nil
        statusView.toolTip = folder.statusText
        if folder.isRefreshing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func setRowActive(_ active: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = active ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
    }

    private func configureRow(_ row: LiveFolderRow) {
        iconView.isHidden = false
        folderIconView.isHidden = true
        iconView.image = Self.symbol(row.isDraft ? "pencil.circle" : "arrow.triangle.pull")
        titleLabel.stringValue = row.title
        titleLabel.font = .systemFont(ofSize: 13, weight: row.isUnread ? .semibold : .regular)
        titleLabel.toolTip = row.title
        let detail = [row.repository, row.author].compactMap { $0 }.joined(separator: " · ")
        subtitleLabel.stringValue = detail
        subtitleLabel.isHidden = detail.isEmpty
        spinner.stopAnimation(nil)
        statusView.isHidden = true
        updateTrailingControls()
    }

    private func configureSignIn(_ item: SidebarItem) {
        iconView.isHidden = false
        folderIconView.isHidden = true
        iconView.image = Self.symbol("person.crop.circle.badge.exclamationmark")
        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.isHidden = true
        unreadDot.isHidden = true
        removeButton.isHidden = true
        statusView.isHidden = true
        spinner.stopAnimation(nil)
    }

    private func updateTrailingControls() {
        guard let rowItem = item as? LiveFolderRowItem else { return }
        removeButton.isHidden = !isHovering
        unreadDot.isHidden = isHovering || !rowItem.row.isUnread
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateTrailingControls()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateTrailingControls()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovering = false
        spinner.stopAnimation(nil)
        setRowActive(false)
    }

    @MainActor @objc private func removeClicked() {
        (item as? LiveFolderRowItem)?.removeFromFolder()
    }

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? image
    }
}
