// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Auth0
import WebKit
import JWTDecode
import PostHog
import Security

struct AccountDeletionCredentialFence {
    private static let markerSuffix = ".phi-account-deletion-credentials.pending"

    let markerURL: URL

    static var currentProduct: AccountDeletionCredentialFence {
        let dataRoot = URL(
            fileURLWithPath: FileSystemUtils.applicationSupportDirctory(),
            isDirectory: true
        )
        return AccountDeletionCredentialFence(
            markerURL: dataRoot.deletingLastPathComponent().appendingPathComponent(
                dataRoot.lastPathComponent + markerSuffix,
                isDirectory: false
            )
        )
    }

    var isActive: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    func activate() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("account-deletion-v1".utf8).write(to: markerURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func deactivate() -> Bool {
        do {
            if isActive {
                try FileManager.default.removeItem(at: markerURL)
            }
            return !isActive
        } catch {
            return false
        }
    }
}

final class AuthFailureTraceBuffer {
    private struct Entry {
        let timestamp: Date
        let event: String
        let details: [String: String]
        let fileID: String
        let function: String
        let line: Int
        let callStackSymbols: [String]
    }

    private let capacity: Int
    private let dateProvider: () -> Date
    private let queue = DispatchQueue(label: "com.phi.auth.failure-trace")
    private var entries: [Entry] = []
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(capacity: Int = 40, dateProvider: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.dateProvider = dateProvider
    }

    func record(
        _ event: String,
        details: [String: String] = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: Int = #line,
        callStackSymbols: [String] = []
    ) {
        let entry = Entry(
            timestamp: dateProvider(),
            event: event,
            details: details,
            fileID: fileID,
            function: function,
            line: line,
            callStackSymbols: callStackSymbols
        )

        queue.sync {
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
            AppLogInfo("[AuthTrace] \(formatLocalLogLine(entry))")
        }
    }

    func renderedTrace() -> String {
        queue.sync {
            guard !entries.isEmpty else {
                return "Auth trace is empty."
            }

            return entries.map(formatTraceLine).joined(separator: "\n")
        }
    }

    private func formatLocalLogLine(_ entry: Entry) -> String {
        var line = entry.event
        let sortedDetails = entry.details
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        if !sortedDetails.isEmpty {
            line += " | \(sortedDetails)"
        }
        return line
    }

    private func formatTraceLine(_ entry: Entry) -> String {
        var line = "\(formatter.string(from: entry.timestamp)) | \(entry.event)"
        let sortedDetails = entry.details
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        if !sortedDetails.isEmpty {
            line += " | \(sortedDetails)"
        }
        line += " | \(entry.fileID):\(entry.line) | \(entry.function)"
        if !entry.callStackSymbols.isEmpty {
            line += "\n    stack:\n    \(entry.callStackSymbols.joined(separator: "\n    "))"
        }
        return line
    }
}

class AuthManager {
    static let shared = AuthManager()
    private(set) var currentCredentials: Credentials?

    private let accountDeletionStateLock = NSLock()
    private var accountDeletionInProgress = false
    private var accountDeletionReplacementLoginToken: UUID?
    private var accountDeletionHoldsSharedTokenLock = false
    private let accountDeletionCredentialFence = AccountDeletionCredentialFence.currentProduct
    private var accountDeletionFenceAwaitingExplicitLogin = false

    var isAccountDeletionInProgress: Bool {
        accountDeletionStateLock.lock()
        defer { accountDeletionStateLock.unlock() }
        return accountDeletionInProgress
    }
    
    let browserAuthCallbackQueue = DispatchQueue(label: "com.phi.auth.browser-callback")
    var pendingBrowserAuthCallback: ((URL) -> Void)?
    var pendingBrowserAuthCallbackToken: UUID?
    var pendingBrowserAuthCallbackReplacementLoginToken: UUID?

    private lazy var authURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    
    private var credentialStoreKey: String {
        let storeKey: String
        #if DEBUG
        if Self.useStagingAuth0 {
            storeKey = "credentials-nightly"
        } else {
            storeKey = "credentials"
        }
        #elseif NIGHTLY_BUILD
        storeKey = "credentials-nightly"
        #else
        // Keep the release key stable so existing users do not lose cached credentials.
        storeKey = "credentials"
        #endif
        return storeKey
    }

    private lazy var credentialManager: CredentialsManager =  {
        // Keep Auth0's automatic retry window short. With rotating refresh tokens, a
        // missed successful response leaves the client holding the previous RT; delayed
        // retries can then exceed Auth0's overlap period and destroy the token family.
        return CredentialsManager(
            authentication: Auth0.authentication(clientId: clicentId, domain: domain, session: authURLSession),
            storeKey: credentialStoreKey,
            maxRetries: 1
        )
    }()
    
    // Renew throttling: check hourly, but only exchange the refresh token when the
    // access token is close to expiry.
    // `lastRenewAttemptAt` is bumped on success, business failures, and timeouts so
    // the failure trace can explain the most recent exchange attempt. Transient
    // network failures are intentionally NOT recorded here: doing so would make a
    // missed-response retry look like a deliberate successful sync point.
    private var lastRenewAttemptAt: Date?
    // `lastSuccessfulSyncAt` is only bumped when local credentials are known to be in sync
    // with the shared store (successful renew, or successful import from the shared store).
    // It MUST be the basis for the `shared_token_not_newer` short-circuit in
    // `performSharedStoreRecovery`; using `lastRenewAttemptAt` there would cause Phi to
    // skip importing a fresher Sentinel-written token after Phi had a recent failed renew,
    // which leaves the local Auth0 SDK with a rotated (stale) refresh token.
    private var lastSuccessfulSyncAt: Date?
    private var auth0RefreshConfig: ResolvedAuth0RefreshConfig {
        ExperimentConfigProvider.live.resolveAuth0RefreshConfig(.auth0RefreshTimingExperiment)
    }
    private var renewCooldown: TimeInterval {
        TimeInterval(auth0RefreshConfig.checkInterval)
    }
    private var renewUrgentWindow: TimeInterval {
        TimeInterval(auth0RefreshConfig.urgentWindow)
    }

    private var isRenewing = false
    private let failureTrace = AuthFailureTraceBuffer()
    var reauthenticationState: AuthReauthenticationState = .normal {
        didSet {
            guard oldValue != reauthenticationState else { return }
            NotificationCenter.default.post(name: .authReauthenticationStateDidChange, object: nil)
        }
    }
    var isPresentingReauthenticationPrompt = false
    var hasPersistedReauthenticationState = false

    // Periodic renew timer: checks whether credentials are close enough to expiry to renew.
    private var renewTimer: Timer?
    private var renewTimerInterval: TimeInterval?
    private var heartbeatTimer: DispatchSourceTimer?
    
    #if DEBUG
    /// DEBUG builds can switch both Auth0 config and API base URL to staging.
    static let useStagingAuth0 = true
    #elseif NIGHTLY_BUILD
    static let useStagingAuth0 = true
    #else
    static let useStagingAuth0 = false
    #endif
    
