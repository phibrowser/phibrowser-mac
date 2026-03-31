// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Sparkle
extension SidebarViewController {
    func showUpdateReminder(version: String) {
        let reminderView = ReminderView(version: version)
        reminderView.delegate = self
        
        // Surface the update reminder through the notification area.
        showNotificationView(reminderView, height: 42)
    }
    
    func hideUpdateReminder() {
        hideNotificationView(animated: true)
    }
}

extension SidebarViewController: ReminderViewDelegate {
    func reminderViewDidSelectRemindLater(_ view: ReminderView) {
        hideUpdateReminder()
    }
    
    func confirmToDownload(_ view: ReminderView) {
        let response = AppController.shared.showInstallAvailableAlert(version: view.version)
        if response == .alertFirstButtonReturn {
            hideUpdateReminder()
            AppController.shared.installUpdateImmediately()
        }
    }
}

protocol ReminderViewDelegate: AnyObject {
    func reminderViewDidSelectRemindLater(_ view: ReminderView)
    func confirmToDownload(_ view: ReminderView)
}

class ReminderView: NSView {
    
    weak var delegate: ReminderViewDelegate?
    let version: String
    
    // MARK: - Colors
    private let normalBackgroundColor: Mapper<CGColor> = NSColor.white.cgColor <> NSColor.black.cgColor
    private let hoverBackgroundColor: Mapper<CGColor> = NSColor(white: 0.95, alpha: 1).cgColor <> NSColor(white: 0.15, alpha: 1).cgColor
    
    // MARK: - UI Elements
    private let containerView = NSView()
    private let iconImageView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    
    // MARK: - Initialization
    init(version: String) {
        self.version = version
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        phiLayer?.backgroundColor = NSColor.white.cgColor <> NSColor.black.cgColor
        phiLayer?.setBorderColor(.border)
        
        setupContainerView()
        setupIcon()
        setupMessageLabel()
        setupCloseButton()
        setupLayout()
    }
    
    private func setupContainerView() {
        containerView.wantsLayer = true
        addSubview(containerView)
    }
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        delegate?.confirmToDownload(self)
    }
    
    private func setupIcon() {
        iconImageView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: NSLocalizedString("Update available", comment: "Sidebar update reminder - Accessibility description for update icon"))
        iconImageView.contentTintColor = .systemBlue
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        containerView.addSubview(iconImageView)
    }
    
    private func setupMessageLabel() {
        messageLabel.stringValue = String(format: NSLocalizedString("New Version %@ Available", comment: "Sidebar update reminder - Message showing new version is available"), version)
        messageLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        messageLabel.textColor = .labelColor
        messageLabel.maximumNumberOfLines = 1
        messageLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(messageLabel)
    }
    
    private func setupCloseButton() {
        // Close Button
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: NSLocalizedString("Close", comment: "Sidebar update reminder - Accessibility description for close button"))
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.controlSize = .small
        containerView.addSubview(closeButton)
    }
    
    private func setupLayout() {
        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        iconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(20)
        }
        
        closeButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(20)
        }
        
        messageLabel.setContentHuggingPriority(.defaultLow - 10, for: .horizontal)
        messageLabel.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        messageLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(8)
            make.trailing.equalTo(closeButton.snp.leading).offset(-8)
            make.centerY.equalToSuperview()
        }
    }
    
    // MARK: - Actions
    @objc private func closeTapped() {
        delegate?.reminderViewDidSelectRemindLater(self)
    }
    
    
    // MARK: - Visual Effects
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        animateBackgroundColor(to: hoverBackgroundColor.currentValue)
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        animateBackgroundColor(to: normalBackgroundColor.currentValue)
    }
    
    private func animateBackgroundColor(to color: CGColor) {
        guard let layer = layer else { return }
        
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer.backgroundColor
        animation.toValue = color
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        
        layer.backgroundColor = color
        layer.add(animation, forKey: "backgroundColor")
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        trackingAreas.forEach { removeTrackingArea($0) }
        
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
}
