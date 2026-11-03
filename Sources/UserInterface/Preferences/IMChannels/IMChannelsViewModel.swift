// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@MainActor
@Observable
final class IMChannelsViewModel {
    // MARK: - Official Bot State

    var pairing: ChannelPairing?
    var isOfficialBotLoading = false
    var officialBotErrorMessage: String?

    var officialBotDisplayName: String {
        guard let p = pairing else { return "" }
        return p.platformName ?? p.platformUsername ?? p.platformUserId
    }

    // MARK: - Custom Bot State

    var customBot: CustomBotChannel?
    var isImServerConnected = false
    var customBotToken = ""
    var isCustomBotSaving = false
    var isCustomBotLinking = false
    var isCustomBotExpanded = true
    var showTokenPlaintext = false
    var verifyResult: (success: Bool, error: String?)?
    var isVerifying = false
    var customBotErrorMessage: String?

    var customBotServiceIssueMessage: String? {
        if let customBotErrorMessage {
            return customBotErrorMessage
        }
        if hasLoaded && !isImServerConnected {
            return NSLocalizedString("settings.phiLink.serviceUnavailableMessage", value: "The local IM service is unavailable. Check whether Phi Sentinel started normally and the IM service is running.",
                comment: "IM Channels - Message shown when im-server is not connected"
            )
        }
        return nil
    }

    var customBotHasServiceIssue: Bool {
        customBotServiceIssueMessage != nil
    }

    // MARK: - Agent Persona

    var agentName: String = "Phi"

    // MARK: - Shared State

    var hasLoaded = false

    var topNoticeMessages: [String] {
        var messages: [String] = []
        for message in [pairing == nil ? officialBotErrorMessage : nil, customBotServiceIssueMessage].compactMap({ $0 }) {
            if !messages.contains(message) {
                messages.append(message)
            }
        }
        return messages
    }

    private let api = IMChannelAPIClient.shared
    private var pairingLoadGeneration = 0

    // MARK: - Load All