    let (domain, clicentId, audience) : (String, String, String) = {
        #if DEBUG
        if useStagingAuth0 {
            // use satage auth0 config
            return (
                "auth.stag.phibrowser.com",
                "360ZYEcp1T2AexR9rzoUkIn0VTVWc0pv",
                "https://phibrowser-stag.us.auth0.com/api/v2/"
            )
        } else {
            // prod
            return (
                "auth.phibrowser.com",
                "jrFgfm2FA8DoPBzs4ysOePZKwFCcDbo4",
                "https://phibrowser.us.auth0.com/api/v2/"
            )
        }
        #else
        guard let path = Bundle.main.path(forResource: "Auth0", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let domain = dict["Domain"] as? String,
              let clientId = dict["ClientId"] as? String,
              let audience = dict["Audience"] as? String
        else {
            fatalError("Missing 'Domain' or 'Audience' in Auth0.plist")
        }
        return (domain, clientId, audience)
        #endif
    }()

    init() {
        guard accountDeletionCredentialFence.isActive else {
            return
        }

        setAccountDeletionInProgress(true)
        accountDeletionFenceAwaitingExplicitLogin = true
        let storesCleared = clearCredentialStores(postSharedTokenChange: true)
        if storesCleared {
            AppLogInfo(
                "[AccountDeletion] Cleared fenced credentials; automatic session recovery remains blocked until explicit login"
            )
        } else {
            AppLogError("[AccountDeletion] Startup credential recovery failed; login remains fenced")
        }
    }

    @MainActor
    func login() async -> Result<Credentials, Error> {
        let isReplacingDeletedAccount = isAccountDeletionInProgress
            && accountDeletionFenceAwaitingExplicitLogin
        guard !isAccountDeletionInProgress || isReplacingDeletedAccount else {
            return .failure(CancellationError())
        }
        let replacementLoginToken = isReplacingDeletedAccount ? UUID() : nil
        if let replacementLoginToken {
            setAccountDeletionReplacementLoginToken(replacementLoginToken)
        }
        defer {
            if let replacementLoginToken {
                clearAccountDeletionReplacementLoginToken(replacementLoginToken)
            }
        }
        recordTrace("login-started")
        do {
            // Browser URL scheme handling conflicts with AuthenticationServices, so login runs
            // in the default browser and resumes through the callback URL.
            let results = try await Auth0.webAuth(clientId: clicentId, domain: domain)
                .audience(audience)
                .scope("openid profile email offline_access")
                .provider(
                    makeExternalBrowserAuthProvider(
                        accountDeletionReplacementLoginToken: replacementLoginToken
                    )
                )
                .start()

            let holdsDeletionRecoveryLock: Bool
            if isReplacingDeletedAccount {
                // Sentinel can have one pre-deletion renewal still waiting on
                // Auth0. Serialize the replacement login behind that writer,
                // clear its result, then install the new account while still
                // holding the cross-process lock.
                holdsDeletionRecoveryLock = await acquireSharedLock(timeout: 50)
                guard holdsDeletionRecoveryLock else {
                    recordTrace("login-blocked-account-deletion-lock-timeout")
                    return .failure(CancellationError())
                }
            } else {
                holdsDeletionRecoveryLock = false
            }
            defer {
                if holdsDeletionRecoveryLock {
                    SharedTokenLock.shared.unlock()
                }
            }

            if isReplacingDeletedAccount {
                guard clearLocalAccountData(postSharedTokenChange: false),
                      accountDeletionCredentialFence.deactivate() else {
                    AppLogError(
                        "[AccountDeletion] Could not release the credential fence for explicit login"
                    )
                    return .failure(CancellationError())
                }
                accountDeletionFenceAwaitingExplicitLogin = false
                setAccountDeletionInProgress(false)
            }

            guard !isAccountDeletionInProgress else {
                _ = clearCredentialStores(postSharedTokenChange: false)
                return .failure(CancellationError())
            }
            guard storeCredentialsIfAllowed(results) else {
                _ = clearCredentialStores(postSharedTokenChange: false)
                return .failure(CancellationError())
            }
            self.currentCredentials = results
            self.lastRenewAttemptAt = Date()
            self.reauthenticationState = .normal
            self.clearPersistedReauthenticationState()
            // Bump `lastSuccessfulSyncAt` only when shared store actually accepted
            // the new credentials. Otherwise launch-time recovery would think the
            // shared store is in sync with us and skip importing a token written
            // out-of-process while the keychain write was failing.
            if syncSharedTokens(results) {
                self.lastSuccessfulSyncAt = Date()
            }
            startRenewTimer()
            startHeartbeat()
            writeSharedAuth0Config()
            recordTrace("login-succeeded", details: credentialSnapshotDetails())
            return .success(results)
        } catch {
            recordTrace("login-failed", details: ["error": error.localizedDescription])
            AppLogError("login with auth0 failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
    
    /// Outcome of the network half of a logout.
    enum RemoteWebSessionClearOutcome {
        case cleared
        /// The logout page never ran at all; whether that abandons the logout
        /// is the caller's decision. Three ways to get here: the settings pane
        /// cancelled the transaction (its window was closed — an abandonment —
        /// or its wait timed out, which the pane compensates by finishing the
        /// logout locally: with the external-browser flow an unreachable Auth0
        /// never surfaces as an error here, it simply never calls back), the
        /// external browser could not be launched, or another Web Auth
        /// transaction holds Auth0's process-wide barrier.
        ///
        /// A failure to launch the browser is a genuine failure rather than an
        /// abandoned attempt, and it is deliberately treated the same: nothing
        /// was cleared remotely and nothing is in flight, so the honest answer
        /// is to abort and let the settings pane report it.
        ///
        /// The barrier case is why this is not merely "no worse than doing
        /// nothing": the transaction still holding the barrier is a login or a
        /// reauthentication, and its callback stores credentials and rebuilds
        /// the account. Clearing local state underneath it would be undone the
        /// moment the user finishes in the browser.
        case notPerformed
        /// The call failed. No local state was touched.
        case failed
    }

    /// Tears down the Auth0 web session. This is the only network-dependent
    /// half of a logout: it opens the logout URL in the external browser and
    /// waits for the callback, so it can fail, stall, or be cancelled. It
    /// touches no local state, which is cleared separately by
    /// `clearLocalAccountData()`.
    func clearRemoteWebSession() async -> RemoteWebSessionClearOutcome {
        do {
            // Google does not support the federated logout flow we want here, so keep it disabled
            // and clear local web state instead.
            try await Auth0
                .webAuth(clientId: clicentId, domain: domain)
                .provider(makeExternalBrowserAuthProvider())
                .clearSession(federated: false)
            return .cleared
        } catch WebAuthError.userCancelled {
            recordTrace("remote-web-session-clear-cancelled")
            return .notPerformed
        } catch WebAuthError.transactionActiveAlready {
            recordTrace("remote-web-session-clear-blocked-by-active-transaction")
            AppLogWarn("clearing the auth0 web session was blocked by an active web auth transaction")
            return .notPerformed
        } catch {
            recordTrace("remote-web-session-clear-failed", details: ["error": error.localizedDescription])
            AppLogError("clearing the auth0 web session failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Starts the irreversible local-auth half of account deletion by
    /// freezing credential writers and persisting the durable fence. The
    /// caller posts the signed event synchronously after this returns, while
    /// the account identity is still present, then performs the silent clear.
    @MainActor
    func beginAccountDeletionFinalization() -> Bool {
        setAccountDeletionInProgress(true)
        clearAccountDeletionReplacementLoginToken()
        guard SharedTokenLock.shared.lockWithTimeout(5) else {
            AppLogError("[AccountDeletion] Failed to acquire the shared-token lock")
            return false
        }
        let fenceActivated = accountDeletionCredentialFence.activate()
        guard fenceActivated else {
            SharedTokenLock.shared.unlock()
            AppLogError("[AccountDeletion] Failed to persist the credential fence")
            return false
        }
        accountDeletionHoldsSharedTokenLock = true
        return true
    }

    /// Cancels in-process writers and performs the first credential clear
    /// immediately after the signed deletion event has been posted.
    @MainActor
    func clearInitialAccountDeletionCredentials() async {
        cancelOngoingWebAuthentication()
        if isRenewing {
            authURLSession.invalidateAndCancel()
        }

        let holdsSharedLock: Bool
        if accountDeletionHoldsSharedTokenLock {
            holdsSharedLock = true
        } else {
            // Defense in depth for direct callers that did not run the
            // coordinator's fenced preflight.
            holdsSharedLock = await acquireSharedLock(timeout: 5)
        }
        defer {
            if holdsSharedLock {
                SharedTokenLock.shared.unlock()
            }
            accountDeletionHoldsSharedTokenLock = false
        }
        let storesCleared = clearLocalAccountData(postSharedTokenChange: false)
        if !storesCleared {
            AppLogError("[AccountDeletion] Initial credential clear failed")
        }
    }

    /// Clears every piece of local account state: the stored credentials, the
    /// cross-process token store, the cached account identity (profile, avatar
    /// bytes, current account reference) and the timers that assume a live
    /// session.
    ///
    /// Nothing here depends on the network, so it cannot fail for connectivity
    /// reasons and callers can run it on its own, without
    /// `clearRemoteWebSession()`. Order matters at the end: the persisted
    /// reauthentication state lives in the account's defaults, so it has to be
    /// dropped while the account reference is still around.
    @MainActor
    @discardableResult
    func clearLocalAccountData(postSharedTokenChange: Bool = true) -> Bool {
        currentCredentials = nil
        lastRenewAttemptAt = nil
        lastSuccessfulSyncAt = nil
        reauthenticationState = .normal
        clearPersistedReauthenticationState()
        stopRenewTimer()
        stopHeartbeat()
        AccountController.shared.clearCachedAccount()
        return clearCredentialStores(postSharedTokenChange: postSharedTokenChange)
    }

    func setAccountDeletionInProgress(_ value: Bool) {
        accountDeletionStateLock.lock()
        accountDeletionInProgress = value
        accountDeletionStateLock.unlock()
    }

    func permitsExternalBrowserAuthentication(
        accountDeletionReplacementLoginToken token: UUID?
    ) -> Bool {
        accountDeletionStateLock.lock()
        defer { accountDeletionStateLock.unlock() }
        guard accountDeletionInProgress else {
            return true
        }
        guard let token else {
            return false
        }
        return token == accountDeletionReplacementLoginToken
    }

    func setAccountDeletionReplacementLoginToken(_ token: UUID) {
        accountDeletionStateLock.lock()
        accountDeletionReplacementLoginToken = token
        accountDeletionStateLock.unlock()
    }

    func clearAccountDeletionReplacementLoginToken(_ token: UUID? = nil) {
        accountDeletionStateLock.lock()
        defer { accountDeletionStateLock.unlock() }
        guard token == nil || token == accountDeletionReplacementLoginToken else {
            return
        }
        accountDeletionReplacementLoginToken = nil
    }

    private func clearCredentialStores(postSharedTokenChange: Bool) -> Bool {
        _ = credentialManager.clear()
        var localStatus = storedAuth0CredentialStatus()
        if localStatus == errSecSuccess {
            _ = credentialManager.clear()
            localStatus = storedAuth0CredentialStatus()
        }
        let localCleared = localStatus == errSecItemNotFound
        if !localCleared {
            AppLogError(
                "[Auth] Local Auth0 credential verification failed with OSStatus \(localStatus)"
            )
        }

        let sharedCleared = SharedAuthTokenStore.shared.clear(
            postChangeNotification: postSharedTokenChange
        )
        return localCleared && sharedCleared
    }

    private func storeCredentialsIfAllowed(_ credentials: Credentials) -> Bool {
        guard !isAccountDeletionInProgress else {
            return false
        }
        return credentialManager.store(credentials: credentials)
    }

    private func storedAuth0CredentialStatus() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? FileSystemUtils.bundleId,
            kSecAttrAccount as String: credentialStoreKey,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    /// User-initiated logout: best-effort remote session teardown followed by
    /// the local clear.
    ///
    /// Every remote failure past a started attempt is logged and ignored,
    /// because the local clear is what actually ends the session and it must
    /// not depend on the network. (It used to: the remote step shared a `do`
    /// block with the local clear, so any remote failure skipped the clear and
    /// left the user logged in.)
    ///
    /// Returns false when the remote step never ran. Whether that abandons the
    /// logout is the settings pane's decision: window-close cancellation and
    /// launch/barrier failures abandon it, while the pane's own timeout gives
    /// up on the network only and continues via `completeLogoutLocally()`.
    func logOut() async -> Bool {
        if case .notPerformed = await clearRemoteWebSession() {
            return false
        }
        await completeLogoutLocally()
        return true
    }

    /// The local half of a user-initiated logout: the analytics capture, the
    /// local clear, and the logout traces. Called by `logOut()` after the
    /// remote attempt, and directly by the settings pane when its timeout
    /// gives up waiting for the Auth0 callback — an unreachable Auth0 must
    /// not leave the user logged in.
    @MainActor
    func completeLogoutLocally() {
        recordTrace("user-logout-started")
        // PostHog: capture the logout event before the clear, which drops the
        // account reference and with it the analytics identity.
        PostHogSDK.shared.capture("user_logged_out")
        clearLocalAccountData()
        recordTrace("user-logout-succeeded")
        PostHogSDK.shared.reset()
    }
    
    func refreshAuthStatus() async {
        guard !isAccountDeletionInProgress else {
            currentCredentials = nil
            recordTrace("refresh-auth-status-skipped-account-deletion")
            return
        }
        recordTrace("refresh-auth-status-started")
        await MainActor.run {
            hydrateAccountForReauthenticationIfNeeded()
            restorePersistedReauthenticationStateIfNeeded(
                promptIfDue: true,
                trigger: "launch"
            )
        }
        if hasReauthenticationGraceSession() {
            recordTrace("refresh-auth-status-skipped-reauthentication-required")
            return
        }
        // `getActiveCredentials()` itself performs shared-store recovery on cache miss;
        // calling `recoverFromSharedStoreIfNeeded` again here would just double-acquire
        // the cross-process lock for no benefit.
        currentCredentials = await getActiveCredentials()
        if currentCredentials != nil {
            await startRenewTimer()
            startHeartbeat()
            writeSharedAuth0Config()
            recordTrace("refresh-auth-status-restored", details: credentialSnapshotDetails())
        } else {
            recordTrace("refresh-auth-status-no-credentials")
        }
    }

    /// Alwayws used to determin wheather the use has logged in
    func hasRecoverableLoginSession() -> Bool {
        guard !isAccountDeletionInProgress else {
            return false
        }
#if DEBUG
        if EnvironmentChecker.isRunningPreview {
            return false
        }
#endif
        if hasReauthenticationGraceSession(),
           LoginController.shared.phase == .done {
            return true
        }
        return credentialManager.canRenew()
    }
    
    func getActiveCredentials() async -> Credentials? {
        guard !isAccountDeletionInProgress else {
            return nil
        }
#if DEBUG
        if EnvironmentChecker.isRunningPreview {
            return nil
        }
#endif
        if hasReauthenticationGraceSession() {
            recordTrace("active-credentials-skipped-reauthentication-required")
            return nil
        }

        if let currentCredentials,
           currentCredentials.expiresIn.timeIntervalSinceNow > 0 {
            return currentCredentials
        }
        recordTrace("active-credentials-cache-miss", details: credentialSnapshotDetails())
        self.currentCredentials = nil
        await recoverFromSharedStoreIfNeeded(reason: "getActiveCredentials")

        if let currentCredentials,
           currentCredentials.expiresIn.timeIntervalSinceNow > 0 {
            recordTrace("active-credentials-recovered-from-shared-store", details: credentialSnapshotDetails())
            return currentCredentials
        }

        // Without a stored refresh token (user-initiated logout, first launch, keychain
        // wipe, etc.) calling into `credentialManager.credentials()` or
        // `renewCredentialsAsync(...)` would surface `noCredentials` from the Auth0 SDK
        // and trip the forced-logout path even though there was never a session to lose.
        // Bail out early before touching the SDK; `recoverFromSharedStoreIfNeeded` above
        // would have flipped `canRenew()` to true via `store(credentials:)` if the
        // shared store had a usable token.
        let canRenew = await MainActor.run {
            credentialManager.canRenew()
        }
        guard canRenew else {
            recordTrace("active-credentials-skipped-no-refresh-token", details: credentialSnapshotDetails())
            return nil
        }

        let hasLocallyValidCredentials = await MainActor.run {
            credentialManager.hasValid()
        }
        if hasLocallyValidCredentials {
            do {
                let credential = try await credentialManager.credentials()
                guard !isAccountDeletionInProgress else {
                    _ = clearCredentialStores(postSharedTokenChange: false)
                    return nil
                }
                self.currentCredentials = credential
                recordTrace(
                    "active-credentials-restored-from-local-store",
                    details: [
                        "expiresAt": iso8601String(credential.expiresIn),
                        "hasRefreshToken": boolString(credential.refreshToken != nil)
                    ]
                )
                return credential
            } catch {
                logCredentialsFailure(error, operation: "retrieve local valid credentials")
                return nil
            }
        }

        // The Auth0 SDK's `credentials()` will internally call `renew()` with the locally
        // cached refresh token if the access token is expired. Calling it without holding
        // `SharedTokenLock` opens a race where Sentinel (after Phi was thought to be a
        // zombie) has already rotated the refresh token in the shared store, leaving the
        // SDK's cached RT stale and triggering ferrt. Route the renewal through the
        // lock-protected path instead.
        recordTrace("active-credentials-routing-to-locked-renew")
        return await renewCredentialsAsync(operation: "retrieve active credentials")
    }
    
    func storedUserInfo() -> UserInfo? {
        guard !isAccountDeletionInProgress else {
            return nil
        }
        return credentialManager.user
    }

    func checkLoginStatusOnChromiumLaunch() -> Bool {
        guard !isAccountDeletionInProgress else {
            return false
        }
        // Hot path: Chromium polls this on every page load / tab change. Once
        // login has finished and we have credentials in memory, the answer is
        // already settled — `transitionToLoggedOutState` clears
        // `currentCredentials` and flips `phase` back to `.login` atomically
        // on the main actor, so the (`phase == .done`, `currentCredentials != nil`)
        // pair is a reliable proxy for "user is logged in" without paying for
        // the keychain reads inside `canRenew()` / `credentialManager.user`.
        if LoginController.shared.phase == .done,
           (currentCredentials != nil || hasReauthenticationGraceSession()) {
            return true
        }

        guard hasRecoverableLoginSession() else {
            return false
        }

        if let storedUserInfo = credentialManager.user {
            LoginController.shared.initAcoountWithUserInfo(storedUserInfo)
            restorePersistedReauthenticationStateIfNeeded(
                promptIfDue: true,
                trigger: "chromium_launch"
            )
        } else if let currentCredentials {
            LoginController.shared.initAccountIfNeeded(currentCredentials)
            restorePersistedReauthenticationStateIfNeeded(
                promptIfDue: true,
                trigger: "chromium_launch"
            )
        } else {
            return false
        }

        return LoginController.shared.phase == .done
    }
    
    func getAccessTokenSyncly() -> String? {
        guard !isAccountDeletionInProgress else {
            return nil
        }
        if hasReauthenticationGraceSession() {
            return nil
        }

        // Hot path: Chromium calls this multiple times per second to attach
        // bearer tokens to outgoing requests. When the in-memory access token
        // is still valid we answer entirely from memory — no keychain
        // round-trip, no securityd IPC, no trace activity. The previous
        // implementation gated this on a `credentialManager.canRenew()`
        // keychain probe whose only purpose was to detect "SDK keychain wiped
        // externally", which is a degraded state we cannot recover from
        // synchronously anyway; the periodic renew timer and launch recovery
        // catch it on a non-hot path.
        if let currentCredentials,
           currentCredentials.expiresIn.timeIntervalSinceNow > 0 {
            return currentCredentials.accessToken
        }

        guard credentialManager.canRenew() else {
            return nil
        }
        if let currentCredentials {
            recordTrace(
                "access-token-syncly-skipped-expired-current-credentials",
                details: ["expiresAt": iso8601String(currentCredentials.expiresIn)]
            )
        }
        // Falling back to the shared store's access token can return a token that is
        // already expired or about to be rotated. Callers that hit this path should
        // schedule an async `getActiveCredentials()` to refresh the cache; the trace
        // helps spot when that scheduling is missing.
        if let sharedToken = SharedAuthTokenStore.shared.read(),
           let expiresAt = sharedToken.expiresAt,
           expiresAt.timeIntervalSinceNow > 0 {
            return sharedToken.accessToken
        }
        recordTrace("access-token-syncly-no-valid-token")
        renewCredentials()
        return nil
    }
    
    private func shouldRenewNow() -> Bool {
        guard let exp = currentCredentials?.expiresIn else {
            return true
        }
        return exp.timeIntervalSinceNow <= renewUrgentWindow
    }
    
    func renewCredentials() {
        Task { _ = await renewCredentialsAsync(operation: "renew credentials") }
    }

    /// Decides whether `applicationShouldHandleReopen` should fire a renew.
    /// Reopen is a high-frequency user gesture (every Dock click, every
    /// foreground transition) and the previous unconditional renewal turned it
    /// into a constant ferrt risk: each reopen is a fresh chance to submit a
    /// stale RT to Auth0. We now skip the renew unless one of:
    /// - we have no in-memory credentials (let the regular recovery flow run);
    /// - access token is within the configured urgent window.
    /// The periodic renew timer still checks long-running sessions for refresh needs.
    ///
    /// Delegates the urgent-window logic to `shouldRenewNow()` so reopen and
    /// the internal preflight in `renewCredentialsAsync` agree on what counts
    /// as "due for renewal". The explicit `isRenewing` check here is a
    /// fast-path optimization to avoid spawning a Task that the preflight
    /// would immediately skip; the preflight still does its own check.
    func shouldRenewOnReopen() -> Bool {
        if isAccountDeletionInProgress { return false }
        if isRenewing { return false }
        return shouldRenewNow()
    }

    /// Lock-protected renewal. Returns the resulting credentials when the renew completes
    /// successfully (or when the shared store already has a fresh token that satisfies the
    /// caller); otherwise returns nil. All mutations to `currentCredentials`,
    /// `lastRenewAttemptAt`, `lastSuccessfulSyncAt`, and `isRenewing` happen on the main
    /// actor to avoid data races with cache reads from `getActiveCredentials()` and the
    /// renew timer.
    @discardableResult
    func renewCredentialsAsync(operation: String) async -> Credentials? {
        await MainActor.run {
            recordTrace("renew-requested", details: credentialSnapshotDetails())
        }

        let preflight = await MainActor.run { () -> RenewPreflightDecision in
            if isAccountDeletionInProgress {
                recordTrace("renew-skipped", details: ["reason": "account_deletion"])
                return .skip
            }
            if hasReauthenticationGraceSession() {
                recordTrace("renew-skipped", details: ["reason": "reauthentication_required"])
                AppLogInfo("[TokenRenew] skip renew: reauthentication is required")
                return .skip
            }
            if isRenewing {
                recordTrace("renew-skipped", details: ["reason": "already_in_progress"])
                AppLogDebug("[TokenRenew] skip renew: already in progress")
                return .skip
            }
            if !shouldRenewNow() {
                var details: [String: String] = [
                    "reason": "not_in_urgent_window",
                    "lastRenewAttemptAt": iso8601String(lastRenewAttemptAt)
                ]
                if let expiresAt = currentCredentials?.expiresIn {
                    details["currentCredentialExpiresAt"] = iso8601String(expiresAt)
                    details["currentCredentialSecondsToExpiry"] = String(Int(expiresAt.timeIntervalSinceNow))
                }
                recordTrace(
                    "renew-skipped",
                    details: details
                )
                AppLogInfo("[TokenRenew] skip renew: access token is not within urgent window; expires at: \(String(describing: currentCredentials?.expiresIn))")
                return .returnCachedCredentials(currentCredentials)
            }
            return .proceed
        }

        switch preflight {
        case .skip:
            return nil
        case .returnCachedCredentials(let cached):
            return cached
        case .proceed:
            break
        }

        guard SharedTokenLock.shared.tryLock() else {
            await MainActor.run {
                recordTrace("renew-skipped", details: ["reason": "shared_lock_unavailable"])
                AppLogInfo("[TokenRenew] skip renew: another process holds the lock")
            }
            return await currentCredentialsOnMain()
        }

        let preRenewOutcome = await MainActor.run { () -> PreRenewDoubleCheckOutcome in
            isRenewing = true
            return importFresherSharedTokenIfAvailableLocked()
        }

        if case .satisfied(let credentials) = preRenewOutcome {
            SharedTokenLock.shared.unlock()
            await MainActor.run { isRenewing = false }
            return credentials
        }

        let result = await callAuth0Renew(operation: operation)
        SharedTokenLock.shared.unlock()
        return result
    }

    private enum RenewPreflightDecision {
        case skip
        case returnCachedCredentials(Credentials?)
        case proceed
    }

    private enum PreRenewDoubleCheckOutcome {
        case satisfied(Credentials?)
        case proceed
    }

    @MainActor
    private func currentCredentialsOnMain() -> Credentials? {
        currentCredentials
    }

    /// MUST be called on the main actor while holding `SharedTokenLock`.
    @MainActor
    private func importFresherSharedTokenIfAvailableLocked() -> PreRenewDoubleCheckOutcome {
        guard let sharedToken = SharedAuthTokenStore.shared.read() else {
            return .proceed
        }
        // Compare against `lastSuccessfulSyncAt`, not `lastRenewAttemptAt`. The latter is
        // bumped on failure/timeout too, so using it would cause us to ignore a fresher
        // Sentinel-written token after a Phi-side renew failure.
        let sharedIsNewer = lastSuccessfulSyncAt.map { sharedToken.updatedAt > $0 } ?? true
        guard sharedIsNewer else {
            return .proceed
        }

        // A nil expiresAt means the token was written by an older version that did not
        // include expiry. Importing it would set `expiresIn = Date()`, immediately
        // appearing expired and triggering another renew on the very next call. Skip.
        guard let sharedExpiresAt = sharedToken.expiresAt else {
            recordTrace(
                "renew-skipped-shared-import",
                details: [
                    "reason": "shared_token_missing_expires_at",
                    "sharedTokenUpdatedAt": iso8601String(sharedToken.updatedAt)
                ]
            )
            AppLogWarn("[TokenRenew] shared token has no expiresAt; cannot safely import")
            return .proceed
        }

        guard let refreshToken = sharedToken.refreshToken else {
            return .proceed
        }

        let imported = Credentials(
            accessToken: sharedToken.accessToken,
            tokenType: "Bearer",
            idToken: sharedToken.idToken ?? "",
            refreshToken: refreshToken,
            expiresIn: sharedExpiresAt
        )
        if storeCredentialsIfAllowed(imported) {
            self.currentCredentials = imported
            self.lastSuccessfulSyncAt = sharedToken.updatedAt
            recordTrace("renew-imported-shared-token", details: sharedTokenDetails(sharedToken))
            AppLogInfo("[TokenRenew] imported fresher shared token before renew, checking if still needed")
        }

        if sharedExpiresAt.timeIntervalSinceNow > renewUrgentWindow {
            recordTrace(
                "renew-skipped",
                details: [
                    "reason": "shared_token_still_fresh",
                    "sharedTokenUpdatedAt": iso8601String(sharedToken.updatedAt)
                ]
            )
            AppLogInfo("[TokenRenew] imported token is still fresh, skipping renew")
            return .satisfied(currentCredentials)
        }
        return .proceed
    }

    private func callAuth0Renew(operation: String) async -> Credentials? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Credentials?, Never>) in
            let completionLock = NSLock()
            var completed = false

            let timeoutWork = DispatchWorkItem { [weak self] in
                completionLock.lock()
                defer { completionLock.unlock() }
                guard !completed else { return }
                completed = true
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                Task { @MainActor in
                    self.recordTrace("renew-timed-out", details: self.credentialSnapshotDetails())
                    AppLogError("[TokenRenew] renew timed out after 45s, releasing lock")
                    self.lastRenewAttemptAt = Date()
                    self.isRenewing = false
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeoutWork)

            credentialManager.renew(parameters: ["audience": audience]) { [weak self] result in
                completionLock.lock()
                defer { completionLock.unlock() }
                guard !completed else { return }
                completed = true
                timeoutWork.cancel()

                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                // Record the callback trace synchronously, NOT inside the
                // `Task { @MainActor in ... }` below. Otherwise a process death
                // between the SDK delivering the callback and the main actor
                // picking up the task would leave no trace at all, which is
                // precisely the post-mortem scenario this entry is meant to
                // disambiguate (callback fired vs. callback never fired).
                let outcome: String
                switch result {
                case .success: outcome = "success"
                case .failure: outcome = "failure"
                }
                self.recordTrace(
                    "renew-callback-received",
                    details: [
                        "outcome": outcome,
                        "operation": operation
                    ]
                )

                // Persist to the shared store in the same synchronous context the
                // SDK callback hands us. Auth0's CredentialsManager has already
                // written RT_new to the local keychain by the time this closure
                // runs; if we deferred the shared-store write to a `Task @MainActor`
                // and the process died before that task was scheduled, we'd be
                // left with a "local has RT_new, shared still has RT_old" split
                // brain — exactly the precondition for the next launch's
                // `applySharedStoreRecoveryLocked` to overwrite our newer local
                // RT with the stale shared RT, leading to ferrt on the next
                // renew. Doing the keychain write up-front shrinks that window
                // from a main-actor hop to a couple of Keychain calls.
                let syncedCredentials: (Credentials, Bool)? = {
                    guard case .success(let credentials) = result else { return nil }
                    let ok = self.syncSharedTokens(credentials)
                    return (credentials, ok)
                }()

                Task { @MainActor in
                    if self.isAccountDeletionInProgress {
                        _ = self.clearCredentialStores(postSharedTokenChange: false)
                        self.currentCredentials = nil
                        self.isRenewing = false
                        self.recordTrace("renew-result-discarded-account-deletion")
                        continuation.resume(returning: nil)
                        return
                    }

                    switch result {
                    case .success(let credentials):
                        self.lastRenewAttemptAt = Date()
                        self.currentCredentials = credentials
                        // Only bump `lastSuccessfulSyncAt` when shared store actually
                        // accepted the new credentials. Otherwise the next
                        // `recoverFromSharedStoreIfNeeded` would short-circuit on
                        // `sharedToken.updatedAt <= lastSyncedAt` and skip importing
                        // a token that was never written.
                        if let synced = syncedCredentials, synced.1 {
                            self.lastSuccessfulSyncAt = Date()
                        }
                        self.reauthenticationState = .normal
                        self.clearPersistedReauthenticationState()
                        self.recordTrace("renew-succeeded", details: self.credentialSnapshotDetails())
                        AppLogInfo("[TokenRenew] renew successful, expires at: \(credentials.expiresIn)")
                        self.isRenewing = false
                        continuation.resume(returning: credentials)
                    case .failure(let error):
                        // Do not mark network failures as a completed renew attempt. A
                        // missed successful response can leave the client holding the
                        // previous RT, so traces must keep that ambiguity visible.
                        if Self.isNetworkRenewError(error) {
                            var details = Self.networkErrorDetails(error)
                            details["operation"] = operation
                            self.recordTrace(
                                "renew-network-error-no-cooldown",
                                details: details
                            )
                            AppLogInfo("[TokenRenew] network error, preserving last successful sync point: \(error.localizedDescription)")
                        } else {
                            self.lastRenewAttemptAt = Date()
                        }
                        self.logCredentialsFailure(error, operation: operation)
                        self.isRenewing = false
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func logCredentialsFailure(_ error: Error, operation: String) {
        if let managerError = error as? CredentialsManagerError {
            let failureReason = authFailureReason(for: managerError)
            let details = authFailureDetails(
                operation: operation,
                failureReason: failureReason,
                underlyingError: managerError.cause?.localizedDescription
            )
            recordTrace("credentials-failure", details: details)

            let reauthenticationReason = reauthenticationReason(for: managerError)

            if hasReauthenticationGraceSession(),
               reauthenticationReason != nil {
                recordTrace(
                    "credentials-failure-ignored-during-reauthentication",
                    details: ["reason": failureReason, "operation": operation]
                )
            } else if let reauthenticationReason {
                Task { @MainActor [weak self] in
                    self?.enterReauthenticationRequiredState(reason: reauthenticationReason)
                }
            }
            if let cause = managerError.cause {
                AppLogError("\(operation) failed: \(managerError.debugDescription) underlying error: \(cause.localizedDescription)")
            } else {
                AppLogError("\(operation) failed: \(managerError.debugDescription)")
            }
        } else {
            AppLogError("\(operation) failed: \(error.localizedDescription)")
        }
    }

    func reportReauthenticationResult(
        succeeded: Bool,
        reason: AuthReauthenticationReason,
        details: [String: String]
    ) {
        SentryService.captureAuthReauthenticationResult(
            succeeded: succeeded,
            reason: reason.rawValue,
            trace: failureTrace.renderedTrace(),
            attributes: details
        )
    }

    private func reauthenticationReason(for managerError: CredentialsManagerError) -> AuthReauthenticationReason? {
        guard CredentialsManagerError.renewFailed ~= managerError,
              let authError = managerError.cause as? AuthenticationError else {
            return nil
        }

        if authError.isInvalidRefreshToken {
            return .invalidRefreshToken
        }
        if authError.isRefreshTokenDeleted {
            return .refreshTokenDeleted
        }
        return nil
    }

    func transitionToLoggedOutState() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isAccountDeletionInProgress {
                self.recordTrace("forced-logout-absorbed-account-deletion")
                _ = self.clearLocalAccountData(postSharedTokenChange: false)
                return
            }
            AppLogInfo("transition auth state to login: clearing local credentials after unrecoverable session loss")
            self.clearLocalAccountData()
            LoginController.shared.phase = .login
            MainBrowserWindowControllersManager.shared.closeAllWindows()
            LoginController.shared.showLoginWindow()
        }
    }
    
    // MARK: - Periodic Renew Timer
    
    /// Starts the periodic renew timer. Should be called after successful login or credential restoration.
    /// The timer fires every hour and calls renewCredentials(), which internally checks shouldRenewNow()
    /// to avoid redundant renew attempts if a manual renew happened recently.
    @MainActor
    func startRenewTimer() {
        let timerInterval = renewCooldown
        if let renewTimer, renewTimer.isValid, renewTimerInterval == timerInterval {
            return
        }
        renewTimer?.invalidate()

        let timer = Timer(
            timeInterval: timerInterval,
            repeats: true
        ) { [weak self] _ in
            AppLogInfo("periodic renew check fired")
            Task { @MainActor [weak self] in
                self?.startRenewTimer()
            }
            self?.renewCredentials()
        }

        renewTimer = timer
        renewTimerInterval = timerInterval
        RunLoop.main.add(timer, forMode: .common)
        AppLogInfo("renew timer started, interval: \(timerInterval)s")
    }
    
    /// Stops the periodic renew timer. Should be called on logout or when credentials are cleared.
    @MainActor
    func stopRenewTimer() {
        renewTimer?.invalidate()
        renewTimer = nil
        renewTimerInterval = nil
    }

    func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 30, leeway: .seconds(5))
        timer.setEventHandler {
            SharedHeartbeatStore.shared.write()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    func writeSharedAuth0Config() {
        SharedAuth0Config.shared.write(
            domain: domain,
            clientId: clicentId,
            audience: audience
        )
    }
    
    func clenupLocaCrendentials() {
        lastRenewAttemptAt = nil
    }
    
    static func retriveUserInfo(from credentials: Credentials) -> User {
        let idToken = credentials.idToken
        return User(from: idToken)
    }
    
    func clearLocalCredentials() {
        _ = credentialManager.clear()
        SharedAuthTokenStore.shared.clear()
    }

    @MainActor
    func pauseRenewalForReauthentication() {
        stopRenewTimer()
    }

    @MainActor
    func storeReauthenticatedCredentials(_ credentials: Credentials) -> Bool {
        guard !isAccountDeletionInProgress else {
            return false
        }
        guard reauthenticatedCredentialsMatchCurrentAccount(credentials) else {
            recordTrace("reauthentication-user-mismatch")
            return false
        }

        guard storeCredentialsIfAllowed(credentials) else {
            return false
        }
        currentCredentials = credentials
        lastRenewAttemptAt = Date()
        if syncSharedTokens(credentials, renewedBy: "phi-reauthentication") {
            lastSuccessfulSyncAt = Date()
        }
        startRenewTimer()
        startHeartbeat()
        writeSharedAuth0Config()
        return true
    }

    @MainActor
    func hydrateAccountForReauthenticationIfNeeded() {
        guard !isAccountDeletionInProgress,
              AccountController.shared.account == nil,
              let storedUserInfo = credentialManager.user else {
            return
        }

        LoginController.shared.initAcoountWithUserInfo(storedUserInfo)
    }

    @MainActor
    func reauthenticatedCredentialsMatchCurrentAccount(_ credentials: Credentials) -> Bool {
        let user = Self.retriveUserInfo(from: credentials)
        guard let newUserID = user.sub else {
            return false
        }

        if let currentUserID = AccountController.shared.account?.userID {
            return currentUserID == newUserID
        }

        LoginController.shared.initAccountIfNeeded(credentials)
        return AccountController.shared.account?.userID == newUserID
    }

    func recoverFromSharedStoreIfNeeded() async {
        await recoverFromSharedStoreIfNeeded(reason: "unspecified")
    }

    func recoverFromSharedStoreIfNeeded(reason: String) async {
        guard !isAccountDeletionInProgress else {
            return
        }
        // Read the snapshot we need for the comparison on the main actor first to avoid
        // racing with renew callbacks and timer-driven mutations of `lastSuccessfulSyncAt`.
        let lastSyncedAt = await MainActor.run { lastSuccessfulSyncAt }
        let acquired = await acquireSharedLock(timeout: 5)
        guard acquired else {
            await MainActor.run {
                recordTrace("shared-store-recovery-skipped", details: ["reason": "\(reason):lock_timeout"])
                AppLogWarn("[TokenRenew] failed to acquire lock for launch recovery, proceeding with local credentials")
            }
            return
        }
        defer { SharedTokenLock.shared.unlock() }

        await MainActor.run {
            recordTrace("shared-store-recovery-started", details: ["reason": reason])
            applySharedStoreRecoveryLocked(reason: reason, lastSyncedAt: lastSyncedAt)
        }
    }

    private func acquireSharedLock(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SharedTokenLock.shared.lockWithTimeout(timeout))
            }
        }
    }

    /// MUST be called on the main actor while holding `SharedTokenLock`. The recovery
    /// short-circuit compares against `lastSuccessfulSyncAt` so a recent failed renew
    /// (which only bumps `lastRenewAttemptAt`) does not hide a fresher Sentinel-written
    /// shared token and leave the SDK with a rotated refresh token.
    @MainActor
    private func applySharedStoreRecoveryLocked(reason: String, lastSyncedAt: Date?) {
        guard !isAccountDeletionInProgress else {
            return
        }
        guard let sharedToken = SharedAuthTokenStore.shared.read() else {
            recordTrace("shared-store-recovery-skipped", details: ["reason": "\(reason):no_shared_token"])
            return
        }

        if let lastSyncedAt, sharedToken.updatedAt <= lastSyncedAt {
            recordTrace("shared-store-recovery-skipped", details: ["reason": "\(reason):shared_token_not_newer"])
            return
        }

        // Defend against the most damaging variant of the Auth0 incident
        // 2026-04-22: a previous Phi process rotated the RT (Auth0 SDK already
        // wrote RT_new to the local keychain), but our shared-store sync did
        // not land before that process exited. On relaunch the shared store
        // still holds RT_old; importing it would overwrite RT_new in the local
        // keychain and the very next renew would submit RT_old to Auth0,
        // triggering ferrt and destroying the entire token family.
        //
        // Two complementary checks below cover the two ways "local is fresher"
        // can manifest:
        //
        //   (a) Same process: `currentCredentials` already holds the newer
        //       credentials in memory but never reached the shared store.
        //   (b) New process: `currentCredentials` is nil but the SDK keychain
        //       might still contain a fresher access token from a previous
        //       process's successful renew. We probe via the SDK's only
        //       side-effect-free read API, `hasValid(minTTL:)`, which checks
        //       the locally stored access token's remaining lifetime without
        //       touching the network or rotating anything.
        if isLocalCredentialsFresherThanShared(sharedToken: sharedToken) {
            handleLocalFresherThanShared(sharedToken: sharedToken, reason: reason)
            return
        }

        guard let refreshToken = sharedToken.refreshToken else {
            recordTrace("shared-store-recovery-skipped", details: ["reason": "\(reason):missing_refresh_token"])
            return
        }

        // Same rationale as in `importFresherSharedTokenIfAvailableLocked`: importing with
        // `expiresIn = Date()` would immediately appear expired and trigger another renew
        // on the very next call.
        guard let sharedExpiresAt = sharedToken.expiresAt else {
            recordTrace(
                "shared-store-recovery-skipped",
                details: ["reason": "\(reason):shared_token_missing_expires_at"]
            )
            AppLogWarn("[TokenRenew] shared token has no expiresAt; cannot safely import on recovery")
            return
        }

        let credentials = Credentials(
            accessToken: sharedToken.accessToken,
            tokenType: "Bearer",
            idToken: sharedToken.idToken ?? "",
            refreshToken: refreshToken,
            expiresIn: sharedExpiresAt
        )

        if storeCredentialsIfAllowed(credentials) {
            self.currentCredentials = credentials
            self.lastSuccessfulSyncAt = sharedToken.updatedAt
            recordTrace("shared-store-recovery-imported-token", details: sharedTokenDetails(sharedToken))
            AppLogInfo("[TokenRenew] imported shared token (renewedBy=\(sharedToken.renewedBy ?? "unknown"), expireDate=\(sharedExpiresAt), updatedAt=\(sharedToken.updatedAt))")
        }
    }

    /// Returns true when our local store (in-memory credentials, or the
    /// underlying Auth0 SDK keychain probed via `hasValid(minTTL:)`) is known
    /// to be NEWER than the shared-store snapshot. Used by recovery to refuse
    /// stale shared writes from overwriting fresher local credentials.
    @MainActor
    private func isLocalCredentialsFresherThanShared(sharedToken: SharedAuthToken) -> Bool {
        guard let sharedExpiresAt = sharedToken.expiresAt else {
            // We never import a shared token without `expiresAt` anyway, so do
            // not bother claiming "local is fresher" here. The downstream
            // `shared_token_missing_expires_at` branch will handle the skip.
            return false
        }

        // Case (a): in-memory credentials are the cheapest, most reliable
        // comparison — same access-token TTL means later `expiresIn` ⇔ later
        // server-issued credential.
        if let local = currentCredentials, local.expiresIn > sharedExpiresAt {
            return true
        }

        // Case (b): probe the Auth0 SDK keychain. `hasValid(minTTL:)` returns
        // true iff the locally stored access token still has at least `minTTL`
        // seconds remaining; it does NOT trigger a renew. We add a small
        // buffer so identical-TTL tokens (e.g. shared was just imported from
        // local) do not accidentally pass the probe.
        let sharedRemainingSeconds = Int(sharedExpiresAt.timeIntervalSinceNow)
        let bufferSeconds = 5 * 60
        let probeTTLSeconds = sharedRemainingSeconds + bufferSeconds
        if probeTTLSeconds > 0,
           credentialManager.canRenew(),
           credentialManager.hasValid(minTTL: probeTTLSeconds) {
            return true
        }

        return false
    }

    /// Records the "skipped to protect local" decision and reverse-syncs to
    /// the shared store when we have the in-memory credentials handy. We can
    /// only safely reverse-sync from `currentCredentials` because the SDK has
    /// no public API to extract the keychain RT without potentially renewing.
    /// In the keychain-only fresher case we accept that the shared store will
    /// catch up on Phi's next successful renew.
    @MainActor
    private func handleLocalFresherThanShared(sharedToken: SharedAuthToken, reason: String) {
        if let local = currentCredentials {
            let synced = syncSharedTokens(local, renewedBy: "phi-recovery-reverse")
            recordTrace(
                "shared-store-recovery-reverse-synced",
                details: [
                    "reason": reason,
                    "synced": boolString(synced),
                    "localExpiresAt": iso8601String(local.expiresIn),
                    "sharedExpiresAt": iso8601String(sharedToken.expiresAt),
                    "sharedTokenUpdatedAt": iso8601String(sharedToken.updatedAt)
                ]
            )
            if synced {
                self.lastSuccessfulSyncAt = Date()
            }
            AppLogInfo("[TokenRenew] local credentials are fresher than shared store; reverse-synced to shared")
        } else {
            recordTrace(
                "shared-store-recovery-skipped-local-fresher",
                details: [
                    "reason": reason,
                    "sharedExpiresAt": iso8601String(sharedToken.expiresAt),
                    "sharedTokenUpdatedAt": iso8601String(sharedToken.updatedAt)
                ]
            )
            AppLogInfo("[TokenRenew] SDK keychain holds fresher credentials than shared store; skipping import (reverse-sync will happen on next renew)")
        }
    }

    /// Persists the freshly issued credentials to the App Group keychain so other
    /// processes (Sentinel) can pick them up. Returns `false` when the underlying
    /// keychain write failed; callers MUST treat that as "shared store still holds
    /// the previous RT" and avoid bumping `lastSuccessfulSyncAt`, otherwise the
    /// next `applySharedStoreRecoveryLocked` would short-circuit on
    /// `sharedToken.updatedAt <= lastSyncedAt` and never re-import.
    ///
    /// Failures are surfaced (not silent) as `shared-token-sync-failed` in the
    /// trace buffer and via `AppLogError`, so any subsequent forced-logout Sentry
    /// event will carry them in its attached trace.
    ///
    /// We deliberately DO NOT retry the failed write here. A naive
    /// "1s later, upsert again" retry races with the rest of the world:
    ///   1. Sentinel could acquire `SharedTokenLock` in the meantime and rotate
    ///      the RT itself; an unlocked retry would then overwrite the newer
    ///      shared token with our captured (now stale) one and trigger ferrt.
    ///   2. The user could call `logOut()` and clear the shared store; an
    ///      unlocked retry would resurrect the deleted session, leaving
    ///      Sentinel running on a server-revoked refresh token.
    ///   3. The next successful Phi-side renew will sync again anyway, so the
    ///      "eventually consistent" guarantee is already provided by the normal
    ///      renew path — a retry only buys us 1 second of head start.
    /// Implementing a safe retry would require reacquiring `SharedTokenLock` and
    /// re-checking shared-store freshness against the captured credentials,
    /// effectively duplicating `applySharedStoreRecoveryLocked`. The complexity
    /// is not worth the marginal benefit; if observability ever shows a real
    /// pattern of transient F4/F5 (`errSecInteractionNotAllowed`,
    /// `errSecMissingEntitlement`) failures that hurt users, revisit then.
    ///
    /// Residual risk acknowledged: if the keychain write fails AND the process
    /// exits AND a new process starts within ~5 minutes (so the buffer in
    /// `isLocalCredentialsFresherThanShared` does not save us), the new process
    /// can import the stale shared token and ferrt on the next renew. We accept
    /// this because (a) keychain transient failures are themselves rare on
    /// macOS and (b) the `shared-token-sync-failed` trace lets us spot the
    /// pattern in Sentry if it actually happens.
    @discardableResult
    private func syncSharedTokens(_ credentials: Credentials, renewedBy: String = "phi") -> Bool {
        guard !isAccountDeletionInProgress else {
            return false
        }
        let auth0Sub = User(from: credentials.idToken).sub
        let ok = SharedAuthTokenStore.shared.upsert(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            idToken: credentials.idToken,
            auth0Sub: auth0Sub,
            expiresAt: credentials.expiresIn,
            renewedBy: renewedBy
        )
        if !ok {
            recordTrace(
                "shared-token-sync-failed",
                details: [
                    "expiresAt": iso8601String(credentials.expiresIn),
                    "hasRefreshToken": boolString(credentials.refreshToken != nil),
                    "renewedBy": renewedBy
                ]
            )
            AppLogError("[TokenRenew] shared store upsert failed (renewedBy=\(renewedBy))")
        }
        return ok
    }

    func recordTrace(
        _ event: String,
        details: [String: String] = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: Int = #line,
        callStackSymbols: [String] = []
    ) {
        failureTrace.record(
            event,
            details: details,
            fileID: fileID,
            function: function,
            line: line,
            callStackSymbols: callStackSymbols
        )
    }

    /// Returns true when a renew failure is caused by a transient network condition
    /// (URLError covered by Auth0's `AuthenticationError.isNetworkError`). Network
    /// failures are not recorded as completed renew attempts because the server may
    /// have rotated the refresh token even when the client missed the response.
    private static func isNetworkRenewError(_ error: Error) -> Bool {
        if let authError = error as? AuthenticationError {
            return authError.isNetworkError
        }
        if let managerError = error as? CredentialsManagerError,
           let authError = managerError.cause as? AuthenticationError {
            return authError.isNetworkError
        }
        return false
    }

    /// Decomposes a renew failure into post-mortem-friendly fields. Concrete
    /// `URLError` codes are critical here: a `cancelled`/`networkConnectionLost`
    /// suggests the server may have rotated the RT but the response was lost on
    /// the way back (see Auth0 ferrt scenarios), while `notConnectedToInternet`
    /// implies the request never reached Auth0 at all and the RT is still valid.
    private static func networkErrorDetails(_ error: Error) -> [String: String] {
        var details: [String: String] = [
            "error": error.localizedDescription
        ]
        if let urlError = unwrapURLError(from: error) {
            details["urlErrorCode"] = String(urlError.errorCode)
            // `URLError.errorDomain` is a static `"NSURLErrorDomain"`. Spell
            // the literal so readers don't have to reason about the static
            // type-property pun (and so it stays correct if Apple ever splits
            // the type).
            details["urlErrorDomain"] = "NSURLErrorDomain"
        }
        return details
    }

    /// Mirrors the same nesting that `isNetworkRenewError` peels through, so
    /// that any error we classify as "network" also yields a concrete URLError
    /// for the trace. The most common renew shape is
    /// `CredentialsManagerError(.renewFailed, cause: AuthenticationError(info[cause]: URLError))`,
    /// because Auth0's `AuthenticationError.isNetworkError` reads `cause as? URLError`
    /// from `info["cause"]`. The previous version of this helper only tried
    /// `managerError.cause as? URLError`, which is never true for renew
    /// failures and silently dropped the `urlErrorCode` field on exactly the
    /// errors we needed to classify post-mortem.
    private static func unwrapURLError(from error: Error) -> URLError? {
        if let direct = error as? URLError {
            return direct
        }
        if let managerError = error as? CredentialsManagerError {
            if let authError = managerError.cause as? AuthenticationError,
               let urlError = authError.cause as? URLError {
                return urlError
            }
            // Forward-compatible fallback: if a future SDK starts wrapping
            // the URLError directly, accept that shape too.
            if let urlError = managerError.cause as? URLError {
                return urlError
            }
        }
        if let authError = error as? AuthenticationError,
           let urlError = authError.cause as? URLError {
            return urlError
        }
        return nil
    }

    private func authFailureReason(for managerError: CredentialsManagerError) -> String {
        if CredentialsManagerError.noCredentials ~= managerError {
            return "no_credentials"
        }
        if CredentialsManagerError.noRefreshToken ~= managerError {
            return "no_refresh_token"
        }
        guard let authError = managerError.cause as? AuthenticationError else {
            return "credentials_manager_error"
        }
        if authError.isInvalidRefreshToken {
            return "invalid_refresh_token"
        }
        if authError.isRefreshTokenDeleted {
            return "refresh_token_deleted"
        }
        return "renew_failed"
    }

    private func authFailureDetails(
        operation: String,
        failureReason: String,
        underlyingError: String?
    ) -> [String: String] {
        var details = credentialSnapshotDetails()
        details["operation"] = operation
        details["failureReason"] = failureReason
        details["underlyingError"] = underlyingError ?? "nil"
        return details
    }

    func credentialSnapshotDetails() -> [String: String] {
        var details: [String: String] = [
            "isRenewing": boolString(isRenewing),
            "canRenew": boolString(credentialManager.canRenew()),
            "lastRenewAttemptAt": iso8601String(lastRenewAttemptAt)
        ]

        if let currentCredentials {
            details["hasCurrentCredentials"] = "true"
            details["currentCredentialExpiresAt"] = iso8601String(currentCredentials.expiresIn)
            details["currentCredentialSecondsToExpiry"] = String(Int(currentCredentials.expiresIn.timeIntervalSinceNow))
            details["currentCredentialHasRefreshToken"] = boolString(currentCredentials.refreshToken != nil)
        } else {
            details["hasCurrentCredentials"] = "false"
        }

        if let sharedToken = SharedAuthTokenStore.shared.read() {
            for (key, value) in sharedTokenDetails(sharedToken) {
                details[key] = value
            }
        } else {
            details["hasSharedToken"] = "false"
        }

        return details
    }

    private func sharedTokenDetails(_ sharedToken: SharedAuthToken) -> [String: String] {
        [
            "hasSharedToken": "true",
            "sharedTokenUpdatedAt": iso8601String(sharedToken.updatedAt),
            "sharedTokenExpiresAt": iso8601String(sharedToken.expiresAt),
            "sharedTokenSecondsToExpiry": sharedToken.expiresAt.map { String(Int($0.timeIntervalSinceNow)) } ?? "nil",
            "sharedTokenRenewedBy": sharedToken.renewedBy ?? "nil",
            "sharedTokenHasRefreshToken": boolString(sharedToken.refreshToken != nil)
        ]
    }

    func iso8601String(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return ISO8601DateFormatter().string(from: date)
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

struct User {
    let name: String?
    let email: String?
    let picture: String?
    let sub: String?
    
    init(from idToken: String) {
        let jwt = try? decode(jwt: idToken)
        self.name = jwt?.claim(name: "name").string
        self.email = jwt?.claim(name: "email").string
        self.picture = jwt?.claim(name: "picture").string
        self.sub = jwt?.claim(name: "sub").string
    }
    
    init (name: String?, email: String?, picture: String?, sub: String?) {
        self.name = name
        self.email = email
        self.picture = picture
        self.sub = sub
    }
    
    init(_ auth0UserInfo: UserInfo) {
        self.name = auth0UserInfo.name
        self.email = auth0UserInfo.email
        self.picture = auth0UserInfo.picture?.absoluteString
        self.sub = auth0UserInfo.sub
    }
}
