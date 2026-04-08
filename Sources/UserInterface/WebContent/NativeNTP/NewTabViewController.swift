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
        imageView.image = .nativeNTPIcon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        return imageView
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
    }

    private func setupViews() {
        view.addSubview(scrollView)
        scrollView.documentView = contentView

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        addChild(omniBoxController)
        contentView.addSubview(iconImageView)
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

        let contentWidth = max(omniSize.width, iconSize.width)
        let contentHeight = iconSize.height + contentSpacing + omniSize.height
        let collapsedContentHeight = iconSize.height + contentSpacing + collapsedOmniBoxHeight

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

        let omniX = originX + (contentWidth - omniSize.width) / 2
        let omniY = originY + 50
        omniBoxController.view.frame = NSRect(x: omniX, y: omniY, width: omniSize.width, height: omniSize.height)

        let iconX = originX + (contentWidth - iconSize.width) / 2
        let iconY = omniBoxController.view.frame.maxY + contentSpacing
        iconImageView.frame = NSRect(x: iconX, y: iconY, width: iconSize.width, height: iconSize.height)

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

extension NewTabViewController: OmniBoxActionDelegate {
    func omniBoxDidClear() {
        setNativeControlsHidden(true)
        omniBoxController.reset()
    }
}
