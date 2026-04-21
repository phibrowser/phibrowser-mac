// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import QuartzCore

final class OmniBoxContainerViewController: NSViewController {
    private(set) var omniBoxController: OmniBoxViewController?
    private var cancellables = Set<AnyCancellable>()
    
    private let omniBoxWidth: CGFloat = 520
    private let maxOmniBoxHeight: CGFloat = 284 // 57 (base) + 226 (max suggestions) + 1 (separator)
    private let collapsedOmniBoxHeight: CGFloat = 52 // base 52 + separator 1
    private weak var parentView: EventBlockBgView?
    private var showFromAddressBar: Bool = false
    private weak var addressView: NSView?
    private(set) var hasShown = false
    private var needsShowAnimation = false
    private var animationOn = false
    private weak var browserState: BrowserState?
    private var focusingTabObserver: AnyCancellable?
    
    init(browserState: BrowserState, superView: EventBlockBgView? = nil) {
        super.init(nibName: nil, bundle: nil)
        self.browserState = browserState
        self.parentView = superView
        omniBoxController = OmniBoxViewController(viewModel: .init(windowState: browserState), state: browserState)
        omniBoxController?.setActionDelegate(self)
        
        superView?.mouseDown = { [weak self] event in
            self?.superViewClicked(event)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.postsFrameChangedNotifications = true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupOmniBoxView()
        setupSuggestionObserver()
        setupFrameObserver()
        setupKeyboardMonitoring()
        view.window?.makeFirstResponder(omniBoxController?.view)
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        showFromAddressBar = false
        addressView = nil
        hasShown = false
    }
    
    private func setupOmniBoxView() {
        guard let omniBoxView = omniBoxController?.view else { return }
        
        omniBoxView.wantsLayer = true
        omniBoxView.translatesAutoresizingMaskIntoConstraints = true
        omniBoxView.autoresizingMask = []
        view.addSubview(omniBoxView)
    }
    
    private func setupFrameObserver() {
    }
    
    private func setupKeyboardMonitoring() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyDown(event: event) ?? event
        }
    }
    
    private func observeFocusingTabChange() {
        focusingTabObserver = browserState?.$focusingTab
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hideOmniBox()
            }
    }
    
    private func superViewClicked(_ event: NSEvent) {
        guard let omniBoxView = omniBoxController?.view else { return }
        
        guard let superview = view.superview else { return }
        let clickLocation = event.locationInWindow
        let clickPointInSuperview = superview.convert(clickLocation, from: nil)
        
        let clickPointInView = view.convert(clickLocation, from: nil)
        
        let omniBoxFrameInView = omniBoxView.frame
        let isClickInsideOmniBox = omniBoxFrameInView.contains(clickPointInView)
        
        if !isClickInsideOmniBox {
            hideOmniBox()
        }
    }
    
    
    func showOmniBox(fromAddressBar: Bool, addressView: NSView? = nil) {
        self.addressView = addressView
        showFromAddressBar = fromAddressBar && addressView != nil
        needsShowAnimation = true
        omniBoxController?.logOpenTrace(
            stage: "show-omnibox",
            details: "fromAddressBar=\(fromAddressBar) anchored=\(showFromAddressBar)"
        )
        if !showFromAddressBar {
            omniBoxController?.view.alphaValue = 1
            hasShown = true
        } else {
            showOmniboxReletiveToAdressView(omniBoxController?.contentSize ?? .zero)
        }
        omniBoxController?.focusTextField()
        observeFocusingTabChange()
    }
    
    func hideOmniBox(fromAddressBar: Bool = false) {
        focusingTabObserver = nil
        guard animationOn else {
           hideOmniBoxWithoutAnimation()
            return
        }
        
        if self.showFromAddressBar {
            hideOmniBoxFromAddressbarWithAnimation()
        } else {
            guard let omniBoxView = omniBoxController?.view else { return }
            let duration: TimeInterval = 0.33
            
            let fadeAnimation = CABasicAnimation(keyPath: "opacity")
            fadeAnimation.fromValue = 1.0
            fadeAnimation.toValue = 0.0
            fadeAnimation.duration = duration
            fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            
            let scaleAnimation = CABasicAnimation(keyPath: "transform")
            scaleAnimation.fromValue = CATransform3DIdentity
            scaleAnimation.toValue = createCenterScaleTransform(for: omniBoxView, scale: 1.1)
            scaleAnimation.duration = duration
            scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            
            let animationGroup = CAAnimationGroup()
            animationGroup.animations = [fadeAnimation, scaleAnimation]
            animationGroup.duration = duration
            animationGroup.fillMode = .forwards
            animationGroup.isRemovedOnCompletion = false
            
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                self?.hasShown = false
                self?.view.superview?.removeFromSuperview()
                omniBoxView.alphaValue = 0
                omniBoxView.layer?.removeAllAnimations()
            }
            
            omniBoxView.layer?.add(animationGroup, forKey: "hideAnimation")
            
            CATransaction.commit()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.omniBoxController?.reset()
        }
        
    }
    
    private func showWithAnimation(frame: NSRect) {
        guard let omniBoxView = omniBoxController?.view else { return }

        let duration: TimeInterval = 0.2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        omniBoxView.frame = frame
        omniBoxView.alphaValue = 1.0
        omniBoxView.layer?.opacity = 1.0
        omniBoxView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        
        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = 0.0
        fadeAnimation.toValue = 1.0
        fadeAnimation.duration = duration
        fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = createCenterScaleTransform(for: omniBoxView, scale: 1.2)
        scaleAnimation.toValue = CATransform3DIdentity
        scaleAnimation.duration = duration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [fadeAnimation, scaleAnimation]
        animationGroup.duration = duration
        animationGroup.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.omniBoxController?.focusTextField()
            self?.hasShown = true
            self?.needsShowAnimation = false
        }
        
        omniBoxView.layer?.add(animationGroup, forKey: "showAnimation")
        CATransaction.commit()
    }
    
    private func showOmniboxReletiveToAdressView(_ size: NSSize) {
        guard let omniBoxView = omniBoxController?.view,
              let addressView = addressView else {
            return
        }

        if let newFrame = calculateFrameRelativeToAddressView(size: size, addressView: addressView) {
            if needsShowAnimation && animationOn {
                guard size.height > 52 else { return }
                showOmniBoxFromAddressbarWithAnimation(newFrame)
            } else {
                omniBoxView.alphaValue = 1
                omniBoxView.frame = newFrame
                needsShowAnimation = false
                hasShown = true
            }
        }

    }
    
    private func calculateFrameRelativeToAddressView(size: NSSize, addressView: NSView) -> NSRect? {
        let parentBounds = view.bounds
        guard parentBounds.width > 0, parentBounds.height > 0 else { return nil }

        let addressFrameInParent = view.convert(addressView.bounds, from: addressView)

        let anchoredHeight = min(maxOmniBoxHeight, parentBounds.height)
        let actualHeight = min(size.height, anchoredHeight)

        let navigationAtTop = PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop

        // Keep the legacy layout aligned to the address bar width.
        var actualWidth: CGFloat
        if navigationAtTop {
            actualWidth = min(addressFrameInParent.width, parentBounds.width)
        } else {
            let minOmniBoxWidth: CGFloat = 460
            actualWidth = min(max(addressFrameInParent.width, minOmniBoxWidth), parentBounds.width)
            if actualWidth >= minOmniBoxWidth {
                actualWidth = actualWidth + 2
            }
        }

        let anchoredX = addressFrameInParent.minX
        let anchoredTop = addressFrameInParent.maxY

        let proposedY = anchoredTop - actualHeight

        let x = max(0, min(anchoredX, parentBounds.width - actualWidth)) - 1
        let y = max(0, min(proposedY, parentBounds.height - actualHeight)) + 2

        return NSRect(x: x, y: y, width: actualWidth, height: actualHeight)
    }
    
    private func showOmniBoxFromAddressbarWithAnimation(_ frame: NSRect) {
        guard let omniBoxView = omniBoxController?.view else { return }

        // Ensure the view has a backing layer
        if omniBoxView.layer == nil { omniBoxView.wantsLayer = true }

        let duration: TimeInterval = 0.25
        let minScale: CGFloat = 0.01

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        omniBoxView.frame = frame

        if let layer = omniBoxView.layer {
            let oldAnchor = layer.anchorPoint
            let newAnchor = CGPoint(x: 0, y: 1)
            if oldAnchor != newAnchor {
                let size = layer.bounds.size
                let dx = (newAnchor.x - oldAnchor.x) * size.width
                let dy = (newAnchor.y - oldAnchor.y) * size.height
                layer.anchorPoint = newAnchor
                layer.position = CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)
            }
            layer.transform = CATransform3DIdentity
            layer.opacity = 1.0
        }

        omniBoxView.alphaValue = 1.0
        CATransaction.commit()

        let initialTransform = CATransform3DMakeScale(minScale, minScale, 1.0)

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = initialTransform
        transformAnimation.toValue = CATransform3DIdentity
        transformAnimation.duration = duration
        transformAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = 0.0
        fadeAnimation.toValue = 1.0
        fadeAnimation.duration = duration
        fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [fadeAnimation, transformAnimation]
        animationGroup.duration = duration
        animationGroup.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.omniBoxController?.focusTextField()
            self?.hasShown = true
            self?.needsShowAnimation = false
        }

        omniBoxView.layer?.add(animationGroup, forKey: "expandAnimation")

        CATransaction.commit()
    }

    private func hideOmniBoxWithoutAnimation() {
        omniBoxController?.view.alphaValue = 0.0
        parentView?.removeFromSuperview()
        hasShown = false
        showFromAddressBar = false
        omniBoxController?.reset()
    }
    
    private func hideOmniBoxFromAddressbarWithAnimation() {
        guard let omniBoxView = omniBoxController?.view else { return }
        
        guard animationOn else {
            hideOmniBoxWithoutAnimation()
            return
        }

        if omniBoxView.layer == nil { omniBoxView.wantsLayer = true }
        guard let layer = omniBoxView.layer else { return }

        let duration: TimeInterval = 0.25
        let minScale: CGFloat = 0.01

        layer.removeAnimation(forKey: "expandAnimation")

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let newAnchor = CGPoint(x: 0, y: 1)
        if layer.anchorPoint != newAnchor {
            let size = layer.bounds.size
            let dx = (newAnchor.x - layer.anchorPoint.x) * size.width
            let dy = (newAnchor.y - layer.anchorPoint.y) * size.height
            layer.anchorPoint = newAnchor
            layer.position = CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)
        }

        layer.transform = CATransform3DIdentity
        layer.opacity = 1.0
        omniBoxView.alphaValue = 1.0

        CATransaction.commit()

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = CATransform3DIdentity
        transformAnimation.toValue = CATransform3DMakeScale(minScale, minScale, 1.0)
        transformAnimation.duration = duration
        transformAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = 1.0
        fadeAnimation.toValue = 0.0
        fadeAnimation.duration = duration
        fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [fadeAnimation, transformAnimation]
        animationGroup.duration = duration
        animationGroup.fillMode = .forwards
        animationGroup.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak omniBoxView] in
            guard let self = self, let omniBoxView = omniBoxView else { return }
            if let layer = omniBoxView.layer {
                layer.removeAllAnimations()
                layer.transform = CATransform3DIdentity
                layer.opacity = 1.0
            }
            omniBoxView.alphaValue = 0.0
            self.parentView?.removeFromSuperview()
            self.hasShown = false
            self.showFromAddressBar = false
        }

        layer.add(animationGroup, forKey: "collapseAnimation")

        CATransaction.commit()
    }

    // Note: The anchorPoint change is localized to this view's layer and is safe because we compensate the position,
    // so the view's frame and layout are preserved and unaffected for other code.

    /// Create a scale transform anchored at the top-left corner.
    /// - Parameters:
    ///   - viewSize: Final view size.
    ///   - scale: Scale factor from `0.01` to `1.0`.
    /// - Returns: A transform that scales from the top-left corner.
    private func createTopLeftScaleTransform(viewSize: NSSize, scale: CGFloat) -> CATransform3D {
        let anchorX: CGFloat = 0
        let anchorY: CGFloat = viewSize.height

        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, anchorX, anchorY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1.0)
        transform = CATransform3DTranslate(transform, -anchorX, -anchorY, 0)
        return transform
    }
    
    private func createCenterScaleTransform(for view: NSView, scale: CGFloat) -> CATransform3D {
        let bounds = view.bounds
        let centerX = bounds.width / 2
        let centerY = bounds.height / 2
        
        var transform = CATransform3DMakeTranslation(centerX, centerY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1.0)
        transform = CATransform3DTranslate(transform, -centerX, -centerY, 0)
        
        return transform
    }
    
    private func setupSuggestionObserver() {
        guard let omniBoxController = omniBoxController else { return }
        
        omniBoxController.$contentSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSize in
                self?.updateOmniBoxFrame(newSize)
            }
            .store(in: &cancellables)
        
        let frameChangePublisher = NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: view)
            .map { _ in () }
        
        let sidebarWidthPublisher = browserState?.$sidebarWidth
            .map { _ in () }
            .eraseToAnyPublisher() ?? Empty<Void, Never>().eraseToAnyPublisher()
        
        frameChangePublisher
            .merge(with: sidebarWidthPublisher)
            .sink { [weak self] _ in
                self?.updateOmniBoxFrame()
            }
            .store(in: &cancellables)
    }
    
    private func updateOmniBoxFrame(_ newSize: NSSize? = nil) {
        guard let omniBoxView = omniBoxController?.view else { return }
        if showFromAddressBar {
            showOmniboxReletiveToAdressView(newSize ?? omniBoxController?.contentSize ?? .zero)
            return
        }

        let parentBounds = view.bounds
        guard parentBounds.width > 0, parentBounds.height > 0 else { return }
        let contentSize = newSize ??  omniBoxController?.contentSize ?? .zero
        let anchoredHeight = min(maxOmniBoxHeight, parentBounds.height)
        let actualHeight = min(contentSize.height, anchoredHeight)
        let actualWidth = min(contentSize.width, parentBounds.width)

        let sidebarWidth = browserState?.sidebarWidth ?? 0
        let rightAreaWidth = parentBounds.width - sidebarWidth
        let x: CGFloat
        if sidebarWidth == 0 || rightAreaWidth < actualWidth {
            x = max((parentBounds.width - actualWidth) / 2, 0)
        } else {
            x = max(sidebarWidth + (rightAreaWidth - actualWidth) / 2, 0)
        }
        
        let anchoredTop = (parentBounds.height + anchoredHeight) / 2
        let proposedY = anchoredTop - actualHeight
        let y = max(0, min(proposedY, parentBounds.height - actualHeight))

        let newFrame = NSRect(x: x, y: y, width: actualWidth, height: actualHeight)
        if needsShowAnimation && animationOn {
            showWithAnimation(frame: newFrame)
        } else {
            omniBoxView.frame = newFrame
        }
    }
    
    private func handleKeyDown(event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            hideOmniBox()
            return nil
        }
        
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            hideOmniBox()
            return nil
        }
        
        return event
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension OmniBoxContainerViewController: OmniBoxActionDelegate {
    func omniBoxDidClear() {
        hideOmniBox(fromAddressBar: false)
    }
}
