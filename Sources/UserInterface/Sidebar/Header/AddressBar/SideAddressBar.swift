// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Combine
import SwiftUI
class SideAddressBar: NSView {
    private enum LayoutMetrics {
        static let extensionButtonWidth: CGFloat = 24
        static let extensionButtonSpacing: CGFloat = 2
        static let rightStackSpacing: CGFloat = 6
        static let textFieldLeadingInset: CGFloat = 12
        static let textFieldTrailingSpacing: CGFloat = 8
        static let rightStackTrailingInset: CGFloat = 4
        static let minimumAddressTextWidth: CGFloat = 84
    }

    private var containerView: HoverableView!
    private lazy var extensionMenuHostingView: NSHostingView<ExtensionPopoverButton> = {
        let hosting = NSHostingView(rootView: ExtensionPopoverButton(extensionManager: nil))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }()
    
    private var textField: NSTextField!
    private var rightStackView: CustomStackView!
    private var extensionIconsStackView: CustomStackView!
    @Published var currentTab: Tab?
    
    private var cancellables = Set<AnyCancellable>()

    var showBackgroundWhenInactive: Bool = true {
        didSet {
            updateBackgroundAppearance()
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        
        setupContainerView()
        setupTextField()
        setupRightStackView()
        setupLayout()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupObservers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.unsafeBrowserState?.extensionManager.refreshExtensions()
        }
    }
    
    private func setupObservers() {
        guard let browserState = unsafeBrowserState else { return }
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        extensionMenuHostingView.rootView = ExtensionPopoverButton(extensionManager: browserState.extensionManager)
        
        $currentTab
            .compactMap { $0 }
            .map { tab in
                tab.$url
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] url in
                self?.textField.stringValue = URLProcessor.displayName(for: url ?? "")
            }
            .store(in: &cancellables)

