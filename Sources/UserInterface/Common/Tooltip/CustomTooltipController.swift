// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import QuartzCore
import SwiftUI

enum CustomTooltipPlacement: Equatable {
    case below
    case right
    case belowAttached
    case rightTopAttached
    case leftTopAttached
}

enum CustomTooltipHandoffGroup: Equatable {
    case standard
    case tabPreview
}

struct CustomTooltipGeometry {
    static let anchorGap: CGFloat = 6
    static let screenMargin: CGFloat = 4

    static func origin(
        contentSize: CGSize,
        anchorScreenRect: CGRect,
        visibleFrame: CGRect?,
        placement: CustomTooltipPlacement
    ) -> CGPoint {
        let preferredOrigin: CGPoint
        switch placement {
        case .below:
            preferredOrigin = CGPoint(
                x: anchorScreenRect.midX - contentSize.width / 2,
                y: anchorScreenRect.minY - anchorGap - contentSize.height
            )
        case .right:
            preferredOrigin = CGPoint(
                x: anchorScreenRect.maxX + anchorGap,
                y: anchorScreenRect.midY - contentSize.height / 2
            )
        case .belowAttached:
            preferredOrigin = CGPoint(
                x: anchorScreenRect.midX - contentSize.width / 2,
                y: anchorScreenRect.minY - contentSize.height
            )
        case .leftTopAttached:
            preferredOrigin = CGPoint(
                x: anchorScreenRect.minX - contentSize.width,
                y: anchorScreenRect.maxY - contentSize.height
            )
        case .rightTopAttached:
            preferredOrigin = CGPoint(
                x: anchorScreenRect.maxX,
                y: anchorScreenRect.maxY - contentSize.height
            )
        }

        guard let visibleFrame else { return preferredOrigin }

        var origin = preferredOrigin
        switch placement {
        case .below:
            let aboveY = anchorScreenRect.maxY + anchorGap
            if origin.y < visibleFrame.minY + screenMargin,
               aboveY + contentSize.height <= visibleFrame.maxY - screenMargin {
                origin.y = aboveY
            }
        case .right:
            let leftX = anchorScreenRect.minX - anchorGap - contentSize.width
            if origin.x + contentSize.width > visibleFrame.maxX - screenMargin,
               leftX >= visibleFrame.minX + screenMargin {
                origin.x = leftX
            }
        case .belowAttached:
            let aboveY = anchorScreenRect.maxY
            if origin.y < visibleFrame.minY + screenMargin,
               aboveY + contentSize.height <= visibleFrame.maxY - screenMargin {
                origin.y = aboveY
            }
        case .leftTopAttached:
            let rightX = anchorScreenRect.maxX
            if origin.x < visibleFrame.minX + screenMargin,
               rightX + contentSize.width <= visibleFrame.maxX - screenMargin {
                origin.x = rightX
            }
        case .rightTopAttached:
            let leftX = anchorScreenRect.minX - contentSize.width
            if origin.x + contentSize.width > visibleFrame.maxX - screenMargin,
               leftX >= visibleFrame.minX + screenMargin {
                origin.x = leftX
            }
        }

        let minimumX = visibleFrame.minX + screenMargin
        let minimumY = visibleFrame.minY + screenMargin
        let maximumX = max(minimumX, visibleFrame.maxX - contentSize.width - screenMargin)
        let maximumY = max(minimumY, visibleFrame.maxY - contentSize.height - screenMargin)
        origin.x = min(max(origin.x, minimumX), maximumX)
        origin.y = min(max(origin.y, minimumY), maximumY)
        return origin
    }
}

/// Timing shared by the AppKit and SwiftUI custom-tooltip APIs.
///
/// `showDelay` applies to a cold hover. After a tooltip has been visible in the
/// same window, moving directly to another registered view skips that view's
/// delay so the handoff matches the warm behavior of system tooltips.
struct CustomTooltipConfiguration: Equatable {
    static let `default` = CustomTooltipConfiguration()

    var showDelay: TimeInterval
    var displayDuration: TimeInterval?
    var placement: CustomTooltipPlacement
    var handoffDelay: TimeInterval
    var handoffGroup: CustomTooltipHandoffGroup
    var handoffFrameAnimationDuration: TimeInterval

