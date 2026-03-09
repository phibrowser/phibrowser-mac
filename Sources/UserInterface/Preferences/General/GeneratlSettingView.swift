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
                ThemeColorSettingView()
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

struct ThemeColorSettingView: View {
    @State private var selectedThemeId: String = ThemeManager.shared.currentTheme.id

    private let themes = Theme.builtInThemes
    private let sliderAnimation = Animation.spring(response: 0.28, dampingFraction: 0.84)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(NSLocalizedString("Theme color", comment: "General settings - Section title for configuring theme color"))
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .padding(.bottom, 12)

            ThemeColorPickerTrack(
                themes: themes,
                selectedThemeId: selectedThemeId,
                animation: sliderAnimation,
                onSelectTheme: selectTheme(_:)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            withAnimation(sliderAnimation) {
                selectedThemeId = ThemeManager.shared.currentTheme.id
            }
        }
    }

    private func selectTheme(_ theme: Theme) {
        guard selectedThemeId != theme.id else { return }

        withAnimation(sliderAnimation) {
            selectedThemeId = theme.id
        }

        ThemeManager.shared.switchTheme(to: theme.id)
    }
}

private struct ThemeColorPickerTrack: View {
    let themes: [Theme]
    let selectedThemeId: String
    let animation: Animation
    let onSelectTheme: (Theme) -> Void

    private let trackWidth: CGFloat = 399
    private let trackHeight: CGFloat = 14
    private let knobSize: CGFloat = 22
    private let pointSize: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let metrics = trackMetrics(for: geometry.size.width)

            ZStack(alignment: .leading) {
                Image(.colorPickerBg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: trackHeight)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(0.1), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                ForEach(Array(themes.enumerated()), id: \.element.id) { index, _ in
                    Circle()
                        .fill(Color.black.opacity(0.88))
                        .frame(width: pointSize, height: pointSize)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                        )
                        .offset(x: pointOffset(for: index, using: metrics))
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.16), radius: 8, y: 2)
                    .offset(x: knobOffset(using: metrics))
                    .animation(animation, value: selectedThemeId)
            }
            .frame(width: geometry.size.width, height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateSelection(at: value.location.x, using: metrics)
                    }
                    .onEnded { value in
                        updateSelection(at: value.location.x, using: metrics)
                    }
            )
        }
        .frame(width: trackWidth, height: knobSize)
    }

    private var selectedIndex: Int {
        themes.firstIndex(where: { $0.id == selectedThemeId }) ?? 0
    }

    private func trackMetrics(for width: CGFloat) -> (usableWidth: CGFloat, step: CGFloat) {
        let usableWidth = max(width - knobSize, 0)
        let step = themes.count > 1 ? usableWidth / CGFloat(themes.count - 1) : 0
        return (usableWidth, step)
    }

    private func knobOffset(using metrics: (usableWidth: CGFloat, step: CGFloat)) -> CGFloat {
        min(CGFloat(selectedIndex) * metrics.step, metrics.usableWidth)
    }

    private func pointOffset(for index: Int, using metrics: (usableWidth: CGFloat, step: CGFloat)) -> CGFloat {
        min(CGFloat(index) * metrics.step, metrics.usableWidth) + ((knobSize - pointSize) / 2)
    }

    private func updateSelection(at locationX: CGFloat, using metrics: (usableWidth: CGFloat, step: CGFloat)) {
        guard let selectedTheme = theme(at: locationX, using: metrics) else { return }
        onSelectTheme(selectedTheme)
    }

    private func theme(at locationX: CGFloat, using metrics: (usableWidth: CGFloat, step: CGFloat)) -> Theme? {
        guard !themes.isEmpty else { return nil }
        guard themes.count > 1, metrics.step > 0 else { return themes.first }

        let clampedOffset = min(max(locationX - (knobSize / 2), 0), metrics.usableWidth)
        let index = Int((clampedOffset / metrics.step).rounded())
        return themes[min(max(index, 0), themes.count - 1)]
    }
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
