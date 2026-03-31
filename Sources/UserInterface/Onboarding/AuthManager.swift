// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Auth0
import WebKit
import JWTDecode
import WebKit
class AuthManager {
    static let shared = AuthManager()
    private(set) var currentCredentials: Credentials?
    private let browserAuthCallbackQueue = DispatchQueue(label: "com.phi.auth.browser-callback")
    private var pendingBrowserAuthCallback: ((URL) -> Void)?
    private var pendingBrowserAuthCallbackToken: UUID?
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
    
    // Renew throttling: allow at most once per hour unless close to expiry
    private var lastRenewAttemptAt: Date?
    private let renewCooldown: TimeInterval = 60 * 60 // 1 hour
    private let renewUrgentWindow: TimeInterval = 10 * 60 // 10 minutes before expiry
    
    // Periodic renew timer: ensures credentials are renewed even if app stays open
    private var renewTimer: Timer?
    
    #if DEBUG
    /// DEBUG builds can switch both Auth0 config and API base URL to staging.
    static let useStagingAuth0 = true
    #elseif NIGHTLY_BUILD
    static let useStagingAuth0 = true
    #else
    static let useStagingAuth0 = false
    #endif
    
    private let (domain, clicentId, audience) : (String, String, String) = {
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
            syncSharedAccessToken(results)
            startRenewTimer()
            return .success(results)
        } catch {
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
            _ = credentialManager.clear()
            lastRenewAttemptAt = nil
            currentCredentials = nil
            SharedAuthTokenStore.shared.clear()
            stopRenewTimer()
            return true
        } catch {
            AppLogError("logout with auth0 failed: \(error.localizedDescription)")
        }
        return false
    }
    
    func refreshAuthStatus() async {
        currentCredentials = await getActiveCredentials()
        if currentCredentials != nil {
            startRenewTimer()
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
        if let currentCredentials {
            return currentCredentials
        }

        do {
            let credential = try await credentialManager.credentials()
            self.currentCredentials = credential
            syncSharedAccessToken(credential)
            return credential
        } catch {
            logCredentialsFailure(error, operation: "retrieve active credentials")
            return nil
        }
    }
    
    func getActiveCredentialsSyncly() -> Credentials? {
        guard credentialManager.canRenew() else {
            return nil
        }
#if DEBUG
        if EnvironmentChecker.isRunningPreview {
            return nil
        }
#endif
        if let currentCredentials {
            return currentCredentials
        }

        var fetched: CredentialsManagerResult<Credentials>?
        let semaphore = DispatchSemaphore(value: 0)
        credentialManager.credentials { result in
            fetched = result
            semaphore.signal()
        }
        semaphore.wait()

        guard let fetched else {
            return nil
        }

        switch fetched {
        case .success(let creds):
            self.currentCredentials = creds
            return creds
        case .failure(let error):
            logCredentialsFailure(error, operation: "retrieve active credentials synchronously")
            return nil
        }
    }
    
    func checkLoginStatusOnChromiumLaunch() -> Bool {
        guard hasRecoverableLoginSession() else {
            return false
        }

        if let storedUserInfo = credentialManager.user {
            LoginController.shared.initAcoountWithUserInfo(storedUserInfo)
        } else if let credential = getActiveCredentialsSyncly() {
            LoginController.shared.initAccountIfNeeded(credential)
        } else {
            return false
        }

        return LoginController.shared.phase == .done
    }
    
    func getAccessTokenSyncly() -> String? {
        guard credentialManager.canRenew() else {
            return nil
        }
        let credential = getActiveCredentialsSyncly()
        return credential?.accessToken
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
        guard shouldRenewNow() else {
            AppLogInfo("skip renew: under cooldown; last attempt at: \(String(describing: lastRenewAttemptAt))")
            return
        }

        credentialManager.renew(parameters: ["audience": audience]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let credentials):
                // Record the attempt time immediately to avoid stampedes
                self.lastRenewAttemptAt = Date()
                self.currentCredentials = credentials
                self.syncSharedAccessToken(credentials)
                AppLogInfo("renew auth0 credentials successful, access token will be expired at: \(credentials.expiresIn)")
            case .failure(let error):
                self.logCredentialsFailure(error, operation: "renew credentials")
            }
        }
    }

    private func logCredentialsFailure(_ error: Error, operation: String) {
        if let managerError = error as? CredentialsManagerError {
            if shouldTransitionToLoggedOutState(for: managerError) {
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
        Task { @MainActor in
            AppLogInfo("transition auth state to login: clearing local credentials after unrecoverable session loss")
            _ = credentialManager.clear()
            SharedAuthTokenStore.shared.clear()
            currentCredentials = nil
            lastRenewAttemptAt = nil
            stopRenewTimer()
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

    private func syncSharedAccessToken(_ credentials: Credentials) {
        let auth0Sub = User(from: credentials.idToken).sub
        _ = SharedAuthTokenStore.shared.upsert(
            accessToken: credentials.accessToken,
            auth0Sub: auth0Sub,
            expiresAt: credentials.expiresIn
        )
    }

    private func makeExternalBrowserAuthProvider() -> WebAuthProvider {
        return { [weak self] authorizeURL, callback in
            let listenerRegistration: (@escaping (URL) -> Void) -> (() -> Void) = { listener in
                guard let self else { return {} }
                return self.registerBrowserAuthCallbackListener(listener)
            }

            return AuthManagerExternalBrowserWebAuthUserAgent(
                authorizeURL: authorizeURL,
                callback: callback,
                registerCallbackURLListener: listenerRegistration
            )
        }
    }

    func resumeExternalBrowserAuthentication(with url: URL) -> Bool {
        guard url.host == domain else {
            return false
        }
        let callback = browserAuthCallbackQueue.sync { pendingBrowserAuthCallback }
        guard let callback else {
            return false
        }
        callback(url)
        return true
    }

    func cancelOngoingWebAuthentication() {
        WebAuthentication.cancel()
        clearBrowserAuthCallbackListener()
    }

    private func registerBrowserAuthCallbackListener(_ listener: @escaping (URL) -> Void) -> (() -> Void) {
        let token = UUID()
        browserAuthCallbackQueue.sync {
            pendingBrowserAuthCallbackToken = token
            pendingBrowserAuthCallback = listener
        }
        return { [weak self] in
            self?.clearBrowserAuthCallbackListener(for: token)
        }
    }

    private func clearBrowserAuthCallbackListener(for token: UUID? = nil) {
        browserAuthCallbackQueue.sync {
            guard token == nil || token == pendingBrowserAuthCallbackToken else {
                return
            }
            pendingBrowserAuthCallbackToken = nil
            pendingBrowserAuthCallback = nil
        }
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