    /// - Parameters:
    ///   - showDelay: Time the pointer must remain over a cold host before the
    ///     tooltip appears.
    ///   - displayDuration: Maximum visible time. Pass `nil` to keep the
    ///     tooltip visible until the pointer or window lifecycle dismisses it.
    init(
        showDelay: TimeInterval = 0.3,
        displayDuration: TimeInterval? = 10,
        placement: CustomTooltipPlacement = .below,
        handoffDelay: TimeInterval = 0,
        handoffGroup: CustomTooltipHandoffGroup = .standard,
        handoffFrameAnimationDuration: TimeInterval = 0
    ) {
        self.showDelay = showDelay
        self.displayDuration = displayDuration
        self.placement = placement
        self.handoffDelay = handoffDelay
        self.handoffGroup = handoffGroup
        self.handoffFrameAnimationDuration = handoffFrameAnimationDuration
    }

    // Sidebar preview registrations survive position changes; resolve their edge when shown.
    var presentationPlacement: CustomTooltipPlacement {
        guard handoffGroup == .tabPreview,
              placement == .rightTopAttached || placement == .leftTopAttached else { return placement }
        return SidebarPosition.isOnRight ? .leftTopAttached : .rightTopAttached
    }

    fileprivate var normalizedShowDelay: TimeInterval {
        max(0, showDelay)
    }

    fileprivate var normalizedDisplayDuration: TimeInterval? {
        displayDuration.map { max(0, $0) }
    }

    fileprivate var normalizedHandoffDelay: TimeInterval {
        max(0, handoffDelay)
    }

    fileprivate var normalizedHandoffFrameAnimationDuration: TimeInterval {
        max(0, handoffFrameAnimationDuration)
    }
}

/// Default chrome used by the string-based custom-tooltip overloads.
/// Callers that need a different style can use the `@ViewBuilder` overload and
/// provide a fully styled SwiftUI view instead.
struct DefaultCustomTooltipContent: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1))
            }
            .fixedSize()
    }
}

@MainActor
protocol CustomTooltipPresenting: AnyObject {
    var isVisible: Bool { get }
    var surfaceIdentifiers: (panel: ObjectIdentifier, hostingView: ObjectIdentifier)? { get }

    func present(
        content: AnyView,
        anchorScreenRect: CGRect,
        screen: NSScreen?,
        themeProvider: ThemeStateProvider,
        placement: CustomTooltipPlacement,
        frameAnimationDuration: TimeInterval
    )
    func dismiss()
}

typealias CustomTooltipPresentationPreparation = @MainActor () -> Bool
typealias CustomTooltipAnchorRectProvider = @MainActor (NSView) -> CGRect

@MainActor
private struct CustomTooltipThemedContent: View {
    @ObservedObject var observer: ThemeObserver
    let content: AnyView

    var body: some View {
        content
            .environment(\.phiThemeObserver, observer)
            .environment(\.phiTheme, observer.theme)
            .environment(\.phiAppearance, observer.appearance)
            .environment(\.colorScheme, observer.appearance.isDark ? .dark : .light)
    }
}

/// Owns the one reusable panel and hosting view used by a source window.
@MainActor
private final class CustomTooltipPanelPresenter: CustomTooltipPresenting {
    private weak var sourceWindow: NSWindow?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var themeProvider: ThemeStateProvider?
    private var themeObserver: ThemeObserver?
    private var appearanceSubscription: AnyObject?

    private(set) var isVisible = false

    var surfaceIdentifiers: (panel: ObjectIdentifier, hostingView: ObjectIdentifier)? {
        guard let panel, let hostingView else { return nil }
        return (ObjectIdentifier(panel), ObjectIdentifier(hostingView))
    }

    init(sourceWindow: NSWindow) {
        self.sourceWindow = sourceWindow
    }

