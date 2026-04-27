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

    private lazy var authURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    
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
        // Keep Auth0's automatic retry window short. With rotating refresh tokens, a
        // missed successful response leaves the client holding the previous RT; delayed
        // retries can then exceed Auth0's overlap period and destroy the token family.
        return CredentialsManager(
            authentication: Auth0.authentication(clientId: clicentId, domain: domain, session: authURLSession),
            storeKey: storeKey,
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
    private let renewCooldown: TimeInterval = 60 * 60 // 1 hour
    private let renewUrgentWindow: TimeInterval = 30 * 60 // 30 minutes before expiry

    private var isRenewing = false
    private let failureTrace = AuthFailureTraceBuffer()
    // Dedupes Sentry forced-logout reports so a single token-family destruction
    // does not produce one event per concurrent caller.
    private var lastForcedLogoutReportAt: Date?
    private let forcedLogoutReportDedupeWindow: TimeInterval = 5 * 60

    // Periodic renew timer: checks whether credentials are close enough to expiry to renew.
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
            self.lastForcedLogoutReportAt = nil
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
            await stopRenewTimer()
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
    /// - access token is within the urgent window (~30 min from expiry).
    /// The periodic renew timer still checks long-running sessions for refresh needs.
    ///
    /// Delegates the urgent-window logic to `shouldRenewNow()` so reopen and
    /// the internal preflight in `renewCredentialsAsync` agree on what counts
    /// as "due for renewal". The explicit `isRenewing` check here is a
    /// fast-path optimization to avoid spawning a Task that the preflight
    /// would immediately skip; the preflight still does its own check.
    func shouldRenewOnReopen() -> Bool {
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
    @MainActor
    func startRenewTimer() {
        if let renewTimer, renewTimer.isValid {
            return
        }

        let timer = Timer(
            timeInterval: renewCooldown,
            repeats: true
        ) { [weak self] _ in
            AppLogInfo("periodic renew check fired")
            self?.renewCredentials()
        }

        renewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        AppLogInfo("renew timer started, interval: \(renewCooldown)s")
    }
    
    /// Stops the periodic renew timer. Should be called on logout or when credentials are cleared.
    @MainActor
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

        if credentialManager.store(credentials: credentials) {
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
