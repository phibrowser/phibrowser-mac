// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Lottie
import SwiftUI

enum BookmarkFolderIcon: String, CaseIterable, Identifiable, Sendable {
    case standard = "default"
    case github
    case discord
    case x
    case reddit
    case facebook
    case emojiHappy = "emoji-happy"
    case emojiSad = "emoji-sad"
    case key
    case download
    case thumbUp = "thumb-up"
    case chartBar = "chart-bar"
    case locationMarker = "location-marker"
    case currencyDollar = "currency-dollar"
    case shieldCheck = "shield-check"
    case heart
    case bookmark
    case refresh
    case chat
    case fire
    case puzzle
    case variable
    case save
    case backspace

    struct Resources: Equatable, Sendable {
        let pickerAssetName: String
        let animationResourceName: String
        let symbolGroupName: String?
    }

    static let resourceMap: [BookmarkFolderIcon: Resources] = [
        .standard: Resources(pickerAssetName: "default", animationResourceName: "null", symbolGroupName: nil),
        .github: Resources(pickerAssetName: "github", animationResourceName: "github", symbolGroupName: "Vector"),
        .discord: Resources(pickerAssetName: "discord", animationResourceName: "discord", symbolGroupName: "Vector"),
        .x: Resources(pickerAssetName: "x", animationResourceName: "x", symbolGroupName: "Vector"),
        .reddit: Resources(pickerAssetName: "reddit", animationResourceName: "reddit", symbolGroupName: "Vector"),
        .facebook: Resources(pickerAssetName: "facebook", animationResourceName: "facebook", symbolGroupName: "Vector"),
        .emojiHappy: Resources(pickerAssetName: "emoji-happy", animationResourceName: "emoji-happy", symbolGroupName: "Icon"),
        .emojiSad: Resources(pickerAssetName: "emoji-sad", animationResourceName: "emoji-sad", symbolGroupName: "Icon"),
        .key: Resources(pickerAssetName: "key", animationResourceName: "key", symbolGroupName: "Icon"),
        .download: Resources(pickerAssetName: "download", animationResourceName: "download", symbolGroupName: "Icon"),
        .thumbUp: Resources(pickerAssetName: "thumb-up", animationResourceName: "thumb-up", symbolGroupName: "Icon"),
        .chartBar: Resources(pickerAssetName: "chart-bar", animationResourceName: "chart-bar", symbolGroupName: "Icon"),
        .locationMarker: Resources(pickerAssetName: "location-marker", animationResourceName: "location-marker", symbolGroupName: "Icon"),
        .currencyDollar: Resources(pickerAssetName: "currency-dollar", animationResourceName: "currency-dollar", symbolGroupName: "Icon"),
        .shieldCheck: Resources(pickerAssetName: "shield-check", animationResourceName: "shield-check", symbolGroupName: "Icon"),
        .heart: Resources(pickerAssetName: "heart", animationResourceName: "heart", symbolGroupName: "Icon"),
        .bookmark: Resources(pickerAssetName: "bookmark", animationResourceName: "bookmark", symbolGroupName: "Icon"),
        .refresh: Resources(pickerAssetName: "refresh", animationResourceName: "refresh", symbolGroupName: "Icon"),
        .chat: Resources(pickerAssetName: "chat", animationResourceName: "chat-alt-2", symbolGroupName: "Icon"),
        .fire: Resources(pickerAssetName: "fire", animationResourceName: "fire", symbolGroupName: "Icon"),
        .puzzle: Resources(pickerAssetName: "puzzle", animationResourceName: "puzzle", symbolGroupName: "Icon"),
        .variable: Resources(pickerAssetName: "variable", animationResourceName: "variable", symbolGroupName: "Icon"),
        .save: Resources(pickerAssetName: "save", animationResourceName: "save", symbolGroupName: "Icon"),
        .backspace: Resources(pickerAssetName: "backspace", animationResourceName: "backspace", symbolGroupName: "Icon"),
    ]

    var id: String { rawValue }

    var resources: Resources {
        Self.resourceMap[self] ?? Self.resourceMap[.standard]!
    }

