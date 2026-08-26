// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

enum PhiAlertLayout {
    static let width: CGFloat = 465
    static let contentWidth: CGFloat = 417
    static let outerPadding: CGFloat = 24
    static let cornerRadius: CGFloat = 24
    static let iconToCopySpacing: CGFloat = 24
    static let copySpacing: CGFloat = 16
    static let actionsSpacing: CGFloat = 36
    static let iconSize = CGSize(width: 24, height: 28.4)
    static let titleHeight: CGFloat = 16
    static let actionHeight: CGFloat = 36
    static let minimumContentHeight: CGFloat = 16
    static let defaultMaximumHeight: CGFloat = 600

    static var fixedChromeHeight: CGFloat {
        outerPadding * 2
            + iconSize.height
            + titleHeight
            + iconToCopySpacing
            + copySpacing
            + actionsSpacing
            + actionHeight
    }

    static func normalizedMaximumHeight(_ maximumHeight: CGFloat) -> CGFloat {
        max(maximumHeight, fixedChromeHeight + minimumContentHeight)
    }

    static func maximumScrollableContentHeight(for maximumHeight: CGFloat) -> CGFloat {
        normalizedMaximumHeight(maximumHeight) - fixedChromeHeight
    }
}

/// A fixed-width, window-themed alert surface matching the shared Phi alert design.
///
/// The icon and title remain fixed while the supplied content scrolls after the
/// alert reaches `maximumHeight`. Callers own the content and action views, so
/// controls beyond the standard buttons can be composed without changing the
/// alert container.
struct PhiAlert<Icon: View, AlertContent: View, Actions: View>: View {
    let title: String
    let maximumHeight: CGFloat
    @ViewBuilder let icon: Icon
    @ViewBuilder let content: AlertContent
    @ViewBuilder let actions: Actions

    @Environment(\.phiAppearance) private var appearance

    init(
        title: String,
        maximumHeight: CGFloat = PhiAlertLayout.defaultMaximumHeight,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder content: () -> AlertContent,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.maximumHeight = maximumHeight
        self.icon = icon()
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PhiAlertLayout.actionsSpacing) {
            headerAndContent

            actions
                .frame(
                    width: PhiAlertLayout.contentWidth,
                    height: PhiAlertLayout.actionHeight
                )
        }
        .padding(PhiAlertLayout.outerPadding)
        .frame(width: PhiAlertLayout.width)
        .background {
            RoundedRectangle(
                cornerRadius: PhiAlertLayout.cornerRadius,
                style: .continuous
            )
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(
                    cornerRadius: PhiAlertLayout.cornerRadius,
                    style: .continuous
                )
                .fill(backgroundTint)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: PhiAlertLayout.cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: PhiAlertLayout.cornerRadius,
                style: .continuous
            )
            .strokeBorder(.white.opacity(appearance.isLight ? 0.5 : 0.12))
        }
    }

    private var backgroundTint: Color {
        if appearance.isLight {
            return Color(
                red: 246.0 / 255.0,
                green: 246.0 / 255.0,
                blue: 246.0 / 255.0
            )
            .opacity(0.8)
        }

        return Color(nsColor: .windowBackgroundColor).opacity(0.8)
    }

    private var headerAndContent: some View {
        VStack(alignment: .leading, spacing: PhiAlertLayout.iconToCopySpacing) {
            iconView

            VStack(alignment: .leading, spacing: PhiAlertLayout.copySpacing) {
                titleView
                scrollableContent
            }
        }
    }

    private var iconView: some View {
        icon
            .frame(
                width: PhiAlertLayout.iconSize.width,
                height: PhiAlertLayout.iconSize.height,
                alignment: .center
            )
    }

    private var titleView: some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .themedForeground(.textPrimaryStrong)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: PhiAlertLayout.titleHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var scrollableContent: some View {
        ScrollView(.vertical) {
            content
                .font(.system(size: 14))
                .themedForeground(.textPrimary)
                .frame(
                    width: PhiAlertLayout.contentWidth,
                    alignment: .topLeading
                )
        }
        .frame(width: PhiAlertLayout.contentWidth, alignment: .top)
        .frame(
            maxHeight: PhiAlertLayout.maximumScrollableContentHeight(
                for: maximumHeight
            ),
            alignment: .top
        )
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Figma-compatible action placement for one, two, or three custom button views.
///
/// With three actions, the leading action stays on the left and the secondary
/// and primary actions form a trailing group. One- and two-action variants keep
/// all visible actions trailing.
struct PhiAlertActions<LeadingAction: View, SecondaryAction: View, PrimaryAction: View>: View {
    @ViewBuilder let leadingAction: LeadingAction
    @ViewBuilder let secondaryAction: SecondaryAction
    @ViewBuilder let primaryAction: PrimaryAction

    init(
        @ViewBuilder leadingAction: () -> LeadingAction,
        @ViewBuilder secondaryAction: () -> SecondaryAction,
        @ViewBuilder primaryAction: () -> PrimaryAction
    ) {
        self.leadingAction = leadingAction()
        self.secondaryAction = secondaryAction()
        self.primaryAction = primaryAction()
    }

    var body: some View {
        HStack(spacing: 0) {
            leadingAction
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                secondaryAction
                primaryAction
            }
        }
    }
}

