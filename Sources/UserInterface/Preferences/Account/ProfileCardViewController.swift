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
    
    // MARK: - Vertical Label Layout
    /// Visual inset from the left edge for the rotated labels.
    private let verticalLabelLeftInset: CGFloat = 17
    /// Visual top offset for `colorLabel`.
    private let colorLabelTopOffset: CGFloat = 60
    /// Visual spacing between the two rotated labels.
    private let verticalLabelSpacing: CGFloat = 6
    /// Horizontal text padding inside each label container.
    private let labelHorizontalPadding: CGFloat = 8
    /// Vertical text padding inside each label container.
    private let labelVerticalPadding: CGFloat = 0
    
    private let phiLabel: NSTextField = {
        let label = NSTextField(labelWithString: NSLocalizedString("Phi", comment: "Profile card - App name displayed on user profile card"))
        label.font = NSFont(name: "IvyPrestoHeadline-SemiBold", size: 16)
        label.textColor = .white
        label.alignment = .center
        return label
    }()
    
    private let dateLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        let font = NSFont(name: "IvyEpic", size: 12) ?? .systemFont(ofSize: 12)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }()
    
    private lazy var dateView: NSView = {
        let view = NSView()
        view.addSubview(dateLabel)
        dateLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        return view
    }()
    
    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont(name: "IvyPrestoHeadline-SemiBold", size: 16)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()
    
    private lazy var colorSlider: CustomSlider = {
        let slider = CustomSlider(frame: NSRect(origin: .zero, size: NSSize(width: 110, height: 20)))
        slider.trackImage = sliderBg
        slider.barSize = NSSize(width: 13, height: 13)
        slider.knobSize = NSSize(width: 20, height: 20)
        slider.minValue = 0
        slider.maxValue = 359
        slider.doubleValue = 180
        slider.target = self
        slider.action = #selector(sliderValueChanged(_:))
        return slider
    }()
    
    private var coloredBgView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.alphaValue = 0.1
        return view
    }()
    
    private let sliderBg: NSImage = {
        return .sliderBg
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
    
    private let colorLabel: NSTextField = {
        let label = NSTextField(labelWithString: "#2D6F7D")
        label.font = NSFont(name: "IvyEpic", size: 12) ?? .systemFont(ofSize: 12)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }()
    
    private lazy var colorView: NSView = {
        let view = NSView()
        view.addSubview(colorLabel)
        colorLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        return view
    }()
    
    private let backgroundImageView: NSImageView = {
        let bg = NSImageView()
        return bg
    }()
      
    var userName: String? {
        didSet {
            nameLabel.stringValue = truncateName(userName ?? "")
        }
    }

    var profile: Profile? {
        didSet {
            nameLabel.stringValue = truncateName(profile?.name ?? "")
            dateLabel.stringValue = formatToLocalDate(profile?.created_at ?? "")
            layoutVerticalLabels()
        }
    }

    /// Truncate name to max display length with ellipsis
    private func truncateName(_ name: String) -> String {
        if name.count > Self.maxNameDisplayLength {
            let index = name.index(name.startIndex, offsetBy: Self.maxNameDisplayLength)
            return String(name[..<index]) + "..."
        }
        return name
    }
    
    // MARK: - Vertical Label Layout
    
    /// Returns the rendered text size for a label.
    private func textSize(for label: NSTextField) -> CGSize {
        let text = label.stringValue
        let font = label.font ?? NSFont.systemFont(ofSize: 12)
        return (text as NSString).size(withAttributes: [.font: font])
    }
    
    /// Positions a view rotated 90 degrees counterclockwise.
    /// 
    /// Visual coordinate mapping after rotation in AppKit coordinates:
    /// - visual width = original height
    /// - visual height = original width
    /// - visual left edge = centerX - originalHeight / 2
    /// - visual top edge = centerY + originalWidth / 2
    ///
    /// - Parameters:
    ///   - targetView: View to position.
    ///   - visualLeft: Visual left edge after rotation.
    ///   - visualTop: Visual top edge after rotation.
    ///   - originalWidth: Width before rotation.
    ///   - originalHeight: Height before rotation.
    private func positionRotatedView(_ targetView: NSView,
                                     visualLeft: CGFloat,
                                     visualTop: CGFloat,
                                     originalWidth: CGFloat,
                                     originalHeight: CGFloat) {
        // Convert visual edges back into the layer center point.
        let centerX = visualLeft + originalHeight / 2
        let centerY = visualTop - originalWidth / 2
        
        // The frame stays in the pre-rotation size space.
        targetView.frame = NSRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
        
        // Position through the layer so the rotation stays centered.
        targetView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        targetView.layer?.position = CGPoint(x: centerX, y: centerY)
        targetView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
    }
    
    /// Recomputes the layout for both rotated labels.
    private func layoutVerticalLabels() {
        guard view.bounds.height > 0 else { return }
        
        let viewHeight = view.bounds.height
        
        // Measure the `colorLabel` container including padding.
        let colorTextSize = textSize(for: colorLabel)
        let colorWidth = colorTextSize.width + labelHorizontalPadding
        let colorHeight = colorTextSize.height + labelVerticalPadding
        
        // Measure the `dateLabel` container including padding.
        let dateTextSize = textSize(for: dateLabel)
        let dateWidth = dateTextSize.width + labelHorizontalPadding
        let dateHeight = dateTextSize.height + labelVerticalPadding
        
        // Visual top position for `colorLabel`.
        let colorVisualTop = viewHeight - colorLabelTopOffset
        
        // Visual bottom equals top minus visual height.
        let colorVisualBottom = colorVisualTop - colorWidth
        
        // Stack `dateLabel` below `colorLabel`.
        let dateVisualTop = colorVisualBottom - verticalLabelSpacing
        
        // Position both rotated label containers.
        positionRotatedView(colorView,
                           visualLeft: verticalLabelLeftInset,
                           visualTop: colorVisualTop,
                           originalWidth: colorWidth,
                           originalHeight: colorHeight)
        
        positionRotatedView(dateView,
                           visualLeft: verticalLabelLeftInset,
                           visualTop: dateVisualTop,
                           originalWidth: dateWidth,
                           originalHeight: dateHeight)
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        applyStoredThemeColor()
        
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
        UserDefaults.standard.set(accentColor?.toHexString(), forKey: PhiPreferences.accentColor.rawValue)
        tearDown()
    }
    
    deinit {
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
        view.addSubview(dateView)
        view.addSubview(colorView)
        view.addSubview(phiLabel)
        view.addSubview(nameLabel)
        view.addSubview(colorSlider)
        
        imageView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.centerX.equalToSuperview().offset(3)
            make.size.equalTo(NSSize(width: 240, height: 380))
        }
        
        coloredBgView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        dotBackgroundImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        phiLabel.snp.makeConstraints { make in
            make.leading.top.equalToSuperview().inset(16)
        }
        
        nameLabel.snp.makeConstraints { make in
            make.trailing.top.equalToSuperview().inset(16)
            make.width.lessThanOrEqualTo(150)  // Limit max width to prevent layout issues
        }
        
        colorSlider.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.size.equalTo(NSSize(width: 110, height: 20))
            make.bottom.equalToSuperview().inset(39)
        }
        
        // Enable manual frame layout for the rotated label containers.
        dateView.translatesAutoresizingMaskIntoConstraints = true
        dateView.wantsLayer = true
        
        colorView.translatesAutoresizingMaskIntoConstraints = true
        colorView.wantsLayer = true
        
        // Perform the initial rotated-label layout.
        layoutVerticalLabels()
    }
    
    private func applyStoredThemeColor() {
        if let hexStr = UserDefaults.standard.string(forKey: PhiPreferences.accentColor.rawValue),
           !hexStr.isEmpty {
            accentColor = NSColor(hexString: hexStr)
            colorSlider.floatValue = Float(accentColor?.hueComponent ?? 180) * 360
            sliderValueChanged(colorSlider)
        } else {
            sliderValueChanged(colorSlider)
        }
    }
    
    override func loadView() {
        view = NSView()
    }
    
    @objc private func sliderValueChanged(_ sender: NSSlider) {
        let hue = CGFloat(sender.doubleValue / 360.0)
        
        let accentColor = NSColor(hue: hue, saturation: 1, brightness: 0.37, alpha: 1)
        self.accentColor = accentColor

        colorLabel.stringValue = accentColor.toHexString()
        
        // Update title color
        phiLabel.textColor = accentColor
        nameLabel.textColor = accentColor
        
        colorView.layer?.backgroundColor = accentColor.cgColor
        dateView.layer?.backgroundColor = accentColor.withAlphaComponent(0.3).cgColor
        
        dotBackgroundImageView.image = dotBg.tinted(with: accentColor)
        colorSlider.trackImage = sliderBg.tinted(with: accentColor)
        
        coloredBgView.layer?.backgroundColor = NSColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 1).cgColor
        colorSlider.knobColor = accentColor
        colorSlider.knobFillColor =  NSColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 0.1)
        // Relayout because the color text may have changed width.
        layoutVerticalLabels()
        
        super.colorSliderChanged(CGFloat(colorSlider.floatValue))
    }
    
    func snapshotAndExport() {
        // Hide the slider so it does not appear in the export.
        let previousHiddenState = colorSlider.isHidden
        colorSlider.isHidden = true

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
            // Restore the slider before returning early.
            colorSlider.isHidden = previousHiddenState
            return
        }

        // Restore the slider after rendering.
        colorSlider.isHidden = previousHiddenState

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
                print("Failed to write PNG file: \(error)")
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
