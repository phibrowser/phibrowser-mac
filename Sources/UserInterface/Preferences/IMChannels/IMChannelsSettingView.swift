// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

struct IMChannelsSettingView: View {
    @State private var vm = IMChannelsViewModel()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                IMSectionHeader(
                    title: NSLocalizedString("Telegram", comment: "Phi Link - Section title"),
                    subtitle: String(
                        format: NSLocalizedString(
                            "Using Telegram to send and receive messages with %@",
                            comment: "Phi Link - Section subtitle with agent name"
                        ),
                        vm.agentName
                    )
                )

                if !vm.topNoticeMessages.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(vm.topNoticeMessages, id: \.self) { message in
                            IMNoticeBanner(message: message)
                        }
                    }
                }

                TelegramChannelsSection(vm: vm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(.windowBackground)
        .frame(width: 680, height: 561)
        .task { await vm.loadAll() }
        .onDisappear { Task { await vm.stopPolling() } }
    }
}

// MARK: - Section Header

private struct IMSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .themedForeground(.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .themedForeground(.textTertiary)
            }
        }
    }
}

// MARK: - Telegram Platform Section

private struct TelegramChannelsSection: View {
    @Bindable var vm: IMChannelsViewModel

    var body: some View {
        IMContainerView {
            OfficialBotSection(vm: vm)
            Divider()
            CustomBotSection(vm: vm)
        }
    }
}

// MARK: - Official Bot Section

private struct OfficialBotSection: View {
    @Bindable var vm: IMChannelsViewModel

    var body: some View {
        DisclosureGroup(isExpanded: $vm.isOfficialBotExpanded) {
            Divider()
            officialBotBody
        } label: {
            officialBotHeader
        }
        .disclosureGroupStyle(IMDisclosureStyle())
    }

