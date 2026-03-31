// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

//  This file contains usage examples for the Phi Theme System.
//  Use #Preview to see the examples in Xcode Canvas.
//  ⚠️ NOTE: All localized strings in this file are prefixed with "/**/" in comments
//  to indicate they are EXAMPLE/TEST strings only, not production UI strings.
//  These should be excluded from production localization workflows.

import SwiftUI
import AppKit

// MARK: - Example Localization Helper

/// Example strings namespace - all strings here are for demo/test purposes only
private enum ExampleStrings {
    // Section titles
    static let appearanceChoice = NSLocalizedString("/**/Appearance Choice", comment: "[EXAMPLE] Theme example: appearance picker section title")
    static let appearance = NSLocalizedString("/**/Appearance", comment: "[EXAMPLE] Theme example: appearance picker label")
    static let currentAppearance = NSLocalizedString("/**/Current Appearance: %@", comment: "[EXAMPLE] Theme example: current appearance label with format")
    static let textColorExample = NSLocalizedString("/**/Text Color Examples", comment: "[EXAMPLE] Theme example: text color section title")
    static let sidebarExample = NSLocalizedString("/**/Sidebar Style Examples", comment: "[EXAMPLE] Theme example: sidebar section title")
    static let borderExample = NSLocalizedString("/**/Border & Separator Examples", comment: "[EXAMPLE] Theme example: border section title")
    
    // Text samples
    static let primaryText = NSLocalizedString("/**/Primary Text - Main content text", comment: "[EXAMPLE] Theme example: primary text sample")
    static let secondaryText = NSLocalizedString("/**/Secondary Text - Supporting text", comment: "[EXAMPLE] Theme example: secondary text sample")
    static let tertiaryText = NSLocalizedString("/**/Tertiary Text - Tertiary level text", comment: "[EXAMPLE] Theme example: tertiary text sample")
    
    // Sidebar labels
    static let selectedTab = NSLocalizedString("/**/Selected Tab", comment: "[EXAMPLE] Theme example: selected tab label")
    static let hoveredTab = NSLocalizedString("/**/Hovered Tab", comment: "[EXAMPLE] Theme example: hovered tab label")
    static let normalTab = NSLocalizedString("/**/Normal Tab", comment: "[EXAMPLE] Theme example: normal tab label")
    
    // Border labels
    static let borderStyle = NSLocalizedString("/**/Border", comment: "[EXAMPLE] Theme example: border style label")
    static let separatorStyle = NSLocalizedString("/**/Separator", comment: "[EXAMPLE] Theme example: separator style label")
    
    // Window labels
    static let windowBackground = NSLocalizedString("/**/Window Background", comment: "[EXAMPLE] Theme example: window background label")
    static let overlayBackground = NSLocalizedString("/**/Overlay Background", comment: "[EXAMPLE] Theme example: overlay background label")
    
    // AppKit section
    static let appKitControlsExample = NSLocalizedString("/**/AppKit Controls Examples", comment: "[EXAMPLE] Theme example: AppKit controls section title")
    static let nsTextFieldWithPhi = NSLocalizedString("/**/NSTextField with phi.textColor:", comment: "[EXAMPLE] Theme example: NSTextField description")
    static let nsTextFieldSample = NSLocalizedString("/**/This is an NSTextField, color changes with appearance", comment: "[EXAMPLE] Theme example: NSTextField sample text")
    static let nsButtonWithPhi = NSLocalizedString("/**/NSButton with phi.title:", comment: "[EXAMPLE] Theme example: NSButton description")
    static let nsViewWithPhiLayer = NSLocalizedString("/**/NSView with phiLayer.backgroundColor:", comment: "[EXAMPLE] Theme example: NSView layer description")
    static let lightModeButton = NSLocalizedString("/**/Light Mode Button", comment: "[EXAMPLE] Theme example: light mode button title")
    static let darkModeButton = NSLocalizedString("/**/Dark Mode Button", comment: "[EXAMPLE] Theme example: dark mode button title")
    
