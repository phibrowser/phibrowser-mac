// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import QuartzCore

final class WebContentProgressBarView: NSView {
    private let solidLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let reflectionLayer = CAGradientLayer()
    private let reflectionMaskLayer = CAGradientLayer()
    private var progressValue: CGFloat = 0
    private var themeObservation: AnyObject?
    private var hideWorkItem: DispatchWorkItem?
    private var hasActiveLoad = false
    private var isCurrentlyVisible = false
    private var lastLogState: ProgressLogState?

    private enum ProgressLogState: String {
        case hidden
        case loading
        case completed
    }

    private let reflectionHeight: CGFloat = 10
    private let reflectionShadowRadius: CGFloat = 6
    private let reflectionShadowOpacity: Float = 0.35
    private let reflectionBaseAlpha: CGFloat = 0.28

    var isLayoutEnabled: Bool = true {
        didSet { updateVisibility(for: progressValue, animated: false) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        hideWorkItem?.cancel()
    }

    func resetForNewTab() {
        hideWorkItem?.cancel()
        hasActiveLoad = false
        lastLogState = nil
        isCurrentlyVisible = false
        alphaValue = 0
        isHidden = true
        progressValue = 0
        updateLayers(animated: false)
        AppLogDebug("[ProgressBar] Reset for new tab")
    }

    func setProgress(_ progress: CGFloat, animated: Bool = true) {
        let clamped = min(max(progress, 0), 1)
        progressValue = clamped
        updateVisibility(for: clamped, animated: animated)
        updateLayers(animated: animated)
    }

    override func layout() {
        super.layout()
        updateLayers(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(reflectionLayer)
        layer?.addSublayer(solidLayer)
        layer?.addSublayer(gradientLayer)
        reflectionLayer.startPoint = CGPoint(x: 0, y: 0.5)
        reflectionLayer.endPoint = CGPoint(x: 1, y: 0.5)
        reflectionLayer.locations = [0, 1]
        reflectionLayer.mask = reflectionMaskLayer
        reflectionMaskLayer.startPoint = CGPoint(x: 0, y: 1)
        reflectionMaskLayer.endPoint = CGPoint(x: 0, y: 0)
        reflectionMaskLayer.locations = [0, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.locations = [0, 1]
        alphaValue = 0
        isHidden = true

        themeObservation = subscribe { [weak self] theme, appearance in
            self?.updateTheme(theme: theme, appearance: appearance)
        }
    }

    private func updateTheme(theme: Theme, appearance: Appearance) {
        let base = ThemedColor.themeColor.resolve(theme: theme, appearance: appearance)
        let background = ThemedColor.contentOverlayBackground.resolve(theme: theme, appearance: appearance)
        solidLayer.backgroundColor = base.cgColor
        gradientLayer.colors = [background.cgColor, base.cgColor]

        let reflectionStart = background.withAlphaComponent(0).cgColor
        let reflectionEnd = base.withAlphaComponent(reflectionBaseAlpha).cgColor
        reflectionLayer.colors = [reflectionStart, reflectionEnd]
        reflectionLayer.shadowColor = base.cgColor
        reflectionLayer.shadowOpacity = reflectionShadowOpacity
        reflectionLayer.shadowRadius = reflectionShadowRadius
        reflectionLayer.shadowOffset = CGSize(width: 0, height: -1)
    }

    private func updateLayers(animated: Bool) {
        let width = bounds.width * progressValue
        let height = bounds.height
        let newFrame = CGRect(x: 0, y: 0, width: width, height: height)
        let cornerRadius = height / 2
        let gradientOpacity = gradientOpacity(for: progressValue)
        let reflectionFrame = CGRect(x: 0, y: -reflectionHeight, width: width, height: reflectionHeight)
        let reflectionOpacity = min(1, 0.25 + 0.45 * gradientOpacity)

        let updateBlock = {
            self.reflectionLayer.frame = reflectionFrame
            self.reflectionMaskLayer.frame = self.reflectionLayer.bounds
            self.reflectionMaskLayer.colors = [
                NSColor.white.withAlphaComponent(0.6).cgColor,
                NSColor.white.withAlphaComponent(0.0).cgColor
            ]
            self.solidLayer.frame = newFrame
            self.gradientLayer.frame = newFrame
            self.solidLayer.cornerRadius = cornerRadius
            self.gradientLayer.cornerRadius = cornerRadius
            self.solidLayer.opacity = Float(1 - gradientOpacity)
            self.gradientLayer.opacity = Float(gradientOpacity)
            self.reflectionLayer.cornerRadius = min(self.reflectionHeight / 2, cornerRadius)
            self.reflectionLayer.opacity = Float(reflectionOpacity)
        }

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            updateBlock()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateBlock()
            CATransaction.commit()
        }
    }

    private func gradientOpacity(for progress: CGFloat) -> CGFloat {
        let fadeStart: CGFloat = 0.3
        let fadeRange: CGFloat = 0.2
        let rawOpacity = (progress - fadeStart) / fadeRange
        return max(0, min(1, rawOpacity))
    }

    private func updateVisibility(for progress: CGFloat, animated: Bool) {
        guard isLayoutEnabled else {
            hasActiveLoad = false
            setVisible(false, animated: animated)
            logState(.hidden, progress: progress)
            return
        }

        if progress <= 0 {
            hasActiveLoad = false
            setVisible(false, animated: animated)
            logState(.hidden, progress: progress)
        } else if progress >= 1 {
            if hasActiveLoad {
                setVisible(true, animated: animated)
                scheduleHide()
                logState(.completed, progress: progress)
                hasActiveLoad = false
            } else {
                setVisible(false, animated: animated)
                logState(.hidden, progress: progress)
            }
        } else {
            hasActiveLoad = true
            setVisible(true, animated: animated)
            logState(.loading, progress: progress)
        }
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        hideWorkItem?.cancel()
        guard visible != isCurrentlyVisible else { return }
        isCurrentlyVisible = visible

        if visible {
            isHidden = false
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    animator().alphaValue = 1
                }
            } else {
                alphaValue = 1
            }
        } else {
            if animated {
                isHidden = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    self?.isHidden = true
                }
            } else {
                alphaValue = 0
                isHidden = true
            }
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.setVisible(false, animated: true)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func logState(_ state: ProgressLogState, progress: CGFloat) {
        guard state != lastLogState else { return }
        lastLogState = state
        let progressString = String(format: "%.3f", progress)
        AppLogDebug("[ProgressBar] state=\(state.rawValue) progress=\(progressString) layoutEnabled=\(isLayoutEnabled)")
    }
}
