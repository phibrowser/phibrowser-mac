// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit

struct PinnedTabItemModel: Hashable {
    let id: String
    let title: String
    let icon: NSImage?
    let tooltip: String?

    init(id: String, title: String, icon: NSImage?, tooltip: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PinnedTabItemModel, rhs: PinnedTabItemModel) -> Bool {
        lhs.id == rhs.id
    }
}

class PinnedExtensionItem: NSCollectionViewItem {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier { .init(rawValue: "\(Self.self)") }

    var itemClicked: ((PinnedTabItemModel, NSView) -> Void)?

    private var iconImageView: NSImageView!
    private var backgroundView: HoverableView!
    private var model: PinnedTabItemModel?

    override func loadView() {
        view = NSView()
        setupUI()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconImageView.image = nil
        view.toolTip = nil
        model = nil
    }

    func configure(with model: PinnedTabItemModel) {
        self.model = model
        iconImageView.image = model.icon ?? defaultIcon()
        view.toolTip = model.tooltip ?? model.title
    }

    override var isSelected: Bool {
        didSet {
            updateSelectedState()
        }
    }
}

// MARK: - UI Setup
private extension PinnedExtensionItem {
    func setupUI() {
        view.wantsLayer = true

        backgroundView = HoverableView()
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.backgroundColor = .sidebarTabHovered
        backgroundView.hoveredColor = .sidebarTabHoveredColorEmphasized
        backgroundView.selectedColor = .sidebarTabSelected
        backgroundView.enableClickAnimation = true
        backgroundView.clickAction = { [weak self] in
            guard let self, let model else { return }
            itemClicked?(model, backgroundView)
        }

        iconImageView = NSImageView()
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerRadius = 4

        view.addSubview(backgroundView)
        backgroundView.addSubview(iconImageView)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(2)
        }

        iconImageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(CGSize(width: 16, height: 16))
        }
    }

    func updateSelectedState() {
        if isSelected {
            backgroundView.isSelected = true
            backgroundView.layer?.borderWidth = 2
            backgroundView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            backgroundView.isSelected = false
            backgroundView.layer?.borderWidth = 0
            backgroundView.layer?.borderColor = NSColor.clear.cgColor
        }
    }

    func defaultIcon() -> NSImage? {
        NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
    }
}
