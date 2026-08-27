// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class ProfileCardViewController: ConchFrameAnimationBaseViewController {
    private var accentColor: NSColor?
    override var imageNamagePrefix: String { "setting_" }
    override var preAnimationImagePrefix: String { "setting-pre-" }

    private static let maxNameDisplayLength = 20
    
    private let dateLabel: WhiteAlphaGradientLabel = {
        let label = WhiteAlphaGradientLabel(labelWithString: "")
        label.font = NSFont(name: "Impact", size: 76)
        label.alignment = .center
        return label
    }()

    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont(name: "IvyPrestoHeadline-SemiBold", size: 16)
        // Face is re-resolved per name in `nameLabel.stringValue` assignment.
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()
    
    private var coloredBgView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.alphaValue = 0.1
        return view
    }()
    
    private let dotBg: NSImage = {
        return .settingDotBg
    }()
    
    private lazy var dotBackgroundImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = dotBg
        imageView.imageScaling = .scaleAxesIndependently
        imageView.alphaValue = 0.15
        return imageView
    }()
    
    private let backgroundImageView: NSImageView = {
        let bg = NSImageView()
        return bg
    }()
      
    var userName: String? {
        didSet {
            setName(truncateName(userName ?? ""))
        }
    }

    var profile: Profile? {
        didSet {
            setName(truncateName(profile?.name ?? ""))
            dateLabel.stringValue = formatToLocalDate(profile?.created_at ?? "")
            adjustDateLabelFontSize()
        }
    }

    /// Truncate name to max display length with ellipsis
    /// Account names are user-supplied and the brand headline face is
    /// Latin-only — see `NSFont.brandDisplay`.
    private func setName(_ name: String) {
        nameLabel.stringValue = name
        nameLabel.font = .brandDisplay("IvyPrestoHeadline-SemiBold", size: 16, renders: name)
    }

    private func truncateName(_ name: String) -> String {
        if name.count > Self.maxNameDisplayLength {
            let index = name.index(name.startIndex, offsetBy: Self.maxNameDisplayLength)
            return String(name[..<index]) + "..."
        }
        return name
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        applyCurrentTheme()
        
        // Backfill from the cached profile if the network copy is not ready yet.
        if profile == nil {
            loadCachedProfile()
        }
    }
    
    /// Loads the cached profile from user defaults.
    private func loadCachedProfile() {
        guard let userDefaults = AccountController.shared.account?.userDefaults else {
            return
        }
        if let cachedProfile: Profile = userDefaults.codableValue(forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue) {
            profile = cachedProfile
            AppLogInfo("📦 [ProfileCard] Loaded cached profile: \(cachedProfile.name)")
        }
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        tearDown()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        AppLogDebug("\(self) - deinit")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.layer?.cornerRadius = 8
        view.clipsToBounds = true
        
        view.addSubview(imageView)
        view.addSubview(coloredBgView)
        view.addSubview(dotBackgroundImageView)
        view.addSubview(nameLabel)
        view.addSubview(dateLabel)
        
        imageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(NSSize(width: 240, height: 380))
        }
        
        coloredBgView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        dotBackgroundImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        nameLabel.snp.makeConstraints { make in
            make.bottom.equalToSuperview().inset(32)
            make.centerX.equalToSuperview()
            make.leading.trailing.lessThanOrEqualToSuperview().inset(24)
        }
        
        dateLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(-12)
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeOrAppearanceChanged),
            name: .themeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeOrAppearanceChanged),
            name: .appearanceDidChange,
            object: nil
        )
        
        applyCurrentTheme()
    }
    
    override func loadView() {
        view = NSView()
    }
    
    @objc private func themeOrAppearanceChanged() {
        applyCurrentTheme()
    }
    
    private func adjustDateLabelFontSize() {
        let maxWidth = view.bounds.width
        var fontSize: CGFloat = 70
        
        dateLabel.font = NSFont(name: "Impact", size: fontSize)
        var textWidth = dateLabel.intrinsicContentSize.width
        
        while textWidth > maxWidth && fontSize > 20 {
            fontSize -= 1
            dateLabel.font = NSFont(name: "Impact", size: fontSize)
            textWidth = dateLabel.intrinsicContentSize.width
        }
    }
    
    private func applyCurrentTheme() {
        let theme = ThemeManager.shared.currentTheme
        let appearance = ThemeManager.shared.currentAppearance
        applyTheme(theme, appearance: appearance)
    }
    
    private func applyTheme(_ theme: Theme, appearance: Appearance) {
        let overlayColor = theme.color(for: .windowOverlayBackground, appearance: appearance).withAlphaComponent(1)
        let resolvedOverlayColor = overlayColor.usingColorSpace(.deviceRGB)
        let hue = resolvedOverlayColor?.hueComponent ?? 0
        let overridedSaturation: CGFloat? = theme == .pure ? 0 : nil
        let overridedBrightness: CGFloat? = theme == .pure ? 0.5 : nil
        let accentColor = theme == .pure ?
        NSColor.black :
        NSColor(hue: hue,
                saturation: 1,
                brightness: 0.37,
                alpha: 1)
        
        self.accentColor = accentColor
        nameLabel.textColor = accentColor
        
        dotBackgroundImageView.image = dotBg.tinted(with: accentColor.withAlphaComponent(0.5))
        
        coloredBgView.layer?.backgroundColor = NSColor(hue: hue,
                                                       saturation: overridedSaturation ?? 0.85,
                                                       brightness: overridedBrightness ?? 0.75,
                                                       alpha: 1).cgColor
        
        super.themChanged(
            h: hue,
            s: overridedSaturation,
            b: overridedBrightness
        )
    }
    
    func snapshotAndExport() {
        let targetView = self.view
        let bounds = targetView.bounds

        // Render through the layer to preserve rounded corners and transparency.
        let viewImage = NSImage(size: bounds.size)
        viewImage.lockFocus()
        // Start from a transparent canvas to avoid a gray matte.
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            targetView.layer?.render(in: context)
        } else {
            targetView.draw(bounds)
        }
        viewImage.unlockFocus()

        // Draw the card into a larger background canvas.
        let bgSize = NSSize(width: bounds.width * 2.0, height: bounds.height * 2.0)
        let composedImage = NSImage(size: bgSize)
        composedImage.lockFocus()

        // Use the chosen accent color as the export background.
        let bgColor = accentColor ?? NSColor.black
        bgColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bgSize)).fill()

        // Center the snapshot inside the larger background.
        let drawOrigin = NSPoint(
            x: (bgSize.width - bounds.width) / 2.0,
            y: (bgSize.height - bounds.height) / 2.0
        )
        let drawRect = NSRect(origin: drawOrigin, size: bounds.size)

        // Composite the transparent card image onto the colored background.
        viewImage.draw(in: drawRect, from: NSRect(origin: .zero, size: bounds.size), operation: .sourceOver, fraction: 1.0)

        composedImage.unlockFocus()

        // Encode the composed image as PNG.
        guard
            let tiffData = composedImage.tiffRepresentation,
            let finalRep = NSBitmapImageRep(data: tiffData),
            let pngData = finalRep.representation(using: .png, properties: [:])
        else {
            return
        }

        // Write the PNG to the user-selected destination.
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "\(userName ?? "Phi").png"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else {
                return
            }
            do {
                try pngData.write(to: url)
            } catch {
                AppLogError("Failed to write PNG file: \(error)")
            }
        }
    }
    
    func formatToLocalDate(_ isoString: String) -> String {
        // Example input: 2025-11-05T11:32:18Z
        // Example output: 2025.1.1 in the current system time zone.

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        guard let date = formatter.date(from: isoString) else {
            return ""
        }

        let outputFormatter = DateFormatter()
        outputFormatter.timeZone = .current   // Use the local time zone.
        outputFormatter.dateFormat = "yyyy.M.d"

        return outputFormatter.string(from: date)
    }
}

private final class WhiteAlphaGradientLabel: NSTextField {
    private let startColor = NSColor.white.withAlphaComponent(0)
    private let endColor = NSColor.white.withAlphaComponent(1)
    private let endLocation: CGFloat = 0.4
    
    override var stringValue: String {
        didSet {
            updateGradientColor()
        }
    }
    
    override var font: NSFont? {
        didSet {
            updateGradientColor()
        }
    }
    
    override func layout() {
        super.layout()
        updateGradientColor()
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGradientColor()
    }
    
    private func updateGradientColor() {
        guard bounds.width > 0, bounds.height > 0 else {
            textColor = startColor
            return
        }
        
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSGradient(colors: [startColor, endColor],
                   atLocations: [0, endLocation],
                   colorSpace: .deviceRGB)?
            .draw(in: NSRect(origin: .zero, size: bounds.size), angle: 90)
        image.unlockFocus()
        
        textColor = NSColor(patternImage: image)
    }
}