    private var officialBotHeader: some View {
        HStack(spacing: 12) {
            Image(.phiLinkBot)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Official Phi Link Telegram bot", comment: "Phi Link - Official Bot title"))
                    .font(.system(size: 14))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("We provide a Telegram bot to relay your messages @philink_bot", comment: "Phi Link - Official Bot subtitle"))
                    .font(.system(size: 12))
                    .themedForeground(.textTertiary)
            }
            Spacer(minLength: 8)
            if !vm.hasLoaded || vm.isOfficialBotLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            if vm.hasLoaded {
                IMStatusBadge(
                    text: officialStatusText,
                    kind: officialStatusKind
                )
            }
        }
    }

    @ViewBuilder
    private var officialBotBody: some View {
        if !vm.hasLoaded {
            loadingRow
        } else if let pairing = vm.pairing, !vm.officialBotNeedsReconnect {
            connectedView(pairing: pairing)
        } else if vm.showPendingSession, let session = vm.activeSession {
            qrCodeView(session: session)
        } else if vm.officialBotErrorMessage != nil {
            serviceIssueView(
                actionTitle: NSLocalizedString("Retry", comment: "Phi Link - Retry loading official bot")
            ) {
                Task { await vm.refreshAll() }
            }
        } else {
            notConnectedView
        }
    }

    private var officialStatusText: String {
        if vm.officialBotHasServiceIssue {
            return NSLocalizedString("Service issue", comment: "Phi Link - Official bot service issue status")
        }
        if vm.pairing != nil && !vm.officialBotNeedsReconnect {
            return NSLocalizedString("Linked", comment: "Phi Link - Official bot linked status")
        }
        return NSLocalizedString("Not linked", comment: "Phi Link - Official bot not linked status")
    }

    private var officialStatusKind: IMStatusKind {
        if vm.officialBotHasServiceIssue {
            return .warning
        }
        if vm.pairing != nil && !vm.officialBotNeedsReconnect {
            return .success
        }
        return .neutral
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 20)
    }

    private func connectedView(pairing: ChannelPairing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("Telegram ID", comment: "Phi Link - Official bot connected label"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(vm.officialBotDisplayName)
                    .font(.system(size: 12))
                    .themedForeground(.textTertiary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                Task { await vm.disconnectOfficialBot() }
            } label: {
                HStack(spacing: 4) {
                    if vm.isOfficialBotLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Label(
                        NSLocalizedString("Unlink", comment: "Phi Link - Official bot unlink button"),
                        systemImage: "link.badge.minus"
                    )
                    .font(.system(size: 13))
                }
            }
            .imDestructiveButtonStyle()
            .disabled(vm.isOfficialBotLoading)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(\.colorScheme) private var colorScheme

    private func qrCodeView(session: PairingSession) -> some View {
        VStack(spacing: 14) {
            if let deepLink = session.deepLink?.trimmingCharacters(in: .whitespacesAndNewlines),
               !deepLink.isEmpty,
               session.status != "expired" {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color(white: 0.18)
                                : Color.white.opacity(0.96)
                        )
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.black.opacity(0.06),
                            lineWidth: 1
                        )
                    qrImage(for: deepLink)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 154, height: 154)
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white)
                        )
                }
                .frame(width: 210, height: 210)
                .shadow(
                    color: colorScheme == .dark
                        ? Color.black.opacity(0.40)
                        : Color.black.opacity(0.08),
                    radius: colorScheme == .dark ? 20 : 14,
                    x: 0,
                    y: 8
                )
                .padding(.top, 8)
            }

            Text(session.status == "expired"
                 ? NSLocalizedString("QR code expired. Generate a fresh one to continue.", comment: "Phi Link - Official bot QR expired hint")
                 : NSLocalizedString("Scan the QR code with your phone camera or click on the button below to add Phi Link bot to your Telegram", comment: "Phi Link - Official bot QR hint"))
                .font(.system(size: 12))
                .themedForeground(.textTertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                if let deepLink = session.deepLink,
                   !deepLink.isEmpty,
                   session.status != "expired",
                   let deepLinkURL = URL(string: deepLink) {
                    Button {
                        NSWorkspace.shared.open(deepLinkURL)
                    } label: {
                        Label(NSLocalizedString("Open in Telegram", comment: "Phi Link - Open official bot link in Telegram"), systemImage: "arrow.up.forward.square")
                            .font(.system(size: 13))
                    }
                    .imPrimaryButtonStyle()
                }

                Button {
                    Task { await vm.refreshQR() }
                } label: {
                    Label(
                        session.status == "expired"
                            ? NSLocalizedString("Relink", comment: "Phi Link - Official bot relink action")
                            : NSLocalizedString("Refresh", comment: "Phi Link - Official bot refresh QR action"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.system(size: 13))
                }
                .imSecondaryButtonStyle()
                .disabled(vm.isOfficialBotLoading)
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var notConnectedView: some View {
        HStack(spacing: 12) {
            Text(String(
                format: NSLocalizedString("Link Telegram to chat with %@.", comment: "Phi Link - Official bot link prompt with agent name"),
                vm.agentName
            ))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .opacity(0.7)
            Spacer(minLength: 8)
            Button {
                Task { await vm.connectOfficialBot() }
            } label: {
                HStack(spacing: 4) {
                    if vm.isOfficialBotLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Label(
                        NSLocalizedString("Link", comment: "Phi Link - Official bot link button"),
                        systemImage: "link.badge.plus"
                    )
                    .font(.system(size: 13))
                }
            }
            .imPrimaryButtonStyle()
            .disabled(vm.isOfficialBotLoading)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serviceIssueView(actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(
                NSLocalizedString(
                    "Retry after Phi Sentinel is running normally.",
                    comment: "IM Channels - Official bot retry hint when service is unavailable"
                )
            )
            .font(.system(size: 13))
            .themedForeground(.textPrimary)
            .opacity(0.7)

            Spacer()

            Button(action: action) {
                Label(actionTitle, systemImage: "arrow.clockwise")
                    .font(.system(size: 13))
            }
            .imSecondaryButtonStyle()
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Custom Bot Section

private struct CustomBotSection: View {
    @Bindable var vm: IMChannelsViewModel

    var body: some View {
        DisclosureGroup(isExpanded: $vm.isCustomBotExpanded) {
            Divider()
            customBotBody
        } label: {
            customBotHeader
        }
        .disclosureGroupStyle(IMDisclosureStyle())
    }

    private var customBotHeader: some View {
        HStack(spacing: 12) {
            TelegramServiceIcon(symbol: "gearshape.fill", tint: Color(red: 0.08, green: 0.52, blue: 0.72))
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Custom Telegram bot", comment: "Phi Link - Custom bot title"))
                    .font(.system(size: 14))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("Setting up your own Telegram bot using Telegram's @BotFather", comment: "Phi Link - Custom bot subtitle"))
                    .font(.system(size: 12))
                    .themedForeground(.textTertiary)
            }
            Spacer(minLength: 8)
            if !vm.hasLoaded || vm.isCustomBotSaving || vm.isVerifying {
                ProgressView()
                    .controlSize(.mini)
            }
            if vm.hasLoaded {
                IMStatusBadge(
                    text: customStatusText,
                    kind: customStatusKind
                )
            }
        }
    }

    @ViewBuilder
    private var customBotBody: some View {
        if !vm.hasLoaded {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 20)
        } else {
            VStack(spacing: 0) {
                if let bot = vm.customBot {
                    configuredView(bot: bot)
                } else {
                    unconfiguredView
                }
            }
        }
    }

    private var customStatusText: String {
        if vm.customBotHasServiceIssue {
            return NSLocalizedString("Service issue", comment: "Phi Link - Custom bot service issue status")
        }
        if vm.customBot?.isRunning == true {
            return NSLocalizedString("Linked", comment: "Phi Link - Custom bot linked status")
        }
        if vm.customBot != nil {
            return NSLocalizedString("Configured", comment: "Phi Link - Custom bot configured status")
        }
        return NSLocalizedString("Not configured", comment: "Phi Link - Custom bot not configured status")
    }

    private var customStatusKind: IMStatusKind {
        if vm.customBotHasServiceIssue {
            return .warning
        }
        if vm.customBot?.isRunning == true {
            return .success
        }
        return .neutral
    }

    private var unconfiguredView: some View {
        VStack(spacing: 0) {
            guideRow
            Divider()
            tokenInputRow

            if let result = vm.verifyResult {
                Divider()
                verificationResultRow(result: result)
            }

            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button {
                    Task { await vm.verifyCustomBot() }
                } label: {
                    HStack(spacing: 4) {
                        if vm.isVerifying {
                            ProgressView().controlSize(.mini)
                        }
                        Label(
                            NSLocalizedString("Verify", comment: "IM Channels - Custom bot verify button"),
                            systemImage: "checkmark.shield"
                        )
                            .font(.system(size: 13))
                    }
                }
                .imSecondaryButtonStyle()
                .disabled(vm.customBotToken.isEmpty || vm.isVerifying || vm.isCustomBotSaving || !vm.isImServerConnected)

                Button {
                    Task { await vm.saveCustomBot() }
                } label: {
                    HStack(spacing: 4) {
                        if vm.isCustomBotSaving {
                            ProgressView().controlSize(.mini)
                        }
                        Label(
                            NSLocalizedString("Save", comment: "IM Channels - Custom bot save button"),
                            systemImage: "checkmark"
                        )
                            .font(.system(size: 13))
                    }
                }
                .imPrimaryButtonStyle()
                .disabled(vm.customBotToken.isEmpty || vm.isCustomBotSaving || !vm.isImServerConnected)
            }
            .padding(.vertical, 12)
        }
    }

    private func configuredView(bot: CustomBotChannel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let username = bot.botUsername {
                        Text("@\(username)")
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                    } else {
                        Text(bot.name)
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(bot.isRunning
                                  ? imSuccessDotColor
                                  : bot.status == "error" ? imErrorColor : imWarningDotColor)
                            .frame(width: 6, height: 6)
                        Text(bot.isRunning
                             ? NSLocalizedString("Linked", comment: "Phi Link - Custom bot linked text")
                             : bot.status == "error"
                                ? (bot.statusMessage ?? NSLocalizedString("Error", comment: "Phi Link - Custom bot generic error text"))
                                : NSLocalizedString("Linking...", comment: "Phi Link - Custom bot linking text"))
                            .font(.system(size: 11))
                            .themedForeground(.textTertiary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 12)

            if let result = vm.verifyResult {
                Divider()
                verificationResultRow(result: result)
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button {
                    Task { await vm.verifyCustomBot() }
                } label: {
                    HStack(spacing: 4) {
                        if vm.isVerifying {
                            ProgressView().controlSize(.mini)
                        }
                        Label(
                            NSLocalizedString("Verify", comment: "IM Channels - Custom bot verify action"),
                            systemImage: "checkmark.shield"
                        )
                            .font(.system(size: 13))
                    }
                }
                .imSecondaryButtonStyle()
                .disabled(vm.isVerifying || vm.isCustomBotSaving || !vm.isImServerConnected)

                Button(role: .destructive) {
                    Task { await vm.removeCustomBot() }
                } label: {
                    HStack(spacing: 4) {
                        if vm.isCustomBotSaving {
                            ProgressView().controlSize(.mini)
                        }
                        Label(
                            NSLocalizedString("Remove", comment: "IM Channels - Custom bot remove action"),
                            systemImage: "trash"
                        )
                            .font(.system(size: 13))
                    }
                }
                .imDestructiveButtonStyle()
                .disabled(vm.isCustomBotSaving || vm.isVerifying || !vm.isImServerConnected)
            }
            .padding(.vertical, 12)
        }
    }

    private var guideRow: some View {
        Text(guideAttributedString)
            .font(.system(size: 12))
            .themedForeground(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                if url.absoluteString == "phi-botfather://open" {
                    openBotFather()
                    return .handled
                }
                return .systemAction
            })
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var guideAttributedString: AttributedString {
        let prefix = NSLocalizedString("Click ", comment: "Phi Link - Custom bot guide prefix")
        let linkText = NSLocalizedString("here to begin the @BotFather", comment: "Phi Link - Custom bot guide link text")
        let suffix = NSLocalizedString(" Telegram bot creation and customization process, follow the on-screen instructions and paste the Bot Token below", comment: "Phi Link - Custom bot guide suffix")

        var result = AttributedString(prefix)
        var link = AttributedString(linkText)
        link.link = URL(string: "phi-botfather://open")
        link.underlineStyle = .single
        result.append(link)
        result.append(AttributedString(suffix))
        return result
    }

    private var tokenInputRow: some View {
        HStack(spacing: 12) {
            Text(NSLocalizedString("Bot Token", comment: "Phi Link - Custom bot token label"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Group {
                    if vm.showTokenPlaintext {
                        TextField("e.g. 123456:ABC-DEF...", text: $vm.customBotToken)
                    } else {
                        SecureField("e.g. 123456:ABC-DEF...", text: $vm.customBotToken)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 280)
                .disabled(!vm.isImServerConnected)
                .onChange(of: vm.customBotToken) {
                    vm.resetVerification()
                }

                Button {
                    vm.showTokenPlaintext.toggle()
                } label: {
                    Label(
                        vm.showTokenPlaintext
                            ? NSLocalizedString("Hide", comment: "Phi Link - Hide token plaintext button")
                            : NSLocalizedString("Show", comment: "Phi Link - Show token plaintext button"),
                        systemImage: vm.showTokenPlaintext ? "eye.slash" : "eye"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                }
                .imSecondaryButtonStyle()
                .disabled(!vm.isImServerConnected)
            }
        }
        .padding(.vertical, 14)
    }

    private func verificationResultRow(result: (success: Bool, error: String?)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? imSuccessColor : imErrorColor)
                .font(.system(size: 13))
            Text(result.success
                 ? NSLocalizedString("Token verified successfully", comment: "IM Channels - Custom bot verify success")
                 : NSLocalizedString("Verification failed. Please check the token and try again.", comment: "IM Channels - Custom bot verify failure"))
                .font(.system(size: 11))
                .foregroundStyle(result.success ? Color.primary : imErrorColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

// MARK: - Reusable Components

private struct IMContainerView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .themedBackground(.settingItemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .themedStroke(.border)
        }
    }
}

private struct IMNoticeBanner: View {
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    private var iconColor: Color {
        colorScheme == .dark
            ? Color(red: 0.96, green: 0.72, blue: 0.30)
            : Color(red: 0.78, green: 0.42, blue: 0.02)
    }

    private var bannerBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.30, green: 0.22, blue: 0.08)
            : Color(red: 0.99, green: 0.96, blue: 0.88)
    }

    private var bannerBorder: Color {
        colorScheme == .dark
            ? Color(red: 0.50, green: 0.38, blue: 0.16)
            : Color(red: 0.94, green: 0.83, blue: 0.56)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 12))
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(bannerBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(bannerBorder, lineWidth: 1)
        }
    }
}