extension PhiAlertActions where LeadingAction == EmptyView {
    init(
        @ViewBuilder secondaryAction: () -> SecondaryAction,
        @ViewBuilder primaryAction: () -> PrimaryAction
    ) {
        self.leadingAction = EmptyView()
        self.secondaryAction = secondaryAction()
        self.primaryAction = primaryAction()
    }
}

extension PhiAlertActions where LeadingAction == EmptyView, SecondaryAction == EmptyView {
    init(@ViewBuilder primaryAction: () -> PrimaryAction) {
        self.leadingAction = EmptyView()
        self.secondaryAction = EmptyView()
        self.primaryAction = primaryAction()
    }
}

enum PhiAlertButtonRole: Equatable {
    case primary
    case secondary
    case destructive
}

/// A standard text action used by the AppKit alert bridge.
///
/// The response is returned through the presentation completion handler. Use
/// AppKit's alert response constants when migrating an existing `NSAlert`.
struct PhiAlertAppKitAction {
    let title: String
    let role: PhiAlertButtonRole
    let response: NSApplication.ModalResponse

    init(
        _ title: String,
        role: PhiAlertButtonRole = .secondary,
        response: NSApplication.ModalResponse
    ) {
        self.title = title
        self.role = role
        self.response = response
    }
}

/// AppKit-facing configuration for the standard text-and-buttons alert.
///
/// The overloads model the three layouts from the design: a trailing primary
/// action, a trailing secondary-primary pair, or a leading action plus the
/// trailing pair. `Style` controls the confirmation button color for every
/// layout. Use the SwiftUI `PhiAlert` initializer when the content or action
/// views need complete customization.
struct PhiAlertAppKitConfiguration {
    enum Style: Equatable {
        case normal
        case critical

        var confirmationButtonRole: PhiAlertButtonRole {
            switch self {
            case .normal:
                return .primary
            case .critical:
                return .destructive
            }
        }
    }

    /// Which button the Return key activates, matching AppKit's notion of a
    /// default button.
    enum DefaultButton: Equatable {
        /// The confirmation button, as in a standard alert.
        case confirmation
        /// No button at all. Irreversible confirmations use this so a
        /// reflexive Return cannot destroy anything; Escape still cancels.
        case noButton
    }

    let title: String
    let message: String
    let icon: NSImage
    let maximumHeight: CGFloat
    let style: Style
    let defaultButton: DefaultButton
    let actions: [PhiAlertAppKitAction]

    init(
        title: String,
        message: String,
        icon: NSImage,
        maximumHeight: CGFloat = PhiAlertLayout.defaultMaximumHeight,
        style: Style = .normal,
        defaultButton: DefaultButton = .confirmation,
        primaryAction: PhiAlertAppKitAction
    ) {
        self.init(
            title: title,
            message: message,
            icon: icon,
            maximumHeight: maximumHeight,
            style: style,
            defaultButton: defaultButton,
            actions: [primaryAction]
        )
    }

    init(
        title: String,
        message: String,
        icon: NSImage = .phiAlertIcon,
        maximumHeight: CGFloat = PhiAlertLayout.defaultMaximumHeight,
        style: Style = .normal,
        defaultButton: DefaultButton = .confirmation,
        secondaryAction: PhiAlertAppKitAction,
        primaryAction: PhiAlertAppKitAction
    ) {
        self.init(
            title: title,
            message: message,
            icon: icon,
            maximumHeight: maximumHeight,
            style: style,
            defaultButton: defaultButton,
            actions: [secondaryAction, primaryAction]
        )
    }

    init(
        title: String,
        message: String,
        icon: NSImage,
        maximumHeight: CGFloat = PhiAlertLayout.defaultMaximumHeight,
        style: Style = .normal,
        defaultButton: DefaultButton = .confirmation,
        leadingAction: PhiAlertAppKitAction,
        secondaryAction: PhiAlertAppKitAction,
        primaryAction: PhiAlertAppKitAction
    ) {
        self.init(
            title: title,
            message: message,
            icon: icon,
            maximumHeight: maximumHeight,
            style: style,
            defaultButton: defaultButton,
            actions: [leadingAction, secondaryAction, primaryAction]
        )
    }

    private init(
        title: String,
        message: String,
        icon: NSImage,
        maximumHeight: CGFloat,
        style: Style,
        defaultButton: DefaultButton,
        actions: [PhiAlertAppKitAction]
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.maximumHeight = maximumHeight
        self.style = style
        self.defaultButton = defaultButton
        self.actions = actions
    }
}

