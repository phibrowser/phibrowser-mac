# Phi Theme System

A theme framework for macOS that supports runtime theme switching and system light/dark appearance, with APIs for both AppKit and SwiftUI.

## Design Summary

A macOS app needs to respond to two dimensions:

1. Appearance: system light/dark mode.
2. Theme: app-defined color palettes.

Instead of manually observing and updating colors in each view, Phi uses declarative bindings.

```swift
// Imperative approach
label.textColor = isDark ? .white : .black

// Phi approach
label.phi.setTextColor(.black <> .white)
```

## Core Concepts

1. `ThemeManager`: global singleton for current theme, current appearance, and user preference.
2. `Mapper<V>`: value mapper resolved from `(theme, appearance)`.
3. `ThemedColor`: color abstraction with theme/appearance-aware resolution.
4. `Phi<Base>`: binder that applies mappers to AppKit properties.
5. `ThemeObserver`: `ObservableObject` used by SwiftUI to trigger refreshes.

## Implementation

### AppKit

AppKit bindings are driven by KVO and associated objects.

- `Phi` stores subscriptions on the target control.
- Subscriptions update values when theme or appearance changes.
- `NSView` observes `effectiveAppearance` and `ThemeManager.currentTheme`.

### SwiftUI

SwiftUI bindings use `Combine` and `@ObservedObject`.

- `ThemeObserver` subscribes to `ThemeManager` publishers.
- `@Published` updates trigger view re-render.
- View modifiers such as `themedForeground` resolve colors at render time.

## Key Design Choices

| Decision | AppKit | SwiftUI | Why |
|---|---|---|---|
| Change observation | KVO | Combine | Native pattern in each framework |
| State storage | Associated objects | `@ObservedObject` | Fits lifecycle model |
| Update trigger | Direct property set | `@Published` body recompute | Aligns with framework update model |
| Subscription lifecycle | Owned by control | Owned by observer | Automatic cleanup |

## Features

- Automatic light/dark adaptation.
- User choice: follow system, force light, force dark.
- Multi-theme switching.
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
label.phi.setTextColor(ThemedColors.textPrimary)
label.phi.setBackgroundColor(ThemedColors.background)

// set APIs also accept Mapper
label.phi.setTextColor(.red <> .white)
label.phi.setBackgroundColor(0xF5F5F5 <> 0x1C1C1E)

// Layer styling
view.wantsLayer = true
view.phiLayer?.setBackgroundColor(ThemedColors.cardBackground)
view.phiLayer?.setBorderColor(ThemedColors.border)

// Button
button.phi.title = "Light Mode" <> "Dark Mode"
button.phi.setContentTintColor(ThemedColors.primary)
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

```swift
// Follow system
ThemeManager.shared.setUserAppearanceChoice(.system)

// Force light
ThemeManager.shared.setUserAppearanceChoice(.light)

// Force dark
ThemeManager.shared.setUserAppearanceChoice(.dark)

let choice = ThemeManager.shared.userAppearanceChoice
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

### Create and Switch Theme

```swift
let myTheme = Theme(id: "ocean", name: "Ocean")
myTheme.setColor(light: .blue, dark: .cyan, for: .primary)
myTheme.setColor(light: .teal, dark: .mint, for: .secondary)
myTheme.setColor(light: .black, dark: .white, for: .textPrimary)

ThemeManager.shared.registerTheme(myTheme)
ThemeManager.shared.switchTheme(to: "ocean")
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
label.phi.setTextColor(ThemedColors.textPrimary)
label.phi.setTextColor(.red <> .white)
view.phiLayer?.setBackgroundColor(ThemedColors.cardBackground)
```

Prefer `set` APIs with `ThemedColor` for clearer semantics and easier global color management.

## Advanced Usage

### Observe Theme/Appearance Changes

```swift
ThemeManager.shared.themeAppearancePublisher
    .sink { theme, appearance in
        print("Theme: \(theme.name), Appearance: \(appearance)")
    }
    .store(in: &cancellables)
```

```swift
NotificationCenter.default.addObserver(
    forName: .themeDidChange,
    object: nil,
    queue: .main
) { _ in
    // Handle change
}
```

```swift
view.phiSubscribe { theme, appearance in
    // Handle change
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

### `ThemeManager`

| Property / Method | Description |
|---|---|
| `shared` | Singleton instance |
| `currentTheme` | Current theme |
| `currentAppearance` | Current appearance |
| `userAppearanceChoice` | User-selected appearance mode |
| `setUserAppearanceChoice(_:)` | Set appearance mode |
| `registerTheme(_:)` | Register a theme |
| `switchTheme(to:)` | Switch theme |

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
