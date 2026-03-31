// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics

struct FeedbackView: View {
    @State private var descriptionText: String = ""
    @Binding var urlString: String
    @State private var selectedFilename: String?
    @State private var selectedFileURL: URL?
    @ObservedObject var viewModel: FeedbackViewModel
    @State private var isShowingFileImporter: Bool = false
    @State private var includeScreenshot: Bool = false
    @State private var sendSystemInfo: Bool = true
    @State private var snapshotImage: NSImage?
    @State private var snapshotURL: URL?
    @State private var isHoveringScreenshot: Bool = false
    @State private var showPermissionAlert: Bool = false
    @State private var showFileSizeAlert: Bool = false
    private let maxDescriptionLength = 4096
    
    var onPrivacyPolicyTap: (() -> Void)?
    var onTermsOfServiceTap: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSend: (([String: AnyHashable]) -> Void)?
    
    private var legalText: AttributedString {
        var string = AttributedString(NSLocalizedString("Some account and system information may be sent to Phinomenon. We will use the information you give us to help address technical issues and to improve our services, subject to our Privacy Policy and Terms of Service.", comment: "Feedback form - Legal disclaimer text explaining data usage, contains links to Privacy Policy and Terms of Service"))
        
        if let range = string.range(of: "Privacy Policy") {
            string[range].link = URL(string: "privacy")
            string[range].underlineStyle = .single
        }
        
        if let range = string.range(of: "Terms of Service") {
            string[range].link = URL(string: "terms")
            string[range].underlineStyle = .single
        }
        
        return string
    }
    