private enum IMStatusKind {
    case success
    case neutral
    case warning

    func foregroundColor(for scheme: ColorScheme) -> Color {
        switch self {
        case .success:
            return scheme == .dark
                ? Color(red: 0.40, green: 0.90, blue: 0.58)
                : Color(red: 0.004, green: 0.4, blue: 0.19)
        case .neutral:
            return Color.secondary
        case .warning:
            return scheme == .dark
                ? Color(red: 0.96, green: 0.72, blue: 0.30)
                : Color(red: 0.62, green: 0.34, blue: 0.02)
        }
    }

    func backgroundColor(for scheme: ColorScheme) -> Color {
        switch self {
        case .success:
            return scheme == .dark
                ? Color(red: 0.08, green: 0.24, blue: 0.14)
                : Color(red: 0.86, green: 0.99, blue: 0.91)
        case .neutral:
            return Color.secondary.opacity(0.08)
        case .warning:
            return scheme == .dark
                ? Color(red: 0.30, green: 0.22, blue: 0.08)
                : Color(red: 1.0, green: 0.95, blue: 0.86)
        }
    }
}

private struct IMStatusBadge: View {
    let text: String
    let kind: IMStatusKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(kind.foregroundColor(for: colorScheme))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(kind.foregroundColor(for: colorScheme))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(kind.backgroundColor(for: colorScheme))
        )
    }
}