    func present(
        content: AnyView,
        anchorScreenRect: CGRect,
        screen: NSScreen?,
        themeProvider: ThemeStateProvider,
        placement: CustomTooltipPlacement,
        frameAnimationDuration: TimeInterval
    ) {
        guard let sourceWindow else { return }
        let (panel, hostingView) = ensureSurface()
        bindTheme(to: themeProvider, panel: panel)

        guard let themeObserver else { return }
        hostingView.rootView = AnyView(
            CustomTooltipThemedContent(observer: themeObserver, content: content)
        )
        hostingView.layoutSubtreeIfNeeded()

        let visibleFrame = (screen ?? sourceWindow.screen ?? NSScreen.main)?.visibleFrame
        var size = hostingView.fittingSize
        if let visibleFrame {
            size.width = min(max(size.width, 1), max(1, visibleFrame.width - 8))
            size.height = min(max(size.height, 1), max(1, visibleFrame.height - 8))
        } else {
            size.width = max(size.width, 1)
            size.height = max(size.height, 1)
        }

        let origin = CustomTooltipGeometry.origin(
            contentSize: size,
            anchorScreenRect: anchorScreenRect,
            visibleFrame: visibleFrame,
            placement: placement
        )

        let targetFrame = CGRect(origin: origin, size: size)
        if isVisible,
           panel.isVisible,
           frameAnimationDuration > 0,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           panel.frame != targetFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = frameAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
        if panel.parent !== sourceWindow {
            panel.parent?.removeChildWindow(panel)
            sourceWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        isVisible = true
    }

    func dismiss() {
        guard let panel else { return }
        panel.orderOut(nil)
        hostingView?.rootView = AnyView(EmptyView())
        isVisible = false
    }

    private func ensureSurface() -> (NSPanel, NSHostingView<AnyView>) {
        if let panel, let hostingView {
            return (panel, hostingView)
        }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]

        let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
        return (panel, hostingView)
    }

    private func bindTheme(to provider: ThemeStateProvider, panel: NSPanel) {
        if themeProvider !== provider {
            themeProvider = provider
            if let themeObserver {
                themeObserver.rebind(to: provider)
            } else {
                themeObserver = ThemeObserver(themeSource: provider)
            }

            appearanceSubscription = provider.subscribe { [weak panel] _, appearance in
                DispatchQueue.main.async {
                    panel?.appearance = appearance.nsAppearance
                }
            }
        }
        panel.appearance = provider.currentAppearance.nsAppearance
    }
}

@MainActor
private final class CustomTooltipRequest {
    let ownerID: UUID
    weak var anchorView: NSView?
    var content: AnyView
    var configuration: CustomTooltipConfiguration
    var anchorRectProvider: CustomTooltipAnchorRectProvider?
    var prepareForPresentation: CustomTooltipPresentationPreparation?

    init(
        ownerID: UUID,
        anchorView: NSView,
        content: AnyView,
        configuration: CustomTooltipConfiguration,
        anchorRectProvider: CustomTooltipAnchorRectProvider?,
        prepareForPresentation: CustomTooltipPresentationPreparation?
    ) {
        self.ownerID = ownerID
        self.anchorView = anchorView
        self.content = content
        self.configuration = configuration
        self.anchorRectProvider = anchorRectProvider
        self.prepareForPresentation = prepareForPresentation
    }
}

/// Window-scoped state machine for every AppKit and SwiftUI custom tooltip in
/// that window. The source window retains this object through an associated
/// object; the controller keeps only a weak reference back to the window.
@MainActor
final class CustomTooltipController {
    typealias Scheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> AnyCancellable
    typealias ThemeProviderResolver = @MainActor (NSWindow) -> ThemeStateProvider

    private static let warmGrace: TimeInterval = 0.3
    private static let pointerWatchdogInterval: TimeInterval = 0.1

    private weak var window: NSWindow?
    private let presenter: CustomTooltipPresenting
    private let scheduler: Scheduler
    private let now: () -> Date
    private let mouseLocation: () -> CGPoint
    private let isEligibleForPresentation: (NSWindow) -> Bool
    private let themeProvider: ThemeProviderResolver

    private var pendingRequest: CustomTooltipRequest?
    private var activeRequest: CustomTooltipRequest?
    private var pendingTask: AnyCancellable?
    private var durationTask: AnyCancellable?
    private var handoffDismissTask: AnyCancellable?
    private var handoffDismissOwnerID: UUID?
    private var pointerWatchdog: Timer?
    private var warmUntil: Date?
    private var warmHandoffGroup: CustomTooltipHandoffGroup?
    private var lifecycleObservers: [NSObjectProtocol] = []

