// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SnapKit
import SwiftUI

private enum KioskToolbarStyle {
    static let borderWidth: CGFloat = 0.5
    static let borderColorOpacity: CGFloat = 0.12
    static let hoverColorOpacity: CGFloat = 0.06
}

private final class KioskToolbarHoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let hoverTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(hoverTrackingArea)
        self.hoverTrackingArea = hoverTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

private final class KioskAddressField: NSTextField {
    var onActivate: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onActivate?()
    }
}

/// Hosts the Kiosk window controls above its single Chromium content view.
final class KioskBrowserToolbar: NSVisualEffectView {
    private enum Layout {
        static let systemAlignedControlCenterOffset: CGFloat = -6
        static let controlCenterOffset = systemAlignedControlCenterOffset
            + KioskBrowserToolbar.titlebarVerticalShift
        static let trafficLightInset: CGFloat = 78
        static let addressBarHeight: CGFloat = 32
        static let spaceMenuMaximumWidth: CGFloat = 220
    }

    static let preferredHeight: CGFloat = 52
    static let titlebarVerticalShift: CGFloat = 4

    private let browserState: KioskBrowserState
    private let addressBarContainer = KioskToolbarHoverTrackingView()
    private let addressBarHoverLayer = CALayer()
    private let addressField = KioskAddressField()
    private var isAddressBarHovered = false

    private var onProfileSelection: ((String) -> Void)?
    private var onSpaceSelection: ((String) -> Void)?
    private var onOmniBoxRequest: (() -> Void)?

    private lazy var profileHostingView = NSHostingView(
        rootView: KioskProfileMenu(
            currentProfileId: browserState.profileId,
            onSelect: { [weak self] profileId in
                self?.onProfileSelection?(profileId)
            }
        )
    )

    private lazy var toolbarActionsHostingView = ThemedHostingView(
        rootView: KioskToolbarActions(
            state: browserState
        ),
        themeSource: browserState.themeContext
    )

    private lazy var spaceHostingView = NSHostingView(
        rootView: KioskSpaceMenu(
            state: browserState,
            onSelect: { [weak self] spaceId in
                self?.onSpaceSelection?(spaceId)
            }
        )
    )

    init(state: KioskBrowserState) {
        browserState = state
        super.init(frame: .zero)
        configureView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAddressBarAppearance()
    }

    func configureActions(
        onProfileSelection: @escaping (String) -> Void,
        onSpaceSelection: @escaping (String) -> Void,
        onOmniBoxRequest: @escaping () -> Void
    ) {
        self.onProfileSelection = onProfileSelection
        self.onSpaceSelection = onSpaceSelection
        self.onOmniBoxRequest = onOmniBoxRequest
    }

    func updateAddress(with url: String?) {
        addressField.stringValue = displayAddressText(for: url)
    }

    var addressBarAnchorView: NSView {
        addressBarContainer
    }

    var controlCenterYsForTesting: [CGFloat] {
        [addressBarContainer.frame.midY, spaceHostingView.frame.midY]
    }

