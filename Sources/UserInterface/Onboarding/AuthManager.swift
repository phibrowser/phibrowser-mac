// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Auth0
import WebKit
import JWTDecode

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
        }
    }

    func renderedTrace() -> String {
        queue.sync {
            guard !entries.isEmpty else {
                return "Auth trace is empty."
            }

            return entries.map { entry in
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
            .joined(separator: "\n")
        }
    }
}

class AuthManager {
    static let shared = AuthManager()
    private(set) var currentCredentials: Credentials?
    
    let browserAuthCallbackQueue = DispatchQueue(label: "com.phi.auth.browser-callback")
    var pendingBrowserAuthCallback: ((URL) -> Void)?
    var pendingBrowserAuthCallbackToken: UUID?
    
    private lazy var credentialManager: CredentialsManager =  {
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
        return CredentialsManager(authentication: Auth0.authentication(clientId: clicentId, domain: domain, session: URLSession.shared), storeKey: storeKey)
    }()
    
    // Renew throttling: allow at most once per hour unless close to expiry.
    // `lastRenewAttemptAt` is bumped on every renew attempt (success / failure / timeout)
    // and is used purely for cooldown decisions in `shouldRenewNow()`.
    private var lastRenewAttemptAt: Date?
    // `lastSuccessfulSyncAt` is only bumped when local credentials are known to be in sync
    // with the shared store (successful renew, or successful import from the shared store).
    // It MUST be the basis for the `shared_token_not_newer` short-circuit in
    // `performSharedStoreRecovery`; using `lastRenewAttemptAt` there would cause Phi to
    // skip importing a fresher Sentinel-written token after Phi had a recent failed renew,
    // which leaves the local Auth0 SDK with a rotated (stale) refresh token.
    private var lastSuccessfulSyncAt: Date?
    private let renewCooldown: TimeInterval = 60 * 60 // 1 hour
    private let renewUrgentWindow: TimeInterval = 10 * 60 // 10 minutes before expiry

    private var isRenewing = false
    private let failureTrace = AuthFailureTraceBuffer()
    // Dedupes Sentry forced-logout reports so a single token-family destruction
    // does not produce one event per concurrent caller.
    private var lastForcedLogoutReportAt: Date?
    private let forcedLogoutReportDedupeWindow: TimeInterval = 5 * 60

    // Periodic renew timer: ensures credentials are renewed even if app stays open
    private var renewTimer: Timer?
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