    static func resolve(_ storedValue: String?) -> BookmarkFolderIcon {
        BookmarkFolderIcon(rawValue: storedValue ?? "") ?? .standard
    }

    static func animationProgress(isExpanded: Bool) -> Double {
        isExpanded ? 1 : 0
    }

    static func strokeColor(theme: Theme, appearance: Appearance) -> NSColor {
        BookmarkFolderIconPalette(theme: theme, appearance: appearance).stroke
    }
}

/// A folder row's icon: a Lottie folder that opens and closes with the
/// folder, recolored for the theme.
final class BookmarkFolderIconView: NSView {
    private var animationView: Lottie.LottieAnimationView?
    private var fallbackView: NSImageView?
    private var renderedKey: String?
    private var icon = BookmarkFolderIcon.standard
    /// Latest requested state; a stroke already playing finishes first.
    private var requestedExpanded = false
    /// End state of the stroke being played, or nil while the icon is at rest.
    private var strokeTarget: Bool?
    private var usesStaticSnapshotIcon = false
    /// The next render shows its state without a stroke, as for a row that
    /// now shows another folder.
    private var snapsToNextState = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func showNextStateWithoutAnimation() {
        snapsToNextState = true
    }

    /// - Parameter usesStaticSnapshotIcon: Holds the icon still at its
    ///   resting frame so an AppKit snapshot of the row captures it.
    func render(icon: BookmarkFolderIcon,
                isExpanded: Bool,
                usesStaticSnapshotIcon: Bool,
                theme: Theme?,
                appearance: Appearance) {
        let key = "\(icon.rawValue)-\(theme?.id ?? "")-\(appearance.description)"
        if key != renderedKey || snapsToNextState {
            renderedKey = key
            snapsToNextState = false
            self.icon = icon
            requestedExpanded = isExpanded
            rebuild(theme: theme, appearance: appearance)
        } else if isExpanded != requestedExpanded {
            requestedExpanded = isExpanded
            // A toggle that arrives mid-stroke (e.g. a double-click) lets the
            // running stroke reach its end, then plays back to the latest
            // state, so the icon opens and closes like the rows do.
            if strokeTarget == nil, !usesStaticSnapshotIcon {
                playStroke(toExpanded: isExpanded)
            }
        }
        if usesStaticSnapshotIcon != self.usesStaticSnapshotIcon {
            self.usesStaticSnapshotIcon = usesStaticSnapshotIcon
            if usesStaticSnapshotIcon {
                pauseAtRequestedState()
                animationView?.forceDisplayUpdate()
            }
        }
        fallbackView?.image = NSImage(resource: requestedExpanded ? .folderOpen : .folderClose)
    }

    private func rebuild(theme: Theme?, appearance: Appearance) {
        animationView?.removeFromSuperview()
        animationView = nil
        fallbackView?.removeFromSuperview()
        fallbackView = nil
        strokeTarget = nil

        let content: NSView
        if let animation = LottieAnimation.named(
            icon.resources.animationResourceName,
            bundle: .main,
            subdirectory: "LottieFiles/BookmarkFolderIcons"
        ) {
            let view = Lottie.LottieAnimationView(
                animation: animation,
                configuration: LottieConfiguration(renderingEngine: .mainThread)
            )
            if let theme {
                applyPalette(BookmarkFolderIconPalette(theme: theme, appearance: appearance), to: view)
            }
            animationView = view
            content = view
            pauseAtRequestedState()
        } else {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            fallbackView = view
            content = view
        }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    private func playStroke(toExpanded expanded: Bool) {
        strokeTarget = expanded
        animationView?.play(
            toProgress: BookmarkFolderIcon.animationProgress(isExpanded: expanded),
            loopMode: .playOnce
        ) { [weak self] completed in
            guard let self, completed, self.strokeTarget != nil else { return }
            if self.strokeTarget != self.requestedExpanded, !self.usesStaticSnapshotIcon {
                self.playStroke(toExpanded: self.requestedExpanded)
            } else {
                self.pauseAtRequestedState()
            }
        }
    }

    private func pauseAtRequestedState() {
        strokeTarget = nil
        animationView?.pause()
        animationView?.currentProgress = BookmarkFolderIcon.animationProgress(isExpanded: requestedExpanded)
    }

    private func applyPalette(_ palette: BookmarkFolderIconPalette, to animationView: Lottie.LottieAnimationView) {
        var colors: [(NSColor, String)] = [
            (palette.frontFill, "Folder1.Rectangle 4.Fill 1.Color"),
            (palette.stroke, "Folder1.Rectangle 4.Stroke 1.Color"),
            (palette.backFill, "Folder2.Rectangle 19.Fill 1.Color"),
            (palette.stroke, "Folder2.Rectangle 19.Stroke 1.Color"),
        ]
        if let symbolGroupName = icon.resources.symbolGroupName {
            colors.append((palette.stroke, "**.\(symbolGroupName).Fill 1.Color"))
        }
        for (color, keypath) in colors {
            animationView.setValueProvider(
                ColorValueProvider(color.lottieColor),
                keypath: AnimationKeypath(keypath: keypath)
            )
        }
    }
}

struct BookmarkFolderIconPicker: View {
    let selected: BookmarkFolderIcon
    let onSelect: (BookmarkFolderIcon) -> Void

