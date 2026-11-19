// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Phi commands offered in the V2 omnibox. Chromium ranks them by title and
/// keywords and forwards the chosen raw value back for execution.
enum OmniboxCommand: String, CaseIterable {
    case manageExtensions
    case newSplitView
    case addVerticalSplitView
    case addLeftSplit
    case addTopSplit
    case removeSplitView
    case switchToLightMode
    case switchToDarkMode
    case switchToBalancedMode
    case switchToPerformanceMode
    case switchToComfortableMode

    var title: String {
        switch self {
        case .switchToBalancedMode:
            return NSLocalizedString("omnibox.command.switchToBalancedMode", value: "Switch to balanced mode",
                comment: "Omnibox commands - Sets the browser layout preference to balanced mode")
        case .switchToPerformanceMode:
            return NSLocalizedString("omnibox.command.switchToPerformanceMode", value: "Switch to performance mode",
                comment: "Omnibox commands - Sets the browser layout preference to performance mode")
        case .switchToComfortableMode:
            return NSLocalizedString("omnibox.command.switchToComfortableMode", value: "Switch to comfortable mode",
                comment: "Omnibox commands - Sets the browser layout preference to comfortable mode")
        case .switchToLightMode:
            return NSLocalizedString("omnibox.command.switchToLightMode", value: "Switch to light mode",
                comment: "Omnibox commands - Sets the browser appearance preference to light mode")
        case .switchToDarkMode:
            return NSLocalizedString("omnibox.command.switchToDarkMode", value: "Switch to dark mode",
                comment: "Omnibox commands - Sets the browser appearance preference to dark mode")
        case .removeSplitView:
            return NSLocalizedString("omnibox.command.removeSplitView", value: "Remove split view",
                comment: "Omnibox commands - Separates the current split into two tabs without closing either page")
        case .manageExtensions:
            return NSLocalizedString("omnibox.command.manageExtensions", value: "Manage extensions",
                comment: "Omnibox commands - Command that opens the extensions management page")
        case .newSplitView:
            return NSLocalizedString("omnibox.command.newSplitView", value: "Add split view",
                comment: "Omnibox commands - Command that splits the current tab with a new tab")
        case .addVerticalSplitView:
            return NSLocalizedString("omnibox.command.addVerticalSplitView", value: "Add vertical split view",
                comment: "Omnibox commands - Adds a new pane below the current tab")
        case .addLeftSplit:
            return NSLocalizedString("omnibox.command.addLeftSplit", value: "Add left split",
                comment: "Omnibox commands - Adds a new pane to the left of the current tab")
        case .addTopSplit:
            return NSLocalizedString("omnibox.command.addTopSplit", value: "Add top split",
                comment: "Omnibox commands - Adds a new pane above the current tab")
        }
    }

    /// English, so they also match when the title is localized.
    var keywords: [String] {
        switch self {
        case .switchToBalancedMode: return ["switch", "balanced", "mode", "layout"]
        case .switchToPerformanceMode: return ["switch", "performance", "mode", "layout"]
        case .switchToComfortableMode: return ["switch", "comfortable", "mode", "layout"]
        case .switchToLightMode: return ["switch", "light", "mode", "appearance", "theme"]
        case .switchToDarkMode: return ["switch", "dark", "mode", "appearance", "theme"]
        case .removeSplitView: return ["remove", "split", "view", "unsplit", "separate"]
        case .manageExtensions: return ["manage", "extensions", "add-ons", "plugins"]
        case .newSplitView: return ["add", "new", "split", "view", "pane", "side by side"]
        case .addVerticalSplitView: return ["add", "vertical", "split", "view", "bottom", "stacked"]
        case .addLeftSplit: return ["add", "left", "split", "horizontal", "pane"]
        case .addTopSplit: return ["add", "top", "split", "vertical", "pane"]
        }
    }

    var symbolName: String {
        switch self {
        case .switchToBalancedMode, .switchToPerformanceMode, .switchToComfortableMode:
            return "rectangle.3.group"
        case .switchToLightMode: return "sun.max"
        case .switchToDarkMode: return "moon"
        case .removeSplitView: return "rectangle"
        case .manageExtensions: return "puzzlepiece.extension"
        case .newSplitView, .addLeftSplit: return "rectangle.split.2x1"
        case .addVerticalSplitView, .addTopSplit: return "rectangle.split.1x2"
        }
    }
}

extension BrowserState {
    @MainActor
    func omniboxCommandCatalog() -> OmniboxNativeCommandSnapshot {
        .init(status: .complete, entities: OmniboxCommand.allCases
            .filter { canPerformOmniboxCommand($0) }
            .map { .init(commandID: $0.rawValue, title: $0.title, keywords: $0.keywords) })
    }

    @MainActor
    func canPerformOmniboxCommand(_ command: OmniboxCommand) -> Bool {
        switch command {
        case .removeSplitView:
            guard !isKioskWindow, !isInPlaceholderMode, groupOverviewState == nil,
                  pendingSplitPreview == nil, let tab = focusingTab,
                  let split = splitGroup(forTabId: tab.guid) else { return false }
            return !split.isPinned
        case .manageExtensions, .switchToLightMode, .switchToDarkMode,
             .switchToBalancedMode, .switchToPerformanceMode, .switchToComfortableMode:
            return true
        case .newSplitView, .addVerticalSplitView, .addLeftSplit, .addTopSplit:
            return canSplitFocusedTabWithNewTab
        }
    }

    /// Validates now and performs on a later main-actor turn, once the
    /// Chromium selection that forwarded the command has unwound.
    @MainActor
    func scheduleOmniboxCommand(_ commandID: String) -> Bool {
        guard let command = OmniboxCommand(rawValue: commandID),
              canPerformOmniboxCommand(command) else { return false }
        Task { @MainActor [weak self] in
            self?.performOmniboxCommand(command)
        }
        return true
    }

    /// The choosing omnibox closes first: hiding it would otherwise end a
    /// surface the command presents, such as the split pane picker.
    @MainActor
    private func performOmniboxCommand(_ command: OmniboxCommand) {
        guard canPerformOmniboxCommand(command) else { return }
        if let omnibox = windowController?.omniBoxContainerViewController, omnibox.hasShown {
            omnibox.hideOmniBox()
        }
        AppLogInfo("[OmniboxNative] perform command=\(command.rawValue)")
        switch command {
        case .switchToBalancedMode:
            PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)
        case .switchToPerformanceMode:
            PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        case .switchToComfortableMode:
            PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        case .switchToLightMode:
            ThemeManager.shared.setUserAppearanceChoice(.light)
        case .switchToDarkMode:
            ThemeManager.shared.setUserAppearanceChoice(.dark)
        case .removeSplitView:
            if let tab = focusingTab, let split = splitGroup(forTabId: tab.guid) {
                removeSplit(split.id)
            }
        case .manageExtensions:
            createTab(URLProcessor.processUserInput("phi://extensions"))
        case .newSplitView:
            splitFocusedTabWithNewTab()
        case .addVerticalSplitView:
            splitFocusedTabWithNewTab(layout: .horizontal)
        case .addLeftSplit:
            splitFocusedTabWithNewTab(newTabSlot: .left)
        case .addTopSplit:
            splitFocusedTabWithNewTab(newTabSlot: .left, layout: .horizontal)
        }
    }
}