    var pendingOwnerID: UUID? { pendingRequest?.ownerID }
    var activeOwnerID: UUID? { activeRequest?.ownerID }
    var isVisible: Bool { presenter.isVisible }
    var surfaceIdentifiers: (panel: ObjectIdentifier, hostingView: ObjectIdentifier)? {
        presenter.surfaceIdentifiers
    }

    init(
        window: NSWindow,
        presenter: CustomTooltipPresenting? = nil,
        scheduler: Scheduler? = nil,
        now: @escaping () -> Date = Date.init,
        mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        isEligibleForPresentation: ((NSWindow) -> Bool)? = nil,
        themeProvider: ThemeProviderResolver? = nil
    ) {
        self.window = window
        self.presenter = presenter ?? CustomTooltipPanelPresenter(sourceWindow: window)
        self.scheduler = scheduler ?? CustomTooltipController.schedule
        self.now = now
        self.mouseLocation = mouseLocation
        self.isEligibleForPresentation = isEligibleForPresentation ?? { window in
            NSApp.isActive && window.isKeyWindow && window.isVisible && !window.isMiniaturized
        }
        self.themeProvider = themeProvider ?? { $0.themeStateProvider }
        observeLifecycle(of: window)
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        pointerWatchdog?.invalidate()
        pendingTask?.cancel()
        durationTask?.cancel()
        handoffDismissTask?.cancel()
    }

    func pointerEntered(
        ownerID: UUID,
        anchorView: NSView,
        content: AnyView,
        configuration: CustomTooltipConfiguration,
        anchorRectProvider: CustomTooltipAnchorRectProvider? = nil,
        prepareForPresentation: CustomTooltipPresentationPreparation? = nil
    ) {
        let request = CustomTooltipRequest(
            ownerID: ownerID,
            anchorView: anchorView,
            content: content,
            configuration: configuration,
            anchorRectProvider: anchorRectProvider,
            prepareForPresentation: prepareForPresentation
        )

        pendingTask?.cancel()
        pendingTask = nil
        pendingRequest = nil

        let hasActiveRequestInGroup = activeRequest?.configuration.handoffGroup
            == configuration.handoffGroup
        if activeRequest != nil, !hasActiveRequestInGroup {
            hideActive(preserveWarmth: false)
        }

        if hasActiveRequestInGroup
            || isWarm(for: configuration.handoffGroup)
            || configuration.normalizedShowDelay == 0 {
            show(request)
            return
        }

        warmUntil = nil
        warmHandoffGroup = nil
        schedulePendingPresentation(request)
    }

    func update(
        ownerID: UUID,
        anchorView: NSView,
        content: AnyView,
        configuration: CustomTooltipConfiguration,
        anchorRectProvider: CustomTooltipAnchorRectProvider? = nil,
        prepareForPresentation: CustomTooltipPresentationPreparation? = nil
    ) {
        if let pendingRequest, pendingRequest.ownerID == ownerID {
            let previousShowDelay = pendingRequest.configuration.normalizedShowDelay
            pendingRequest.anchorView = anchorView
            pendingRequest.content = content
            pendingRequest.configuration = configuration
            pendingRequest.anchorRectProvider = anchorRectProvider
            pendingRequest.prepareForPresentation = prepareForPresentation
            if previousShowDelay != configuration.normalizedShowDelay {
                schedulePendingPresentation(pendingRequest)
            }
            return
        }

        guard let activeRequest, activeRequest.ownerID == ownerID else { return }
        let previousDisplayDuration = activeRequest.configuration.normalizedDisplayDuration
        activeRequest.anchorView = anchorView
        activeRequest.content = content
        activeRequest.configuration = configuration
        activeRequest.anchorRectProvider = anchorRectProvider
        activeRequest.prepareForPresentation = prepareForPresentation
        refreshVisibleRequest(activeRequest)
        if self.activeRequest === activeRequest,
           previousDisplayDuration != configuration.normalizedDisplayDuration {
            startDisplayDurationTimer(for: activeRequest)
        }
    }

    func pointerExited(ownerID: UUID) {
        if pendingRequest?.ownerID == ownerID {
            pendingTask?.cancel()
            pendingTask = nil
            pendingRequest = nil
        }

        guard activeRequest?.ownerID == ownerID else { return }
        let delay = activeRequest?.configuration.normalizedHandoffDelay ?? 0
        guard delay > 0 else {
            hideActive(preserveWarmth: true)
            return
        }
        scheduleHandoffDismissal(ownerID: ownerID, delay: delay)
    }