/// The default 130-by-36 alert button. Callers can place any other button view
/// in `PhiAlertActions` when a flow needs different styling or behavior.
struct PhiAlertButton<Label: View>: View {
    let role: PhiAlertButtonRole
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovered = false

    init(
        role: PhiAlertButtonRole = .secondary,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(PhiAlertButtonStyle(role: role, isHovered: isHovered))
        .frame(width: 130, height: PhiAlertLayout.actionHeight)
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
    }
}

extension PhiAlertButton where Label == Text {
    init(
        _ title: String,
        role: PhiAlertButtonRole = .secondary,
        action: @escaping () -> Void
    ) {
        self.init(role: role, action: action) {
            Text(title)
        }
    }
}

private struct PhiAlertButtonStyle: ButtonStyle {
    let role: PhiAlertButtonRole
    let isHovered: Bool

    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(foregroundColor)
            .background(
                backgroundColor.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var backgroundColor: Color {
        switch role {
        case .primary:
            let color = isHovered
                ? ThemedColor.themeColorOnHover
                : ThemedColor.themeColor
            return color.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
        case .secondary:
            return Color(
                nsColor: NSColor(
                    calibratedWhite: secondaryBackgroundWhite,
                    alpha: 1
                )
            )
        case .destructive:
            return Color(nsColor: .systemRed)
                .opacity(isHovered ? 0.82 : 1)
        }
    }

    private var secondaryBackgroundWhite: CGFloat {
        if appearance.isLight {
            return isHovered ? 0.82 : 0.88
        }

        return isHovered ? 0.30 : 0.24
    }

    private var foregroundColor: Color {
        switch role {
        case .primary, .destructive:
            return .white
        case .secondary:
            return ThemedColor.textPrimary.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
        }
    }

    private var borderOpacity: Double {
        role == .secondary ? 0.25 : 0.35
    }
}

private struct PhiAlertAppKitContent: View {
    let configuration: PhiAlertAppKitConfiguration
    let dismiss: PhiAlertDismissAction

    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        PhiAlert(
            title: configuration.title,
            maximumHeight: configuration.maximumHeight
        ) {
            Image(nsImage: configuration.icon)
                .renderingMode(configuration.icon.isTemplate ? .template : .original)
                .foregroundStyle(appearance.isLight ? Color.black : Color.white)
        } content: {
            Text(configuration.message)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            PhiAlertAppKitActions(
                actions: configuration.actions,
                confirmationButtonRole: configuration.style.confirmationButtonRole,
                defaultButton: configuration.defaultButton,
                dismiss: dismiss
            )
        }
    }
}

private struct PhiAlertAppKitActions: View {
    let actions: [PhiAlertAppKitAction]
    let confirmationButtonRole: PhiAlertButtonRole
    let defaultButton: PhiAlertAppKitConfiguration.DefaultButton
    let dismiss: PhiAlertDismissAction

    /// Nil leaves the confirmation button off the Return key, which is what
    /// `DefaultButton.noButton` asks for.
    private var confirmationShortcut: KeyboardShortcut? {
        defaultButton == .confirmation ? .defaultAction : nil
    }

    @ViewBuilder
    var body: some View {
        switch actions.count {
        case 1:
            PhiAlertActions {
                button(for: actions[0], role: confirmationButtonRole)
                    .keyboardShortcut(confirmationShortcut)
            }
        case 2:
            PhiAlertActions(
                secondaryAction: {
                    button(for: actions[0])
                        .keyboardShortcut(.cancelAction)
                },
                primaryAction: {
                    button(for: actions[1], role: confirmationButtonRole)
                        .keyboardShortcut(confirmationShortcut)
                }
            )
        case 3:
            PhiAlertActions(
                leadingAction: {
                    button(for: actions[0])
                },
                secondaryAction: {
                    button(for: actions[1])
                        .keyboardShortcut(.cancelAction)
                },
                primaryAction: {
                    button(for: actions[2], role: confirmationButtonRole)
                        .keyboardShortcut(confirmationShortcut)
                }
            )
        default:
            EmptyView()
        }
    }

    private func button(
        for action: PhiAlertAppKitAction,
        role: PhiAlertButtonRole? = nil
    ) -> some View {
        PhiAlertButton(action.title, role: role ?? action.role) {
            dismiss(action.response)
        }
    }
}

@MainActor
struct PhiAlertDismissAction {
    private let handler: (NSApplication.ModalResponse) -> Void

    fileprivate init(handler: @escaping (NSApplication.ModalResponse) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ response: NSApplication.ModalResponse = .cancel) {
        handler(response)
    }
}

private final class PhiAlertWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PhiAlertQuitConfirmationAction {
    var handler: (() -> Void)?
}

