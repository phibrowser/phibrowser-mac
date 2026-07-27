// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FeedbackView: View {
    @Binding var urlString: String
    @ObservedObject var viewModel: FeedbackViewModel
    @State private var isShowingFileImporter: Bool = false
    private let maxDescriptionLength = 4096
    
    var onPrivacyPolicyTap: (() -> Void)?
    var onTermsOfServiceTap: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSend: (() -> Void)?

    private let attachmentRowHeight: CGFloat = 24
    private let attachmentRowSpacing: CGFloat = 6

    private var windowBackgroundColor: Color {
        Color(NSColor.windowBackgroundColor)
    }

    private var controlBackgroundColor: Color {
        Color(NSColor.controlBackgroundColor)
    }

    private var separatorColor: Color {
        Color(NSColor.separatorColor)
    }
    
    private var legalText: AttributedString {
        var string = AttributedString(NSLocalizedString("feedback.form.privacyNotice", value: "Some account and system information may be sent to Phinomenon. We will use the information you give us to help address technical issues and to improve our services, subject to our Privacy Policy and Terms of Service.", comment: "Feedback form - Legal disclaimer text explaining data usage, contains links to Privacy Policy and Terms of Service"))
        
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
         onSend: (() -> Void)? = nil) {
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    descriptionSection
                    additionalInfoSection
                    legalSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .animation(.easeOut(duration: 0.2), value: viewModel.attachments.count)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
            }
            .onChange(of: viewModel.attachments.count) { _ in
                scrollToLastAttachment(proxy)
            }
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity)
        .background(windowBackgroundColor)
        .background(FeedbackPasteImageMonitor { image in
            viewModel.addPastedImage(image)
        })
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                viewModel.addFileURLs(urls)
            case .failure(let error):
                AppLogError("File selection error: \(error.localizedDescription)")
            }
        }
        .alert(
            NSLocalizedString("feedback.form.localSaveFailure.title", value: "Could Not Save Feedback", comment: "Feedback form - Alert title when local outbox save fails"),
            isPresented: Binding(
                get: { viewModel.localSaveError != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.localSaveError = nil
                    }
                }
            )
        ) {
            Button(NSLocalizedString("feedback.form.localSaveFailure.dismissButton", value: "OK", comment: "Feedback form - Local-save failure alert dismiss button"), role: .cancel) { }
        } message: {
            Text(viewModel.localSaveError ?? "")
        }
        .alert(
            NSLocalizedString("feedback.form.attachmentFailure.title", value: "Could Not Add Attachment", comment: "Feedback form - Alert title when selected attachments cannot be added"),
            isPresented: Binding(
                get: { viewModel.attachmentError != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.attachmentError = nil
                    }
                }
            )
        ) {
            Button(NSLocalizedString("feedback.form.attachmentFailure.dismissButton", value: "OK", comment: "Feedback form - Attachment failure alert dismiss button"), role: .cancel) { }
        } message: {
            Text(viewModel.attachmentError ?? "")
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("feedback.form.descriptionSection.title", value: "Describe the issue in detail", comment: "Feedback form - Section header prompting user to describe the issue"))
                .font(.headline)

            TextEditor(text: $viewModel.descriptionText)
                .compatHiddenScrollContentBackground()
                .font(.body)
                .frame(height: 144)
                .padding(4)
                .background(controlBackgroundColor)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(separatorColor, lineWidth: 1)
                )
                .onChange(of: viewModel.descriptionText, perform: { newValue in
                    if newValue.count > maxDescriptionLength {
                        viewModel.descriptionText = String(newValue.prefix(maxDescriptionLength))
                    }
                })

            if viewModel.descriptionText.count >= 3000 {
                Text("\(viewModel.descriptionText.count)/\(maxDescriptionLength)")
                    .font(.caption)
                    .foregroundStyle(viewModel.descriptionText.count >= maxDescriptionLength ? .red : .yellow)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var additionalInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("feedback.form.additionalInfoSection.title", value: "Additional info (optional)", comment: "Feedback form - Section header for optional additional information"))
                .font(.headline)

            VStack(spacing: 11) {
                HStack {
                    Text(NSLocalizedString("feedback.form.urlField.label", value: "URL", comment: "Feedback form - Label for URL input field"))
                        .foregroundStyle(.primary)
                    Spacer()
                    TextField("URL", text: $urlString)
                        .textFieldStyle(.plain)
                        .compatFocusEffectDisabled()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider()

                attachmentPickerRow

                if !viewModel.attachments.isEmpty {
                    Divider()
                    attachmentList()
                }
            }
            .padding()
            .background(controlBackgroundColor)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(separatorColor, lineWidth: 1)
            )
        }
    }

    private var legalSection: some View {
        Text(legalText)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
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
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(NSLocalizedString("feedback.form.sendButton", value: "Send", comment: "Feedback form - Send button to submit feedback")) {
                    guard viewModel.canSend else { return }
                    onSend?()
                }
                .disabled(!viewModel.canSend)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(windowBackgroundColor)
        }
        .frame(maxWidth: .infinity)
    }

    private var attachmentPickerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("feedback.form.attachmentsSection.title", value: "Attach files", comment: "Feedback form - Label for file attachment section"))
                    .foregroundStyle(.primary)

                Text(NSLocalizedString("feedback.form.attachmentsSection.pasteImageHint", value: "Or paste an image", comment: "Feedback form - Hint explaining pasted images can be added as attachments"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: {
                isShowingFileImporter = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text(NSLocalizedString("feedback.form.attachmentsSection.chooseFilesButton", value: "Choose Files", comment: "Feedback form - Button to open file picker for attachments"))
                }
            }
        }
    }

    private func attachmentList() -> some View {
        VStack(spacing: attachmentRowSpacing) {
            ForEach(viewModel.attachments) { attachment in
                FeedbackAttachmentRow(attachment: attachment) {
                    FeedbackAttachmentPreviewer.open(attachment)
                } onRemove: {
                    viewModel.removeAttachment(id: attachment.id)
                }
                .frame(height: attachmentRowHeight)
                .id(attachment.id)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func scrollToLastAttachment(_ proxy: ScrollViewProxy) {
        guard let lastID = viewModel.attachments.last?.id else {
            return
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
    
    private func openPrivacyPolicy() {
        onPrivacyPolicyTap?()
    }
    
    private func openTermsOfService() {
        onTermsOfServiceTap?()
    }
}

private struct FeedbackAttachmentRow: View {
    let attachment: FeedbackDraftAttachment
    let onInspect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.kind == .image ? "photo" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(attachment.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Button(action: onInspect) {
                Image(systemName: "magnifyingglass")
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(attachment.kind == .image
                  ? NSLocalizedString("feedback.form.attachment.previewTooltip", value: "Preview attachment", comment: "Feedback form - Tooltip for previewing an attachment")
                  : NSLocalizedString("feedback.form.attachment.showInFinderTooltip", value: "Show in Finder", comment: "Download item row - Tooltip for show in finder button"))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("feedback.form.attachment.removeTooltip", value: "Remove attachment", comment: "Feedback form - Tooltip for removing an attachment"))
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
    }
}

@MainActor
private enum FeedbackAttachmentPreviewer {
    private static let previewBundleIdentifier = "com.apple.Preview"

    static func open(_ attachment: FeedbackDraftAttachment) {
        switch attachment.kind {
        case .image:
            guard let url = imagePreviewURL(for: attachment) else { return }
            openInPreview(url)
        case .file:
            revealInFinder(attachment)
        }
    }

    private static func imagePreviewURL(for attachment: FeedbackDraftAttachment) -> URL? {
        switch attachment.source {
        case .file(let url):
            return url
        case .pastedImage(let data):
            do {
                return try writeTemporaryPreviewFile(for: attachment, data: data)
            } catch {
                AppLogError("Feedback attachment preview failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static func writeTemporaryPreviewFile(
        for attachment: FeedbackDraftAttachment,
        data: Data
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhiFeedbackPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = attachment.filename.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(attachment.id.uuidString)-\(filename)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func openInPreview(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()

        guard let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previewBundleIdentifier) else {
            if !NSWorkspace.shared.open(url) {
                AppLogError("Feedback attachment preview failed: Preview.app is unavailable")
            }
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: configuration) { _, error in
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            if let error {
                AppLogError("Feedback attachment preview failed: \(error.localizedDescription)")
            }
        }
    }

    private static func revealInFinder(_ attachment: FeedbackDraftAttachment) {
        guard case .file(let url) = attachment.source else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if didAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

private struct FeedbackPasteImageMonitor: NSViewRepresentable {
    let onPasteImage: (NSImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPasteImage: onPasteImage)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
    }

    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?
        private let onPasteImage: (NSImage) -> Void

        init(onPasteImage: @escaping (NSImage) -> Void) {
            self.onPasteImage = onPasteImage
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isCommandPaste(event),
                      event.window === self.view?.window,
                      let image = NSImage(pasteboard: .general) else {
                    return event
                }
                onPasteImage(image)
                return nil
            }
        }

        private func isCommandPaste(_ event: NSEvent) -> Bool {
            event.charactersIgnoringModifiers?.lowercased() == "v" &&
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        }
    }
}

#Preview {
    FeedbackView(viewModel: FeedbackViewModel())
}

private extension View {
    /// `scrollContentBackground` requires macOS 13; macOS 12 keeps the
    /// default editor background (visual-only degradation).
    @ViewBuilder
    func compatHiddenScrollContentBackground() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// `focusEffectDisabled` requires macOS 14; macOS 12/13 keep the focus
    /// ring (visual-only degradation).
    @ViewBuilder
    func compatFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