        let widthPublisher = NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: containerView)
            .map { [weak self] _ in self?.containerView.bounds.width ?? 0 }
            .prepend(containerView.bounds.width)
            .removeDuplicates()
            .eraseToAnyPublisher()
        
        browserState.extensionManager.$pinedExtensions
            .combineLatest(widthPublisher, browserState.$layoutMode)
            .map { [weak self] exts, width, layoutMode in
                guard layoutMode == .performance else { return false }
                return self?.shouldDisplayPinnedExtensionsWithinSidebar(
                    pinnedExtensionCount: exts.count,
                    containerWidth: width
                ) ?? false
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { shouldDisplay in
                browserState.extensionManager.shouldDisplayExtensionsWithinSidebar = shouldDisplay
            }
            .store(in: &cancellables)

        browserState.extensionManager.$pinedExtensions
            .combineLatest(
                browserState.extensionManager.$shouldDisplayExtensionsWithinSidebar.removeDuplicates(),
                browserState.$layoutMode.removeDuplicates()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinnedExtensions, display, layoutMode in
                guard layoutMode == .performance, display == false else {
                    self?.updateExtensionIcons([])
                    return
                }
                self?.updateExtensionIcons(pinnedExtensions)
            }
            .store(in: &cancellables)
    }
    
    private func updateExtensionIcons(_ pinnedExtensions: [Extension]) {
        extensionIconsStackView.arrangedSubviews.forEach { view in
            extensionIconsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        
        for ext in pinnedExtensions {
            let button = createExtensionButton(for: ext)
            extensionIconsStackView.addArrangedSubview(button)
        }
    }

    private func shouldDisplayPinnedExtensionsWithinSidebar(
        pinnedExtensionCount: Int,
        containerWidth: CGFloat
    ) -> Bool {
        guard pinnedExtensionCount > 0 else { return false }

        let pinnedIconsWidth = CGFloat(pinnedExtensionCount) * LayoutMetrics.extensionButtonWidth
        let pinnedIconsSpacing = CGFloat(max(0, pinnedExtensionCount - 1)) * LayoutMetrics.extensionButtonSpacing
        let rightControlsWidth = pinnedIconsWidth
            + pinnedIconsSpacing
            + LayoutMetrics.rightStackSpacing
            + LayoutMetrics.extensionButtonWidth
        let reservedHorizontalInsets = LayoutMetrics.textFieldLeadingInset
            + LayoutMetrics.textFieldTrailingSpacing
            + LayoutMetrics.rightStackTrailingInset
        let remainingTextWidth = containerWidth - rightControlsWidth - reservedHorizontalInsets

        return remainingTextWidth < LayoutMetrics.minimumAddressTextWidth
    }
    
    private func createExtensionButton(for ext: Extension) -> HoverableButtonNSView {
        let image: NSImage
        if let icon = ext.icon {
            image = icon
        } else {
            if let defaultImage = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil) {
                image = defaultImage
            } else {
                image = NSImage()
            }
        }
        
        let config = HoverableButtonConfig(image: image,
                                           imageSize: .init(width: 16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(extensionButtonClicked(_:)))
        button.toolTip = ext.name
        
        button.identifier = NSUserInterfaceItemIdentifier(ext.id)
        
        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 24, height: 24))
        }
        
        return button
    }
    
    @objc private func extensionButtonClicked(_ sender: NSView) {
        guard let extensionId = sender.identifier?.rawValue else { return }

        let point = ExtensionPopupAnchor.pointBelowView(sender)
            ?? ExtensionPopupAnchor.mouseFallback()

        ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
            withId: extensionId,
            pointInScreen: point,
            windowId: unsafeBrowserState?.windowId.int64Value ?? 0
        )
    }
   
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        unsafeBrowserWindowController?.openLocationBar(containerView)
    }
    
    private func setupContainerView() {
        containerView = HoverableView()
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.hoveredColor = .sidebarTabHoveredColorEmphasized
        containerView.postsFrameChangedNotifications = true
        addSubview(containerView)
        updateBackgroundAppearance()
    }

    private func updateBackgroundAppearance() {
        if showBackgroundWhenInactive {
            containerView?.backgroundColor = .sidebarTabHovered
        } else {
            containerView?.backgroundColor = .clear
        }
    }
    
    private func setupTextField() {
        textField = NSTextField()
        textField.isBordered = false
        textField.backgroundColor = NSColor.clear
        textField.font = NSFont.systemFont(ofSize: 13)
        
        let placeholder = NSMutableAttributedString(string: NSLocalizedString("Search or Enter URL", comment: "Sidebar address bar - Placeholder text prompting user to enter URL or search query"))
        placeholder.addAttributes([
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 13)
        ], range: NSRange(location: 0, length: placeholder.length))
        textField.placeholderAttributedString = placeholder
        
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.focusRingType = .none
        textField.maximumNumberOfLines = 1
        textField.isEditable = false
        textField.isSelectable = false
        textField.lineBreakMode = .byTruncatingTail
        containerView.addSubview(textField)
    }
    
    private func setupRightStackView() {
        rightStackView = CustomStackView()
        rightStackView.orientation = .horizontal
        rightStackView.spacing = 6
        rightStackView.alignment = .centerY
        rightStackView.distribution = .gravityAreas
        
        extensionIconsStackView = CustomStackView()
        extensionIconsStackView.orientation = .horizontal
        extensionIconsStackView.spacing = 2
        extensionIconsStackView.alignment = .centerY
        
        rightStackView.addArrangedSubview(extensionIconsStackView)
        rightStackView.addArrangedSubview(extensionMenuHostingView)
        extensionMenuHostingView.snp.makeConstraints { make in
            make.width.height.equalTo(24)
        }
        containerView.addSubview(rightStackView)
    }
    
    private func setupLayout() {
        containerView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.right.equalToSuperview()
            make.top.bottom.equalToSuperview()
        }

        rightStackView.setContentHuggingPriority(.init(1000), for: .horizontal)
        rightStackView.setContentCompressionResistancePriority(.init(1000), for: .horizontal)
        rightStackView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().inset(4)
            make.height.equalToSuperview()
        }

        textField.setContentHuggingPriority(.init(1), for: .horizontal)
        textField.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        textField.snp.makeConstraints { make in
            make.leading.equalTo(containerView).offset(12)
            make.centerY.equalTo(containerView)
            make.trailing.equalTo(rightStackView.snp.leading).offset(-8)
        }
    }
    
    private func createIconButton(systemName: String? = nil, size: CGFloat, image: NSImage?) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        if let image {
            button.image = image
        } else if let systemName {
            if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
            }
        }
       
        
        button.imageScaling = .scaleProportionallyDown
        
        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: size + 4, height: size + 4))
        }
        
        return button
    }
}

struct ExtensionPopoverButton: View {
    @State private var isShown = false
    let extensionManager: ExtensionManager?

    var body: some View {
        let isPresented = Binding(
            get: { isShown && extensionManager != nil },
            set: { isShown = $0 }
        )

        LottieMenuButtonRepresentable(isShown: $isShown)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        .popover(isPresented: isPresented, arrowEdge: .top) {
            if let manager = extensionManager {
                ExtensionList(
                    extensionManager: manager,
                    onRequestDismiss: { isShown = false }
                )
            } else {
                EmptyView()
            }
        }
    }
}

struct LottieMenuButtonRepresentable: NSViewRepresentable {
    @Binding var isShown: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isShown: $isShown)
    }

    func makeNSView(context: Context) -> LottieAnimationNSView {
        let config = LottieAnimationViewConfig(
            animationName: "extension-button",
            size: CGSize(width: 24, height: 24),
            hoverBackgroundColor: Color(nsColor: .sidebarTabHovered),
            cornerRadius: 4,
            animationTrigger: .onHoverEnter,
            themedTintColor: .textPrimary,
            reverseOnHoverExit: true
        )
        let view = LottieAnimationNSView(config: config, target: context.coordinator, selector: #selector(Coordinator.handleClick))
        return view
    }

    func updateNSView(_ nsView: LottieAnimationNSView, context: Context) {
    }

    class Coordinator: NSObject {
        private var isShown: Binding<Bool>

        init(isShown: Binding<Bool>) {
            self.isShown = isShown
        }

        @objc func handleClick() {
            isShown.wrappedValue.toggle()
        }
    }
}

extension SideAddressBar {
    class CustomStackView: NSStackView {
        override func mouseDown(with event: NSEvent) {
        }
    }
}