    private func configureView() {
        material = .headerView
        blendingMode = .withinWindow
        state = .active

        addressBarContainer.wantsLayer = true
        addressBarContainer.layer?.cornerCurve = .circular
        addressBarContainer.layer?.cornerRadius = Layout.addressBarHeight / 2
        addressBarContainer.layer?.borderWidth = KioskToolbarStyle.borderWidth
        addressBarContainer.layer?.masksToBounds = true
        addressBarHoverLayer.autoresizingMask = [
            .layerWidthSizable,
            .layerHeightSizable,
        ]
        addressBarContainer.layer?.insertSublayer(addressBarHoverLayer, at: 0)
        addressBarContainer.onHoverChange = { [weak self] isHovered in
            guard let self, isAddressBarHovered != isHovered else { return }
            isAddressBarHovered = isHovered
            updateAddressBarAppearance()
        }
        updateAddressBarAppearance()

        addressField.placeholderString = NSLocalizedString(
            "addressBar.input.placeholder",
            value: "Search or Enter URL",
            comment: "Address bar - Text field placeholder prompting the user to search or enter a URL"
        )
        addressField.font = .systemFont(ofSize: 13)
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.alignment = .center
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.isEditable = false
        addressField.isSelectable = false
        addressField.onActivate = { [weak self] in
            self?.onOmniBoxRequest?()
        }

        // The toolbar owns titlebar placement, so SwiftUI must not add safe-area offsets.
        profileHostingView.safeAreaRegions = []
        toolbarActionsHostingView.safeAreaRegions = []
        spaceHostingView.safeAreaRegions = []

        addSubview(addressBarContainer)
        addressBarContainer.addSubview(profileHostingView)
        addressBarContainer.addSubview(addressField)
        addressBarContainer.addSubview(toolbarActionsHostingView)
        addSubview(spaceHostingView)

        spaceHostingView.setContentHuggingPriority(.required, for: .horizontal)
        spaceHostingView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        spaceHostingView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.centerY.equalToSuperview().offset(Layout.controlCenterOffset)
            make.width.lessThanOrEqualTo(Layout.spaceMenuMaximumWidth)
            make.height.equalTo(34)
        }
        addressBarContainer.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Layout.trafficLightInset)
            make.trailing.equalTo(spaceHostingView.snp.leading).offset(-8)
            make.centerY.equalToSuperview().offset(Layout.controlCenterOffset)
            make.height.equalTo(Layout.addressBarHeight)
        }
        profileHostingView.setContentHuggingPriority(.required, for: .horizontal)
        profileHostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profileHostingView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(5)
            make.centerY.equalToSuperview()
            make.height.equalTo(26)
            make.width.lessThanOrEqualTo(138)
        }
        toolbarActionsHostingView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(5)
            make.centerY.equalToSuperview()
            make.width.equalTo(52)
            make.height.equalTo(26)
        }
        addressField.snp.makeConstraints { make in
            make.leading.equalTo(profileHostingView.snp.trailing).offset(6)
            make.trailing.equalTo(toolbarActionsHostingView.snp.leading).offset(-6)
            make.centerY.equalToSuperview().offset(4)
            make.height.equalTo(24)
        }

        browserState.extensionManager.refreshExtensions()
    }

    private func updateAddressBarAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            addressBarContainer.layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(0.55)
                .cgColor
            addressBarContainer.layer?.borderColor = NSColor.labelColor
                .withAlphaComponent(KioskToolbarStyle.borderColorOpacity)
                .cgColor
            addressBarHoverLayer.backgroundColor = NSColor.labelColor
                .withAlphaComponent(
                    isAddressBarHovered ? KioskToolbarStyle.hoverColorOpacity : 0
                )
                .cgColor
        }
    }

    private func displayAddressText(for url: String?) -> String {
        guard let url, !url.isEmpty, !url.isNTP else { return "" }
        return URLProcessor.displayName(
            for: URLProcessor.phiBrandEnsuredUrlString(url)
        )
    }
}

private struct KioskProfileMenu: View {
    @ObservedObject private var profileManager: ProfileManager
    let currentProfileId: String
    let onSelect: (String) -> Void

    init(
        currentProfileId: String,
        profileManager: ProfileManager = .shared,
        onSelect: @escaping (String) -> Void
    ) {
        self.currentProfileId = currentProfileId
        self.profileManager = profileManager
        self.onSelect = onSelect
    }

    private var currentProfileName: String {
        profileManager.profile(for: currentProfileId)?.displayName
            ?? currentProfileId
    }

    var body: some View {
        Menu {
            ForEach(profileManager.userAssignableProfiles) { profile in
                Button {
                    onSelect(profile.profileId)
                } label: {
                    HStack {
                        Text(verbatim: profile.displayName)
                        if profile.profileId == currentProfileId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(profile.profileId == currentProfileId)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: currentProfileName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(
            "kiosk.toolbar.profileMenu.accessibilityLabel",
            value: "Switch Profile",
            comment: "Kiosk toolbar - Accessibility label for the current-profile menu"
        ))
        .onAppear {
            profileManager.refresh()
        }
    }
}

private struct KioskToolbarActions: View {
    let state: KioskBrowserState

    @State private var isExtensionPopoverShown = false
    @State private var copyButtonAnchorView: NSView?
    @State private var showCopyConfirmation = false

    var body: some View {
        HStack(spacing: 2) {
            HeaderExtensionMenuButton(
                extensionManager: state.extensionManager,
                browserState: state,
                isPopoverShown: $isExtensionPopoverShown,
                showsManagement: false
            )
            KioskCopyURLButtonView(
                state: state,
                showCopyConfirmation: $showCopyConfirmation,
                dismissTooltip: {
                    copyButtonAnchorView?.window?.customTooltipController
                        .dismissAll()
                }
            )
            .background(
                AddressBarAnchorView { view in
                    copyButtonAnchorView = view
                }
                .allowsHitTesting(false)
            )
            .customTooltip {
                CommandShortcutTooltipContent(
                    title: NSLocalizedString(
                        "browser.webContentAddressBar.copyURLTooltip",
                        value: "Copy URL",
                        comment: "Copy URL shortcut tooltip title"
                    ),
                    command: .PHI_COPY_URL
                )
            }
        }
        .frame(height: 26)
    }
}

private struct KioskCopyURLButtonView: View {
    let state: KioskBrowserState
    @Binding var showCopyConfirmation: Bool
    let dismissTooltip: () -> Void

    @State private var isButtonHovering = false
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        let iconName = showCopyConfirmation ? "checkmark" : "link"
        let iconColor = showCopyConfirmation
            ? ThemedColor.textPrimary.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
            : ThemedColor.textPrimary.swiftUIColor(
                theme: theme,
                appearance: appearance
            )

        Button {
            dismissTooltip()
            guard let urlString = state.focusingTab?.url,
                  !urlString.isEmpty else { return }
            let branded = URLProcessor.phiBrandEnsuredUrlString(urlString)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branded, forType: .string)
            showCopyConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showCopyConfirmation = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.sidebarTabHovered))
                    .frame(width: 24, height: 24)
                    .opacity(isButtonHovering ? 1 : 0)

                Image(systemName: iconName)
                    .contentTransition(
                        .symbolEffect(.replace, options: .speed(3))
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .accessibilityLabel(NSLocalizedString(
            "browser.webContentAddressBar.copyURLTooltip",
            value: "Copy URL",
            comment: "Copy URL shortcut tooltip title"
        ))
        .onHover { hovering in
            isButtonHovering = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isButtonHovering)
    }
}

enum KioskSpaceMenuTargetResolver {
    static func primarySpace(
        in spaces: [SpaceModel],
        activeSpaceId: String?
    ) -> SpaceModel? {
        if let activeSpaceId,
           let activeSpace = spaces.first(where: {
               $0.spaceId == activeSpaceId
           }) {
            return activeSpace
        }
        return spaces.first(where: {
            $0.spaceId == LocalStore.defaultSpaceId
        }) ?? spaces.first
    }
}

private struct KioskSpaceMenu: View {
    private enum Layout {
        static let height: CGFloat = 32
        static let iconSize: CGFloat = 12
        static let menuButtonWidth: CGFloat = 32
    }

