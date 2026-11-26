// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

@MainActor
final class CustomTooltipRegistration: NSObject {
    let ownerID = UUID()

    private weak var view: NSView?
    private weak var activeController: CustomTooltipController?
    private var tooltipContent: AnyView
    private var configuration: CustomTooltipConfiguration
    private var trackingArea: NSTrackingArea?
    private var windowObservation: NSKeyValueObservation?
    private var toolTipObservation: NSKeyValueObservation?
    private var displacedNativeTooltip: String?
    private var isApplyingNativeTooltipChange = false
    private var isInvalidated = false
    private(set) var isHovering = false

    init(
        view: NSView,
        tooltipContent: AnyView,
        configuration: CustomTooltipConfiguration
    ) {
        self.view = view
        self.tooltipContent = tooltipContent
        self.configuration = configuration
        self.displacedNativeTooltip = view.toolTip
        super.init()

        installTrackingArea(on: view)
        observeWindow(of: view)
        observeNativeTooltip(of: view)
        suppressNativeTooltips(on: view)
    }

    func update(
        tooltipContent: AnyView,
        configuration: CustomTooltipConfiguration
    ) {
        self.tooltipContent = tooltipContent
        self.configuration = configuration
        guard let view else { return }
        suppressNativeTooltips(on: view)

        guard isHovering,
              let window = view.window else { return }
        let controller = window.customTooltipController
        activeController = controller
        controller.update(
            ownerID: ownerID,
            anchorView: view,
            content: tooltipContent,
            configuration: configuration
        )
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isHovering = false
        activeController?.pointerExited(ownerID: ownerID)
        activeController = nil
        windowObservation = nil
        toolTipObservation = nil

        guard let view else { return }
        if let trackingArea {
            view.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        view.removeAllToolTips()
        view.toolTip = displacedNativeTooltip
    }

    func handlePointerEntered() {
        guard !isInvalidated,
              let view,
              let window = view.window else { return }
        isHovering = true
        suppressNativeTooltips(on: view)

        let controller = window.customTooltipController
        if activeController !== controller {
            activeController?.pointerExited(ownerID: ownerID)
            activeController = controller
        }
        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: view,
            content: tooltipContent,
            configuration: configuration
        )
    }

    func handlePointerExited() {
        isHovering = false
        activeController?.pointerExited(ownerID: ownerID)
        activeController = nil
    }

    @objc(mouseEntered:)
    private func handleMouseEntered(_ event: NSEvent) {
        if let view, Self.isCoveredByInWindowOverlay(view, at: event.locationInWindow) {
            return
        }
        handlePointerEntered()
    }

    /// Tracking areas ignore what is drawn above them in the same window, so
    /// an anchor under an in-window overlay (the omnibox, tab search) still
    /// gets `mouseEntered`. The pointer is on the overlay when the window's
    /// hit test lands in an overlay backdrop the anchor is not part of.
    private static func isCoveredByInWindowOverlay(_ view: NSView, at locationInWindow: NSPoint) -> Bool {
        guard let frameView = view.window?.contentView?.superview,
              let hit = frameView.hitTest(locationInWindow) else { return false }
        var candidate: NSView? = hit
        while let current = candidate {
            if current is EventBlockBgView {
                return !view.isDescendant(of: current)
            }
            candidate = current.superview
        }
        return false
    }

    @objc(mouseExited:)
    private func handleMouseExited(_ event: NSEvent) {
        handlePointerExited()
    }

    private func installTrackingArea(on view: NSView) {
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    private func observeWindow(of view: NSView) {
        windowObservation = view.observe(\.window, options: [.old, .new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self else { return }
                let oldWindow = change.oldValue ?? nil
                let newWindow = change.newValue ?? nil
                guard oldWindow !== newWindow else { return }
                self.isHovering = false
                self.activeController?.pointerExited(ownerID: self.ownerID)
                self.activeController = nil
            }
        }
    }

    private func observeNativeTooltip(of view: NSView) {
        toolTipObservation = view.observe(\.toolTip, options: [.new]) { [weak self, weak view] _, change in
            MainActor.assumeIsolated {
                guard let self,
                      !self.isInvalidated,
                      !self.isApplyingNativeTooltipChange,
                      let view else { return }
                self.displacedNativeTooltip = change.newValue ?? nil
                self.suppressNativeTooltips(on: view)
            }
        }
    }

    private func suppressNativeTooltips(on view: NSView) {
        if let toolTip = view.toolTip {
            displacedNativeTooltip = toolTip
        }
        isApplyingNativeTooltipChange = true
        view.toolTip = nil
        isApplyingNativeTooltipChange = false
        view.removeAllToolTips()
    }
}

private var customTooltipRegistrationKey: UInt8 = 0

@MainActor
extension NSView {
    var customTooltipRegistration: CustomTooltipRegistration? {
        objc_getAssociatedObject(
            self,
            &customTooltipRegistrationKey
        ) as? CustomTooltipRegistration
    }

    /// Installs the default text tooltip. The custom tooltip becomes the sole
    /// tooltip owner for this view, so existing `addToolTip` rects are removed;
    /// a displaced `toolTip` string is restored when the custom tooltip is
    /// removed. Install after configuring native tooltip rects. Passing `nil`
    /// or an empty string removes the custom tooltip.
    func setCustomTooltip(
        _ text: String?,
        configuration: CustomTooltipConfiguration = .default
    ) {
        guard let text, !text.isEmpty else {
            removeCustomTooltip()
            return
        }
        setCustomTooltip(configuration: configuration) {
            DefaultCustomTooltipContent(text: text)
        }
    }

