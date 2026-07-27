// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Sign-in / unlock sheet for the Bitwarden credential provider, presented from
/// the General settings card. Its layout mirrors Bitwarden's own login form:
/// the wordmark, a "Log in" title, an email step (email + "Remember email" +
/// Continue), and the "Accessing:" server footer — deliberately without the
/// "Create account" entry point (Phi does not onboard new Bitwarden accounts).
///
/// In `.login` mode it is a two-step flow (email → master password, matching
/// Bitwarden's real UX); in `.unlock` mode it collects the master password for
/// an already-authenticated account, plus an optional two-step code for 2FA
/// accounts whose remembered device trust has expired (unlock is a re-login
/// under the hood).
///
/// It drives `BitwardenService`, which forwards to the out-of-process helper.
/// Password login is the supported path; the server-region selector resolves to
/// identity + api URLs the helper applies (US default / EU / self-hosted).
struct BitwardenLoginSheet: View {
    enum Mode {
        case login
        case unlock
    }

    /// Two-step progression within `.login` mode. `.unlock` ignores this.
    private enum Step {
        case email
        case password
    }

    /// Server region shown in the footer selector; resolves to the identity +
    /// api URLs the helper logs in against (see `serverURLs()`).
    private enum Region: String, CaseIterable, Identifiable {
        case us
        case eu
        case selfHosted

        var id: String { rawValue }

        var label: String {
            switch self {
            case .us: return "bitwarden.com"
            case .eu: return "bitwarden.eu"
            case .selfHosted: return NSLocalizedString("settings.bitwardenLoginSheet.selfHostedServerOption", value: "self-hosted", comment: "Bitwarden login sheet - self-hosted server option")
            }
        }
    }

    let mode: Mode
    /// Called after a successful login/unlock so the caller can refresh status.
    var onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage("bitwarden.rememberEmail") private var rememberEmail = false
    @AppStorage("bitwarden.rememberedEmail") private var storedEmail = ""

    @State private var step: Step = .email
    @State private var email = ""
    @State private var password = ""
    @State private var twoFactor = ""
    @State private var region: Region = .us
    @State private var selfHostURL = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    /// Bitwarden brand blue for the primary action and links.
    private let brandBlue = Color(red: 0.204, green: 0.286, blue: 0.851)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            switch (mode, step) {
            case (.login, .email):
                emailStep
            case (.login, .password):
                passwordStep
            case (.unlock, _):
                unlockStep
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mode == .login {
                footer
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            if rememberEmail, !storedEmail.isEmpty { email = storedEmail }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(.bitwardenIcon)
                .resizable()
                .frame(width: 24, height: 24)
            Text("Bitwarden")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(brandBlue)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(isBusy)
        }
    }

    // MARK: - Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("settings.bitwardenLoginSheet.emailStep.title", value: "Log in", comment: "Bitwarden login sheet - Email step title"))
                .font(.system(size: 22, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                requiredLabel(NSLocalizedString("settings.bitwardenLoginSheet.emailField.label", value: "Email address", comment: "Bitwarden login sheet - email field label"))
                styledField {
                    TextField("", text: $email)
                        .textContentType(.username)
                        .disableAutocorrection(true)
                        .onSubmit { continueToPassword() }
                }
                Toggle(isOn: $rememberEmail) {
                    Text(NSLocalizedString("settings.bitwardenLoginSheet.rememberEmailToggle", value: "Remember email", comment: "Bitwarden login sheet - remember email toggle"))
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }

            if region == .selfHosted {
                VStack(alignment: .leading, spacing: 6) {
                    requiredLabel(NSLocalizedString("settings.bitwardenLoginSheet.selfHostedServer.fieldLabel", value: "Self-hosted server URL", comment: "Bitwarden login sheet - self-hosted server URL field label"))
                    styledField {
                        TextField("https://vault.example.com", text: $selfHostURL)
                            .urlTextContentType()
                            .disableAutocorrection(true)
                            .onSubmit { continueToPassword() }
                    }
                }
            }

            primaryButton(NSLocalizedString("settings.bitwardenLoginSheet.continueButton", value: "Continue", comment: "Bitwarden login sheet - continue button")) {
                continueToPassword()
            }
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("settings.bitwardenLoginSheet.passwordStep.title", value: "Log in", comment: "Bitwarden login sheet - Password step title"))
                .font(.system(size: 22, weight: .bold))

            HStack(spacing: 6) {
                Text(email)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(NSLocalizedString("settings.bitwardenLoginSheet.changeEmailLink", value: "Change", comment: "Bitwarden login sheet - change email link")) {
                    step = .email
                    password = ""
                    twoFactor = ""
                    errorMessage = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(brandBlue)
                .disabled(isBusy)
            }

            VStack(alignment: .leading, spacing: 6) {
                requiredLabel(NSLocalizedString("settings.bitwardenLoginSheet.masterPasswordField.label", value: "Master password", comment: "Bitwarden login sheet - master password field label"))
                styledField {
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .onSubmit { if canSubmitPassword { submitLogin() } }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("settings.bitwardenLoginSheet.twoStepCodeField.label", value: "Two-step login code (if enabled)", comment: "Bitwarden login sheet - 2FA field label"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                styledField {
                    TextField("", text: $twoFactor)
                        .disableAutocorrection(true)
                        .onSubmit { if canSubmitPassword { submitLogin() } }
                }
            }

            primaryButton(NSLocalizedString("settings.bitwardenLoginSheet.loginButton", value: "Log in", comment: "Bitwarden login sheet - submit button")) {
                submitLogin()
            }
            .disabled(!canSubmitPassword)
        }
    }

    private var unlockStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("settings.bitwardenUnlockSheet.title", value: "Unlock", comment: "Bitwarden unlock sheet - title"))
                .font(.system(size: 22, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                requiredLabel(NSLocalizedString("settings.bitwardenUnlockSheet.masterPasswordField.label", value: "Master password", comment: "Bitwarden login sheet - master password field label"))
                styledField {
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .onSubmit { if canSubmitPassword { submitUnlock() } }
                }
            }

            // Unlock is a re-login under the hood. A 2FA account normally
            // rides its remembered device trust; when that has expired the
            // helper answers "Two-step code required." and this field is the
            // way through.
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("settings.bitwardenUnlockSheet.twoStepCodeField.label", value: "Two-step login code (if enabled)", comment: "Bitwarden login sheet - 2FA field label"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                styledField {
                    TextField("", text: $twoFactor)
                        .disableAutocorrection(true)
                        .onSubmit { if canSubmitPassword { submitUnlock() } }
                }
            }

            primaryButton(NSLocalizedString("settings.bitwardenUnlockSheet.unlockButton", value: "Unlock", comment: "Bitwarden unlock sheet - submit button")) {
                submitUnlock()
            }
            .disabled(!canSubmitPassword)
        }
    }

