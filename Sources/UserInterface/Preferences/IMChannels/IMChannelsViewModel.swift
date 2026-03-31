// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@Observable
final class IMChannelsViewModel {
    // MARK: - Official Bot State

    var pairing: ChannelPairing?
    var activeSession: PairingSession?
    var isOfficialBotLoading = false
    var isOfficialBotExpanded = true
    var officialBotErrorMessage: String?

    var officialBotNeedsReconnect: Bool {
        pairing?.localStatus == "needs_reconnect"
    }

    var officialBotHasServiceIssue: Bool {
        officialBotErrorMessage != nil
    }

    var officialBotDisplayName: String {
        guard let p = pairing else { return "" }
        return p.platformName ?? p.platformUsername ?? p.platformUserId
    }

    /// Mirrors Sidebar's `showPendingSession`:
    /// show QR only when there IS an active session AND there is NO valid pairing.
    var showPendingSession: Bool {
        guard let session = activeSession else { return false }
        let isPendingOrExpired = session.status == "pending" || session.status == "expired"
        let hasValidPairing = pairing != nil && !officialBotNeedsReconnect
        return isPendingOrExpired && !hasValidPairing
    }

    // MARK: - Custom Bot State

    var customBot: CustomBotChannel?
    var isImServerConnected = false
    var customBotToken = ""
    var isCustomBotSaving = false
    var isCustomBotExpanded = false
    var showTokenPlaintext = false
    var verifyResult: (success: Bool, error: String?)?
    var isVerifying = false
    var customBotErrorMessage: String?