    @MainActor
    func login() async -> Result<Credentials, Error> {
        recordTrace("login-started")
        do {
            // Browser URL scheme handling conflicts with AuthenticationServices, so login runs
            // in the default browser and resumes through the callback URL.
            let results = try await Auth0.webAuth(clientId: clicentId, domain: domain)
                .audience(audience)
                .scope("openid profile email offline_access")
                .provider(makeExternalBrowserAuthProvider())
                .start()
            _ = credentialManager.store(credentials: results)
            self.currentCredentials = results
            self.lastRenewAttemptAt = Date()
            self.lastSuccessfulSyncAt = Date()
            self.lastForcedLogoutReportAt = nil
            syncSharedTokens(results)
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
    
    func logOut() async -> Bool {
        do {
            // Google does not support the federated logout flow we want here, so keep it disabled
            // and clear local web state instead.
            try await Auth0
                .webAuth(clientId: clicentId, domain: domain)
                .provider(makeExternalBrowserAuthProvider())
                .clearSession(federated: false)
            recordTrace("user-logout-started")
            _ = credentialManager.clear()
            lastRenewAttemptAt = nil
            lastSuccessfulSyncAt = nil
            lastForcedLogoutReportAt = nil
            currentCredentials = nil
            SharedAuthTokenStore.shared.clear()
            stopRenewTimer()
            stopHeartbeat()
            recordTrace("user-logout-succeeded")
            return true
        } catch {
            recordTrace("user-logout-failed", details: ["error": error.localizedDescription])
            AppLogError("logout with auth0 failed: \(error.localizedDescription)")
        }
        return false
    }
    
    func refreshAuthStatus() async {
        recordTrace("refresh-auth-status-started")
        // `getActiveCredentials()` itself performs shared-store recovery on cache miss;
        // calling `recoverFromSharedStoreIfNeeded` again here would just double-acquire
        // the cross-process lock for no benefit.
        currentCredentials = await getActiveCredentials()
        if currentCredentials != nil {
            startRenewTimer()
            startHeartbeat()
            writeSharedAuth0Config()
            recordTrace("refresh-auth-status-restored", details: credentialSnapshotDetails())
        } else {
            recordTrace("refresh-auth-status-no-credentials")
        }
    }

    /// Alwayws used to determin wheather the use has logged in
    func hasRecoverableLoginSession() -> Bool {
#if DEBUG
        if EnvironmentChecker.isRunningPreview {
            return false
        }
#endif
        return credentialManager.canRenew()
    }
    
    func getActiveCredentials() async -> Credentials? {
#if DEBUG
        if EnvironmentChecker.isRunningPreview {
            return nil
        }
#endif
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
    
    func checkLoginStatusOnChromiumLaunch() -> Bool {
        guard hasRecoverableLoginSession() else {
            return false
        }

        if let storedUserInfo = credentialManager.user {
            LoginController.shared.initAcoountWithUserInfo(storedUserInfo)
        } else if let currentCredentials {
            LoginController.shared.initAccountIfNeeded(currentCredentials)
        } else {
            return false
        }

        return LoginController.shared.phase == .done
    }
    
    func getAccessTokenSyncly() -> String? {
        guard credentialManager.canRenew() else {
            return nil
        }
        if let currentCredentials {
            if currentCredentials.expiresIn.timeIntervalSinceNow > 0 {
                return currentCredentials.accessToken
            }
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
        guard let last = lastRenewAttemptAt else { return true }
        let now = Date()
        if let exp = currentCredentials?.expiresIn {
            let secondsToExpiry = exp.timeIntervalSince(now)
            if secondsToExpiry <= renewUrgentWindow { return true }
        }
        return now.timeIntervalSince(last) >= renewCooldown
    }
    
    func renewCredentials() {
        Task { _ = await renewCredentialsAsync(operation: "renew credentials") }
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
            if isRenewing {
                recordTrace("renew-skipped", details: ["reason": "already_in_progress"])
                AppLogDebug("[TokenRenew] skip renew: already in progress")
                return .skip
            }
            if !shouldRenewNow() {
                recordTrace(
                    "renew-skipped",
                    details: [
                        "reason": "cooldown",
                        "lastRenewAttemptAt": iso8601String(lastRenewAttemptAt)
                    ]
                )
                AppLogInfo("[TokenRenew] skip renew: under cooldown; last attempt at: \(String(describing: lastRenewAttemptAt))")
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
        if credentialManager.store(credentials: imported) {
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
                    AppLogError("[TokenRenew] renew timed out after 30s, releasing lock")
                    self.lastRenewAttemptAt = Date()
                    self.isRenewing = false
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)

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

                Task { @MainActor in
                    switch result {
                    case .success(let credentials):
                        self.lastRenewAttemptAt = Date()
                        self.lastSuccessfulSyncAt = Date()
                        self.currentCredentials = credentials
                        self.syncSharedTokens(credentials)
                        self.recordTrace("renew-succeeded", details: self.credentialSnapshotDetails())
                        AppLogInfo("[TokenRenew] renew successful, expires at: \(credentials.expiresIn)")
                        self.isRenewing = false
                        continuation.resume(returning: credentials)
                    case .failure(let error):
                        self.lastRenewAttemptAt = Date()
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
            if shouldTransitionToLoggedOutState(for: managerError) {
                recordTrace(
                    "transition-to-logged-out",
                    details: ["reason": failureReason, "operation": operation],
                    callStackSymbols: Array(Thread.callStackSymbols.prefix(16))
                )
                reportForcedLogoutIfNeeded(operation: operation, reason: failureReason, details: details)
                transitionToLoggedOutState()
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

    /// A single token-family destruction can be observed by several concurrent callers
    /// (`APIClient.token`, `MessageRouter`, `SetNameViewController`, the renew timer,
    /// etc.). Without dedupe, every one of them would push a Sentry event, drowning the
    /// dashboard. Dedupe within a short window per process; the first caller still
    /// records full context.
    private func reportForcedLogoutIfNeeded(
        operation: String,
        reason: String,
        details: [String: String]
    ) {
        if let lastReportedAt = lastForcedLogoutReportAt,
           Date().timeIntervalSince(lastReportedAt) < forcedLogoutReportDedupeWindow {
            recordTrace(
                "forced-logout-report-suppressed",
                details: [
                    "reason": reason,
                    "operation": operation,
                    "lastReportedAt": iso8601String(lastReportedAt)
                ]
            )
            return
        }
        lastForcedLogoutReportAt = Date()
        SentryService.captureAuthForcedLogout(
            operation: operation,
            reason: reason,
            trace: failureTrace.renderedTrace(),
            attributes: details
        )
    }

    private func shouldTransitionToLoggedOutState(for managerError: CredentialsManagerError) -> Bool {
        if CredentialsManagerError.noCredentials ~= managerError ||
            CredentialsManagerError.noRefreshToken ~= managerError {
            return true
        }

        guard CredentialsManagerError.renewFailed ~= managerError,
              let authError = managerError.cause as? AuthenticationError else {
            return false
        }

        return authError.isInvalidRefreshToken || authError.isRefreshTokenDeleted
    }

    private func transitionToLoggedOutState() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AppLogInfo("transition auth state to login: clearing local credentials after unrecoverable session loss")
            _ = self.credentialManager.clear()
            SharedAuthTokenStore.shared.clear()
            self.currentCredentials = nil
            self.lastRenewAttemptAt = nil
            self.lastSuccessfulSyncAt = nil
            self.stopRenewTimer()
            self.stopHeartbeat()
            LoginController.shared.phase = .login
            AccountController.shared.account = nil
            MainBrowserWindowControllersManager.shared.closeAllWindows()
            LoginController.shared.showLoginWindow()
        }
    }
    
    // MARK: - Periodic Renew Timer
    
    /// Starts the periodic renew timer. Should be called after successful login or credential restoration.
    /// The timer fires every hour and calls renewCredentials(), which internally checks shouldRenewNow()
    /// to avoid redundant renew attempts if a manual renew happened recently.
    func startRenewTimer() {
        // Invalidate any existing timer to avoid duplicates
        stopRenewTimer()
        
        // Schedule timer on main run loop
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renewTimer = Timer.scheduledTimer(
                withTimeInterval: self.renewCooldown,
                repeats: true
            ) { [weak self] _ in
                AppLogInfo("periodic renew timer fired")
                self?.renewCredentials()
            }
            // Ensure timer fires even when UI is tracking (e.g., during scrolling)
            if let timer = self.renewTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
            AppLogInfo("renew timer started, interval: \(self.renewCooldown)s")
        }
    }
    
    /// Stops the periodic renew timer. Should be called on logout or when credentials are cleared.
    func stopRenewTimer() {
        renewTimer?.invalidate()
        renewTimer = nil
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

    func recoverFromSharedStoreIfNeeded() async {
        await recoverFromSharedStoreIfNeeded(reason: "unspecified")
    }

    func recoverFromSharedStoreIfNeeded(reason: String) async {
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
        guard let sharedToken = SharedAuthTokenStore.shared.read() else {
            recordTrace("shared-store-recovery-skipped", details: ["reason": "\(reason):no_shared_token"])
            return
        }

        if let lastSyncedAt, sharedToken.updatedAt <= lastSyncedAt {
            recordTrace("shared-store-recovery-skipped", details: ["reason": "\(reason):shared_token_not_newer"])
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

        if credentialManager.store(credentials: credentials) {
            self.currentCredentials = credentials
            self.lastSuccessfulSyncAt = sharedToken.updatedAt
            recordTrace("shared-store-recovery-imported-token", details: sharedTokenDetails(sharedToken))
            AppLogInfo("[TokenRenew] imported shared token (renewedBy=\(sharedToken.renewedBy ?? "unknown"), expireDate=\(sharedExpiresAt), updatedAt=\(sharedToken.updatedAt))")
        }
    }

    private func syncSharedTokens(_ credentials: Credentials, renewedBy: String = "phi") {
        let auth0Sub = User(from: credentials.idToken).sub
        _ = SharedAuthTokenStore.shared.upsert(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            idToken: credentials.idToken,
            auth0Sub: auth0Sub,
            expiresAt: credentials.expiresIn,
            renewedBy: renewedBy
        )
    }

    private func recordTrace(
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

    private func credentialSnapshotDetails() -> [String: String] {
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

    private func iso8601String(_ date: Date?) -> String {
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