    private static let itemSize: CGFloat = 26
    private static let iconSize: CGFloat = 20
    private static let columnSpacing: CGFloat = 16
    private static let rowSpacing: CGFloat = 4
    private static let gridWidth: CGFloat = 236
    private static let pickerWidth: CGFloat = 264

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(Self.itemSize), spacing: Self.columnSpacing),
            count: 6
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Self.rowSpacing) {
            ForEach(BookmarkFolderIcon.allCases) { icon in
                BookmarkFolderIconPickerButton(
                    icon: icon,
                    isSelected: icon == selected,
                    action: { onSelect(icon) }
                )
            }
        }
        .frame(width: Self.gridWidth)
        .padding(.vertical, 12)
        .frame(width: Self.pickerWidth)
    }
}

private struct BookmarkFolderIconPickerButton: View {
    let icon: BookmarkFolderIcon
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var changeIconLabel: String {
        NSLocalizedString(
            "sidebar.bookmarkCell.folderIcon.changeAction",
            value: "Change Folder Icon",
            comment: "Bookmark folder icon picker - Accessibility label and help text for choosing a folder icon"
        )
    }

    var body: some View {
        Button(action: action) {
            pickerImage
                .frame(width: 20, height: 20)
                .frame(width: 26, height: 26)
                .background(background)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(changeIconLabel)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(Text(changeIconLabel))
        .accessibilityValue(Text(verbatim: icon.rawValue))
        .accessibilityIdentifier("bookmarkFolderIcon.\(icon.rawValue)")
    }

    @ViewBuilder
    private var pickerImage: some View {
        Image(icon.resources.pickerAssetName, bundle: .main)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                isSelected
                    ? Color.sidebarTabSelected
                    : (isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .shadow(
                color: .black.opacity(isSelected ? 0.15 : 0),
                radius: 1,
                x: 0,
                y: 1
            )
    }
}

private struct BookmarkFolderIconPalette {
    let backFill: NSColor
    let frontFill: NSColor
    let stroke: NSColor

    init(theme: Theme, appearance: Appearance) {
        let accent = theme.color(for: .themeColor, appearance: appearance)
        let hsb = accent.toHSBComponents()

        if appearance.isDark {
            backFill = theme.color(for: .windowBackground, appearance: appearance)
            frontFill = Self.makeColor(
                hue: hsb.h,
                saturation: hsb.s + 0.07,
                brightness: hsb.b - 0.24
            )
            stroke = .white
        } else {
            backFill = Self.makeColor(
                hue: hsb.h,
                saturation: 0.65,
                brightness: hsb.b - 0.15
            )
            frontFill = Self.makeColor(hue: hsb.h, saturation: 0.20, brightness: 1.00)
            stroke = Self.makeColor(hue: hsb.h, saturation: 0.65, brightness: 0.30)
        }
    }

    private static func makeColor(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> NSColor {
        NSColor(
            calibratedHue: hue,
            saturation: min(max(saturation, 0), 1),
            brightness: min(max(brightness, 0), 1),
            alpha: 1
        )
    }
}