/// Presents a SwiftUI `PhiAlert` through AppKit as a window-attached sheet, as
/// a non-modal panel attached to a window, or as a standalone centered panel.
/// Every entry point shares the same window construction, theme subscription,
/// and dismissal path.
@MainActor
final class PhiAlertPresenter {
    private static let synchronousEventPumpModes: [RunLoop.Mode] = [
        .eventTracking,
        .default,
    ]
    private static let synchronousEventPumpSliceDuration: TimeInterval = 1.0 / 120.0

    private enum PresentationStyle {
        case none
        case sheet
        case standalone
        case nonModal
    }

    private weak var sourceWindow: NSWindow?
    private var alertWindow: NSWindow?
    private var appearanceSubscription: AnyObject?
    private var parentCloseObservation: NSObjectProtocol?
    private var frameObservations: [NSObjectProtocol] = []
    /// Where the alert's top-left corner sits, so a content-driven resize can
    /// put it back there (see `observeAlertWindowFrame`). Nil until the window
    /// has been placed.
    private var anchoredTopLeft: CGPoint?
    /// Strong self-reference held while a non-modal alert is on screen. A
    /// sheet is kept alive by AppKit's sheet completion handler and the
    /// synchronous styles by their calling frame; the non-modal style has
    /// neither, and callers are free to discard the returned handle.
    private var selfReferenceWhilePresented: PhiAlertPresenter?
    private var onDismiss: ((NSApplication.ModalResponse) -> Void)?
    private var presentationStyle = PresentationStyle.none

    private(set) var isPresented = false

    private init(
        sourceWindow: NSWindow?,
        onDismiss: ((NSApplication.ModalResponse) -> Void)?
    ) {
        self.sourceWindow = sourceWindow
        self.onDismiss = onDismiss
    }

    @discardableResult
    static func present<Content: View>(
        over parentWindow: NSWindow,
        onDismiss: ((NSApplication.ModalResponse) -> Void)? = nil,
        @ViewBuilder content: (PhiAlertDismissAction) -> Content
    ) -> PhiAlertPresenter {
        let presenter = PhiAlertPresenter(
            sourceWindow: parentWindow,
            onDismiss: onDismiss
        )
        let dismiss = PhiAlertDismissAction { [weak presenter] response in
            presenter?.dismiss(response)
        }
        presenter.presentSheet(content: content(dismiss))
        return presenter
    }

    /// Presents the alert as a floating panel attached to `parentWindow`
    /// instead of a sheet, leaving that window fully usable: tab switching,
    /// scrolling, and clicking all keep working while the panel is up. The
    /// parent/child relationship keeps the panel above its window, moves it
    /// with the window, hides it with the window, and ends the presentation
    /// when the window closes.
    @discardableResult
    static func presentNonModally<Content: View>(
        over parentWindow: NSWindow,
        onDismiss: ((NSApplication.ModalResponse) -> Void)? = nil,
        @ViewBuilder content: (PhiAlertDismissAction) -> Content
    ) -> PhiAlertPresenter {
        let presenter = PhiAlertPresenter(
            sourceWindow: parentWindow,
            onDismiss: onDismiss
        )
        let dismiss = PhiAlertDismissAction { [weak presenter] response in
            presenter?.dismiss(response)
        }
        presenter.presentNonModal(content: content(dismiss))
        return presenter
    }

    static func runSheetSynchronously<Content: View>(
        over sourceWindow: NSWindow,
        @ViewBuilder content: (PhiAlertDismissAction) -> Content
    ) -> NSApplication.ModalResponse {
        let presenter = PhiAlertPresenter(
            sourceWindow: sourceWindow,
            onDismiss: nil
        )
        let dismiss = PhiAlertDismissAction { [weak presenter] response in
            presenter?.dismiss(response)
        }
        return presenter.runSheetSynchronously(content: content(dismiss))
    }

    /// Synchronous presentation for callers with no visible window to host a
    /// sheet (e.g. an agent request arriving while every browser window is
    /// closed): the alert floats as its own centered panel, themed from the
    /// shared fallback source.
    static func runStandaloneSynchronously<Content: View>(
        @ViewBuilder content: (PhiAlertDismissAction) -> Content
    ) -> NSApplication.ModalResponse {
        let presenter = PhiAlertPresenter(
            sourceWindow: nil,
            onDismiss: nil
        )
        let dismiss = PhiAlertDismissAction { [weak presenter] response in
            presenter?.dismiss(response)
        }
        return presenter.runStandaloneSynchronously(content: content(dismiss))
    }

    func dismiss(_ response: NSApplication.ModalResponse = .cancel) {
        guard let alertWindow else { return }

        switch presentationStyle {
        case .sheet:
            if let sheetParent = alertWindow.sheetParent {
                sheetParent.endSheet(alertWindow, returnCode: response)
            } else {
                alertWindow.close()
                completeDismissal(response)
            }
        case .nonModal:
            alertWindow.parent?.removeChildWindow(alertWindow)
            alertWindow.close()
            completeDismissal(response)
        case .none, .standalone:
            alertWindow.close()
            completeDismissal(response)
        }
    }

