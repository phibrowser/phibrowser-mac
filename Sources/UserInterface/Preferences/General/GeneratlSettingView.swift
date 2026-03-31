// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

enum NewTabBehaviour: String, CaseIterable, Identifiable {
    case newTabPage
    case omnibox
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .newTabPage:
            return NSLocalizedString("New Tab Page", comment: "General settings - Option to open New Tab Page when pressing ⌘+T")
        case .omnibox:
            return NSLocalizedString("Omnibox", comment: "General settings - Option to open Omnibox search when pressing ⌘+T")
        }
    }
}

struct GeneralSettingView: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
//                ThemeSectionView()
                AppearanceSectionView()
                BrowsingSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(.windowBackground)
        .frame(width: 680, height: 561)
    }
}

private struct ThemeColorOption: Identifiable {
    let id: String
    let color: Color
    let label: String?
}

private struct ThemeSectionView: View {
    @State private var selectedColorID: String = "white"

    private let colorOptions: [ThemeColorOption] = [
        ThemeColorOption(id: "white", color: .white, label: "White"),
        ThemeColorOption(id: "green", color: Color(hexString: "#8DE17E"), label: nil),
        ThemeColorOption(id: "cyan", color: Color(hexString: "#70D7E2"), label: nil),
        ThemeColorOption(id: "blue", color: Color(hexString: "#7D84F6"), label: nil),
        ThemeColorOption(id: "purple", color: Color(hexString: "#C870DE"), label: nil),
        ThemeColorOption(id: "red", color: Color(hexString: "#F18375"), label: nil),
        ThemeColorOption(id: "yellow", color: Color(hexString: "#EBCB6A"), label: nil)
    ]

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Theme", comment: "General settings - Theme section title")) {
            GeneralContainerView {
                GeneralRowView(title: NSLocalizedString("Color", comment: "General settings - Theme color row title")) {
                    HStack(spacing: 12) {
                        ForEach(colorOptions) { option in
                            ThemeColorItemView(
                                option: option,
                                selected: selectedColorID == option.id,
                                action: { selectedColorID = option.id }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct AppearanceSectionView: View {
    @AppStorage(PhiPreferences.GeneralSettings.layoutModeKey)
    private var layoutModeRawValue: String = PhiPreferences.GeneralSettings.loadLayoutMode().rawValue

    @State private var selectedAppearance: UserAppearanceChoice = ThemeManager.shared.userAppearanceChoice

    private var selectedLayoutMode: Binding<LayoutMode> {
        Binding(
            get: { LayoutMode(rawValue: layoutModeRawValue) ?? PhiPreferences.GeneralSettings.loadLayoutMode() },
            set: { mode in
                layoutModeRawValue = mode.rawValue
                PhiPreferences.GeneralSettings.saveLayoutMode(mode)
            }
        )
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Appearance", comment: "General settings - Appearance section title")) {
            GeneralContainerView {
                GeneralRowView(title: NSLocalizedString("Layout mode", comment: "General settings - Layout mode row title"), alignment: .top) {
                    HStack(spacing: 16) {
                        ForEach(LayoutMode.allCases) { mode in
                            GeneralSttingCardView(
                                image: Image(layoutImageResource(for: mode)),
                                action: { selectedLayoutMode.wrappedValue = mode },
                                selected: selectedLayoutMode.wrappedValue == mode,
                                title: mode.displayName
                            )
                        }
                    }
                }

                Divider()

                GeneralRowView(title: NSLocalizedString("Color appearance", comment: "General settings - Color appearance row title"), alignment: .top) {
                    HStack(spacing: 16) {
                        ForEach(UserAppearanceChoice.allCases, id: \.self) { choice in
                            GeneralSttingCardView(
                                image: Image(appearanceImageName(for: choice)),
                                action: {
                                    selectedAppearance = choice
                                    ThemeManager.shared.setUserAppearanceChoice(choice)
                                },
                                selected: selectedAppearance == choice,
                                title: choice.localizedName
                            )
                        }
                    }
                }
            }
        }
    }

    private func layoutImageResource(for mode: LayoutMode) -> ImageResource {
        switch mode {
        case .performance:
            return .tabLayoutPerformance
        case .balanced:
            return .tabLayoutBalanced
        case .comfortable:
            return .tabLayoutComfortable
        }
    }

    private func appearanceImageName(for choice: UserAppearanceChoice) -> String {
        switch choice {
        case .system:
            return "appearance-system"
        case .light:
            return "appearance-light"
        case .dark:
            return "appearance-dark"
        }
    }
}

private struct BrowsingSectionView: View {
    @AppStorage(PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
    private var openNewTabPageOnCmdT: Bool = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.alwaysShowURLPath.rawValue)
    private var alwaysShowURLPath: Bool = PhiPreferences.GeneralSettings.alwaysShowURLPath.defaultValue

    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

    private var selectedBehavior: Binding<NewTabBehaviour> {
        Binding(
            get: { openNewTabPageOnCmdT ? .newTabPage : .omnibox },
            set: { openNewTabPageOnCmdT = ($0 == .newTabPage) }
        )
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Browsing", comment: "General settings - Browsing section title")) {
            VStack(alignment: .leading, spacing: 8) {
                GeneralContainerView {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("New tab behavior", comment: "General settings - Row title for configuring new tab behavior"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            if !phiAIEnabled {
                                Text(NSLocalizedString("New Tab Page requires Phi AI to be enabled", comment: "General settings - Hint shown when Phi AI is disabled explaining New Tab Page requires it"))
                                    .font(.system(size: 11))
                                    .themedForeground(.textTertiary)
                            }
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 16) {
                            ForEach(NewTabBehaviour.allCases) { behavior in
                                GeneralSttingCardView(
                                    image: Image(newTabImageName(for: behavior)),
                                    action: {
                                        if behavior == .newTabPage && !phiAIEnabled { return }
                                        selectedBehavior.wrappedValue = behavior
                                    },
                                    selected: selectedBehavior.wrappedValue == behavior,
                                    title: behavior.displayName
                                )
                                .opacity(behavior == .newTabPage && !phiAIEnabled ? 0.4 : 1.0)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    GeneralRowView(title: NSLocalizedString("Always show full URL", comment: "General settings - Toggle title for always showing full URL in address bar")) {
                        Toggle("", isOn: $alwaysShowURLPath)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                    }
                    
                    Divider()
                    
                    Button(action: handleAdditionalBrowserSettingsTap) {
                        GeneralRowView(title: NSLocalizedString("Additional browser settings", comment: "General settings - Title for always more settings")) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .themedForeground(.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func newTabImageName(for behavior: NewTabBehaviour) -> String {
        switch behavior {
        case .newTabPage:
            return "newtab-ntp"
        case .omnibox:
            return "newtab-omibar"
        }
    }

    private func handleAdditionalBrowserSettingsTap() {
        MainBrowserWindowControllersManager
            .shared
            .activeWindowController?
            .browserState
            .createTab("chrome://settings")
    }
}

private struct GeneralSectionView<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralContainerView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .themedBackground(.settingItemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .themedStroke(.border)
        }
    }
}

private struct GeneralRowView<Accessory: View>: View {
    let title: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThemeColorItemView: View {
    let option: ThemeColorOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(option.color)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle()
                            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                            .padding(-2)
                    }

                Text(option.label ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .opacity(option.label == nil ? 0 : 1)
            }
            .frame(width: 32)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    GeneralSettingView()
}
