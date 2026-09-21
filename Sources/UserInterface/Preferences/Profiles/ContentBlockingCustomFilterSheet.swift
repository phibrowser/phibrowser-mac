// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// What the user typed into the custom filter sheet, and the checks that
/// run before it is handed to Chromium (which validates again).
struct ContentBlockingCustomFilterInput: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case url, rules
        var id: String { rawValue }
    }

    var kind: Kind = .url
    var name = ""
    var url = ""
    var rules = ""

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The message to show instead of submitting, or nil when the input is
    /// complete.
    var validationError: String? {
        if trimmedName.isEmpty {
            return NSLocalizedString("settings.privacy.contentBlocking.customFilter.error.name", value: "Give the filter a name.", comment: "Custom filter sheet - Validation message when the name is empty")
        }
        switch kind {
        case .url:
            guard let parsed = URL(string: trimmedURL),
                  let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = parsed.host, !host.isEmpty else {
                return NSLocalizedString("settings.privacy.contentBlocking.customFilter.error.url", value: "Enter a full http(s) URL.", comment: "Custom filter sheet - Validation message when the URL is missing or not http(s)")
            }
        case .rules:
            if rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return NSLocalizedString("settings.privacy.contentBlocking.customFilter.error.rules", value: "Enter at least one filter rule.", comment: "Custom filter sheet - Validation message when the rules text is empty")
            }
        }
        return nil
    }
}

/// The "Custom filter" sheet: a URL to download, or pasted rules.
struct ContentBlockingCustomFilterSheet: View {
    @ObservedObject var settings: ContentBlockingSettings
    @Environment(\.dismiss) private var dismiss
    @State private var input = ContentBlockingCustomFilterInput()
    @State private var submitError: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("settings.privacy.contentBlocking.customFilter.title", value: "Custom filter", comment: "Custom filter sheet - Title"))
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            Picker("", selection: $input.kind) {
                Text(NSLocalizedString("settings.privacy.contentBlocking.customFilter.kind.url", value: "URL", comment: "Custom filter sheet - Segment for a filter list downloaded from a URL")).tag(ContentBlockingCustomFilterInput.Kind.url)
                Text(NSLocalizedString("settings.privacy.contentBlocking.customFilter.kind.rules", value: "Custom", comment: "Custom filter sheet - Segment for pasted filter rules")).tag(ContentBlockingCustomFilterInput.Kind.rules)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            field(NSLocalizedString("settings.privacy.contentBlocking.customFilter.name", value: "Name", comment: "Custom filter sheet - Label of the name field")) {
                TextField(NSLocalizedString("settings.privacy.contentBlocking.customFilter.namePlaceholder", value: "e.g. My filter", comment: "Custom filter sheet - Placeholder of the name field"), text: $input.name)
                    .textFieldStyle(.roundedBorder)
            }
            switch input.kind {
            case .url:
                field(NSLocalizedString("settings.privacy.contentBlocking.customFilter.url", value: "URL", comment: "Custom filter sheet - Label of the URL field")) {
                    // The example URL is not a translatable string.
                    TextField("", text: $input.url, prompt: Text(verbatim: "https://example.com/filters.txt"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            case .rules:
                field(NSLocalizedString("settings.privacy.contentBlocking.customFilter.rules", value: "Filter rules", comment: "Custom filter sheet - Label of the rules text area")) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $input.rules)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 160)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).stroke(Color(.separatorColor)))
                        if input.rules.isEmpty {
                            Text(verbatim: "||example.com^\n@@||allowed.example^")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            if let message = submitError ?? (attempted ? input.validationError : nil) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("settings.privacy.contentBlocking.customFilter.cancel", value: "Cancel", comment: "Custom filter sheet - Cancel button")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("settings.privacy.contentBlocking.customFilter.add", value: "Add", comment: "Custom filter sheet - Button that adds the filter")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
        }
        .padding(24)
        .frame(width: 440)
        .themedBackground(PhiPreferences.fixedWindowBackground)
    }

    @State private var attempted = false

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            content()
        }
    }

    private func submit() {
        attempted = true
        submitError = nil
        guard input.validationError == nil else { return }
        isSubmitting = true
        settings.addCustomList(name: input.trimmedName,
                               url: input.kind == .url ? input.trimmedURL : nil,
                               rules: input.kind == .rules ? input.rules : nil) { error in
            isSubmitting = false
            if let error {
                submitError = error
            } else {
                dismiss()
            }
        }
    }
}
