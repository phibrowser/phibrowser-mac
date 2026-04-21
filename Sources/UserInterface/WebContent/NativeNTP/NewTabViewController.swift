// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

final class NewTabViewController: NSViewController {
    private let browserState: BrowserState
    private var cancellables = Set<AnyCancellable>()

    private let iconSize = NSSize(width: 64, height: 64)
    private let contentSpacing: CGFloat = 40
    private let collapsedOmniBoxHeight: CGFloat = 57
    private var areControlsHidden = false

    private lazy var omniBoxController: OmniBoxViewController = {
        let controller = OmniBoxViewController(viewModel: .init(windowState: browserState), state: browserState)
        controller.setActionDelegate(self)
        return controller
    }()

    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        return scrollView
    }()

    private let contentView = NSView()

    private lazy var iconImageView: NSImageView = {
        let imageView = NSImageView()
        if browserState.isIncognito {
            imageView.image = .nativeNTPIncognito
        } else {
            imageView.image = .nativeNTPIcon
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        return imageView
    }()
    
    private lazy var incognitoLabel: NSTextField = {
        let tf = NSTextField()
        tf.stringValue = NSLocalizedString("Incognito", comment: "Incognito label in the native new tab page")
        tf.font = NSFont(name: "IvyPrestoHeadline-Light", size: 21)
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.alignment = .center
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byClipping
        tf.maximumNumberOfLines = 1
        tf.textColor = .primaryLabel
        tf.allowsDefaultTighteningForTruncation = false
        return tf
    }()

    init(state: BrowserState) {
        self.browserState = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.contentOverlayBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupObservers()
        updateContentLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        omniBoxController.focusTextField()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContentLayout()
    }

    func updateForTab(_ tab: Tab?) {
        setNativeControlsHidden(false)
        omniBoxController.setCurrentTabForNavigation(tab)
    }

    func focusOmnibox() {
        omniBoxController.focusTextField()
    }
    
    private func setNativeControlsHidden(_ hidden: Bool) {
        guard areControlsHidden != hidden else { return }
        areControlsHidden = hidden
        iconImageView.isHidden = hidden
        omniBoxController.view.isHidden = hidden
        incognitoLabel.isHidden = hidden
    }

    private func setupViews() {
        view.addSubview(scrollView)
        scrollView.documentView = contentView

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        addChild(omniBoxController)
        contentView.addSubview(iconImageView)
        contentView.addSubview(incognitoLabel)
        contentView.addSubview(omniBoxController.view)

        omniBoxController.view.translatesAutoresizingMaskIntoConstraints = true
        omniBoxController.view.autoresizingMask = []
    }

    private func setupObservers() {
        omniBoxController.$contentSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateContentLayout()
            }
            .store(in: &cancellables)
    }

    private func updateContentLayout() {
        guard isViewLoaded else { return }
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }
        let omniSize = omniBoxController.contentSize
        
        // Measure incognito label size using the cell to include internal padding
        var labelSize: NSSize
        if let cell = incognitoLabel.cell {
            labelSize = cell.cellSize
        } else {
            labelSize = incognitoLabel.attributedStringValue.size()
        }
        // Ceil to whole pixels and add 2pt padding to avoid last character clipping
        labelSize.width = ceil(labelSize.width) + 2
        labelSize.height = ceil(labelSize.height)
        let labelHeight = labelSize.height

        // Content size includes icon, label (6pt below icon), and omni (48pt below label)
        let contentWidth = max(omniSize.width, iconSize.width, labelSize.width)
        let contentHeight = iconSize.height + 6 + labelHeight + 48 + omniSize.height
        let collapsedContentHeight = iconSize.height + 6 + labelHeight + 48 + collapsedOmniBoxHeight

        let documentWidth = max(contentWidth, clipSize.width)
        let documentHeight = max(contentHeight, clipSize.height)
        contentView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)

        let originX = (documentWidth - contentWidth) / 2
        let anchorTop = (clipSize.height + collapsedContentHeight) / 2
        let originY: CGFloat
        if contentHeight <= clipSize.height {
            originY = max(anchorTop - contentHeight, 0)
        } else {
            originY = 0
        }

        // Position icon at the top of our content column
        let iconX = originX + (contentWidth - iconSize.width) / 2
        let iconY = originY + (iconSize.height + 6 + labelHeight + 48 + omniSize.height) - iconSize.height
        iconImageView.frame = NSRect(x: iconX, y: iconY, width: iconSize.width, height: iconSize.height)

        // Position label 6pt below the icon, centered horizontally
        let labelX = originX + (contentWidth - labelSize.width) / 2
        let labelY = iconImageView.frame.minY - 6 - labelHeight
        incognitoLabel.frame = NSRect(x: labelX, y: labelY, width: labelSize.width, height: labelHeight)

        // Position omnibox 48pt below the label
        let omniX = originX + (contentWidth - omniSize.width) / 2
        let omniY = incognitoLabel.frame.minY - 48 - omniSize.height
        omniBoxController.view.frame = NSRect(x: omniX, y: omniY, width: omniSize.width, height: omniSize.height)

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

extension NewTabViewController: OmniBoxActionDelegate {
    func omniBoxDidClear() {
        setNativeControlsHidden(true)
        omniBoxController.reset()
    }
}

