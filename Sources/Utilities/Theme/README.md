# Phi Theme System

A theme framework for macOS that supports runtime theme switching and system light/dark appearance, with APIs for both AppKit and SwiftUI.

> Updated in 2026-03: the main browser window now uses a window-scoped theme-context model. `ThemeManager.shared` still exists, but it now primarily acts as a theme registry, shared default source, and compatibility fallback. The real theme state for browser-window UI lives in `BrowserState.themeContext`. Incognito windows use a fixed dark appearance and no longer follow system appearance or app-level appearance changes.

## Design Summary

A macOS app needs to respond to two dimensions:

1. Appearance: system light/dark mode.
2. Theme: app-defined color palettes.

Instead of manually observing and updating colors in each view, Phi uses declarative bindings.

```swift
// Imperative approach
label.textColor = isDark ? .white : .black
NotificationCenter.addObserver(...) { label.textColor = isDark ? .white : .black }

// Phi approach
label.phi.setTextColor(.black <> .white)
```

## Core Concepts

```text
┌──────────────────────────────────────────────────────────────┐
│                    ThemeManager.shared                      │
│      Theme registry + shared defaults + compatibility       │
└──────────────────────────┬───────────────────────────────────┘
                           │
                 resolve default config
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                  BrowserState.themeContext                  │
│ currentTheme / userAppearanceChoice / currentAppearance     │
│ fixed-window-appearance semantics when choice != .system    │
│                  (one per browser window)                   │
└──────────────────────────┬───────────────────────────────────┘
                           │
             ┌─────────────┴─────────────┐
             ▼                           ▼
┌─────────────────────────┐   ┌──────────────────────────────┐
│   AppKit Phi Binding    │   │ SwiftUI ThemeObserver/env    │
└─────────────────────────┘   └──────────────────────────────┘
```

1. `ThemeManager`: shared theme registry, shared defaults, and fallback source for non-browser windows.
2. `BrowserThemeContext`: browser-window-scoped theme state attached to `BrowserState`.
   Any window with `userAppearanceChoice != .system` is treated as a fixed-appearance window and no longer follows later system or app-level appearance changes.
3. `Mapper<V>`: value mapper resolved from `(theme, appearance)`.
4. `ThemedColor`: color abstraction with theme/appearance-aware resolution.
5. `Phi<Base>`: binder that applies mappers to AppKit properties.
6. `ThemeObserver`: `ObservableObject` used by SwiftUI to consume window-scoped theme state through environment values.

## Implementation

### AppKit

AppKit bindings are driven by `ThemeSource`, KVO, and associated objects.

- `Phi` stores subscriptions on the target control.
- Bindings resolve from the current `ThemeSource`, which may be the enclosing browser window's `BrowserThemeContext` or the shared fallback.
- `NSView` prefers `themeStateProvider.currentAppearance` instead of treating `effectiveAppearance` as the only appearance truth.

Example:

```swift
extension NSView: ThemeSource {
    public func subscribe(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        let provider = themeStateProvider
        action(provider.currentTheme, provider.currentAppearance)

        let appearanceObs = observe(\.effectiveAppearance) { _, _ in
            action(provider.currentTheme, self.currentAppearance)
        }

        let themeObs = provider.subscribe { theme, _ in
            action(theme, self.currentAppearance)
        }

        return CompoundObservation([appearanceObs, themeObs])
    }
}
```

### SwiftUI

SwiftUI bindings use `Combine`, `ObservableObject`, and environment propagation.

- `ThemeObserver` subscribes to a `ThemeStateProvider`.
- Browser-window hosting boundaries inject a window-scoped observer via `phiThemeObserver(_:)`.
- Themed SwiftUI modifiers resolve from `@Environment(\.phiTheme)` and `@Environment(\.phiAppearance)` so they stay aligned with the current browser window.

Example:

```swift
struct ThemedForegroundModifier: ViewModifier {
    let themedColor: ThemedColor
    @Environment(\.phiTheme) var theme
    @Environment(\.phiAppearance) var appearance

    func body(content: Content) -> some View {
        content.foregroundColor(themedColor.swiftUIColor(theme: theme, appearance: appearance))
    }
}
```

## Key Design Choices

