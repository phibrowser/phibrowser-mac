// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

// MARK: - Palette

/// What the Customize Toolbar sheet lists: every button this window's
/// profile can use, Phi's own first, then one per installed extension.
enum ToolbarPalette {
    /// Phi's buttons in the order the sheet lists them: the default
    /// arrangement's, left to right.
    static let phiItems: [ToolbarItemID] = [
        .sidebarToggle, .back, .forward, .reload,
        .readerView, .siteMemories, .copyURL, .siteMenu,
        .extensionsButton, .memory, .downloads, .feedback, .chat,
    ]

    /// Phi AI's buttons exist only with Phi AI on and outside incognito;
    /// Feedback only for a signed-in user; Toggle Sidebar only in a layout
    /// with a sidebar (not Comfortable). Extensions come last.
    static func items(isPhiAIEnabled: Bool, isGuest: Bool, isIncognito: Bool, hasSidebar: Bool = true, extensionIDs: [String]) -> [ToolbarItemID] {
        let hasPhiAI = isPhiAIEnabled && !isIncognito
        let phi = phiItems.filter { item in
            switch item {
            case .sidebarToggle: return hasSidebar
            case .memory, .chat, .siteMemories: return hasPhiAI
            case .feedback: return !isGuest
            default: return true
            }
        }
        return phi + extensionIDs.map(ToolbarItemID.extensionAction)
    }