    /// Brings a presented alert back in front of its parent window. The
    /// account flows call this from the guard that refuses a second
    /// presentation, so clicking an entry point whose panel is already up
    /// finds that panel instead of doing nothing.
    ///
    /// The parent comes forward first so the panel is not left floating above
    /// a window buried behind another one, and the panel takes the keyboard:
    /// the user clicked the entry point to answer the panel, and a recalled
    /// panel that ignores typing is no better than a lost one.
    func bringToFront() {
        guard isPresented, let alertWindow else { return }

        alertWindow.parent?.orderFront(nil)
        alertWindow.makeKeyAndOrderFront(nil)
    }

    private func presentSheet<Content: View>(content: Content) {
        guard let sourceWindow else { return }

        let alertWindow = makeAlertWindow(
            content: content,
            themeProvider: sourceWindow.themeStateProvider
        )
        presentationStyle = .sheet
        isPresented = true
        sourceWindow.beginSheet(alertWindow) { [self] response in
            completeDismissal(response)
        }
    }

    private func presentStandalone<Content: View>(content: Content) {
        let alertWindow = makeAlertWindow(
            content: content,
            themeProvider: ThemeManager.shared
        )
        presentationStyle = .standalone
        isPresented = true
        alertWindow.level = .modalPanel
        alertWindow.center()
        NSApp.activate(ignoringOtherApps: false)
        alertWindow.makeKeyAndOrderFront(nil)
    }

    private func presentNonModal<Content: View>(content: Content) {
        guard let sourceWindow else { return }

        let alertWindow = makeAlertWindow(
            content: content,
            themeProvider: sourceWindow.themeStateProvider
        )
        presentationStyle = .nonModal
        isPresented = true
        selfReferenceWhilePresented = self
        // A borderless window has no title bar to drag it by, so the panel
        // has to move from its background. The sheet path stays immovable.
        alertWindow.isMovable = true
        alertWindow.isMovableByWindowBackground = true
        // AppKit sizes a sheet to its content when it attaches it; nothing
        // does that for a panel, and the fitting size measured before the
        // hosting view lays out can still be zero.
        if let contentView = alertWindow.contentViewController?.view {
            alertWindow.setContentSize(contentView.fittingSize)
        }
        alertWindow.setFrameOrigin(
            centeredOrigin(for: alertWindow.frame.size, over: sourceWindow)
        )
        observeParentWindowClose(sourceWindow)
        sourceWindow.addChildWindow(alertWindow, ordered: .above)
        alertWindow.makeKeyAndOrderFront(nil)
    }

    /// Centered on the parent's content area rather than on the screen, which
    /// would put the panel somewhere else entirely once the window is not on
    /// the main display.
    private func centeredOrigin(
        for size: CGSize,
        over parentWindow: NSWindow
    ) -> CGPoint {
        let contentRect = parentWindow.contentRect(
            forFrameRect: parentWindow.frame
        )
        return CGPoint(
            x: contentRect.midX - size.width / 2,
            y: contentRect.midY - size.height / 2
        )
    }

