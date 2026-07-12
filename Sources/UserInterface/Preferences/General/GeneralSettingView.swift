// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

func normalizedThemeSliderTrackColor(from color: NSColor) -> NSColor {
    let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
    return resolvedColor.withAlphaComponent(1)
}

/// Linear mapping between the overlay slider position (0...100) and the actual
/// allowed opacity percentage (10...80). Keeping the slider on a full 0...100
/// range lets the knob travel to both visual ends, while the underlying overlay
/// alpha is constrained to a tasteful sub-range.
private enum OverlayOpacityScale {
    static let minOpacityPercent: Double = 10
    static let maxOpacityPercent: Double = 80

    static func opacityPercent(forSlider sliderValue: Double) -> Double {
        let clamped = min(max(sliderValue, 0), 100)
        return minOpacityPercent + (maxOpacityPercent - minOpacityPercent) * (clamped / 100)
    }

    static func sliderValue(forOpacityPercent opacityPercent: Double) -> Double {
        let clamped = min(max(opacityPercent, minOpacityPercent), maxOpacityPercent)
        return (clamped - minOpacityPercent) / (maxOpacityPercent - minOpacityPercent) * 100
    }
}

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
    @ObservedObject private var settingsPresentation = SettingsPresentationState.shared

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                if !settingsPresentation.openedFromIncognito {
                    ThemeSectionView()
                }
                AppearanceSectionView()
                BrowsingSectionView()
                LanguageSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }
}

private struct ThemeSectionView: View {
    @State private var selectedThemeId: String = ThemeManager.shared.currentTheme.id
    @State private var sliderValue: Double = OverlayOpacityScale.sliderValue(
        forOpacityPercent: ThemeManager.shared.currentTheme.windowOverlayOpacity(for: ThemeManager.shared.currentAppearance) * 100
    )

    @AppStorage(PhiPreferences.ThemeSettings.selectionTintEnabled.rawValue)
    private var selectionTintEnabled: Bool = true

    @Environment(\.phiAppearance) private var appearance

    private var themes: [Theme] {
        ThemeManager.shared.orderedThemes
    }
    
    private var selectedTheme: Theme {
        themes.first(where: { $0.id == selectedThemeId }) ?? ThemeManager.shared.currentTheme
    }
    
    private var sliderTrackColor: NSColor {
        selectedTheme.color(for: .windowOverlayBackground, appearance: appearance)
    }
    