    // Code examples
    static let codeExamples = NSLocalizedString("/**/Code Examples", comment: "[EXAMPLE] Theme example: code examples section title")
    static let basicUsage = NSLocalizedString("/**/Basic Usage - <> Operator", comment: "[EXAMPLE] Theme example: basic usage code title")
    static let userAppearanceChoice = NSLocalizedString("/**/User Appearance Choice", comment: "[EXAMPLE] Theme example: user appearance code title")
    static let swiftUIModifiers = NSLocalizedString("/**/SwiftUI Modifiers", comment: "[EXAMPLE] Theme example: SwiftUI modifiers code title")
    static let customTheme = NSLocalizedString("/**/Custom Theme", comment: "[EXAMPLE] Theme example: custom theme code title")
}

// MARK: - SwiftUI Examples

/// SwiftUI example view for the theme system.
@available(macOS 14.0, *)
struct ThemeSwiftUIExampleView: View {
    @ObservedObject private var observer = ThemeObserver.shared
    @State private var selectedChoice: UserAppearanceChoice = ThemeManager.shared.userAppearanceChoice
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Appearance picker
                appearancePickerSection
                
                Divider()
                
                // Text color examples
                textColorSection
                
                Divider()
                
                // Sidebar examples
                sidebarSection
                
                Divider()
                
                // Border and separator examples
                borderSection
                
                Divider()
                
                // Window background examples
                windowSection
            }
            .padding(20)
        }
        .frame(minWidth: 400, minHeight: 500)
        .background(observer.resolve(.windowBackground))
    }
    
    // MARK: - Sections
    
    private var appearancePickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ExampleStrings.appearanceChoice)
                .font(.headline)
                .themedForeground(.textPrimary)
            
            Picker(ExampleStrings.appearance, selection: $selectedChoice) {
                ForEach(UserAppearanceChoice.allCases, id: \.self) { choice in
                    Text(choice.localizedName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedChoice) { _, newValue in
                ThemeManager.shared.setUserAppearanceChoice(newValue)
            }
            
            Text(String(format: ExampleStrings.currentAppearance, observer.appearance.description))
                .font(.caption)
                .themedForeground(.textSecondary)
        }
    }
    
    private var textColorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ExampleStrings.textColorExample)
                .font(.headline)
                .themedForeground(.textPrimary)
            
            Group {
                Text(ExampleStrings.primaryText)
                    .themedForeground(.textPrimary)
                
                Text(ExampleStrings.secondaryText)
                    .themedForeground(.textSecondary)
                
                Text(ExampleStrings.tertiaryText)
                    .themedForeground(.textTertiary)
            }
            .font(.body)
        }
    }
    
    private var sidebarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ExampleStrings.sidebarExample)
                .font(.headline)
                .themedForeground(.textPrimary)
            
            VStack(spacing: 4) {
                // Selected state
                HStack {
                    Image(systemName: "folder.fill")
                    Text(ExampleStrings.selectedTab)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .themedBackground(.sidebarTabSelectedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                
                // Hover state
                HStack {
                    Image(systemName: "doc.text")
                    Text(ExampleStrings.hoveredTab)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .themedBackground(.sidebarTabHoveredBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                
                // Default state
                HStack {
                    Image(systemName: "photo")
                    Text(ExampleStrings.normalTab)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .themedForeground(.textPrimary)
            .font(.body)
        }
    }
    
    private var borderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ExampleStrings.borderExample)
                .font(.headline)
                .themedForeground(.textPrimary)
            
            HStack(spacing: 20) {
                // Border
                Text(ExampleStrings.borderStyle)
                    .font(.body)
                    .themedForeground(.textPrimary)
                    .padding(16)
                    .themedBorder(.border, width: 1)
                
                // Separator example
                VStack(spacing: 8) {
                    Text("Item 1")
                        .themedForeground(.textPrimary)
                    
                    Rectangle()
                        .themedFill(.separator)
                        .frame(height: 1)
                    
                    Text("Item 2")
                        .themedForeground(.textPrimary)
                }
                .font(.body)
            }
        }
    }
    
    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ExampleStrings.windowBackground)
                .font(.headline)
                .themedForeground(.textPrimary)
            
            HStack(spacing: 16) {
                // Window background
                VStack {
                    RoundedRectangle(cornerRadius: 8)
                        .themedFill(.windowBackground)
                        .frame(width: 80, height: 50)
                        .themedBorder(.border, width: 1)
                    
                    Text(ExampleStrings.windowBackground)
                        .font(.caption2)
                        .themedForeground(.textSecondary)
                }
                
                // Overlay background
                VStack {
                    RoundedRectangle(cornerRadius: 8)
                        .themedFill(.windowOverlayBackground)
                        .frame(width: 80, height: 50)
                        .themedBorder(.border, width: 1)
                    
                    Text(ExampleStrings.overlayBackground)
                        .font(.caption2)
                        .themedForeground(.textSecondary)
                }
            }
        }
    }
}

