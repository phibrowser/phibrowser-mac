// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
#if DEBUG
import UniformTypeIdentifiers
#endif

private final class FallbackOverlayContainerView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82).cgColor
    }
}

private enum LiquidGlassAdaptor {
    private static let fallbackCornerRadius = LiquidGlassCompatible.webContentInnerComponentsCornerRadius

    static func wrappingContent(_ content: NSView, cornerRadius: CGFloat = fallbackCornerRadius) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            content.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            return glass
        }

        let container = FallbackOverlayContainerView(cornerRadius: cornerRadius)
        container.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        return container
    }
}

private final class CircularHoverButton: NSView {
    private let button = NSButton()
    private let hoverLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private let diameter: CGFloat

    weak var target: AnyObject? {
        get { button.target }
        set { button.target = newValue }
    }

    var action: Selector? {
        get { button.action }
        set { button.action = newValue }
    }

    var isButtonEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            button.alphaValue = newValue ? 1.0 : 0.4
        }
    }

    init(symbolName: String, accessibilityDescription: String, diameter: CGFloat = 28) {
        self.diameter = diameter
        super.init(frame: .zero)

        wantsLayer = true

        hoverLayer.cornerRadius = diameter / 2
        hoverLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverLayer)

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.toolTip = accessibilityDescription
        button.focusRingType = .none
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel(accessibilityDescription)
        addSubview(button)

        snp.makeConstraints { make in
            make.width.height.equalTo(diameter)
        }
        button.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hoverLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverLayer.backgroundColor = NSColor.clear.cgColor
        }
    }
}

final class ImagePreviewViewController: NSViewController {
    private let state: BrowserImagePreviewState
    private var cancellables = Set<AnyCancellable>()

    private let titleLabel = NSTextField(labelWithString: "")
    private let previousButton: CircularHoverButton
    private let nextButton: CircularHoverButton
    private let zoomOutButton: CircularHoverButton
    private let zoomInButton: CircularHoverButton
    private let zoomPercentLabel = NSTextField(labelWithString: "100%")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = ZoomableImageScrollView()

    private let leftNavStack = NSStackView()
    private let rightNavStack = NSStackView()
    private let bottomToolbarStack = NSStackView()
    private let centerOverlayStack = NSStackView()

    private let leftNavigation: NSView
    private let rightNavigation: NSView
    private let bottomToolbar: NSView

