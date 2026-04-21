// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Security
import SecurityInterface

@MainActor
final class CertificatePanelSheetDelegate: NSObject {
    static let shared = CertificatePanelSheetDelegate()

    @objc func certificateSheetDidEnd(_ sheet: NSWindow,
                                      returnCode: NSInteger,
                                      contextInfo: UnsafeMutableRawPointer?) {
        // No-op: sheet lifecycle is handled by SFCertificatePanel.
    }
}

// Protocol to abstract ExtensionManager for testing
protocol ExtensionManagerProtocol: ObservableObject {
    var extensions: [Extension] { get }
    func refreshExtensions()
    func togglePin(_ model: Extension)
}

extension ExtensionManager: ExtensionManagerProtocol {}

struct ExtensionList<Manager: ExtensionManagerProtocol>: View {
    @ObservedObject private var extensionManager: Manager
    private let needSettings: Bool
    private let onRequestDismiss: (() -> Void)?
    private let triggerAnchorView: NSView?
    @State private var contentSize: CGSize = .zero
    
    var onFrameChanged: ((CGSize) -> Void)?
    
    #if DEBUG
    @State private var isTestMode = false
    @State private var currentTestCase = 0
    private let testCases = [0, 1, 3, 4, 8, 12, 15, 16, 17, 24, 32]
    #endif
    
    private let columns = Array(repeating: GridItem(.fixed(50), spacing: 6), count: 4)
    private let itemWidth: CGFloat = 50
    private let itemHeight: CGFloat = 32
    private let spacing: CGFloat = 6
    private let maxRows = 4
    private let fixedWidth: CGFloat = 240
    
    init(
        extensionManager: Manager,
        onFrameChanged: ((CGSize) -> Void)? = nil,
        needSettings: Bool = true,
        onRequestDismiss: (() -> Void)? = nil,
        triggerAnchorView: NSView? = nil
    ) {
        self.extensionManager = extensionManager
        self.onFrameChanged = onFrameChanged
        self.needSettings = needSettings
        self.onRequestDismiss = onRequestDismiss
        self.triggerAnchorView = triggerAnchorView
    }
    
    private var needsScrolling: Bool {
        extensionManager.extensions.count > maxRows * 4
    }
    
    private var gridHeight: CGFloat {
        let itemCount = extensionManager.extensions.count
        let rows = min(maxRows, Int(ceil(Double(itemCount) / 4.0)))
        return CGFloat(rows) * itemHeight + CGFloat(max(0, rows - 1)) * spacing
    }
    