// MARK: - AppKit Bridged Examples

/// Bridges `NSTextField` into SwiftUI.
@available(macOS 10.15, *)
struct AppKitTextFieldExample: NSViewRepresentable {
    let text: String
    
    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(labelWithString: text)
        textField.font = .systemFont(ofSize: 14)
        
        // Bind the label color through Phi.
        textField.phi.textColor = .red <> .orange
        
        return textField
    }
    
    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }
}

/// Bridges `NSButton` into SwiftUI.
@available(macOS 10.15, *)
struct AppKitButtonExample: NSViewRepresentable {
    let action: () -> Void
    
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Light", target: context.coordinator, action: #selector(Coordinator.buttonClicked))
        button.bezelStyle = .rounded
        
        // Swap the button title with appearance changes.
        button.phi.title = ExampleStrings.lightModeButton <> ExampleStrings.darkModeButton
        
        return button
    }
    
    func updateNSView(_ nsView: NSButton, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }
    
    class Coordinator: NSObject {
        let action: () -> Void
        
        init(action: @escaping () -> Void) {
            self.action = action
        }
        
        @objc func buttonClicked() {
            action()
        }
    }
}

/// Bridges an `NSView` with a themed backing layer into SwiftUI.
@available(macOS 10.15, *)
struct AppKitLayerViewExample: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        
        // Drive the layer colors through Phi.
        view.phiLayer?.backgroundColor = 0xF5F5F5 <> 0x2C2C2E
        view.phiLayer?.borderColor = 0xE0E0E0 <> 0x3A3A3C
        view.layer?.borderWidth = 1
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// AppKit example view for the theme system.
@available(macOS 14.0, *)
struct ThemeAppKitExampleView: View {
    @ObservedObject private var observer = ThemeObserver.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(ExampleStrings.appKitControlsExample)
                    .font(.headline)
                    .themedForeground(.textPrimary)
                
                // NSTextField example
                VStack(alignment: .leading, spacing: 8) {
                    Text(ExampleStrings.nsTextFieldWithPhi)
                        .font(.caption)
                        .themedForeground(.textSecondary)
                    
                    AppKitTextFieldExample(text: ExampleStrings.nsTextFieldSample)
                        .frame(height: 20)
                }
                
                // NSButton example
                VStack(alignment: .leading, spacing: 8) {
                    Text(ExampleStrings.nsButtonWithPhi)
                        .font(.caption)
                        .themedForeground(.textSecondary)
                    
                    AppKitButtonExample {
                        print("Button clicked!")
                    }
                    .frame(height: 30)
                }
                
                // Layer-backed NSView example
                VStack(alignment: .leading, spacing: 8) {
                    Text(ExampleStrings.nsViewWithPhiLayer)
                        .font(.caption)
                        .themedForeground(.textSecondary)
                    
                    AppKitLayerViewExample()
                        .frame(height: 60)
                }
                