    /// Installs a custom SwiftUI tooltip on an AppKit host view. The supplied
    /// content owns its complete visual style and should have an intrinsic size.
    /// Install after configuring native tooltip rects.
    func setCustomTooltip<TooltipContent: View>(
        configuration: CustomTooltipConfiguration = .default,
        @ViewBuilder content: () -> TooltipContent
    ) {
        installCustomTooltip(
            content: AnyView(content()),
            configuration: configuration
        )
    }

    func removeCustomTooltip() {
        customTooltipRegistration?.invalidate()
        objc_setAssociatedObject(
            self,
            &customTooltipRegistrationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func installCustomTooltip(
        content: AnyView,
        configuration: CustomTooltipConfiguration
    ) {
        if let registration = customTooltipRegistration {
            registration.update(
                tooltipContent: content,
                configuration: configuration
            )
            return
        }

        let registration = CustomTooltipRegistration(
            view: self,
            tooltipContent: content,
            configuration: configuration
        )
        objc_setAssociatedObject(
            self,
            &customTooltipRegistrationKey,
            registration,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

private struct CustomTooltipModifier: ViewModifier {
    let tooltipContent: AnyView?
    let configuration: CustomTooltipConfiguration
    let fallbackNativeHelp: Text?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let tooltipContent {
            // Clear native help applied before `customTooltip`. A directly
            // applied help after it is absorbed by CustomTooltipContainer.
            content
                .help("")
                .background {
                    CustomTooltipAnchor(
                        tooltipContent: tooltipContent,
                        configuration: configuration
                    )
                }
        } else if let fallbackNativeHelp {
            content.help(fallbackNativeHelp)
        } else {
            content
        }
    }
}

/// Concrete wrapper returned by `customTooltip` so a directly-applied native
/// `.help(...)` after it is absorbed instead of becoming an outer system
/// tooltip. Native help applied before `customTooltip` is cleared by the body
/// modifier above, covering both common modifier orders.
struct CustomTooltipContainer<Content: View>: View {
    @ViewBuilder let content: Content
    let tooltipContent: AnyView?
    let configuration: CustomTooltipConfiguration
    private var fallbackNativeHelp: Text?

    var suppressesNativeHelp: Bool {
        tooltipContent != nil
    }

    init(
        content: Content,
        tooltipContent: AnyView?,
        configuration: CustomTooltipConfiguration,
        fallbackNativeHelp: Text? = nil
    ) {
        self.content = content
        self.tooltipContent = tooltipContent
        self.configuration = configuration
        self.fallbackNativeHelp = fallbackNativeHelp
    }

    var body: some View {
        content.modifier(
            CustomTooltipModifier(
                tooltipContent: tooltipContent,
                configuration: configuration,
                fallbackNativeHelp: fallbackNativeHelp
            )
        )
    }

    func help(_ textKey: LocalizedStringKey) -> Self {
        applyingFallbackHelp(Text(textKey))
    }

    @available(macOS 13.0, *)
    func help(_ textKey: LocalizedStringResource) -> Self {
        applyingFallbackHelp(Text(textKey))
    }

    func help(_ text: Text) -> Self {
        applyingFallbackHelp(text)
    }

    func help<S: StringProtocol>(_ text: S) -> Self {
        applyingFallbackHelp(Text(verbatim: String(text)))
    }

    private func applyingFallbackHelp(_ text: Text) -> Self {
        guard tooltipContent == nil else { return self }
        return CustomTooltipContainer(
            content: content,
            tooltipContent: tooltipContent,
            configuration: configuration,
            fallbackNativeHelp: text
        )
    }
}

private struct CustomTooltipAnchor: NSViewRepresentable {
    let tooltipContent: AnyView
    let configuration: CustomTooltipConfiguration

    func makeNSView(context: Context) -> CustomTooltipAnchorView {
        CustomTooltipAnchorView()
    }

    func updateNSView(_ nsView: CustomTooltipAnchorView, context: Context) {
        nsView.setCustomTooltip(configuration: configuration) {
            tooltipContent
        }
    }

    static func dismantleNSView(_ nsView: CustomTooltipAnchorView, coordinator: Void) {
        nsView.removeCustomTooltip()
    }
}

@MainActor
private final class CustomTooltipAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension View {
    /// Adds a default-styled custom tooltip that takes precedence over a
    /// directly adjacent native `.help(...)` in either modifier order.
    /// Apply the pair after layout modifiers so both describe the same view.
    func customTooltip(
        _ text: String?,
        configuration: CustomTooltipConfiguration = .default
    ) -> CustomTooltipContainer<Self> {
        CustomTooltipContainer(
            content: self,
            tooltipContent: text.flatMap { text in
                text.isEmpty ? nil : AnyView(DefaultCustomTooltipContent(text: text))
            },
            configuration: configuration
        )
    }

    /// Adds a custom-styled tooltip. The supplied content owns its complete
    /// appearance and should have an intrinsic size.
    ///
    /// A directly adjacent native `.help(...)` is suppressed in either
    /// modifier order while this custom tooltip is present.
    /// Apply the pair after layout modifiers so both describe the same view.
    func customTooltip<TooltipContent: View>(
        configuration: CustomTooltipConfiguration = .default,
        @ViewBuilder content: () -> TooltipContent
    ) -> CustomTooltipContainer<Self> {
        CustomTooltipContainer(
            content: self,
            tooltipContent: AnyView(content()),
            configuration: configuration
        )
    }
}