    func dismiss(ownerID: UUID) {
        if pendingRequest?.ownerID == ownerID {
            pendingTask?.cancel()
            pendingTask = nil
            pendingRequest = nil
        }
        if handoffDismissOwnerID == ownerID {
            cancelHandoffDismissal()
        }
        guard activeRequest?.ownerID == ownerID else { return }
        hideActive(preserveWarmth: false)
    }

    func dismissAll() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingRequest = nil
        cancelHandoffDismissal()
        hideActive(preserveWarmth: false)
    }

    private func isWarm(for handoffGroup: CustomTooltipHandoffGroup) -> Bool {
        if activeRequest != nil { return true }
        guard warmHandoffGroup == handoffGroup,
              let warmUntil else { return false }
        return now() < warmUntil
    }

    private func schedulePendingPresentation(_ request: CustomTooltipRequest) {
        pendingTask?.cancel()
        pendingTask = nil
        pendingRequest = nil

        let delay = request.configuration.normalizedShowDelay
        guard delay > 0 else {
            show(request)
            return
        }

        pendingRequest = request
        pendingTask = scheduler(delay) { [weak self, weak request] in
            guard let self, let request, self.pendingRequest === request else { return }
            self.pendingTask = nil
            self.pendingRequest = nil
            self.show(request)
        }
    }

    private func show(_ request: CustomTooltipRequest) {
        guard let context = presentationContext(for: request) else { return }
        guard request.prepareForPresentation?() != false else { return }
        cancelHandoffDismissal()
        let previousHandoffGroup = activeRequest?.configuration.handoffGroup
        let isNewOwner = activeRequest?.ownerID != request.ownerID
        let shouldAnimateFrame = presenter.isVisible
            && isNewOwner
            && previousHandoffGroup == request.configuration.handoffGroup
        activeRequest = request
        warmUntil = nil
        warmHandoffGroup = nil

        presenter.present(
            content: request.content,
            anchorScreenRect: context.anchorScreenRect,
            screen: context.screen,
            themeProvider: context.themeProvider,
            placement: request.configuration.presentationPlacement,
            frameAnimationDuration: shouldAnimateFrame
                ? request.configuration.normalizedHandoffFrameAnimationDuration
                : 0
        )
        startPointerWatchdog()

        if isNewOwner {
            startDisplayDurationTimer(for: request)
        }
    }

    private func refreshVisibleRequest(_ request: CustomTooltipRequest) {
        guard let context = presentationContext(for: request) else {
            hideActive(preserveWarmth: false)
            return
        }
        guard request.prepareForPresentation?() != false else {
            hideActive(preserveWarmth: false)
            return
        }
        cancelHandoffDismissal()
        presenter.present(
            content: request.content,
            anchorScreenRect: context.anchorScreenRect,
            screen: context.screen,
            themeProvider: context.themeProvider,
            placement: request.configuration.presentationPlacement,
            frameAnimationDuration: 0
        )
    }

    private func presentationContext(
        for request: CustomTooltipRequest
    ) -> (anchorScreenRect: CGRect, screen: NSScreen?, themeProvider: ThemeStateProvider)? {
        guard let window,
              let anchorView = request.anchorView,
              anchorView.window === window,
              !anchorView.isHiddenOrHasHiddenAncestor,
              isEligibleForPresentation(window) else {
            return nil
        }

        let visibleBounds = anchorView.bounds.intersection(anchorView.visibleRect)
        guard !visibleBounds.isEmpty else { return nil }
        let hoverRectInWindow = anchorView.convert(visibleBounds, to: nil)
        let hoverScreenRect = window.convertToScreen(hoverRectInWindow)
        guard hoverScreenRect.contains(mouseLocation()) else { return nil }

        let anchorBounds = (request.anchorRectProvider?(anchorView) ?? anchorView.bounds)
            .intersection(visibleBounds)
        guard !anchorBounds.isEmpty else { return nil }
        let anchorRectInWindow = anchorView.convert(anchorBounds, to: nil)
        let anchorScreenRect = window.convertToScreen(anchorRectInWindow)

        let screen = NSScreen.screens.first { $0.frame.contains(
            CGPoint(x: anchorScreenRect.midX, y: anchorScreenRect.midY)
        ) } ?? window.screen
        return (anchorScreenRect, screen, themeProvider(window))
    }

    private func startDisplayDurationTimer(for request: CustomTooltipRequest) {
        durationTask?.cancel()
        durationTask = nil
        guard let duration = request.configuration.normalizedDisplayDuration else { return }

        durationTask = scheduler(duration) { [weak self, weak request] in
            guard let self, let request, self.activeRequest === request else { return }
            self.durationTask = nil
            self.hideActive(preserveWarmth: false)
        }
    }

    private func hideActive(preserveWarmth: Bool) {
        cancelHandoffDismissal()
        let wasVisible = activeRequest != nil || presenter.isVisible
        let previousHandoffGroup = activeRequest?.configuration.handoffGroup
        activeRequest = nil
        durationTask?.cancel()
        durationTask = nil
        stopPointerWatchdog()
        presenter.dismiss()

        if preserveWarmth, wasVisible {
            warmUntil = now().addingTimeInterval(Self.warmGrace)
            warmHandoffGroup = previousHandoffGroup
        } else {
            warmUntil = nil
            warmHandoffGroup = nil
        }
    }

    private func scheduleHandoffDismissal(ownerID: UUID, delay: TimeInterval) {
        guard handoffDismissOwnerID != ownerID else { return }
        cancelHandoffDismissal()
        handoffDismissOwnerID = ownerID
        stopPointerWatchdog()
        handoffDismissTask = scheduler(delay) { [weak self] in
            guard let self,
                  self.handoffDismissOwnerID == ownerID,
                  self.activeRequest?.ownerID == ownerID else { return }
            self.handoffDismissTask = nil
            self.handoffDismissOwnerID = nil
            self.hideActive(preserveWarmth: false)
        }
    }

    private func cancelHandoffDismissal() {
        handoffDismissTask?.cancel()
        handoffDismissTask = nil
        handoffDismissOwnerID = nil
    }

    private func startPointerWatchdog() {
        guard pointerWatchdog == nil else { return }
        let timer = Timer(timeInterval: Self.pointerWatchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.validatePointerStillInsideActiveHost()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerWatchdog = timer
    }

    private func stopPointerWatchdog() {
        pointerWatchdog?.invalidate()
        pointerWatchdog = nil
    }

    private func validatePointerStillInsideActiveHost() {
        guard let request = activeRequest else {
            stopPointerWatchdog()
            return
        }
        guard let window,
              let anchorView = request.anchorView,
              anchorView.window === window,
              !anchorView.isHiddenOrHasHiddenAncestor else {
            hideActive(preserveWarmth: false)
            return
        }

        let visibleBounds = anchorView.bounds.intersection(anchorView.visibleRect)
        let rectInWindow = anchorView.convert(visibleBounds, to: nil)
        let anchorScreenRect = window.convertToScreen(rectInWindow)
        guard anchorScreenRect.contains(mouseLocation()) else {
            pointerExited(ownerID: request.ownerID)
            return
        }
    }

    private func observeLifecycle(of window: NSWindow) {
        let center = NotificationCenter.default
        let windowNotifications: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
        ]
        for name in windowNotifications {
            lifecycleObservers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.dismissAll()
                    }
                }
            )
        }

        let applicationNotifications: [Notification.Name] = [
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
        ]
        for name in applicationNotifications {
            lifecycleObservers.append(
                center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.dismissAll()
                    }
                }
            )
        }
    }

    private static func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return AnyCancellable { timer.invalidate() }
    }
}

private var customTooltipControllerKey: UInt8 = 0

@MainActor
extension NSWindow {
    /// The single reusable custom-tooltip controller owned by this window.
    var customTooltipController: CustomTooltipController {
        if let controller = objc_getAssociatedObject(
            self,
            &customTooltipControllerKey
        ) as? CustomTooltipController {
            return controller
        }

        let controller = CustomTooltipController(window: self)
        objc_setAssociatedObject(
            self,
            &customTooltipControllerKey,
            controller,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return controller
    }
}