    /// The presenting caller tears its flow down from the dismissal
    /// completion, so a parent window closing with a panel up has to run that
    /// same completion — skipping it would leave the caller believing a panel
    /// is still on screen and refusing the next attempt.
    private func observeParentWindowClose(_ parentWindow: NSWindow) {
        parentCloseObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parentWindow,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(.cancel)
            }
        }
    }

    private func runSheetSynchronously<Content: View>(
        content: Content
    ) -> NSApplication.ModalResponse {
        var response: NSApplication.ModalResponse?
        onDismiss = { response = $0 }
        presentSheet(content: content)
        pumpEvents(while: { response == nil && isPresented })
        return response ?? .cancel
    }

    private func runStandaloneSynchronously<Content: View>(
        content: Content
    ) -> NSApplication.ModalResponse {
        var response: NSApplication.ModalResponse?
        onDismiss = { response = $0 }
        presentStandalone(content: content)
        pumpEvents(while: { response == nil && isPresented })
        return response ?? .cancel
    }

    // Chromium owns the outer NSApplication event loop. A nested RunLoop
    // alone does not dequeue NSEvents, so explicitly pump and dispatch them
    // while preserving the synchronous API for the presented alert.
    private func pumpEvents(while shouldContinue: () -> Bool) {
        while shouldContinue() {
            for mode in Self.synchronousEventPumpModes {
                guard shouldContinue() else { break }
                autoreleasepool {
                    let waitUntil = Date(
                        timeIntervalSinceNow: Self.synchronousEventPumpSliceDuration
                    )
                    if let event = NSApp.nextEvent(
                        matching: .any,
                        until: waitUntil,
                        inMode: mode,
                        dequeue: true
                    ) {
                        NSApp.sendEvent(event)
                    }
                }
            }
        }
    }

    private func makeAlertWindow<Content: View>(
        content: Content,
        themeProvider: ThemeStateProvider
    ) -> NSWindow {
        let hostingController = ThemedHostingController(
            rootView: content,
            themeSource: themeProvider
        )
        let fittingSize = hostingController.sizeThatFits(
            in: CGSize(
                width: PhiAlertLayout.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        )

        let alertWindow = PhiAlertWindow(
            contentRect: CGRect(origin: .zero, size: fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        alertWindow.animationBehavior = .alertPanel
        alertWindow.appearance = themeProvider.currentAppearance.nsAppearance
        alertWindow.backgroundColor = .clear
        alertWindow.isOpaque = false
        alertWindow.hasShadow = true
        alertWindow.isMovable = false
        alertWindow.isReleasedWhenClosed = false
        alertWindow.contentViewController = hostingController

        appearanceSubscription = themeProvider.subscribe { [weak alertWindow] _, appearance in
            DispatchQueue.main.async {
                alertWindow?.appearance = appearance.nsAppearance
            }
        }

        observeAlertWindowFrame(alertWindow)
        self.alertWindow = alertWindow
        return alertWindow
    }

    /// Keeps a freestanding alert hanging from its top-left corner while its
    /// content changes size — a disclosure the user opens inside the alert
    /// (the agent consent prompt's command and process tree) is the case this
    /// exists for. The hosting controller reports the new height to the
    /// window, and AppKit resizes a frame around its BOTTOM-left origin, so
    /// without this the panel walks up the screen as it grows and the copy the
    /// user was reading moves out from under them.
    ///
    /// Sheets are left alone: AppKit already anchors those to the top edge of
    /// their parent window and owns their geometry.
    private func observeAlertWindowFrame(_ window: NSWindow) {
        let center = NotificationCenter.default
        frameObservations = [
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: nil
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.anchoredTopLeft = CGPoint(x: window.frame.minX,
                                                    y: window.frame.maxY)
                }
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: nil
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.reanchorAfterResize(window)
                }
            },
        ]
    }

    private func reanchorAfterResize(_ window: NSWindow) {
        // The first resize is the one that sizes the window to its content,
        // before anything has placed it. Record where it lands rather than
        // dragging it to an anchor that doesn't exist yet.
        guard let anchor = anchoredTopLeft else {
            anchoredTopLeft = CGPoint(x: window.frame.minX, y: window.frame.maxY)
            return
        }
        guard presentationStyle == .standalone || presentationStyle == .nonModal else {
            return
        }

        var frame = window.frame
        frame.origin = CGPoint(x: anchor.x, y: anchor.y - frame.height)
        // An alert that grew taller than the room below its anchor is pushed
        // back onto the screen: keeping the top-left corner is the point of
        // this, but not at the cost of the buttons sliding off the bottom.
        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if frame.minY < visibleFrame.minY {
                frame.origin.y = visibleFrame.minY
            }
            // Taller than the screen: the top wins, since that is where the
            // title and the reason for the prompt are.
            if frame.maxY > visibleFrame.maxY {
                frame.origin.y = visibleFrame.maxY - frame.height
            }
        }
        guard frame.origin != window.frame.origin else { return }
        window.setFrameOrigin(frame.origin)
    }

    private func completeDismissal(_ response: NSApplication.ModalResponse) {
        guard isPresented else { return }
        isPresented = false
        presentationStyle = .none
        appearanceSubscription = nil
        if let parentCloseObservation {
            NotificationCenter.default.removeObserver(parentCloseObservation)
            self.parentCloseObservation = nil
        }
        frameObservations.forEach(NotificationCenter.default.removeObserver)
        frameObservations = []
        anchoredTopLeft = nil
        alertWindow = nil
        // Kept on the stack until this returns: for a non-modal alert this is
        // the reference the presenter lives on, and the completion below is
        // free to drop every other one.
        let selfReference = selfReferenceWhilePresented
        selfReferenceWhilePresented = nil
        let completion = onDismiss
        onDismiss = nil
        completion?(response)
        withExtendedLifetime(selfReference) {}
    }
}

@MainActor
extension NSWindow {
    /// Presents the standard alert from AppKit without constructing SwiftUI views.
    @discardableResult
    func presentPhiAlert(
        _ configuration: PhiAlertAppKitConfiguration,
        onDismiss: ((NSApplication.ModalResponse) -> Void)? = nil
    ) -> PhiAlertPresenter {
        presentPhiAlert(onDismiss: onDismiss) { dismiss in
            PhiAlertAppKitContent(
                configuration: configuration,
                dismiss: dismiss
            )
        }
    }

    /// Presents custom SwiftUI alert content using this window's theme context.
    @discardableResult
    func presentPhiAlert<Content: View>(
        onDismiss: ((NSApplication.ModalResponse) -> Void)? = nil,
        @ViewBuilder content: (PhiAlertDismissAction) -> Content
    ) -> PhiAlertPresenter {
        PhiAlertPresenter.present(
            over: self,
            onDismiss: onDismiss,
            content: content
        )
    }