| Decision | AppKit | SwiftUI | Why |
|---|---|---|---|
| Change observation | KVO | Combine | Native pattern in each framework |
| State storage | Associated objects | `@ObservedObject` / environment | Fits lifecycle model |
| Update trigger | Direct property set | `@Published` body recompute | Aligns with framework update model |
| Subscription lifecycle | Owned by control | Owned by observer | Automatic cleanup |
| Browser-window truth | `BrowserThemeContext` | `phiTheme` / `phiAppearance` environment | Keeps theme and appearance scoped to one window |

## Features

- Automatic light/dark adaptation.
- User choice: follow system, force light, force dark.
- Fixed-appearance windows do not follow later system or app-level appearance changes.
- Multi-theme switching.
- Browser-window theme isolation.
- Incognito windows always stay dark.
- Works in both AppKit and SwiftUI.
- Persistent user preference.
- Concise `<>` mapper operator.
- Dynamic image tinting based on theme/appearance.

## Quick Start

### AppKit

```swift
import AppKit

// Mapper syntax
label.phi.textColor = .red <> .yellow
label.phi.textColor = 0x333333 <> 0xFFFFFF

// Recommended: set APIs with ThemedColor
label.phi.setTextColor(.textPrimary)
label.phi.setBackgroundColor(.windowBackground)

// set APIs also accept Mapper
label.phi.setTextColor(.red <> .white)
label.phi.setBackgroundColor(0xF5F5F5 <> 0x1C1C1E)

// Layer styling
view.wantsLayer = true
view.phiLayer?.setBackgroundColor(.windowBackground)
view.phiLayer?.setBorderColor(.border)

// Button
button.phi.title = "Light Mode" <> "Dark Mode"
button.phi.setContentTintColor(.themeColor)
```

### SwiftUI

```swift
import SwiftUI

Text("Hello")
    .themedForeground(.textPrimary)

Rectangle()
    .themedFill(.cardBackground)

RoundedRectangle(cornerRadius: 8)
    .themedStroke(.border, lineWidth: 1)

VStack { ... }
    .themedShadow(.primary, radius: 10, y: 5)
```

## User Appearance Preference

### Current Model

- For main browser windows, theme and appearance should be understood primarily as `BrowserState.themeContext` state.
- Normal windows currently still initialize from `ThemeManager.shared` shared defaults.
- Incognito windows force `.dark` and do not follow system appearance, app-level appearance, or shared appearance changes.
- Any browser window with `userAppearanceChoice != .system` is a fixed-appearance window.
- UI that has not yet joined a browser-window theme context may still use `ThemeManager.shared` as a compatibility fallback.

### Update Shared Defaults

```swift
// Follow system
ThemeManager.shared.setUserAppearanceChoice(.system)

// Force light
ThemeManager.shared.setUserAppearanceChoice(.light)

// Force dark
ThemeManager.shared.setUserAppearanceChoice(.dark)

let choice = ThemeManager.shared.userAppearanceChoice
```

### Read or Update a Specific Browser Window

If you already have the relevant `BrowserState`, prefer the window-scoped context:

```swift
let choice = browserState.themeContext.userAppearanceChoice
let appearance = browserState.themeContext.currentAppearance

browserState.themeContext.setTheme(Theme.ocean)
browserState.themeContext.setUserAppearanceChoice(.dark)
```

### SwiftUI Settings Example

```swift
struct AppearanceSettingsView: View {
    @State private var selectedChoice: UserAppearanceChoice = ThemeManager.shared.userAppearanceChoice

    var body: some View {
        Picker("Appearance", selection: $selectedChoice) {
            ForEach(UserAppearanceChoice.allCases, id: \.self) { choice in
                Text(choice.localizedName).tag(choice)
            }
        }
        .onChange(of: selectedChoice) { newValue in
            ThemeManager.shared.setUserAppearanceChoice(newValue)
        }
    }
}
```

### AppKit Settings Example

```swift
popupButton.removeAllItems()
for choice in UserAppearanceChoice.allCases {
    popupButton.addItem(withTitle: choice.localizedName)
}
popupButton.selectItem(at: ThemeManager.shared.userAppearanceChoice.rawValue)

@objc func appearanceChanged(_ sender: NSPopUpButton) {
    if let choice = UserAppearanceChoice(rawValue: sender.indexOfSelectedItem) {
        ThemeManager.shared.setUserAppearanceChoice(choice)
    }
}
```

