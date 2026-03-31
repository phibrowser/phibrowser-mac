// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Auth0
import SwiftUI

class SetNameViewController: OnboardingBaseViewController {
    var newNameSettled: ((String) -> Void)?
    private var originalUserName: String?
    var credentials: Credentials? {
        didSet {
            if let credentials {
                let userInfo = AuthManager.retriveUserInfo(from: credentials)
                originalUserName = userInfo.name
                textField.stringValue = "\(userInfo.name ?? "")"
            }
        }
    }
    
    lazy var titleView: NSView = {
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        bg.layer?.cornerRadius = 10
        bg.addSubview(textField)
        textField.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(17)
        }
        return bg
    }()
    
    let textField: NSTextField = {
        let tf = NSTextField()
        tf.textColor = .white
        tf.isEditable = true
        tf.font = NSFont.systemFont(ofSize: 24)
        tf.alignment = .left
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        return tf
    }()
    
    /// Error label rendered with gradient text.
    private lazy var errorLabel: GradientColorLabel = {
        let label = GradientColorLabel(
            text: "",
            gradientColors: [
                Color(hexString: "#9452F9"),
                Color(hexString: "#E8C0FF")
            ],
            fontSize: 15
        )
        label.alphaValue = 0
        label.isHidden = true
        return label
    }()
    
    /// Loading indicator displayed during profile updates.
    private lazy var loadingIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isHidden = true
        return indicator
    }()
    
    /// Tracks whether the save request is currently running.
    private var isLoading: Bool = false {
        didSet {
            if isLoading {
                loadingIndicator.isHidden = false
                loadingIndicator.startAnimation(nil)
                textField.isEditable = false
                nextButton.isEnabled = false
            } else {
                loadingIndicator.stopAnimation(nil)
                loadingIndicator.isHidden = true
                textField.isEditable = true
                nextButton.isEnabled = true
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        skipButton.isHidden = true
        titleLabel.stringValue = NSLocalizedString("What should I call you?", comment: "Set name page - Title asking user for their preferred name")
        view.addSubview(titleView)
        titleView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(titleLabel.snp.bottom).offset(130)
            make.size.equalTo(NSSize(width: 398, height: 54))
        }
        
        view.addSubview(errorLabel)
        errorLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(titleView.snp.bottom).offset(12)
        }
        
        view.addSubview(loadingIndicator)
        loadingIndicator.snp.makeConstraints { make in
            make.centerY.equalTo(nextButton)
            make.leading.equalTo(nextButton).offset(15)
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        if credentials == nil {
            credentials = AuthManager.shared.getActiveCredentialsSyncly()
        }
    }
    
    override func nextButtonTapped(_ sender: NSButton? = nil) {
        hideError()
        
        let newUserName = textField.stringValue
        
        if let errorMessage = validateUserName(newUserName) {
            showError(errorMessage)
            return
        }
        
        guard newUserName != originalUserName else {
            UserDefaults.standard.set(newUserName, forKey: PhiPreferences.preferedUserName.rawValue)
            newNameSettled?(newUserName)
            return
        }
        
        isLoading = true
        
        Task {
            do {
                let _ =  try await APIClient.shared.updateProfile(updates: .init(name: textField.stringValue))
                await MainActor.run {
                    isLoading = false
                    UserDefaults.standard.set(textField.stringValue, forKey: PhiPreferences.preferedUserName.rawValue)
                    newNameSettled?(textField.stringValue)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    showError(error.localizedDescription)
                }
                AppLogError("update user profile failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Validation
    
    /// Validates the user-provided display name.
    private func validateUserName(_ name: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        
        if trimmedName.isEmpty {
            return NSLocalizedString("Name cannot be empty", comment: "Set name page - Error message when user name is empty or contains only spaces")
        }
        
        if name.count > 100 {
            return NSLocalizedString("Name is too long (maximum 100 characters)", comment: "Set name page - Error message when user name exceeds 100 characters")
        }
        
        return nil
    }
    
    // MARK: - Error Handling
    
    /// Shows the inline validation or request error.
    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            errorLabel.animator().alphaValue = 1.0
        }
    }
    
    /// Hides the inline error message.
    private func hideError() {
        guard !errorLabel.isHidden else { return }
        
        errorLabel.isHidden = true
        errorLabel.alphaValue = 0
    }
}