    @ObservedObject private var spaceManager: SpaceManager
    @State private var isPrimaryActionHovered = false
    @State private var isSpaceListHovered = false
    let state: KioskBrowserState
    let onSelect: (String) -> Void

    init(
        spaceManager: SpaceManager = .shared,
        state: KioskBrowserState,
        onSelect: @escaping (String) -> Void
    ) {
        self.spaceManager = spaceManager
        self.state = state
        self.onSelect = onSelect
    }

    private var availableSpaces: [SpaceModel] {
        guard !state.isIncognito,
              PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() else {
            return []
        }
        return spaceManager.spaces
    }

    private var primarySpace: SpaceModel? {
        KioskSpaceMenuTargetResolver.primarySpace(
            in: availableSpaces,
            activeSpaceId: spaceManager.activeSpaceId
        )
    }

    private var title: String {
        NSLocalizedString(
            "kiosk.toolbar.openInSpace",
            value: "Open in",
            comment: "Kiosk toolbar - Prefix before the active Space name in the primary open action"
        )
    }

    private var spaceListTitle: String {
        NSLocalizedString(
            "kiosk.toolbar.spaceList.accessibilityLabel",
            value: "Choose Space",
            comment: "Kiosk toolbar - Accessibility label and tooltip for the button that shows the Space list"
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openInPrimarySpace) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    if let primarySpace {
                        SpaceIconView(
                            storedValue: primarySpace.iconName,
                            size: Layout.iconSize,
                            symbolWeight: .semibold,
                            tint: .primary
                        )
                        .accessibilityHidden(true)
                        .fixedSize()
                        Text(verbatim: primarySpace.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, alignment: .leading)
                            .layoutPriority(-1)
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(
                KioskSpaceMenuSegmentButtonStyle(
                    isHovered: isPrimaryActionHovered
                )
            )
            .disabled(primarySpace == nil)
            .onHover { isPrimaryActionHovered = $0 }

            Divider()
                .frame(height: 18)

            Menu {
                ForEach(availableSpaces, id: \.spaceId) { space in
                    Button {
                        select(space)
                    } label: {
                        HStack {
                            Label {
                                Text(verbatim: space.name)
                            } icon: {
                                // The native Menu bridge can treat an emoji
                                // SpaceIconView's Text as the item title.
                                if let image = SpaceIconView.menuImage(
                                    for: space.iconName,
                                    size: Layout.iconSize
                                ) {
                                    Image(nsImage: image)
                                }
                            }
                            if space.spaceId == primarySpace?.spaceId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: Layout.menuButtonWidth,
                        height: Layout.height
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(
                KioskSpaceMenuSegmentButtonStyle(
                    isHovered: isSpaceListHovered
                )
            )
            .disabled(availableSpaces.isEmpty)
            .accessibilityLabel(spaceListTitle)
            .help(spaceListTitle)
            .onHover { isSpaceListHovered = $0 }
        }
        .frame(height: Layout.height)
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    Color.primary.opacity(KioskToolbarStyle.borderColorOpacity),
                    lineWidth: KioskToolbarStyle.borderWidth
                )
        }
        .clipShape(Capsule())
    }

    private func openInPrimarySpace() {
        guard let primarySpace else { return }
        select(primarySpace)
    }

    private func select(_ space: SpaceModel) {
        onSelect(space.spaceId)
    }
}

private struct KioskSpaceMenuSegmentButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(
                    configuration.isPressed
                        ? 0.10
                        : isHovered ? KioskToolbarStyle.hoverColorOpacity : 0
                )
            )
    }
}