    /// Presents the standard alert as a non-modal panel attached to this
    /// window, which stays usable while the panel is up.
    @discardableResult
    func presentPhiAlertNonModally(
        _ configuration: PhiAlertAppKitConfiguration,
        onDismiss: ((NSApplication.ModalResponse) -> Void)? = nil
    ) -> PhiAlertPresenter {
        presentPhiAlertNonModally(onDismiss: onDismiss) { dismiss in
            PhiAlertAppKitContent(
                configuration: configuration,
                dismiss: dismiss
            )
        }
    }

    /// Presents custom SwiftUI alert content as a non-modal panel using this
    /// window's theme context.
    @discardableResult
    func presentPhiAlertNonModally<Content: View>(
        onDismiss: ((NSApplication.ModalResponse) -> Void)? = nil,
        @ViewBuilder content: (PhiAlertDismissAction) -> Content
    ) -> PhiAlertPresenter {
        PhiAlertPresenter.presentNonModally(
            over: self,
            onDismiss: onDismiss,
            content: content
        )
    }
}

@MainActor
extension NSApplication {
    /// Presents the standard alert as a sheet and returns the selected response
    /// synchronously, matching `NSAlert.runModal()` call-site semantics.
    func runPhiAlert(
        _ configuration: PhiAlertAppKitConfiguration,
        relativeTo sourceWindow: NSWindow? = nil
    ) -> NSApplication.ModalResponse {
        runPhiAlert(relativeTo: sourceWindow) { dismiss in
            PhiAlertAppKitContent(
                configuration: configuration,
                dismiss: dismiss
            )
        }
    }

    /// Presents custom SwiftUI alert content as a sheet and returns its response
    /// synchronously using the resolved source window's theme context.
    func runPhiAlert<Content: View>(
        relativeTo sourceWindow: NSWindow? = nil,
        @ViewBuilder content: (PhiAlertDismissAction) -> Content
    ) -> NSApplication.ModalResponse {
        // Without a visible host window the alert floats standalone instead of
        // silently resolving to .cancel — an agent-initiated prompt must reach
        // the user even when every browser window is closed.
        guard let sourceWindow = resolvedPhiAlertSourceWindow(sourceWindow),
              sourceWindow.isVisible else {
            return PhiAlertPresenter.runStandaloneSynchronously(content: content)
        }

        return PhiAlertPresenter.runSheetSynchronously(
            over: sourceWindow,
            content: content
        )
    }

    private func resolvedPhiAlertSourceWindow(
        _ sourceWindow: NSWindow?
    ) -> NSWindow? {
        sourceWindow
            ?? keyWindow
            ?? mainWindow
            ?? MainBrowserWindowControllersManager.shared.activeWindowController?.window
    }
}

@MainActor
extension PhiAlert where Icon == EmptyView, AlertContent == EmptyView, Actions == EmptyView {
    /// Presents the standard quit confirmation alert and returns whether the
    /// user confirmed termination.
    static func runQuitAlert(relativeTo sourceWindow: NSWindow? = nil) -> Bool {
        let configuration = PhiAlertAppKitConfiguration(
            title:  NSLocalizedString("common.quitConfirmation.title", value: "Are you sure you want to quit Phi?",
                comment: "Quit confirmation title"
            ),
            message: NSLocalizedString("common.quitConfirmation.message", value: "Any unsaved changes may be lost.",
                comment: "Quit confirmation message"
            ),
            secondaryAction: PhiAlertAppKitAction(
                NSLocalizedString("common.quitConfirmation.cancelButton", value: "Cancel", comment: "Cancel"),
                response: .alertSecondButtonReturn
            ),
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString("common.quitConfirmation.quitButton", value: "Quit", comment: "Quit"),
                role: .primary,
                response: .alertFirstButtonReturn
            )
        )