                Spacer()
            }
            .padding(20)
        }
        .frame(minWidth: 350, minHeight: 300)
        .background(observer.resolve(.windowBackground))
    }
}

// MARK: - Code Examples View

/// Code example showcase.
@available(macOS 14.0, *)
struct ThemeCodeExamplesView: View {
    @ObservedObject private var observer = ThemeObserver.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(ExampleStrings.codeExamples)
                    .font(.headline)
                    .themedForeground(.textPrimary)
                
                codeBlock(
                    title: ExampleStrings.basicUsage,
                    code: """
                    // Set a text color
                    label.phi.textColor = .red <> .yellow
                    
                    // Use hex values
                    label.phi.textColor = 0x333333 <> 0xFFFFFF
                    
                    // Set a layer background
                    view.phiLayer?.backgroundColor = .white <> .black
                    """
                )
                
                codeBlock(
                    title: ExampleStrings.userAppearanceChoice,
                    code: """
                    // Follow the system
                    ThemeManager.shared.setUserAppearanceChoice(.system)
                    
                    // Force light mode
                    ThemeManager.shared.setUserAppearanceChoice(.light)
                    
                    // Force dark mode
                    ThemeManager.shared.setUserAppearanceChoice(.dark)
                    """
                )
                
                codeBlock(
                    title: ExampleStrings.swiftUIModifiers,
                    code: """
                    Text("Hello")
                        .themedForeground(.textPrimary)
                    
                    // Sidebar selected state
                    HStack { ... }
                        .themedBackground(.sidebarTabSelectedBackground)
                    
                    // Border
                    Text("Content")
                        .themedBorder(.border, width: 1)
                    """
                )
                
                codeBlock(
                    title: ExampleStrings.customTheme,
                    code: """
                    let myTheme = Theme(id: "custom", name: "Custom")
                    myTheme.setColor(
                        light: NSColor(hex: 0x1B4332),
                        dark: NSColor(hex: 0xD8F3DC),
                        for: .textPrimary
                    )
                    ThemeManager.shared.registerTheme(myTheme)
                    ThemeManager.shared.switchTheme(to: "custom")
                    """
                )
            }
            .padding(20)
        }
        .frame(minWidth: 400, minHeight: 400)
        .background(observer.resolve(.windowBackground))
    }
    
    private func codeBlock(title: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
                .themedForeground(.textPrimary)
            
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .themedForeground(.textSecondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: NSColor(white: 0.5, alpha: 0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Combined Example View

/// Combined example view.
@available(macOS 14.0, *)
struct ThemeCombinedExampleView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ThemeSwiftUIExampleView()
                .tabItem { Text("SwiftUI") }
                .tag(0)
            
            ThemeAppKitExampleView()
                .tabItem { Text("AppKit") }
                .tag(1)
            
            ThemeCodeExamplesView()
                .tabItem { Text("Code Examples") }
                .tag(2)
        }
        .frame(width: 500, height: 550)
    }
}

// MARK: - Previews

@available(macOS 14.0, *)
#Preview("SwiftUI Example") {
    ThemeSwiftUIExampleView()
}

@available(macOS 14.0, *)
#Preview("AppKit Controls Example") {
    ThemeAppKitExampleView()
}

@available(macOS 14.0, *)
#Preview("Code Examples") {
    ThemeCodeExamplesView()
}

@available(macOS 14.0, *)
#Preview("Combined Example") {
    ThemeCombinedExampleView()
}

// MARK: - Dark Mode Preview

@available(macOS 14.0, *)
#Preview("Dark Mode") {
    ThemeSwiftUIExampleView()
        .onAppear {
            ThemeManager.shared.setUserAppearanceChoice(.dark)
        }
        .preferredColorScheme(.dark)
}

@available(macOS 14.0, *)
#Preview("Light Mode") {
    ThemeSwiftUIExampleView()
        .onAppear {
            ThemeManager.shared.setUserAppearanceChoice(.light)
        }
        .preferredColorScheme(.light)
}
