// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

class ColoredVisualEffectView: NSVisualEffectView {
    // Dedicated backing view that carries the resolved color fill.
    private let colorView = NSView()
    private var themeSubscription: AnyCancellable?

    /// Static background color synced onto the backing view.
    /// The alpha channel still participates in the visual-effect blend.
    var backgroundColor: NSColor? {
        didSet {
            updateColor()
        }
    }
    
    /// Theme-driven background color. Takes precedence over `backgroundColor`.
    var themedBackgroundColor: ThemedColor? {
        didSet {
            if themedBackgroundColor != nil {
                subscribeToThemeChanges()
            } else {
                themeSubscription?.cancel()
                themeSubscription = nil
            }
            updateColor()
        }
    }
    
    /// Optional alpha override applied after color resolution.
    var colorAlphaComponent: CGFloat? {
        didSet {
            updateColor()
        }
    }

    // MARK: - Overrides

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    deinit {
        themeSubscription?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep the color view behind all visual-effect content.
        if colorView.superview != self {
            addSubview(colorView, positioned: .below, relativeTo: nil)
        }
        updateColor()
    }

    private func commonInit() {
        colorView.wantsLayer = true
        colorView.layer?.backgroundColor = makeBackgroundColor().cgColor
        
        colorView.autoresizingMask = [.width, .height]
        colorView.frame = self.bounds
        
        addSubview(colorView, positioned: .below, relativeTo: nil)
    }
    
    private func subscribeToThemeChanges() {
        // Reuse the existing subscription when one is already active.
        guard themeSubscription == nil else { return }
        
        let manager = ThemeManager.shared
        themeSubscription = Publishers.Merge(
            manager.themePublisher.map { _ in () },
            manager.appearancePublisher.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateColor()
        }
    }

    private func updateColor() {
        colorView.layer?.backgroundColor = makeBackgroundColor().cgColor
    }
    
    private func makeBackgroundColor() -> NSColor {
        // Prefer the theme-driven color when present.
        if let themedColor = themedBackgroundColor {
            let resolvedColor = themedColor.resolved()
            if let alpha = colorAlphaComponent {
                return resolvedColor.withAlphaComponent(alpha)
            }
            return resolvedColor
        }
        
        // Fall back to the static background color.
        guard let backgroundColor else {
            return .clear
        }
        if let alpha = colorAlphaComponent {
            return backgroundColor.withAlphaComponent(alpha)
        }
        return backgroundColor
    }
}