        let confirmationAction = PhiAlertQuitConfirmationAction()
        let commandQMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard isCommandQ(event) else { return event }
            confirmationAction.handler?()
            return nil
        }
        defer {
            if let commandQMonitor {
                NSEvent.removeMonitor(commandQMonitor)
            }
        }

        let response = NSApp.runPhiAlert(relativeTo: sourceWindow) { dismiss in
            makeQuitAlertContent(
                configuration: configuration,
                dismiss: dismiss,
                confirmationAction: confirmationAction
            )
        }

        return response == .alertFirstButtonReturn
    }

    private static func isCommandQ(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        let unsupportedModifiers: NSEvent.ModifierFlags = [
            .control,
            .option,
            .shift,
        ]
        return modifiers.contains(.command)
            && modifiers.intersection(unsupportedModifiers).isEmpty
            && event.charactersIgnoringModifiers?.lowercased() == "q"
    }

    private static func makeQuitAlertContent(
        configuration: PhiAlertAppKitConfiguration,
        dismiss: PhiAlertDismissAction,
        confirmationAction: PhiAlertQuitConfirmationAction
    ) -> some View {
        confirmationAction.handler = {
            dismiss(.alertFirstButtonReturn)
        }
        return PhiAlertAppKitContent(
            configuration: configuration,
            dismiss: dismiss
        )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Short Copy - One Button") {
    let configuration = PhiAlertAppKitConfiguration(
        title: "Update complete",
        message: "Phi is ready to use.",
        icon: .phiAlertIcon,
        primaryAction: PhiAlertAppKitAction(
            "OK",
            role: .primary,
            response: .alertFirstButtonReturn
        )
    )

    return PhiAlertAppKitContent(
        configuration: configuration,
        dismiss: PhiAlertDismissAction { _ in }
    )
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Figma Layout - Three Buttons") {
    let configuration = PhiAlertAppKitConfiguration(
        title: "A new version of Phi is available",
        message: "Install it now to get the latest improvements.",
        icon: .phiAlertIcon,
        leadingAction: PhiAlertAppKitAction(
            "Skip This Version",
            response: .alertThirdButtonReturn
        ),
        secondaryAction: PhiAlertAppKitAction(
            "Remind Me Later",
            response: .alertSecondButtonReturn
        ),
        primaryAction: PhiAlertAppKitAction(
            "Install Update",
            role: .primary,
            response: .alertFirstButtonReturn
        )
    )

    return PhiAlertAppKitContent(
        configuration: configuration,
        dismiss: PhiAlertDismissAction { _ in }
    )
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Medium Copy - Two Buttons") {
    let configuration = PhiAlertAppKitConfiguration(
        title: "Quit Phi?",
        message: "Are you sure you want to quit Phi? Any unsaved changes may be lost.",
        style: .critical,
        secondaryAction: PhiAlertAppKitAction(
            "Cancel",
            response: .alertSecondButtonReturn
        ),
        primaryAction: PhiAlertAppKitAction(
            "Save and Quit",
            role: .primary,
            response: .alertFirstButtonReturn
        )
    )

    return PhiAlertAppKitContent(
        configuration: configuration,
        dismiss: PhiAlertDismissAction { _ in }
    )
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Long Copy - Three Long Button Titles") {
    let paragraph = "This preview verifies that longer explanatory copy remains readable while the alert keeps its fixed width. When the content reaches the configured maximum height, only this text area should scroll."
    let configuration = PhiAlertAppKitConfiguration(
        title: "Review changes before quitting",
        message: Array(repeating: paragraph, count: 8).joined(separator: "\n\n"),
        icon: .phiAlertIcon,
        maximumHeight: 480,
        leadingAction: PhiAlertAppKitAction(
            "Quit Without Saving",
            role: .destructive,
            response: .alertThirdButtonReturn
        ),
        secondaryAction: PhiAlertAppKitAction(
            "Keep Reviewing Changes",
            response: .alertSecondButtonReturn
        ),
        primaryAction: PhiAlertAppKitAction(
            "Save Everything and Quit",
            role: .primary,
            response: .alertFirstButtonReturn
        )
    )

    return PhiAlertAppKitContent(
        configuration: configuration,
        dismiss: PhiAlertDismissAction { _ in }
    )
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Dark Mode - White Icon") {
    let configuration = PhiAlertAppKitConfiguration(
        title: "Quit Phi?",
        message: "The alert icon should render white when the window uses its dark appearance.",
        secondaryAction: PhiAlertAppKitAction(
            "Cancel",
            response: .alertSecondButtonReturn
        ),
        primaryAction: PhiAlertAppKitAction(
            "Quit",
            role: .primary,
            response: .alertFirstButtonReturn
        )
    )

    return PhiAlertAppKitContent(
        configuration: configuration,
        dismiss: PhiAlertDismissAction { _ in }
    )
    .environment(\.phiAppearance, .dark)
    .preferredColorScheme(.dark)
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}
#endif

/// Segmented option control matching the alert's rounded styling (a native
/// segmented control would fight the material surface). Shared by the alerts
/// that ask "for how long?" — agent access and credential approval — so the
/// two prompts a user meets from the same agent look like one system.
struct PhiAlertSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: KeyPath<Option, String>

    @Environment(\.phiAppearance) private var appearance
    @Namespace private var segmentNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(appearance.isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
        )
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selection = option
            }
        } label: {
            Text(option[keyPath: title])
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .themedForeground(.textPrimary)
                .lineLimit(1)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(appearance.isLight ? Color.white : Color.white.opacity(0.22))
                    .shadow(color: .black.opacity(appearance.isLight ? 0.12 : 0.3),
                            radius: 1.5, y: 0.5)
                    .matchedGeometryEffect(id: "selectedSegment", in: segmentNamespace)
            }
        }
    }
}