## Theme Management

### Create and Switch Shared Theme

```swift
let myTheme = Theme(id: "ocean", name: "Ocean")
myTheme.setColor(light: .blue, dark: .cyan, for: .primary)
myTheme.setColor(light: .teal, dark: .mint, for: .secondary)
myTheme.setColor(light: .black, dark: .white, for: .textPrimary)

ThemeManager.shared.registerTheme(myTheme)
ThemeManager.shared.switchTheme(to: "ocean")
```

### Apply Theme to a Specific Browser Window

```swift
browserState.themeContext.setTheme(Theme.ocean)
browserState.themeContext.setUserAppearanceChoice(.dark)
```

### Built-in Themes

```swift
Theme.default
Theme.ocean
Theme.forest
Theme.sunset
Theme.violet
```

## Predefined Color Roles

```swift
ThemedColor.primary
ThemedColor.secondary
ThemedColor.accent

ThemedColor.textPrimary
ThemedColor.textSecondary
ThemedColor.textTertiary
ThemedColor.textInverse

ThemedColor.background
ThemedColor.backgroundSecondary
ThemedColor.cardBackground
ThemedColor.popoverBackground

ThemedColor.border
ThemedColor.separator

ThemedColor.success
ThemedColor.warning
ThemedColor.error
ThemedColor.info

ThemedColor.hover
ThemedColor.pressed
ThemedColor.disabled
```

## Dynamic Image Tinting

### NSImage Extensions

```swift
imageView.phi.image = icon.themed(tint: .primary)
imageView.phi.image = icon.themed(tint: .red <> .blue)
imageView.phi.image = lightIcon.themed(dark: darkIcon)
```

### `ThemedImage`

```swift
let themedIcon = ThemedImage(icon, tint: .primary)
imageView.phi.image = themedIcon.mapper

let coloredIcon = ThemedImage(icon, tint: .red <> .blue)
button.phi.image = coloredIcon.mapper

let switchIcon = ThemedImage(light: sunIcon, dark: moonIcon)
imageView.phi.image = switchIcon.mapper
```

### SwiftUI

```swift
Image(systemName: "star.fill")
    .themedTint(.primary)

ThemedImageView(icon, tint: .accent)
    .frame(width: 32, height: 32)

ThemedImageView(light: sunImage, dark: moonImage)
```

### Direct NSImage Tint

```swift
let tintedImage = originalImage.tinted(with: .red)
```

## API Style Recommendation

Two equivalent styles are available:

```swift
// Property assignment with Mapper
label.phi.textColor = .red <> .white
view.phiLayer?.backgroundColor = 0xF5F5F5 <> 0x2C2C2E

// set APIs with ThemedColor or Mapper
label.phi.setTextColor(.textPrimary)
label.phi.setTextColor(.red <> .white)
view.phiLayer?.setBackgroundColor(.windowBackground)
```

Prefer `set` APIs with `ThemedColor` for clearer semantics and easier global color management.

## Advanced Usage

### Observe Theme and Appearance Changes

Observe one browser window:

```swift
browserState.themeContext.themeAppearancePublisher
    .sink { theme, appearance in
        print("Theme: \(theme.name), Appearance: \(appearance)")
    }
    .store(in: &cancellables)
```

Observe shared fallback notifications:

```swift
NotificationCenter.default.addObserver(
    forName: .themeDidChange,
    object: nil,
    queue: .main
) { _ in
    // Handle change
}
```

Use `phiSubscribe` for the shared fallback source:

```swift
view.phiSubscribe { theme, appearance in
    // Handle change
}
```

Use a window-scoped `Phi` source when the view already belongs to a browser window:

```swift
view.phi(source: view.themeStateProvider).subscribe { theme, appearance in
    // Handle the browser-window-scoped change
}
```

### Dynamic NSColor

```swift
let dynamicColor = ThemedColor.primary.dynamicColor()
view.layer?.backgroundColor = dynamicColor.cgColor
```

### Custom `ThemedColor`

```swift
let customColor = ThemedColor(light: .red, dark: .orange)

let hexColor = ThemedColor(lightHex: 0x333333, darkHex: 0xEEEEEE)

let fullCustom = ThemedColor { theme, appearance in
    if theme.id == "ocean" {
        return appearance.isDark ? .cyan : .blue
    } else {
        return appearance.isDark ? .white : .black
    }
}
```

