// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

enum AccountVerificationEmailMasking {
    static func masked(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "•••" }
        let domain = email[at...]
        guard at != email.startIndex else { return "•••\(domain)" }
        return "\(email[email.startIndex])•••\(domain)"
    }
}

enum AccountVerificationCodeInput {
    static let length = 6

    static func sanitized(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && $0.isNumber }.prefix(length))
    }
}

enum AccountVerificationResendCountdown {
    static func remainingSeconds(until availableAt: Date?, now: Date) -> Int {
        guard let availableAt else { return 0 }
        return max(0, Int(availableAt.timeIntervalSince(now).rounded(.up)))
    }
}

/// Six visual digit boxes backed by one accessible text field. Deletion and
/// export provide their own localised label while sharing all input behaviour.
struct AccountVerificationCodeEntry: View {
    @Binding var code: String
    let isDisabled: Bool
    let accessibilityLabel: String

    @FocusState private var isFocused: Bool
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private static let boxHeight: CGFloat = 64
    private static let boxSpacing: CGFloat = 21
    private static let boxCornerRadius: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.boxSpacing) {
            ForEach(0..<AccountVerificationCodeInput.length, id: \.self) { index in
                digitBox(at: index)
            }
        }
        .accessibilityHidden(true)
        .overlay {
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($isFocused)
                .opacity(0.02)
                .accessibilityLabel(Text(accessibilityLabel))
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .defaultFocus($isFocused, true)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: code) { _, newValue in
            let sanitized = AccountVerificationCodeInput.sanitized(newValue)
            if sanitized != newValue { code = sanitized }
        }
        .onChange(of: isDisabled) { _, disabled in
            if !disabled { isFocused = true }
        }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(code)
        let digit = index < digits.count ? String(digits[index]) : ""
        let isActive = isFocused && !isDisabled && index == digits.count
        return RoundedRectangle(cornerRadius: Self.boxCornerRadius, style: .continuous)
            .fill(boxFill)
            .overlay {
                RoundedRectangle(cornerRadius: Self.boxCornerRadius, style: .continuous)
                    .strokeBorder(
                        isActive ? activeBorder : inactiveBorder,
                        lineWidth: isActive ? 2 : 1
                    )
            }
            .overlay {
                Text(digit)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .themedForeground(.textPrimaryStrong)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.boxHeight)
    }

    private var boxFill: Color {
        appearance.isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.06)
    }

    private var inactiveBorder: Color {
        appearance.isLight ? Color.black.opacity(0.15) : Color.white.opacity(0.18)
    }

    private var activeBorder: Color {
        ThemedColor.themeColor.swiftUIColor(theme: theme, appearance: appearance)
    }
}