    var customBotServiceIssueMessage: String? {
        if let customBotErrorMessage {
            return customBotErrorMessage
        }
        if hasLoaded && !isImServerConnected {
            return NSLocalizedString(
                "The local IM service is unavailable. Check whether Phi Sentinel started normally and the IM service is running.",
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
        for message in [officialBotErrorMessage, customBotServiceIssueMessage].compactMap({ $0 }) {
            if !messages.contains(message) {
                messages.append(message)
            }
        }
        return messages
    }

    private let api = IMChannelAPIClient.shared
    private var pollingTimer: Timer?

    // MARK: - Load All

    func loadAll() async {
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
        await MainActor.run { hasLoaded = true }
        AppLogDebug("[IMChannels] loadAll finished — pairing: \(pairing?.id ?? "nil"), customBot: \(customBot?.id ?? "nil")")
    }

    // MARK: - Agent Persona

    private func loadAgentPersona() async {
        do {
            let response = try await api.fetchAgentPersona()
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
        do {
            let pairings = try await api.listPairings()
            await MainActor.run {
                let found = pairings.first { $0.platform == "telegram" }
                self.pairing = found
                self.officialBotErrorMessage = nil
                AppLogDebug("[IMChannels] loadPairings — found: \(found?.id ?? "nil"), localStatus: \(found?.localStatus ?? "nil")")
            }
        } catch {
            AppLogDebug("[IMChannels] loadPairings failed: \(error)")
            await MainActor.run {
                officialBotErrorMessage = officialBotServiceErrorMessage(for: error)
            }
        }
    }

    func refreshAll() async {
        await MainActor.run {
            officialBotErrorMessage = nil
            customBotErrorMessage = nil
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadPairings() }
            group.addTask { await self.loadCustomBot() }
        }
    }

    func connectOfficialBot() async {
        AppLogDebug("[IMChannels] connectOfficialBot called")
        await MainActor.run {
            isOfficialBotLoading = true
            officialBotErrorMessage = nil
        }
        do {
            let response = try await api.prepareTelegram()
            AppLogDebug("[IMChannels] prepareTelegram success — sessionId: \(response.pairing.sessionId), deepLink: \(response.pairing.deepLink ?? "nil")")
            await MainActor.run {
                activeSession = response.pairing
                officialBotErrorMessage = nil
                isOfficialBotLoading = false
            }
            startPolling(sessionId: response.pairing.sessionId)
        } catch {
            AppLogDebug("[IMChannels] connectOfficialBot FAILED: \(error)")
            await MainActor.run {
                officialBotErrorMessage = officialBotServiceErrorMessage(for: error)
                isOfficialBotLoading = false
            }
        }
    }

    func disconnectOfficialBot() async {
        guard let p = pairing else { return }
        AppLogDebug("[IMChannels] disconnectOfficialBot — pairingId: \(p.id)")

        await MainActor.run {
            isOfficialBotLoading = true
            officialBotErrorMessage = nil
            pairing = nil
            activeSession = nil
        }

        do {
            try await api.disconnectPairing(id: p.id)
            AppLogDebug("[IMChannels] disconnectPairing success")
            await loadPairings()
            await MainActor.run {
                isOfficialBotLoading = false
            }
        } catch {
            AppLogDebug("[IMChannels] disconnectOfficialBot FAILED: \(error)")
            await MainActor.run {
                officialBotErrorMessage = officialBotServiceErrorMessage(for: error)
                isOfficialBotLoading = false
            }
        }
    }

    func refreshQR() async {
        await stopPolling()
        await connectOfficialBot()
    }

    // MARK: - Official Bot Polling

    private func startPolling(sessionId: String) {
        Task { @MainActor in
            self.doStopPolling()
            AppLogDebug("[IMChannels] polling started — sessionId: \(sessionId)")
            let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { await self.pollPairingStatus(sessionId: sessionId) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.pollingTimer = timer
        }
    }

    func stopPolling() async {
        await MainActor.run { doStopPolling() }
    }

    @MainActor
    private func doStopPolling() {
        if pollingTimer != nil {
            AppLogDebug("[IMChannels] polling stopped")
        }
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func pollPairingStatus(sessionId: String) async {
        do {
            let session = try await api.getPairingStatus(sessionId: sessionId)
            AppLogDebug("[IMChannels] poll — status: \(session.status)")

            if session.status == "paired" {
                await stopPolling()
                await loadPairings()
                await MainActor.run {
                    activeSession = nil
                    officialBotErrorMessage = nil
                }
                AppLogDebug("[IMChannels] pairing complete — UI should show connected")
            } else if session.status == "expired" {
                await stopPolling()
                await MainActor.run {
                    activeSession = session
                }
            } else {
                await MainActor.run {
                    let existingDeepLink = activeSession?.deepLink
                    var merged = session
                    if merged.deepLink == nil || merged.deepLink?.isEmpty == true {
                        merged = PairingSession(
                            sessionId: session.sessionId,
                            deepLink: existingDeepLink,
                            expiresAt: session.expiresAt,
                            status: session.status,
                            pairedAt: session.pairedAt,
                            platform: session.platform,
                            platformUserId: session.platformUserId,
                            platformUsername: session.platformUsername,
                            platformName: session.platformName
                        )
                    }
                    activeSession = merged
                }
            }
        } catch {
            AppLogDebug("[IMChannels] polling failed: \(error)")
            await MainActor.run {
                officialBotErrorMessage = officialBotServiceErrorMessage(for: error)
            }
        }
    }

    // MARK: - Custom Bot

    func loadCustomBot() async {
        do {
            let response = try await api.listCustomBotChannels()
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

    func removeCustomBot() async {
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
            fallback: NSLocalizedString(
                "Phi Sentinel service is unavailable. Check whether it started normally.",
                comment: "IM Channels - Official bot service unavailable message"
            )
        )
    }

    private func customBotServiceErrorMessage(for error: Error) -> String {
        serviceErrorMessage(
            for: error,
            fallback: NSLocalizedString(
                "Phi Sentinel service is unavailable. Check whether it started normally.",
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

        if let apiError = error as? IMChannelAPIError {
            switch apiError {
            case .invalidResponse:
                return fallback
            case .httpError(let statusCode):
                if statusCode >= 500 {
                    return fallback
                }
            }
        }

        return error.localizedDescription
    }
}