    // MARK: - Footer (server region)

    private var footer: some View {
        HStack(spacing: 4) {
            Text(NSLocalizedString("settings.bitwardenLoginSheet.serverRegionPrefix", value: "Accessing:", comment: "Bitwarden login sheet - server region prefix"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(Region.allCases) { option in
                    Button {
                        selectRegion(option)
                    } label: {
                        if option == region {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(region.label)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundStyle(brandBlue)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Building blocks

    private func requiredLabel(_ text: String) -> some View {
        HStack(spacing: 2) {
            Text(text).foregroundStyle(.primary)
            Text("*").foregroundStyle(.red)
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private func styledField<Control: View>(@ViewBuilder _ control: () -> Control) -> some View {
        control()
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(brandBlue))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var canSubmitPassword: Bool {
        !isBusy && !password.isEmpty
    }

    private func continueToPassword() {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = NSLocalizedString("settings.bitwardenLoginSheet.emailField.requiredError", value: "Enter your email address.", comment: "Bitwarden login sheet - missing email error")
            return
        }
        if region == .selfHosted, normalizedBaseURL(selfHostURL) == nil {
            errorMessage = NSLocalizedString("settings.bitwardenLoginSheet.emailStep.invalidSelfHostedURLError", value: "Enter a valid self-hosted server URL.", comment: "Bitwarden login sheet - Invalid self-hosted URL error before continuing from the email step")
            return
        }
        email = trimmed
        storedEmail = rememberEmail ? trimmed : ""
        errorMessage = nil
        step = .password
    }

    private func selectRegion(_ option: Region) {
        region = option
        errorMessage = nil
    }

    /// Identity + api URLs for the chosen region, or `nil` for the default US
    /// cloud (the helper defaults to bitwarden.com when none are sent). Returns
    /// `nil` for self-hosted only if the URL fails to normalize — callers
    /// validate that separately before reaching here.
    private func serverURLs() -> (identity: String, api: String)? {
        switch region {
        case .us:
            return nil
        case .eu:
            return ("https://identity.bitwarden.eu", "https://api.bitwarden.eu")
        case .selfHosted:
            guard let base = normalizedBaseURL(selfHostURL) else { return nil }
            return ("\(base)/identity", "\(base)/api")
        }
    }

    /// Trims, adds a default `https://` scheme, and strips trailing slashes.
    /// Returns `nil` if the result has no host. The scheme is otherwise the
    /// user's choice — an explicit `http://` self-host is accepted deliberately.
    private func normalizedBaseURL(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        return value
    }

    private func submitLogin() {
        guard canSubmitPassword else { return }
        if region == .selfHosted, normalizedBaseURL(selfHostURL) == nil {
            step = .email
            errorMessage = NSLocalizedString("settings.bitwardenLoginSheet.submission.invalidSelfHostedURLError", value: "Enter a valid self-hosted server URL.", comment: "Bitwarden login sheet - Invalid self-hosted URL error during login submission")
            return
        }
        isBusy = true
        errorMessage = nil
        let email = self.email
        let password = self.password
        let twoFactor = self.twoFactor.isEmpty ? nil : self.twoFactor
        let server = serverURLs()

        Task {
            do {
                try await BitwardenService.shared.login(
                    email: email,
                    masterPassword: password,
                    twoFactor: twoFactor,
                    identityURL: server?.identity,
                    apiURL: server?.api
                )
                await MainActor.run {
                    isBusy = false
                    onComplete()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func submitUnlock() {
        guard canSubmitPassword else { return }
        isBusy = true
        errorMessage = nil
        let password = self.password
        let twoFactor = self.twoFactor.isEmpty ? nil : self.twoFactor

        Task {
            do {
                try await BitwardenService.shared.unlock(secret: password, twoFactor: twoFactor)
                await MainActor.run {
                    isBusy = false
                    onComplete()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private extension View {
    /// `NSTextContentType.URL` requires macOS 14; older systems skip the
    /// content-type hint (autofill nicety only).
    @ViewBuilder
    func urlTextContentType() -> some View {
        if #available(macOS 14.0, *) {
            self.textContentType(.URL)
        } else {
            self
        }
    }
}