    init(viewModel: FeedbackViewModel,
         onPrivacyPolicyTap: (() -> Void)? = nil,
         onTermsOfServiceTap: (() -> Void)? = nil,
         onCancel: (() -> Void)? = nil,
         onSend: (([String: AnyHashable]) -> Void)? = nil) {
        self.viewModel = viewModel
        self._urlString = Binding(
            get: { viewModel.urlString },
            set: { viewModel.urlString = $0 }
        )
        self.onPrivacyPolicyTap = onPrivacyPolicyTap
        self.onTermsOfServiceTap = onTermsOfServiceTap
        self.onCancel = onCancel
        self.onSend = onSend
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                HStack {
                    Text(NSLocalizedString("Describe the issue in detail", comment: "Feedback form - Label prompting user to describe the issue"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                Spacer()
                    .frame(height: 16)
                
                TextEditor(text: $descriptionText)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .frame(height: 144)
                    .padding(4)
                    .background(Color(NSColor.black.withAlphaComponent(0.02)))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                    .onChange(of: descriptionText, { oldValue, newValue in
                        if newValue.count > maxDescriptionLength {
                            descriptionText = String(newValue.prefix(maxDescriptionLength))
                        }
                    })
                
                if descriptionText.count >= 3000 {
                    Spacer()
                        .frame(height: 5)
                    
                    Text("\(descriptionText.count)/\(maxDescriptionLength)")
                        .font(.caption)
                        .foregroundColor(descriptionText.count > 4500 ? .red : .yellow)
                }
            }
            
            VStack(alignment: .leading, spacing: 16) {
                Text(NSLocalizedString("Additional info (optional)", comment: "Feedback form - Section header for optional additional information"))
                    .foregroundColor(.secondary)
                
                VStack(spacing: 11) {
                    HStack {
                        Text(NSLocalizedString("URL", comment: "Feedback form - Label for URL input field"))
                            .foregroundColor(.primary)
                        Spacer()
                        TextField("URL", text: $urlString)
                            .textFieldStyle(.plain)
                            .focusEffectDisabled()
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Divider()
                    
                    HStack {
                        Text(NSLocalizedString("Attach file", comment: "Feedback form - Label for file attachment section"))
                            .foregroundColor(.primary)
                        
                        if let filename = selectedFilename {
                            Text(filename)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.leading, 8)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            isShowingFileImporter = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text(NSLocalizedString("Choose File", comment: "Feedback form - Button to open file picker for attachment"))
                            }
                        }
                    }
                    
                    if let image = snapshotImage {
                        HStack {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 75)
                                .scaleEffect(isHoveringScreenshot ? 1.1 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringScreenshot)
                                .onHover { hovering in
                                    isHoveringScreenshot = hovering
                                }
                                .onTapGesture {
                                    if let url = snapshotURL {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(NSColor.black.withAlphaComponent(0.02)))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
            .padding(.top, 24)
            
            // Options Section
            VStack(alignment: .leading, spacing: 8) {
                Toggle(NSLocalizedString("Include this screenshot and titles of open tabs", comment: "Feedback form - Checkbox option to include screenshot with feedback"), isOn: $includeScreenshot)
                    .toggleStyle(.checkbox)
                    .onChange(of: includeScreenshot, { oldValue, isOn in
                        if isOn {
                            captureScreenshot()
                        } else {
                            snapshotImage = nil
                            snapshotURL = nil
                        }
                    })
            }
            .padding(.top, 24)
            .alert(NSLocalizedString("Screen Recording Permission Required", comment: "Feedback form - Alert title when screen recording permission is needed"), isPresented: $showPermissionAlert) {
                Button(NSLocalizedString("Open System Settings", comment: "Feedback form - Button to open system settings for screen recording permission")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(NSLocalizedString("Cancel", comment: "Feedback form - Cancel button in permission alert"), role: .cancel) {
                    includeScreenshot = false
                }
            } message: {
                Text(NSLocalizedString("Please allow this app to record your screen to attach screenshots to feedback.", comment: "Feedback form - Alert message explaining why screen recording permission is needed"))
            }
            
            VStack {
                Spacer()
                    .frame(height: 24)
                
                Text(legalText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.absoluteString == "privacy" {
                            openPrivacyPolicy()
                            return .handled
                        } else if url.absoluteString == "terms" {
                            openTermsOfService()
                            return .handled
                        }
                        return .discarded
                    })
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button(NSLocalizedString("Cancel", comment: "Feedback form - Cancel button to dismiss feedback form")) {
                        onCancel?()
                    }
                    .buttonStyle(CancelButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    
                    Button(NSLocalizedString("Send", comment: "Feedback form - Send button to submit feedback")) {
                        guard !descriptionText.isEmpty else {
                            onCancel?()
                            return
                        }
                        onSend?(buildPayload())
                    }
                    .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(SendButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    Spacer()
                }
//                .padding(.top, 2)
            }
//            .debugBorder()
        }
        .padding(36)
        .frame(width: 520)
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Check file size (limit 2MB)
                    do {
                        let resources = try url.resourceValues(forKeys: [.fileSizeKey])
                        if let fileSize = resources.fileSize, fileSize > 2 * 1024 * 1024 {
                            showFileSizeAlert = true
                            return
                        }
                        
                        selectedFilename = url.lastPathComponent
                        selectedFileURL = url
                    } catch {
                        print("Error checking file size: \(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                print("File selection error: \(error.localizedDescription)")
            }
        }
        .alert(NSLocalizedString("File too large", comment: "Feedback form - Alert title when selected file exceeds size limit"), isPresented: $showFileSizeAlert) {
            Button(NSLocalizedString("OK", comment: "Feedback form - OK button to dismiss file size alert"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("Please select a file smaller than 2MB.", comment: "Feedback form - Alert message explaining file size limit"))
        }
    }
    
    private func openPrivacyPolicy() {
        onPrivacyPolicyTap?()
    }
    
    private func openTermsOfService() {
        onTermsOfServiceTap?()
    }
    
    private func captureScreenshot() {
        // Check for screen recording permission
        if !CGPreflightScreenCaptureAccess() {
            // Request permission if not granted
            // Note: CGRequestScreenCaptureAccess returns false if permission is not yet granted or denied
            // We trigger the system prompt here.
            CGRequestScreenCaptureAccess()
            // Since we can't wait for the user's action in a synchronous flow easily here,
            // and if it returns false it might mean "prompting" or "denied",
            // we show the alert to guide them if they have denied it or need to enable it.
            // Ideally, we would only show this if we knew for sure it was denied.
            // But for a simple implementation, we assume if preflight fails, we need user intervention.
            showPermissionAlert = true
            includeScreenshot = false
            return
        }
        
        // Capture the screen content below the current window to avoid capturing the feedback window itself
        // This avoids the need to hide/show the window which causes flickering
        guard let currentWindow = NSApp.keyWindow else { return }
        let windowID = CGWindowID(currentWindow.windowNumber)
        
        guard let screen = currentWindow.screen ?? NSScreen.main else { return }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        let screenBounds = CGDisplayBounds(displayID)
        
        // Capture windows below the feedback window
        if let cgImage = CGWindowListCreateImage(screenBounds, .optionOnScreenBelowWindow, windowID, .bestResolution) {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            self.snapshotImage = nsImage
            
            // Save to temporary file for preview
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "feedback_screenshot_\(Int(Date().timeIntervalSince1970)).png"
            let fileURL = tempDir.appendingPathComponent(fileName)
            
            if let tiffData = nsImage.tiffRepresentation,
               let bitmapImage = NSBitmapImageRep(data: tiffData),
               let pngData = bitmapImage.representation(using: .png, properties: [:]) {
                try? pngData.write(to: fileURL)
                self.snapshotURL = fileURL
            }
        }
    }
    
    private func buildPayload() -> [String: AnyHashable] {
        var payload: [String: AnyHashable] = [
            "description": descriptionText,
            "page_url": urlString,
            "sendSystemInfo": sendSystemInfo,
            "user_email": AccountController.shared.account?.userInfo?.email ?? "",
            "category_tag": "issue-report"
        ]
        
        if includeScreenshot, let image = snapshotImage {
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                payload["screenshot_data"] = pngData
                payload["screenshot_mime_type"] = "image/png"
            }
        }
        
        // Read attachment data
        if let fileURL = selectedFileURL,
           let filename = selectedFilename {
            // Start accessing security scoped resource if needed (for sandboxed apps)
            let gotAccess = fileURL.startAccessingSecurityScopedResource()
            
            if let fileData = try? Data(contentsOf: fileURL) {
                // Passing as a dictionary [FileName: FileDataString]
                payload["attachments"] = [filename: fileData]
            }
            
            if gotAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        return payload
    }
}

struct CancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .frame(width: 110, height: 28)
            .background(Color(NSColor.controlBackgroundColor))
            .foregroundColor(.primary)
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct SendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .frame(width: 110, height: 28)
            .background(isEnabled ? Color.blue : Color.gray.opacity(0.5))
            .foregroundColor(.white)
            .cornerRadius(5)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

//#Preview {
//    FeedbackView(viewModel: FeedbackViewModel())
//}