    private var sliderBorderColor: NSColor {
        ThemedColor.border.resolve(theme: selectedTheme, appearance: appearance)
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Theme", comment: "General settings - Theme section title")) {
            GeneralContainerView {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(NSLocalizedString("Color", comment: "General settings - Theme color row title"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        
                        Spacer(minLength: 12)
                        
                        HStack(alignment: .top, spacing: 13) {
                            ForEach(themes, id: \.id) { theme in
                                ThemeColorItemView(
                                    theme: theme,
                                    selected: selectedThemeId == theme.id,
                                    action: { selectTheme(theme) }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    GeneralRowView(title: NSLocalizedString("Opacity", comment: "General settings - Theme opacity row title for adjusting the selected theme overlay transparency")) {
                        ThemeOpacitySliderView(
                            value: Binding(
                                get: { sliderValue },
                                set: { newValue in
                                    sliderValue = newValue
                                    handleSliderValueChanged(newValue)
                                }
                            ),
                            trackColor: sliderTrackColor,
                            borderColor: sliderBorderColor
                        )
                        .frame(width: 324, height: 20)
                    }

                    Divider()

                    GeneralRowView(title: NSLocalizedString("Apply theme to text selection on web pages", comment: "General settings - Toggle title for tinting ::selection on third-party pages with the window theme accent")) {
                        Toggle("", isOn: $selectionTintEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            syncThemeControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceDidChange)) { _ in
            syncSliderValue()
        }
        .onAppear {
            syncThemeControls()
        }
    }

    private func selectTheme(_ theme: Theme) {
        guard selectedThemeId != theme.id else { return }

        selectedThemeId = theme.id
        ThemeManager.shared.switchTheme(to: theme.id)
        syncSliderValue()
    }
    
    private func handleSliderValueChanged(_ newSliderValue: Double) {
        // Always resolve the appearance through the manager. The Binding stored in
        // ThemeOpacitySliderView.Coordinator is created once and captures a stale
        // `self`, so reading the View's @Environment here would target the wrong
        // appearance after a light/dark switch.
        let opacityPercent = OverlayOpacityScale.opacityPercent(forSlider: newSliderValue)
        let alpha = CGFloat(opacityPercent / 100)
        AppLogDebug("[OverlayOpacity] slider→opacity slider=\(newSliderValue) percent=\(opacityPercent) alpha=\(alpha) appearance=\(ThemeManager.shared.currentAppearance) theme=\(ThemeManager.shared.currentTheme.id)")
        ThemeManager.shared.updateCurrentThemeOverlayOpacity(alpha)
    }

    private func syncThemeControls() {
        selectedThemeId = ThemeManager.shared.currentTheme.id
        syncSliderValue()
    }

    private func syncSliderValue() {
        let appearance = ThemeManager.shared.currentAppearance
        let alpha = ThemeManager.shared.currentTheme.windowOverlayOpacity(for: appearance)
        let opacityPercent = alpha * 100
        let newSliderValue = OverlayOpacityScale.sliderValue(forOpacityPercent: opacityPercent)
        AppLogDebug("[OverlayOpacity] sync appearance=\(appearance) theme=\(ThemeManager.shared.currentTheme.id) alpha=\(alpha) percent=\(opacityPercent) slider=\(newSliderValue) (was=\(sliderValue))")
        sliderValue = newSliderValue
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

private struct LanguageSectionView: View {
    @State private var selection: AppLanguage = PhiPreferences.LanguageSettings.loadChoice()
    /// Shown once the user changes the language this session, since the new
    /// localization only loads on the next launch.
    @State private var showRelaunchHint: Bool = false

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Language", comment: "General settings - Language section title")) {
            GeneralContainerView {
                GeneralRowView(title: NSLocalizedString("Language", comment: "General settings - App interface language row title")) {
                    Picker("", selection: $selection) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: selection) { _, newValue in
                        PhiPreferences.LanguageSettings.save(newValue)
                        showRelaunchHint = true
                    }
                }

                if showRelaunchHint {
                    Divider()

                    HStack(spacing: 12) {
                        Text(NSLocalizedString("Restart Phi to apply the new language.", comment: "General settings - Hint shown after changing the app language, prompting a relaunch"))
                            .font(.system(size: 11))
                            .themedForeground(.textTertiary)
                        Spacer(minLength: 12)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    @Environment(\.phiAppearance) private var appearance

    private var swatchColor: Color {
        if theme == .pure {
            return .white
        }
        return Color(theme.color(for: .themeColor, appearance: appearance))
    }

    var body: some View {
        ThemeSwatchView(
            fillColor: swatchColor,
            ringColor: Color(theme.color(for: .themeColor, appearance: appearance)),
            selected: selected,
            title: theme.name,
            showsContrastBorder: theme == .pure,
            action: action
        )
        .frame(width: 30)
    }
}

private struct ThemeOpacitySliderView: NSViewRepresentable {
    @Binding var value: Double
    let trackColor: NSColor
    let borderColor: NSColor
    
    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }
    
    private static let knobDiameter: CGFloat = 18

    func makeNSView(context: Context) -> CustomSlider {
        let slider = ThemeOpacityCustomSlider(frame: NSRect(origin: .zero, size: NSSize(width: 324, height: 20)))
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = value
        slider.isContinuous = true
        slider.barSize = NSSize(width: 324, height: 10)
        slider.knobSize = NSSize(width: Self.knobDiameter, height: Self.knobDiameter)
        slider.knobView = ThemeOpacitySliderKnobView(
            frame: NSRect(origin: .zero, size: NSSize(width: Self.knobDiameter, height: Self.knobDiameter)),
            borderColor: borderColor
        )
        slider.trackImage = makeTrackImage(color: trackColor, borderColor: borderColor)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.sliderValueChanged(_:))
        return slider
    }
    
    func updateNSView(_ slider: CustomSlider, context: Context) {
        slider.trackImage = makeTrackImage(color: trackColor, borderColor: borderColor)
        if let knobView = slider.knobView as? ThemeOpacitySliderKnobView {
            knobView.borderColor = borderColor
        }
        if slider.doubleValue != value {
            AppLogDebug("[OverlayOpacity] updateNSView push slider \(slider.doubleValue) → \(value)")
            slider.doubleValue = value
        }
    }
    
    private func makeTrackImage(color: NSColor, borderColor: NSColor) -> NSImage {
        let size = NSSize(width: 324, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2)
        path.addClip()
        
        let baseColor = normalizedThemeSliderTrackColor(from: color)
        let startColor = baseColor.withAlphaComponent(OverlayOpacityScale.minOpacityPercent / 100)
        let endColor = baseColor.withAlphaComponent(OverlayOpacityScale.maxOpacityPercent / 100)
        let gradient = NSGradient(starting: startColor, ending: endColor)
        gradient?.draw(in: path, angle: 0)
        
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        
        image.unlockFocus()
        return image
    }
    
    final class Coordinator: NSObject {
        @Binding private var value: Double
        
        init(value: Binding<Double>) {
            self._value = value
        }
        
        @objc func sliderValueChanged(_ sender: NSSlider) {
            AppLogDebug("[OverlayOpacity] NSSlider action value=\(sender.doubleValue)")
            value = sender.doubleValue
        }
    }
}

private final class ThemeOpacitySliderKnobView: NSView {
    var borderColor: NSColor {
        didSet {
            needsDisplay = true
        }
    }
    
    override init(frame frameRect: NSRect) {
        self.borderColor = ThemedColor.border.resolved()
        super.init(frame: frameRect)
        wantsLayer = true
    }
    
    init(frame frameRect: NSRect, borderColor: NSColor) {
        self.borderColor = borderColor
        super.init(frame: frameRect)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        self.borderColor = ThemedColor.border.resolved()
        super.init(coder: coder)
        wantsLayer = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Inset by half the stroke width so the 1pt border sits exactly on the
        // view edge, leaving no visible gap when the knob rests at the bar end.
        let strokeWidth: CGFloat = 1
        let circleRect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.set()

        let fillPath = NSBezierPath(ovalIn: circleRect)
        NSColor.white.setFill()
        fillPath.fill()

        NSGraphicsContext.current?.saveGraphicsState()
        NSShadow().set()
        borderColor.setStroke()
        fillPath.lineWidth = strokeWidth
        fillPath.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// Slider variant whose cell positions the knob using the configured `knobSize`
/// instead of AppKit's default `knobThickness` (~21pt). Other CustomSlider
/// callers use a 20pt knob, where the resulting ~0.5pt gap is invisible; our
/// 16pt knob produces a ~2.5pt visible gap, so we take over the layout.
private final class ThemeOpacityCustomSlider: CustomSlider {
    override class var cellClass: AnyClass? {
        get { ThemeOpacitySliderCell.self }
        set { _ = newValue }
    }
}

private final class ThemeOpacitySliderCell: ImageSliderCell {
    override var knobThickness: CGFloat {
        knobSize?.width ?? super.knobThickness
    }

    /// Span the whole control width so the gradient track image (also generated
    /// at full width) is not squeezed into AppKit's default knob padding.
    override func barRect(flipped: Bool) -> NSRect {
        guard let controlView else {
            return super.barRect(flipped: flipped)
        }
        let bounds = controlView.bounds
        let drawHeight = barSize?.height ?? bounds.height
        return NSRect(
            x: 0,
            y: (bounds.height - drawHeight) / 2.0,
            width: bounds.width,
            height: drawHeight
        )
    }

    override func knobRect(flipped: Bool) -> NSRect {
        guard let controlView else {
            return super.knobRect(flipped: flipped)
        }
        let bounds = controlView.bounds
        let knobWidth = knobSize?.width ?? super.knobThickness
        let knobHeight = knobSize?.height ?? bounds.height
        let denominator = maxValue - minValue
        let ratio: CGFloat = denominator > 0 ? CGFloat((doubleValue - minValue) / denominator) : 0
        let travel = max(0, bounds.width - knobWidth)
        let x = ratio * travel
        let y = (bounds.height - knobHeight) / 2.0
        return NSRect(x: x, y: y, width: knobWidth, height: knobHeight)
    }
}

#Preview {
    GeneralSettingView()
}