    init(state: BrowserImagePreviewState) {
        self.previousButton = CircularHoverButton(
            symbolName: "chevron.left",
            accessibilityDescription: NSLocalizedString(
                "Previous image",
                comment: "Image preview: accessibility label for previous image control"
            )
        )
        self.nextButton = CircularHoverButton(
            symbolName: "chevron.right",
            accessibilityDescription: NSLocalizedString(
                "Next image",
                comment: "Image preview: accessibility label for next image control"
            )
        )
        self.zoomOutButton = CircularHoverButton(
            symbolName: "minus.magnifyingglass",
            accessibilityDescription: NSLocalizedString(
                "Zoom out",
                comment: "Image preview: accessibility label for zoom out control"
            ),
            diameter: 24
        )
        
        self.zoomInButton = CircularHoverButton(
            symbolName: "plus.magnifyingglass",
            accessibilityDescription: NSLocalizedString(
                "Zoom in",
                comment: "Image preview: accessibility label for zoom in control"
            ),
            diameter: 24
        )

        Self.configureNavStack(leftNavStack)
        Self.configureNavStack(rightNavStack)
        Self.configureBottomToolbarStack(bottomToolbarStack)
        Self.configureCenterOverlayStack(centerOverlayStack)

        self.leftNavigation = LiquidGlassAdaptor.wrappingContent(leftNavStack, cornerRadius: 28)
        self.rightNavigation = LiquidGlassAdaptor.wrappingContent(rightNavStack, cornerRadius: 28)
        self.bottomToolbar = LiquidGlassAdaptor.wrappingContent(bottomToolbarStack, cornerRadius: 24)

        self.state = state
        super.init(nibName: nil, bundle: nil)

        previousButton.target = self
        previousButton.action = #selector(showPrevious)
        nextButton.target = self
        nextButton.action = #selector(showNext)
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutFromToolbar)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInFromToolbar)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 18
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        self.view = visualEffectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        leftNavStack.addArrangedSubview(previousButton)
        rightNavStack.addArrangedSubview(nextButton)
        bottomToolbarStack.addArrangedSubview(zoomOutButton)
        bottomToolbarStack.addArrangedSubview(zoomPercentLabel)
        bottomToolbarStack.addArrangedSubview(zoomInButton)
        centerOverlayStack.addArrangedSubview(statusLabel)
        centerOverlayStack.addArrangedSubview(retryButton)

        setupUI()
        bindState()
    }

    func zoomIn() {
        scrollView.zoomIn()
    }

    func zoomOut() {
        scrollView.zoomOut()
    }

    func resetZoom() {
        scrollView.resetToFit()
    }

    private static func configureNavStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        if #available(macOS 26.0, *) {
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        } else {
            stack.edgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        }
    }

    private static func configureBottomToolbarStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        if #available(macOS 26.0, *) {
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        } else {
            stack.edgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        }
    }

    private static func configureCenterOverlayStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
    }

    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        retryButton.target = self
        retryButton.action = #selector(retryCurrentItem)
        retryButton.isHidden = true

        zoomPercentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomPercentLabel.textColor = .labelColor
        zoomPercentLabel.alignment = .center
        zoomPercentLabel.isSelectable = false
        zoomPercentLabel.setContentHuggingPriority(.required, for: .horizontal)
        zoomPercentLabel.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(42)
        }

        view.addSubview(scrollView)
        view.addSubview(centerOverlayStack)
        view.addSubview(titleLabel)
        view.addSubview(leftNavigation)
        view.addSubview(rightNavigation)
        view.addSubview(bottomToolbar)

        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(12)
            make.leading.equalToSuperview().offset(14)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        centerOverlayStack.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.leading.greaterThanOrEqualToSuperview().offset(32)
            make.trailing.lessThanOrEqualToSuperview().offset(-32)
        }

        leftNavigation.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.centerY.equalTo(scrollView)
        }

        rightNavigation.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-14)
            make.centerY.equalTo(scrollView)
        }

        bottomToolbar.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-16)
        }

        scrollView.onZoomChanged = { [weak self] scale, fitScale, minScale in
            guard let self else { return }
            state.updateZoom(scale: scale, fitScale: fitScale, minScale: minScale)
            zoomPercentLabel.stringValue = Self.zoomText(for: scale)
        }
    }

    private func bindState() {
        state.$currentIndex
            .combineLatest(state.$items)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] currentIndex, items in
                guard let self else { return }
                updateTitle(currentIndex: currentIndex, items: items)
                updateChrome(for: items)
            }
            .store(in: &cancellables)

        state.$loadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loadState in
                self?.render(loadState: loadState)
            }
            .store(in: &cancellables)
    }

    private func updateTitle(currentIndex: Int, items: [ImagePreviewItem]) {
        let currentItem = items.indices.contains(currentIndex) ? items[currentIndex] : nil
        titleLabel.stringValue = currentItem?.title ?? currentItem?.suggestedFilename ?? currentItem?.source.url?.lastPathComponent ?? ""
    }

    private func updateChrome(for items: [ImagePreviewItem]) {
        let multiple = items.count > 1
        leftNavigation.isHidden = !multiple
        rightNavigation.isHidden = !multiple
        previousButton.isButtonEnabled = state.canShowPrevious
        nextButton.isButtonEnabled = state.canShowNext
    }

    private func render(loadState: ImagePreviewLoadState) {
        switch loadState {
        case .idle:
            scrollView.clear()
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            retryButton.isHidden = true
        case .loading:
            scrollView.clear()
            statusLabel.stringValue = NSLocalizedString("Loading image…", comment: "Image preview loading")
            statusLabel.isHidden = false
            retryButton.isHidden = true
        case .loaded(let asset):
            statusLabel.isHidden = true
            retryButton.isHidden = true
            scrollView.display(asset: asset)
        case .failed(let error):
            scrollView.clear()
            statusLabel.stringValue = error.message
            statusLabel.isHidden = false
            retryButton.isHidden = false
        }
    }

    private static func zoomText(for scale: CGFloat) -> String {
        let percent = max(Int((scale * 100).rounded()), 1)
        return "\(percent)%"
    }

    @objc private func showPrevious() {
        state.showPrevious()
    }

    @objc private func showNext() {
        state.showNext()
    }

    @objc private func zoomInFromToolbar() {
        zoomIn()
    }

    @objc private func zoomOutFromToolbar() {
        zoomOut()
    }

    @objc private func retryCurrentItem() {
        state.retryCurrentItem()
    }

#if DEBUG
    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = "Select Images"
        panel.message = "Choose one or more local images to append to the current preview list."

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            let newItems = panel.urls.enumerated().map { index, url in
                ImagePreviewItem(
                    id: "debug-local-\(UUID().uuidString)-\(index)",
                    source: .localFile(url),
                    title: url.lastPathComponent,
                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                    suggestedFilename: url.lastPathComponent
                )
            }
            self.state.append(items: newItems)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
#endif
}