private struct TelegramServiceIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct IMDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .themedForeground(.textTertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 12)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private let imSecondaryTint = ThemedColor(
    light: NSColor(hex: 0x3AA4D5),
    dark: NSColor(hex: 0x4CBAE0)
)

private let imDestructiveTint = ThemedColor(
    light: NSColor(hex: 0xDC3545),
    dark: NSColor(hex: 0xFF6B6B)
)

private extension View {
    func imPrimaryButtonStyle() -> some View {
        buttonStyle(.bordered)
            .controlSize(.small)
            .themedTint(imSecondaryTint)
    }

    func imSecondaryButtonStyle() -> some View {
        buttonStyle(.bordered)
            .controlSize(.small)
            .themedTint(imSecondaryTint)
    }

    func imDestructiveButtonStyle() -> some View {
        buttonStyle(.bordered)
            .controlSize(.small)
            .themedTint(imDestructiveTint)
    }
}

// MARK: - QR Code Generator

private func qrImage(for string: String) -> Image {
    let data = Data(string.utf8)
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")

    guard let ciImage = filter.outputImage else {
        return Image(systemName: "qrcode")
    }

    let transform = CGAffineTransform(scaleX: 10, y: 10)
    let scaled = ciImage.transformed(by: transform)

    let rep = NSCIImageRep(ciImage: scaled)
    let nsImage = NSImage(size: rep.size)
    nsImage.addRepresentation(rep)

    return Image(nsImage: nsImage)
}

// MARK: - Dark Mode Adaptive Colors

private let imSuccessDotColor = Color(
    nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.40, green: 0.90, blue: 0.58, alpha: 1)
            : NSColor(red: 0.004, green: 0.4, blue: 0.19, alpha: 1)
    }
)

private let imErrorColor = Color(
    nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1)
            : NSColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)
    }
)

private let imSuccessColor = Color(
    nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.40, green: 0.90, blue: 0.58, alpha: 1)
            : NSColor(red: 0.20, green: 0.70, blue: 0.35, alpha: 1)
    }
)

private let imWarningDotColor = Color(
    nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.96, green: 0.72, blue: 0.30, alpha: 1)
            : NSColor(red: 0.90, green: 0.60, blue: 0.0, alpha: 1)
    }
)

private func openBotFather() {
    if let telegramURL = URL(string: "tg://resolve?domain=BotFather"),
       NSWorkspace.shared.open(telegramURL) {
        return
    }

    if let webURL = URL(string: "https://t.me/BotFather") {
        NSWorkspace.shared.open(webURL)
    }
}

#Preview {
    IMChannelsSettingView()
}