    var body: some View {
        let rawURLString = MainBrowserWindowControllersManager.shared
            .activeWindowController?
            .browserState
            .focusingTab?
            .url ?? ""
        let shouldShowWebsiteSection = needSettings && shouldShowSecuritySection(for: rawURLString)

        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text(NSLocalizedString("Extensions", comment: "Extension list - Section title for browser extensions"))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            
            if extensionManager.extensions.isEmpty {
                Text(NSLocalizedString("No extensions found", comment: "Extension list - Empty state when no extensions are installed"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
            } else {
                // Grid view
                if needsScrolling {
                    ScrollView {
                        gridContent
                            .padding(.horizontal, 12)
                    }
                    .frame(height: gridHeight)
                } else {
                    gridContent
                        .padding(.horizontal, 12)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Setting", comment: "Extension list - Section title for extension settings"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)

                ManageExtensionsButton {
                    let url = URLProcessor.processUserInput("phi://extensions")
                    MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.createTab(url)
                    onRequestDismiss?()
                }
                .padding(.horizontal, 8)
            }
            .padding(.bottom, shouldShowWebsiteSection ? 0 : 12)
    
            if shouldShowWebsiteSection {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Website", comment: "Extension list - Section title for current website security info"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)

                    let tabSecurityInfo = MainBrowserWindowControllersManager.shared
                        .activeWindowController?
                        .browserState
                        .focusingTab?
                        .securityInfo

                    Group {
                        WebsiteSecurityStatusRow(
                            statusText: securityStatusText(from: tabSecurityInfo),
                            isSecure: tabSecurityInfo?.isSecure ?? false
                        )

                        if tabSecurityInfo?.certificates.isEmpty == false {
                            WebsiteCertificateButton(
                                certificateStatusText: certificateStatusText(from: tabSecurityInfo),
                                isCertificateValid: certificateIsValid(from: tabSecurityInfo),
                                certificates: tabSecurityInfo?.certificates ?? []
                            )
                        }

                        WebsiteSettingsButton(onMenuActionSelected: onRequestDismiss)
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: fixedWidth)
        .onAppear {
            extensionManager.refreshExtensions()
        }
    }

    private func securityStatusText(from info: TabSecurityInfo?) -> String {
        guard let info else {
            return NSLocalizedString("Unknown", comment: "Website security unknown")
        }
        guard let isSecure = info.isSecure else {
            return NSLocalizedString("Connection is not fully secure", comment: "Website security not fully secure")
        }
        return isSecure
            ? NSLocalizedString("Connection is secure", comment: "Website security secure")
            : NSLocalizedString("Connection is not secure", comment: "Website security not secure")
    }

    private func certificateStatusText(from info: TabSecurityInfo?) -> String {
        return certificateIsValid(from: info) ? "Certificate is valid" : "Certificate is invalid"
    }

    private func certificateIsValid(from info: TabSecurityInfo?) -> Bool {
        guard let info else {
            return false
        }

        let certStatus: UInt64 = {
            if let value = info.raw["certStatus"] as? UInt64 {
                return value
            }
            if let value = info.raw["certStatus"] as? Int {
                return UInt64(max(0, value))
            }
            if let value = info.raw["certStatus"] as? NSNumber {
                return value.uint64Value
            }
            return 1
        }()

        return certStatus == 0 && !info.certificates.isEmpty
    }

    private func shouldShowSecuritySection(for rawURLString: String) -> Bool {
        let lowercased = rawURLString.lowercased()
        return !lowercased.hasPrefix("chrome://") && !lowercased.hasPrefix("phi://")
    }
    
    private var gridContent: some View {
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(extensionManager.extensions) { ext in
                ExtensionGridItem(
                    ext: ext,
                    onTogglePin: { model in
                        extensionManager.togglePin(model)
                    },
                    onTap: triggerAnchorView.map { anchor in
                        { ext in triggerExtension(ext, anchor: anchor) }
                    },
                    onSecondaryTap: { ext in
                        triggerExtensionContextMenu(ext)
                    }
                )
                .fixedSize()
            }
        }
    }

    private func triggerExtension(_ ext: Extension, anchor: NSView) {
        // Dismiss the SwiftUI popover BEFORE triggering the Chromium popup so
        // the popover's fade-out animation runs in parallel with the popup's
        // appearance instead of overlapping it visually.
        onRequestDismiss?()
        let point = ExtensionPopupAnchor.pointBelowView(anchor)
            ?? ExtensionPopupAnchor.mouseFallback()
        let windowId = MainBrowserWindowControllersManager.shared
            .activeWindowController?.browserState.windowId
        ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
            withId: ext.id,
            pointInScreen: point,
            windowId: windowId?.int64Value ?? 0
        )
    }

    private func triggerExtensionContextMenu(_ ext: Extension) {
        let point = ExtensionPopupAnchor.mouseFallback()
        let windowId = MainBrowserWindowControllersManager.shared
            .activeWindowController?.browserState.windowId
        ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
            withId: ext.id,
            pointInScreen: point,
            windowId: windowId?.int64Value ?? 0
        )
    }
    
    #if DEBUG
    private var debugTestButtons: some View {
        VStack(spacing: 8) {
            Divider()
                .padding(.horizontal, 16)
            
            Text("DEBUG Test Mode")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 16)
            
            HStack(spacing: 8) {
                if isTestMode {
                    Button("Next Test (\(testCases[currentTestCase]) items)") {
                        currentTestCase = (currentTestCase + 1) % testCases.count
                        loadTestData(itemCount: testCases[currentTestCase])
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button("Restore") {
                        isTestMode = false
                        extensionManager.refreshExtensions()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            // no isLoaded update needed
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Start Test") {
                        isTestMode = true
                        currentTestCase = 0
                        loadTestData(itemCount: testCases[currentTestCase])
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    private func loadTestData(itemCount: Int) {
        if let realManager = extensionManager as? ExtensionManager {
            realManager.loadTestData(itemCount: itemCount)
        } else if let mockManager = extensionManager as? MockExtensionManager {
            let mockExtensions = (1...itemCount).map { i in
                Extension.mock(
                    id: "test_\(i)",
                    name: "Test Extension \(i)",
                    isPinned: i <= min(4, itemCount / 4),
                    pinnedIndex: i <= min(4, itemCount / 4) ? i : -1
                )
            }
            mockManager.extensions = mockExtensions
            mockManager.pinedExtensions = mockExtensions.filter { $0.isPinned }
        }
    }
    #endif
}

struct ExtensionGridItem: View {
    @ObservedObject var ext: Extension
    @State private var isHovered = false
    var onTogglePin: ((Extension) -> Void)?
    var onTap: ((Extension) -> Void)?
    var onSecondaryTap: ((Extension) -> Void)?
    
    private let itemWidth: CGFloat = 50
    private let itemHeight: CGFloat = 32
    private let iconSize: CGFloat = 18
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Main item container
            ZStack {
                // Background with hover effect
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color(.sidebarTabHoveredColorEmphasized) : Color(.sidebarTabHovered))
                
                // Extension icon
                if let icon = ext.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .foregroundColor(.secondary)
                }
            }
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .frame(width: itemWidth, height: itemHeight)
            
            // Pin indicator (positioned at item's bottom-trailing corner)
            if ext.isPinned || isHovered {
                Button(action: {
                    if let onTogglePin = onTogglePin {
                        onTogglePin(ext)
                    } else {
                        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.extensionManager.togglePin(ext)
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.black)
                            .frame(width: 16, height: 16)
                        Image(.sidebarPin)
                            .frame(width: 10, height: 16)
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .offset(x: 4, y: 4)
                .opacity(ext.isPinned ? 1.0 : (isHovered ? 0.6 : 0.0))
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .help(ext.isPinned ? NSLocalizedString("Unpin extension", comment: "Extension list - Tooltip for unpinning an extension") : NSLocalizedString("Pin extension", comment: "Extension list - Tooltip for pinning an extension"))
                .allowsHitTesting(true)
            }
        }
        .frame(width: itemWidth, height: itemHeight)
        .contentShape(Rectangle())
        .overlay(
            SecondaryClickPassthrough {
                onSecondaryTap?(ext)
            }
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if let onTap = onTap {
                onTap(ext)
            } else {
                let mouseLocation = NSEvent.mouseLocation
                guard let screen = NSScreen.main else { return }
                let convertedLocation = NSPoint(x: mouseLocation.x, y: screen.frame.height - mouseLocation.y)
                let windowId = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.windowId
                ChromiumLauncher.sharedInstance().bridge?.triggerExtension(withId: ext.id, pointInScreen: convertedLocation, windowId: windowId?.int64Value ?? 0)
            }
        }
    }
}

struct ManageExtensionsButton: View {
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(NSLocalizedString("Manage Extensions", comment: "Extension list - Button to open extensions management page"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(height: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct WebsiteCertificateButton: View {
    let certificateStatusText: String
    let isCertificateValid: Bool
    let certificates: [SecCertificate]
    @State private var isHovered = false

    var body: some View {
        Button(action: showCertificatePanel) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isCertificateValid ? .secondary : .red)
                    .frame(width: 14, alignment: .center)
                
                Text(certificateStatusText)
                    .font(.system(size: 13))
                    .foregroundColor(isCertificateValid ? .secondary : .red)
                    .lineLimit(1)
                
                Spacer()
                
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
                
            }
            .frame(height: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
//        .disabled(certificates.isEmpty)
        .help(certificates.isEmpty
              ? NSLocalizedString("No certificate available", comment: "No certificate tooltip")
              : NSLocalizedString("Show certificate", comment: "Show certificate tooltip"))
    }

    private func showCertificatePanel() {
        guard !certificates.isEmpty else {
            return
        }
        guard let docWindow =
                MainBrowserWindowControllersManager.shared.activeWindowController?.window
                ?? NSApp.keyWindow else {
            return
        }

        let panel = SFCertificatePanel()
        panel.beginSheet(
            for: docWindow,
            modalDelegate: CertificatePanelSheetDelegate.shared,
            didEnd: #selector(CertificatePanelSheetDelegate.certificateSheetDidEnd(_:returnCode:contextInfo:)),
            contextInfo: nil,
            certificates: certificates,
            showGroup: certificates.count > 1
        )
    }
}

struct WebsiteSecurityStatusRow: View {
    let statusText: String
    let isSecure: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isSecure ? "lock.fill" : "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSecure ? .secondary : .red)
                .frame(width: 14, alignment: .center)

            Text(statusText)
                .font(.system(size: 13))
                .foregroundColor(isSecure ? .secondary : .red)

            Spacer()
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
    }
}

struct WebsiteSettingsButton: View {
    let onMenuActionSelected: (() -> Void)?

    private final class MenuActionTarget: NSObject {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSMenuItem) {
            action()
        }
    }

    @State private var isHovered = false
    @State private var anchorView: NSView?
    @State private var isPresentingMenu = false

    var body: some View {
        Button(action: presentSettingsMenu) {
            HStack(spacing: 4) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, alignment: .center)

                Text(NSLocalizedString("Settings", comment: "Extension list - Website settings entry"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(height: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .background(MenuAnchorViewRepresentable(anchorView: $anchorView))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func presentSettingsMenu() {
        guard !isPresentingMenu else {
            return
        }
        guard let anchorView, let window = anchorView.window else {
            return
        }

        isPresentingMenu = true
        defer { isPresentingMenu = false }

        let browserState = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
        let rawURLString = browserState?.focusingTab?.url ?? ""
        let windowId = browserState?.windowId.int64Value ?? 0

        var actionTargets: [MenuActionTarget] = []
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addMenuItem(
            title: String,
            action: @escaping () -> Void
        ) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let target = MenuActionTarget {
                action()
                onMenuActionSelected?()
            }
            actionTargets.append(target)
            item.target = target
            item.action = #selector(MenuActionTarget.performAction(_:))
            menu.addItem(item)
        }

        addMenuItem(title: NSLocalizedString("Clear Cookie", comment: "Extension list - Website settings item to clear cookies")) {
            ChromiumLauncher.sharedInstance()
                .bridge?
                .clearWebsiteCookies(rawURLString, windowId: windowId)
        }

        addMenuItem(title: NSLocalizedString("Clear Cache", comment: "Extension list - Website settings item to clear cache")) {
            ChromiumLauncher.sharedInstance()
                .bridge?
                .clearWebsiteCache(rawURLString, windowId: windowId)
        }

        menu.addItem(.separator())

        addMenuItem(title: NSLocalizedString("More Settings", comment: "Extension list - Website settings item to open more settings")) {
            let url = URLProcessor.processUserInput("chrome://settings/content/siteDetails?site=\(rawURLString)")
            browserState?.createTab(url)
        }

        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
        let pointInWindow = NSPoint(x: anchorRect.maxX + 4, y: anchorRect.maxY - 2)
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
        menu.popUp(positioning: nil, at: pointOnScreen, in: nil)

        _ = actionTargets
    }
}

private struct MenuAnchorViewRepresentable: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            anchorView = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            anchorView = nsView
        }
    }
}

#if DEBUG
// MARK: - Mock Data for Testing

class MockExtensionManager: ObservableObject, ExtensionManagerProtocol {
    @Published var extensions: [Extension] = []
    @Published var pinedExtensions: [Extension] = []
    @Published var phiExtensionVersion: String?
    
    init(mockExtensions: [Extension]) {
        self.extensions = mockExtensions
        self.pinedExtensions = mockExtensions.filter { $0.isPinned }
    }
    
    func refreshExtensions() {
        // Do nothing for mock
    }
    
    func togglePin(_ model: Extension) {
        // Mock toggle for debug test
        if let index = extensions.firstIndex(where: { $0.id == model.id }) {
            extensions[index].isPinned.toggle()
            pinedExtensions = extensions.filter { $0.isPinned }
        }
    }
}

extension Extension {
    static func mock(id: String, name: String, isPinned: Bool = false, pinnedIndex: Int = -1) -> Extension {
        let dict: [String: Any] = [
            "id": id,
            "name": name,
            "version": "1.0.0",
            "isPinned": isPinned,
            "pinnedIndex": pinnedIndex
        ]
        return Extension(from: dict)
    }
}
#endif