    /// The extensions section's order: by name. The extensions model lists
    /// pinned ones first, so its order would move a tile on every drag in
    /// or out of the toolbar.
    static func extensionOrder(_ extensions: [(id: String, name: String)]) -> [String] {
        extensions.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }.map(\.id)
    }

    /// Whether the sheet greys `item` out as already in the toolbar: it is in
    /// the arrangement and this toolbar draws it right now (`isDrawn`, from
    /// `ToolbarItemView.isShown`). An item in the arrangement
    /// that the view does not draw (Toggle Sidebar with the sidebar docked,
    /// Downloads in Balanced's docked layout unless placed) counts as not
    /// placed, so it can be dragged in from the sheet, which moves it. A
    /// removed address bar draws none of its buttons; both styles draw them
    /// while it is shown.
    static func isPlaced(_ item: ToolbarItemID, in arrangement: ToolbarArrangement, isDrawn: Bool) -> Bool {
        guard let zone = arrangement.zone(of: item) else { return false }
        guard isDrawn else { return false }
        return !zone.isAddress || arrangement.drawsAddressZones
    }

    /// Whether the sheet greys the Address tile out: the address bar is in
    /// the toolbar.
    static func isAddressBarPlaced(in arrangement: ToolbarArrangement) -> Bool {
        arrangement.showsAddressBar
    }

    /// The Address tile's name.
    static var addressBarName: String {
        NSLocalizedString("browser.toolbarCustomization.item.address", value: "Address", comment: "Customize Toolbar sheet - Name of the address bar, which shows the page's address between the toolbar's buttons and can be dragged out of the toolbar and back in")
    }

    /// Phi's buttons split where the sheet lists the Address tile: after the
    /// buttons that sit left of the address bar by default.
    static func splitAroundAddressBar(_ items: [ToolbarItemID]) -> (before: [ToolbarItemID], after: [ToolbarItemID]) {
        let left = Set(ToolbarArrangement.standard.placements(in: .left).map(\.item))
        return (items.filter(left.contains), items.filter { !left.contains($0) })
    }

    /// What the default set would draw in `zone` in the current view: the
    /// buttons of `ToolbarArrangement.standard` that the toolbar's own rule
    /// (`ToolbarItemView.isShown`) shows, evaluated as if the arrangement were
    /// `.standard`, so Balanced with the sidebar docked leaves out Downloads,
    /// Memory and Feedback, which the user has not placed.
    static func defaultSetItems(in zone: ToolbarZone, state: WebContentHeaderState) -> [ToolbarItemID] {
        ToolbarArrangement.standard.placements(in: zone).map(\.item).filter {
            ToolbarItemView.isShown($0, state: state, visibleExtensionIDs: [], arrangement: .standard)
        }
    }

    /// The name the sheet shows under a Phi button. An extension shows its
    /// own name, which only its model knows.
    static func name(of item: ToolbarItemID) -> String {
        switch item {
        case .sidebarToggle:
            return NSLocalizedString("browser.toolbarCustomization.item.sidebarToggle", value: "Toggle Sidebar", comment: "Customize Toolbar sheet - Name of the button that shows or hides the sidebar")
        case .back:
            return NSLocalizedString("browser.toolbarCustomization.item.back", value: "Back", comment: "Customize Toolbar sheet - Name of the button that goes back to the previous page")
        case .forward:
            return NSLocalizedString("browser.toolbarCustomization.item.forward", value: "Forward", comment: "Customize Toolbar sheet - Name of the button that goes forward to the next page")
        case .reload:
            return NSLocalizedString("browser.toolbarCustomization.item.reload", value: "Reload", comment: "Customize Toolbar sheet - Name of the button that reloads the page, or stops it while it loads")
        case .extensionsButton:
            return NSLocalizedString("browser.toolbarCustomization.item.extensionsButton", value: "Extensions Menu", comment: "Customize Toolbar sheet - Name of the button that opens the menu listing all installed extensions")
        case .downloads:
            return NSLocalizedString("browser.toolbarCustomization.item.downloads", value: "Downloads", comment: "Customize Toolbar sheet - Name of the button that shows recent downloads")
        case .memory:
            return NSLocalizedString("browser.toolbarCustomization.item.memory", value: "Browser Memory", comment: "Customize Toolbar sheet - Name of the button that opens Phi AI's browser memory")
        case .feedback:
            return NSLocalizedString("browser.toolbarCustomization.item.feedback", value: "Feedback", comment: "Customize Toolbar sheet - Name of the button that opens the feedback form")
        case .chat:
            return NSLocalizedString("browser.toolbarCustomization.item.chat", value: "Chat", comment: "Customize Toolbar sheet - Name of the button that opens Phi AI's chat")
        case .readerView:
            return NSLocalizedString("browser.toolbarCustomization.item.readerView", value: "Reader View", comment: "Customize Toolbar sheet - Name of the button that shows the page in Reader View")
        case .siteMemories:
            return NSLocalizedString("browser.toolbarCustomization.item.siteMemories", value: "Site Memories", comment: "Customize Toolbar sheet - Name of the button that manages Phi AI's memories of the current site")
        case .copyURL:
            return NSLocalizedString("browser.toolbarCustomization.item.copyURL", value: "Copy URL", comment: "Customize Toolbar sheet - Name of the button that copies the page's address")
        case .siteMenu:
            return NSLocalizedString("browser.toolbarCustomization.item.siteMenu", value: "Site Menu", comment: "Customize Toolbar sheet - Name of the button that opens the menu of actions and settings for the current site")
        case .extensionAction(let id):
            return id
        }
    }
}

// MARK: - Presentation

/// The Customize Toolbar sheet: a panel that hangs under the toolbar it
/// customizes, owned by that toolbar's `WebContentHeader` for as long as it
/// is being customized.
///
/// It is a child window, not a window-modal sheet (`beginSheet`): a window
/// with a sheet attached gets no mouse-downs, and the toolbar's own buttons
/// must stay draggable and right-clickable while the sheet is open.
final class ToolbarCustomizationSheet {
    /// The sheet's width when the toolbar has room for it.
    static let preferredWidth: CGFloat = 620
    /// The room the sheet leaves on each side under a narrower toolbar.
    static let horizontalInset: CGFloat = 16
    private static let cornerRadius: CGFloat = 12