## File Layout

```text
Sources/Utilities/Theme/
├── Appearance.swift
├── Bags.swift
├── BrowserThemeContext.swift
├── ColorRole.swift
├── Key.swift
├── Mapper.swift
├── Phi.swift
├── Phi+AppKit.swift
├── Phi+SwiftUI.swift
├── Theme.swift
├── ThemedColor.swift
├── ThemedColors.swift
├── ThemedImage.swift
├── ThemeExample.swift
├── ThemeManager.swift
└── README.md
```

## Localization Keys

Add the following keys in `Localizable.xcstrings`:

```text
"System" = "Follow System";
"Light" = "Light";
"Dark" = "Dark";
```

## API Reference

### `BrowserThemeContext`

| Property / Method | Description |
|---|---|
| `currentTheme` | Current theme for this browser window |
| `currentAppearance` | Effective appearance for this browser window |
| `userAppearanceChoice` | Window-scoped appearance choice |
| `setTheme(_:)` | Update the current window theme |
| `setUserAppearanceChoice(_:)` | Update the current window appearance choice |
| `themeAppearancePublisher` | Observe theme/appearance changes for this window |

### `ThemeManager`

| Property / Method | Description |
|---|---|
| `shared` | Shared registry / fallback instance |
| `currentTheme` | Shared default theme |
| `currentAppearance` | Shared default appearance |
| `userAppearanceChoice` | Shared default appearance mode |
| `setUserAppearanceChoice(_:)` | Set the shared default appearance mode |
| `registerTheme(_:)` | Register a theme |
| `switchTheme(to:)` | Switch the shared default theme |

### `UserAppearanceChoice`

| Value | Description |
|---|---|
| `.system` | Follow system |
| `.light` | Force light mode |
| `.dark` | Force dark mode |

### `Phi` Extensions

#### `NSTextField`

| Method / Property | Description |
|---|---|
| `setTextColor(_:)` | Set text color (`ThemedColor` or `Mapper`) |
| `setBackgroundColor(_:)` | Set background color (`ThemedColor` or `Mapper`) |
| `textColor` | Text color mapper property |
| `backgroundColor` | Background color mapper property |

#### `NSButton`

| Method / Property | Description |
|---|---|
| `setContentTintColor(_:)` | Set content tint (`ThemedColor` or `Mapper`) |
| `title` | Button title |
| `attributedTitle` | Attributed title |
| `contentTintColor` | Content tint mapper property |

#### `NSImageView`

| Method / Property | Description |
|---|---|
| `setContentTintColor(_:)` | Set content tint (`ThemedColor` or `Mapper`) |
| `image` | Image |
| `contentTintColor` | Content tint mapper property |

#### `NSView`

| Property | Description |
|---|---|
| `isHidden` | Visibility |
| `alphaValue` | Opacity |

#### `CALayer` (via `phiLayer`)

| Method / Property | Description |
|---|---|
| `setBackgroundColor(_:)` | Set background color (`ThemedColor` or `Mapper`) |
| `setBorderColor(_:)` | Set border color (`ThemedColor` or `Mapper`) |
| `setShadowColor(_:)` | Set shadow color (`ThemedColor` or `Mapper`) |
| `backgroundColor` | Background mapper property |
| `borderColor` | Border mapper property |
| `shadowColor` | Shadow mapper property |

### `ThemedImage`

| Method / Property | Description |
|---|---|
| `init(_ image:, tint: ThemedColor)` | Theme color tint |
| `init(_ image:, tint: Mapper<NSColor>)` | Mapper tint |
| `init(light:, dark:)` | Appearance-based image switch |
| `.mapper` | Convert to `Mapper<NSImage?>` |
| `.resolved()` | Resolve with current theme/appearance |

### `NSImage` Extensions

| Method | Description |
|---|---|
| `tinted(with: NSColor)` | Tint image with fixed color |
| `themed(tint: ThemedColor)` | Create theme-tinted image mapper |
| `themed(tint: Mapper<NSColor>)` | Create mapper-tinted image |
| `themed(dark: NSImage?)` | Create light/dark image switch |

### SwiftUI `Image` Extension

| Method | Description |
|---|---|
| `themedTint(_ color: ThemedColor)` | Apply theme tint |