    func loadAll() async {
        guard ApplicationState.shared.isAuthenticated else { return }
        AppLogDebug("[IMChannels] loadAll started")
        await MainActor.run {
            officialBotErrorMessage = nil
            customBotErrorMessage = nil
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadPairings() }
            group.addTask { await self.loadCustomBot() }
            group.addTask { await self.loadAgentPersona() }
        }
        guard ApplicationState.shared.isAuthenticated else { return }
        await MainActor.run { hasLoaded = true }
        AppLogDebug("[IMChannels] loadAll finished — pairing: \(pairing?.id ?? "nil"), customBot: \(customBot?.id ?? "nil")")
    }

    // MARK: - Agent Persona

    private func loadAgentPersona() async {
        guard ApplicationState.shared.isAuthenticated else { return }
        do {
            let response = try await api.fetchAgentPersona()
            guard ApplicationState.shared.isAuthenticated else { return }
            let name = response.variables?.name ?? "Phi"
            await MainActor.run {
                self.agentName = name
            }
        } catch {
            AppLogDebug("[IMChannels] loadAgentPersona failed: \(error), using default name")
        }
    }

    // MARK: - Official Bot

    func loadPairings() async {
        guard ApplicationState.shared.isAuthenticated, !isOfficialBotLoading else { return }
        pairingLoadGeneration += 1
        let generation = pairingLoadGeneration
        do {
            let pairings = try await api.listPairings()
            guard ApplicationState.shared.isAuthenticated,
                  generation == pairingLoadGeneration else { return }
            let found = pairings.first { $0.platform == "telegram" }
            self.pairing = found
            self.officialBotErrorMessage = nil
            AppLogDebug("[IMChannels] loadPairings — found: \(found?.id ?? "nil"), localStatus: \(found?.localStatus ?? "nil")")
        } catch {
            AppLogDebug("[IMChannels] loadPairings failed: \(error)")
            guard ApplicationState.shared.isAuthenticated,
                  generation == pairingLoadGeneration else { return }
            officialBotErrorMessage = officialBotServiceErrorMessage(for: error)
        }
    }

    func refreshAll() async {
        guard ApplicationState.shared.isAuthenticated else { return }
        await MainActor.run {
            officialBotErrorMessage = nil
            customBotErrorMessage = nil
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadPairings() }
            group.addTask { await self.loadCustomBot() }
        }
    }

    func disconnectOfficialBot() async {
        guard ApplicationState.shared.isAuthenticated,
              !isOfficialBotLoading, let pairing else { return }
        pairingLoadGeneration += 1
        isOfficialBotLoading = true
        officialBotErrorMessage = nil
        defer { isOfficialBotLoading = false }

        do {
            try await api.disconnectPairing(id: pairing.id)
            self.pairing = nil
        } catch {
            officialBotErrorMessage = officialBotServiceErrorMessage(for: error)
        }
    }

    // MARK: - Custom Bot

    func loadCustomBot() async {
        guard ApplicationState.shared.isAuthenticated else { return }
        do {
            let response = try await api.listCustomBotChannels()
            guard ApplicationState.shared.isAuthenticated else { return }
            await MainActor.run {
                isImServerConnected = response.connected
                customBot = response.channels.first { $0.channelType == "telegram" }
                customBotErrorMessage = nil
            }
        } catch {
            await MainActor.run {
                isImServerConnected = false
                customBotErrorMessage = customBotServiceErrorMessage(for: error)
            }
        }
    }

    func saveCustomBot() async {
        guard ApplicationState.shared.isAuthenticated, !isCustomBotSaving, !isVerifying, !isCustomBotLinking else { return }
        let token = customBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        await MainActor.run {
            isCustomBotSaving = true
            customBotErrorMessage = nil
        }

        if !isVerified {
            await verifyCustomBot()
            guard isVerified else {
                await MainActor.run { isCustomBotSaving = false }
                return
            }
        }

        do {
            let channel: CustomBotChannel
            if let existing = customBot {
                channel = try await api.updateCustomBotChannel(
                    id: existing.id,
                    enabled: true,
                    botToken: token
                )
            } else {
                channel = try await api.createCustomBotChannel(
                    botToken: token,
                    enabled: true
                )
            }
            await MainActor.run {
                customBot = channel
                customBotToken = ""
                verifyResult = nil
                customBotErrorMessage = nil
                isCustomBotSaving = false
            }
        } catch {
            await MainActor.run {
                customBotErrorMessage = customBotServiceErrorMessage(for: error)
                isCustomBotSaving = false
            }
        }
    }

    var isVerified: Bool {
        verifyResult?.success == true
    }

    func resetVerification() {
        verifyResult = nil
    }

    func verifyCustomBot() async {
        guard ApplicationState.shared.isAuthenticated else { return }
        let token = customBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = customBot?.id

        guard !token.isEmpty || channelId != nil else { return }

        await MainActor.run {
            isVerifying = true
            verifyResult = nil
            customBotErrorMessage = nil
        }
        do {
            let result = try await api.verifyBotToken(
                botToken: token.isEmpty ? nil : token,
                channelId: channelId
            )
            await MainActor.run {
                verifyResult = result
                isVerifying = false
            }
        } catch {
            AppLogDebug("[IMChannels] verifyCustomBot failed: \(error)")
            await MainActor.run {
                verifyResult = (success: false, error: nil)
                isVerifying = false
            }
        }
    }

    func prepareCustomBotLink() async -> URL? {
        guard ApplicationState.shared.isAuthenticated, !isCustomBotLinking,
              !isCustomBotSaving, let bot = customBot, !bot.isLinked else { return nil }
        isCustomBotLinking = true
        customBotErrorMessage = nil
        defer { isCustomBotLinking = false }
        do {
            let response = try await api.prepareCustomBotPairing(id: bot.id)
            guard ApplicationState.shared.isAuthenticated, customBot?.id == bot.id else { return nil }
            guard response.expiresAt > Date().timeIntervalSince1970 * 1000,
                  let url = URL(string: response.deepLink), url.scheme == "https", url.host == "t.me" else {
                throw IMChannelAPIError.invalidResponse
            }
            return url
        } catch {
            customBotErrorMessage = customBotServiceErrorMessage(for: error)
            return nil
        }
    }

    func removeCustomBot() async {
        guard ApplicationState.shared.isAuthenticated, !isCustomBotSaving, !isCustomBotLinking else { return }
        guard let existing = customBot else { return }
        await MainActor.run {
            isCustomBotSaving = true
            customBotErrorMessage = nil
            verifyResult = nil
        }
        do {
            try await api.deleteCustomBotChannel(id: existing.id)
            await MainActor.run {
                customBot = nil
                customBotToken = ""
                customBotErrorMessage = nil
                isCustomBotSaving = false
            }
        } catch {
            await MainActor.run {
                customBotErrorMessage = customBotServiceErrorMessage(for: error)
                isCustomBotSaving = false
            }
        }
    }

    // MARK: - Error Messages

    private func officialBotServiceErrorMessage(for error: Error) -> String {
        serviceErrorMessage(
            for: error,
            fallback: NSLocalizedString("settings.phiLink.officialBot.serviceUnavailableMessage", value: "Phi Sentinel service is unavailable. Check whether it started normally.",
                comment: "IM Channels - Official bot service unavailable message"
            )
        )
    }

    private func customBotServiceErrorMessage(for error: Error) -> String {
        serviceErrorMessage(
            for: error,
            fallback: NSLocalizedString("settings.phiLink.customBot.serviceUnavailableMessage", value: "Phi Sentinel service is unavailable. Check whether it started normally.",
                comment: "IM Channels - Custom bot service unavailable message"
            )
        )
    }

    private func serviceErrorMessage(for error: Error, fallback: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return fallback
            default:
                return urlError.localizedDescription
            }
        }

        if let transportError = error as? PhiAgentTransportError {
            switch transportError {
            case .accountUnavailable:
                return sessionExpiredMessage
            case .unreachable, .invalidResponse:
                return fallback
            }
        }

        if let apiError = error as? IMChannelAPIError {
            switch apiError {
            case .invalidResponse:
                return fallback
            case .unauthorized:
                return sessionExpiredMessage
            case .httpError(let statusCode):
                if statusCode >= 500 {
                    return fallback
                }
            }
        }

        return error.localizedDescription
    }

    private var sessionExpiredMessage: String {
        NSLocalizedString("settings.phiLink.sessionExpiredMessage", value: "Your Phi session has expired. Please sign in again, then retry Phi Link.",
            comment: "Phi Link - Message shown when phi-agent returns 401 unauthorized"
        )
    }
}
