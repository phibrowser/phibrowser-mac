// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI

class OnboardingWelcomeViewController: ConchFrameAnimationBaseViewController {
    override var imageNamagePrefix: String { "oobe-" }
    override var preAnimationImagePrefix: String { "oobe-pre-" }
    
    private let dateLabel: NSTextField = {
        let label = NSTextField(labelWithString: "2025.1.1")
        label.font = NSFont(name: "Impact", size: 200)
        label.textColor = .white
        label.alignment = .center
        return label
    }()
    
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: NSLocalizedString("Welcome", comment: "Onboarding welcome page - Main title greeting the user"))
        label.font = NSFont(name: "IvyPrestoDisplay-SemiBoldItalic", size: 46)
        label.textColor = NSColor(red: 0.18, green: 0.42, blue: 0.49, alpha: 1.0) // #2D6F7D
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()
    
    private lazy var colorSlider: CustomSlider = {
        let slider = CustomSlider(frame: NSRect(origin: .zero, size: NSSize(width: 128, height: 20)))
        slider.trackImage = sliderBg
        slider.knobSize = NSSize(width: 20, height: 20)
        slider.barSize = NSSize(width: 13, height: 13)
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
        return .dotBg
    }()
    
    private lazy var dotBackgroundImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = dotBg
        imageView.alphaValue = 0.15
        return imageView
    }()
    
    private let colorLabel: NSTextField = {
        let label = NSTextField(labelWithString: "#2D6F7D")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.drawsBackground = false
        return label
    }()
    
    private lazy var colorView: NSView = {
        let view = NSView()
        view.addSubview(colorLabel)
        colorLabel.snp.makeConstraints { make in
            make.centerY.centerX.equalToSuperview()
        }
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        return view
    }()
    
    private lazy var nextButton: GradientBorderButton = {
        let button = GradientBorderButton()
        button.title = NSLocalizedString("Next", comment: "Onboarding welcome page - Next button to proceed to next step")
        button.clickAction = { [weak self] in
            self?.nextButtonTapped()
        }
        button.cornerRadius = 999
        return button
    }()
    
    private let backgroundImageView: NSImageView = {
        let bg = NSImageView()
        return bg
    }()
    
    private let backgroundImage: NSImage = {
        return .welcomeBg
    }()
    
    var nextClosure: ((Bool) -> Void)?
    private var accentColor: NSColor?
    var userName: String? {
        didSet {
            titleLabel.stringValue = String(format: NSLocalizedString("Welcome %@", comment: "Onboarding welcome page - Personalized welcome title with user name"), userName ?? "")
        }
    }
    
    // MARK: - Lifecycle
    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.white.cgColor
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        sliderValueChanged(colorSlider)
    }
    
    override func viewDidDisappear() {
        super.viewDidDisappear()
    }
    
    private func requesetProfile() async {
        let response = try? await APIClient.shared.getAccountProfile()
        if let profile = response?.data {
            await MainActor.run {
                let dateString = formatToLocalDate(profile.created_at)
                if !dateString.isEmpty {
                    dateLabel.stringValue = formatToLocalDate(profile.created_at)
                    adjustDateLabelFontSize()
                }
            }
        }
    }
    
    private func formatToLocalDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        guard let date = formatter.date(from: isoString) else {
            return ""
        }

        let outputFormatter = DateFormatter()
        outputFormatter.timeZone = .current
        outputFormatter.dateFormat = "yyyy.M.d"

        return outputFormatter.string(from: date)
    }
    
    // MARK: - Setup
    private func setupUI() {
        view.addSubview(imageView)
        view.addSubview(coloredBgView)
        view.addSubview(dotBackgroundImageView)
        view.addSubview(titleLabel)
        view.addSubview(colorSlider)
        view.addSubview(colorView)
        view.addSubview(nextButton)
        
        view.snp.makeConstraints { make in
            make.width.equalTo(640)
            make.height.equalTo(800)
        }
        view.layoutSubtreeIfNeeded()
        
        coloredBgView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        dotBackgroundImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        backgroundImageView.image = backgroundImage
        
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(45)
            make.centerX.equalToSuperview()
            make.leading.trailing.lessThanOrEqualToSuperview().inset(30)
        }
        
        colorSlider.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(22)
            make.centerX.equalToSuperview()
            make.width.equalTo(128)
            make.height.equalTo(20)
        }
        
        colorView.snp.makeConstraints { make in
            make.top.equalTo(colorSlider.snp.bottom).offset(5)
            make.centerX.equalToSuperview()
            make.width.equalTo(128)
            make.height.equalTo(15)
        }
        
        nextButton.snp.makeConstraints { make in
            make.bottom.equalToSuperview().offset(-96)
            make.centerX.equalToSuperview()
            make.width.equalTo(120)
            make.height.equalTo(40)
        }
    }
    
    // MARK: - Actions
    @objc private func sliderValueChanged(_ sender: NSSlider) {
        let hue = CGFloat(sender.doubleValue / 360.0)
        let color = NSColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 0.75)
        
        let accentColor = NSColor(hue: hue, saturation: 1, brightness: 0.37, alpha: 1)
        self.accentColor = accentColor

        colorLabel.stringValue = colorToHex(accentColor)
        
        titleLabel.textColor = accentColor

        colorView.layer?.backgroundColor = accentColor.cgColor
        
        nextButton.titleColor = Color(nsColor: accentColor)
        nextButton.borderColors = [Color(nsColor: accentColor)]
        nextButton.backgroundColor = Color(nsColor: NSColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 0.1))
        
        dotBackgroundImageView.image = dotBg.tinted(with: accentColor)
        colorSlider.trackImage = sliderBg.tinted(with: accentColor)
        
        coloredBgView.layer?.backgroundColor = NSColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 1).cgColor
        colorSlider.knobColor = accentColor
        colorSlider.knobFillColor =  NSColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 0.1)
        colorSliderChanged(CGFloat(sender.floatValue))
    }
    
    private func drawConch(with color: NSColor) {
        let color0 = NSColor.white
        let color57 = color
        let colors = [color0, color57]
        let positions: [CGFloat] = [0.0, 0.1]
        guard let gradient = GradientMapper.makeGradient(colors: colors,
                                                         positions: positions) else {
            return
        }
        guard let strip = GradientMapper.makeStrip(from: gradient) else {
    
            return
        }
        
        guard let mapped = GradientMapper.apply(to: backgroundImage, using: strip) else {
            return
        }
        backgroundImageView.image = mapped
    }
    
    private func nextButtonTapped() {
        UserDefaults.standard.set(colorLabel.stringValue, forKey: PhiPreferences.accentColor.rawValue)
        nextClosure?(true)
    }
    
    // MARK: - Helpers
    private func adjustDateLabelFontSize() {
        let maxWidth = view.bounds.width
        var fontSize: CGFloat = 200
        
        dateLabel.font = NSFont(name: "Impact", size: fontSize)
        var textWidth = dateLabel.intrinsicContentSize.width
        
        while textWidth > maxWidth && fontSize > 20 {
            fontSize -= 1
            dateLabel.font = NSFont(name: "Impact", size: fontSize)
            textWidth = dateLabel.intrinsicContentSize.width
        }
    }
    
    private func colorToHex(_ color: NSColor) -> String {
        guard let rgbColor = color.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        
        let red = Int(rgbColor.redComponent * 255)
        let green = Int(rgbColor.greenComponent * 255)
        let blue = Int(rgbColor.blueComponent * 255)
        
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()

        color.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)

        image.unlockFocus()
        return image
    }
}

class KnobView: NSView {
    var knobColor: NSColor = .white

    override func layout() {
        super.layout()
        self.wantsLayer = true
        self.layer?.cornerRadius = min(self.bounds.width, self.bounds.height) / 2
        self.layer?.masksToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        knobColor.setFill()
        dirtyRect.fill()
    }
}