    /// The sheet's frame under a toolbar's frame (both on screen): its top on
    /// the toolbar's bottom, centered on it, and never wider than it allows.
    static func frame(under header: NSRect, contentSize: NSSize) -> NSRect {
        let width = max(min(contentSize.width, header.width - 2 * horizontalInset), 0)
        return NSRect(
            x: header.midX - width / 2,
            y: header.minY - contentSize.height,
            width: width,
            height: contentSize.height
        )
    }

    /// The sheet's window, so the toolbar can tell its key events apart.
    var window: NSWindow { panel }

    private let panel: ToolbarCustomizationPanel
    private let hostingController: NSHostingController<AnyView>
    private weak var header: NSView?
    private var cancellables = Set<AnyCancellable>()

    init<Content: View>(content: Content) {
        hostingController = NSHostingController(rootView: AnyView(content))
        // The sheet sizes its panel itself (see `reposition`).
        hostingController.sizingOptions = []
        panel = ToolbarCustomizationPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        let content = hostingController.view
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    /// Hangs the sheet under `header` and keeps it there, at its content's
    /// height, while the window resizes, the toolbar moves (the sidebar
    /// docking, a split opening) or `contentDidChange` fires.
    func present(under header: NSView, contentDidChange: AnyPublisher<Void, Never>) {
        guard let parent = header.window else { return }
        self.header = header
        reposition()
        panel.alphaValue = 0
        parent.addChildWindow(panel, ordered: .above)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }

        // The panel mirrors its parent window's appearance, live: an Incognito
        // window is always dark whatever the app's appearance is.
        parent.publisher(for: \.effectiveAppearance, options: [.initial, .new])
            .sink { [weak self] in self?.panel.appearance = $0 }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didResizeNotification, object: parent)
            .merge(with: center.publisher(for: NSView.frameDidChangeNotification, object: header))
            .map { _ in () }
            .merge(with: contentDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reposition() }
            .store(in: &cancellables)
    }

    func close() {
        cancellables.removeAll()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        header = nil
    }

    private func reposition() {
        guard let header, let parent = header.window else { return }
        let headerOnScreen = parent.convertToScreen(header.convert(header.bounds, to: nil))
        let width = max(min(Self.preferredWidth, headerOnScreen.width - 2 * Self.horizontalInset), 0)
        let height = ceil(hostingController.sizeThatFits(in: NSSize(width: width, height: 10_000)).height)
        let frame = Self.frame(under: headerOnScreen, contentSize: NSSize(width: width, height: height))
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// A stretchable rounded-rectangle mask for the panel's background.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Becomes key only for a control that needs it, so the toolbar's window
/// keeps key (and its Escape) while the user works in the sheet.
private final class ToolbarCustomizationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Content

/// The sheet's content. Changes apply as they are made; Done only ends
/// customizing.
struct ToolbarCustomizationSheetView: View {
    @ObservedObject var state: WebContentHeaderState
    let extensionManager: ExtensionManager?
    let customization: ToolbarCustomizationController
    let onDone: () -> Void

    var body: some View {
        Group {
            if let extensionManager {
                ToolbarPaletteExtensionsReader(manager: extensionManager) { content(extensions: $0) }
            } else {
                content(extensions: [])
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func content(extensions: [Extension]) -> some View {
        let items = ToolbarPalette.items(
            isPhiAIEnabled: state.isPhiAIAvailable,
            isGuest: state.isGuest,
            isIncognito: state.isIncognito,
            hasSidebar: !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional,
            extensionIDs: ToolbarPalette.extensionOrder(extensions.map { ($0.id, $0.name) })
        )
        let phiItems = items.filter { item in
            if case .extensionAction = item { return false }
            return true
        }
        let extensionsByID = Dictionary(extensions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let extensionItems = items.compactMap { item -> Extension? in
            if case .extensionAction(let id) = item { return extensionsByID[id] }
            return nil
        }

        return VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("browser.toolbarCustomization.paletteInstructions", value: "Drag your favorite items into the toolbar…", comment: "Customize Toolbar sheet - Heading above the buttons the user can drag into the toolbar"))
                .font(.system(size: 13, weight: .semibold))

            grid {
                let split = ToolbarPalette.splitAroundAddressBar(phiItems)
                ForEach(split.before, id: \.self) { item in
                    phiTile(item)
                }
                ToolbarPaletteTile(
                    payload: .addressBar,
                    name: ToolbarPalette.addressBarName,
                    isPlaced: ToolbarPalette.isAddressBarPlaced(in: state.arrangement)
                ) {
                    ToolbarPaletteAddressIcon()
                }
                ForEach(split.after, id: \.self) { item in
                    phiTile(item)
                }
            }

            if !extensionItems.isEmpty {
                Text(NSLocalizedString("browser.toolbarCustomization.extensionsSection", value: "Extensions", comment: "Customize Toolbar sheet - Heading of the section listing the installed extensions the user can drag into the toolbar"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                grid {
                    ForEach(extensionItems, id: \.id) { ext in
                        ToolbarPaletteTile(
                            payload: .item(.extensionAction(ext.id)),
                            name: ext.name,
                            isPlaced: isPlaced(.extensionAction(ext.id))
                        ) {
                            ToolbarPaletteIcon(item: .extensionAction(ext.id), extensionIcon: ext.icon)
                        }
                    }
                }
            }

            Divider()

            Text(NSLocalizedString("browser.toolbarCustomization.defaultSetInstructions", value: "…or drag the default set into the toolbar.", comment: "Customize Toolbar sheet - Caption above the row that restores the default toolbar when dragged into it"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ToolbarPaletteDefaultSet(state: state)

            Divider()

            HStack(spacing: 10) {
                Text(NSLocalizedString("browser.toolbarCustomization.addressBarStyleLabel", value: "Address bar style", comment: "Customize Toolbar sheet - Label of the control that picks how the address bar looks"))
                    .font(.system(size: 12))
                Picker(selection: addressBarStyle) {
                    Text(NSLocalizedString("browser.toolbarCustomization.addressBarStyle.standard", value: "Standard", comment: "Customize Toolbar sheet - Address bar style: the address in a rounded field with its buttons inside"))
                        .tag(AddressBarStyle.standard)
                    Text(NSLocalizedString("browser.toolbarCustomization.addressBarStyle.minimal", value: "Minimal", comment: "Customize Toolbar sheet - Address bar style: the address as plain text centered in the window, without a field around it"))
                        .tag(AddressBarStyle.minimal)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button(action: onDone) {
                    Text(NSLocalizedString("browser.toolbarCustomization.doneAction", value: "Done", comment: "Customize Toolbar sheet - Button that closes the sheet and returns the toolbar's buttons to normal use"))
                        .frame(minWidth: 52)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func phiTile(_ item: ToolbarItemID) -> some View {
        ToolbarPaletteTile(payload: .item(item), name: ToolbarPalette.name(of: item), isPlaced: isPlaced(item)) {
            ToolbarPaletteIcon(item: item, extensionIcon: nil)
        }
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ToolbarPaletteFlowLayout(spacing: 6, lineSpacing: 10) { content() }
    }

    /// A button is placed once: one the toolbar draws is greyed out. An
    /// extension counts as drawn wherever it is placed.
    private func isPlaced(_ item: ToolbarItemID) -> Bool {
        let isDrawn: Bool
        if case .extensionAction = item {
            isDrawn = true
        } else {
            isDrawn = ToolbarItemView.isShown(item, state: state, visibleExtensionIDs: [])
        }
        return ToolbarPalette.isPlaced(item, in: state.arrangement, isDrawn: isDrawn)
    }

    private var addressBarStyle: Binding<AddressBarStyle> {
        Binding(
            get: { state.arrangement.addressBarStyle },
            set: { [customization] in customization.setAddressBarStyle($0) }
        )
    }
}

/// Lays the sheet's buttons out in rows, wrapping at the sheet's width. Unlike
/// a lazy grid it reports its full height, which sizes the sheet.
private struct ToolbarPaletteFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = self.rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += (row.map(\.height).max() ?? 0) + lineSpacing
        }
    }

    /// The subviews' sizes, row by row.
    private func rows(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, rowWidth + spacing + size.width > width {
                rows.append([])
                rowWidth = 0
            }
            rowWidth += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows.filter { !$0.isEmpty }
    }
}

/// Re-renders the sheet as extensions are installed, removed or pinned.
private struct ToolbarPaletteExtensionsReader<Content: View>: View {
    @ObservedObject var manager: ExtensionManager
    let content: ([Extension]) -> Content

    var body: some View {
        content(manager.extensions)
    }
}

/// One button in the sheet, or the address bar: its icon and its name.
/// Dragged into the toolbar it is placed there; one already placed is greyed
/// out and stays put.
private struct ToolbarPaletteTile<Icon: View>: View {
    static var width: CGFloat { 72 }

    let payload: ToolbarDragPayload
    let name: String
    let isPlaced: Bool
    @ViewBuilder let icon: () -> Icon

    /// The fill's height: a toolbar button's, so a button's icon sits on
    /// the same circle as its hover fill in the toolbar.
    private static var fillHeight: CGFloat { ToolbarCustomizationHoverFill.maxHeight }

    var body: some View {
        VStack(spacing: 5) {
            icon()
                // A button's icon is as wide as the fill is tall: a circle.
                // A wider icon (the Address tile's) gets a capsule.
                .frame(minWidth: Self.fillHeight, minHeight: Self.fillHeight)
                .fixedSize()
                .background(Capsule().fill(Color(.sidebarTabHoveredColorEmphasized)))
                // Only the icon on its fill is grabbed and dragged.
                .overlay(dragSource)
                .frame(height: 30)
            Text(name)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.width)
        .opacity(isPlaced ? 0.35 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var dragSource: some View {
        if !isPlaced {
            // No `onDraggedOut`: a sheet item let go anywhere but a zone does nothing.
            ToolbarItemDragSource(
                payload: payload,
                dragImageShape: .capsule(maxHeight: Self.fillHeight),
                dragImageHasHoverFill: true
            )
        }
    }
}

/// The default arrangement drawn as a toolbar. Dragged into the toolbar, it
/// restores the default buttons and the Standard style.
private struct ToolbarPaletteDefaultSet: View {
    /// The row draws what the default set would show in the current view,
    /// and follows the header's state live.
    @ObservedObject var state: WebContentHeaderState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            icons(in: .left)
            HStack(spacing: 2) {
                Spacer(minLength: 24)
                icons(in: .addressTrailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            icons(in: .right)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        // The system would shrink an image of the whole row; a small
        // symbol of a toolbar is dragged instead.
        .overlay(ToolbarItemDragSource(payload: .defaultSet, makeDragImage: { [colorScheme] context in
            ToolbarDefaultSetDragToken.image(colorScheme: colorScheme, scale: context.scale)
        }))
    }

    private func icons(in zone: ToolbarZone) -> some View {
        HStack(spacing: 2) {
            ForEach(ToolbarPalette.defaultSetItems(in: zone, state: state), id: \.self) { item in
                ToolbarPaletteIcon(item: item, extensionIcon: nil)
            }
        }
    }
}

/// What a drag of the default set carries: a symbol of a toolbar, buttons
/// as dots around a small address bar, on the toolbar's hover fill.
private struct ToolbarDefaultSetDragToken: View {
    private static let dotColor = Color.primary.opacity(0.45)

    var body: some View {
        HStack(spacing: 5) {
            dots(3)
            Capsule()
                .strokeBorder(Self.dotColor, lineWidth: 1)
                .frame(width: 32, height: 12)
            dots(2)
        }
        .padding(.horizontal, 10)
        .frame(height: ToolbarCustomizationHoverFill.maxHeight)
        // The hover color is translucent: the window's background under it
        // keeps the token solid, as the toolbar's own fill does.
        .background(Capsule().fill(Color(.sidebarTabHoveredColorEmphasized)))
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
    }

    private func dots(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().fill(Self.dotColor).frame(width: 6, height: 6)
            }
        }
    }

    /// The token for `colorScheme` at `scale` pixels per point.
    @MainActor
    static func image(colorScheme: ColorScheme, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: ToolbarDefaultSetDragToken().environment(\.colorScheme, colorScheme))
        renderer.scale = scale
        renderer.isOpaque = false
        var image: NSImage?
        // AppKit-backed colors resolve for the token's scheme, not the app's.
        if let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        } else {
            image = renderer.nsImage
        }
        return image
    }
}

/// The Address tile's icon: a small empty address bar.
private struct ToolbarPaletteAddressIcon: View {
    var body: some View {
        Capsule()
            .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
            .frame(width: 30, height: 14)
            // Clear of its fill's rounded ends.
            .padding(.horizontal, 6)
    }
}

/// A toolbar button's icon as the toolbar draws it, without its behavior.
private struct ToolbarPaletteIcon: View {
    let item: ToolbarItemID
    let extensionIcon: NSImage?

    @AppStorage(PhiPreferences.GeneralSettings.sidebarPositionKey)
    private var sidebarPosition = SidebarPosition.left.rawValue

    var body: some View {
        icon.frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .sidebarToggle:
            Image(systemName: sidebarPosition == SidebarPosition.right.rawValue && !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional ? "sidebar.right" : "sidebar.left")
                .font(.system(size: 14))
        case .back:
            Image(systemName: "chevron.left").font(.system(size: 14))
        case .forward:
            Image(systemName: "chevron.right").font(.system(size: 14))
        case .reload:
            ToolbarPaletteLottieIcon(name: "refresh", tint: .custom(light: .black, dark: .white))
        case .extensionsButton:
            Image(.extensionIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
        case .downloads:
            ToolbarPaletteLottieIcon(name: "download-button", tint: .textPrimary)
        case .memory:
            ToolbarPaletteLottieIcon(name: "memory", tint: .custom(light: .black, dark: .white))
        case .feedback:
            Image(nsImage: NSImage(resource: .sidebarFeedback))
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .themedForeground(.textPrimary)
        case .chat:
            Image(.sidebarChat)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundColor(.white)
                .background(Circle().themedFill(.themeColor))
        case .readerView:
            Image(systemName: "doc.plaintext")
                .font(.system(size: 11, weight: .medium))
                .themedForeground(.textPrimary)
        case .siteMemories:
            Image("memory-manage-icon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .themedForeground(.textPrimary)
        case .copyURL:
            Image(systemName: "link")
                .font(.system(size: 11, weight: .medium))
                .themedForeground(.textPrimary)
        case .siteMenu:
            ToolbarPaletteLottieIcon(name: "extension-button", tint: .textPrimary, size: 22)
        case .extensionAction:
            if let extensionIcon {
                Image(nsImage: extensionIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12))
            }
        }
    }
}

/// The first frame of a toolbar button's Lottie icon; it never animates.
private struct ToolbarPaletteLottieIcon: View {
    let name: String
    let tint: ThemedColor
    var size: CGFloat = 24

    @StateObject private var lottieState = LottieAnimationViewState()

    var body: some View {
        LottieAnimationView(
            config: LottieAnimationViewConfig(
                animationName: name,
                size: CGSize(width: size, height: size),
                animationTrigger: .none,
                themedTintColor: tint,
                allowsHitTesting: false
            ),
            state: lottieState
        )
    }
}
