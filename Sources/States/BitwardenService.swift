// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation
import Security

final class BitwardenSessionPersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptsPersistence = true

    func performIfEnabled<T>(_ operation: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsPersistence else { return nil }
        return operation()
    }

    /// Waits for an in-flight Keychain operation and prevents all later ones.
    /// Callers must release this lock before waiting on the helper client queue.
    func fence() {
        lock.lock()
        acceptsPersistence = false
        lock.unlock()
    }

    func performExclusive<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    func resume() {
        lock.lock()
        acceptsPersistence = true
        lock.unlock()
    }
}

/// App-scoped owner of the Bitwarden integration, sibling to `ProfileManager.shared`
/// (per AGENTS.md: reuse the existing singleton pattern, do not add a new state
/// hierarchy). Conforms to `CredentialProvider`, so onboarding, settings, and the
/// agent `credentials.*` handlers depend on the protocol, never on Bitwarden
/// specifics.
///
/// All vault crypto lives out of process in `PhiBitwardenHelper` (the GPL boundary
/// that links the Bitwarden SDK). This class spawns that helper on demand with one
/// end of a socketpair(2) as its stdin — no filesystem socket exists, so no other
/// process can reach or impersonate either side — and talks framed JSON over it
/// using the same length-prefix + challenge handshake as `SentinelIPCClient`.
/// Secrets returned by the helper are wrapped in `RedactedSecret` the moment they
/// cross back into the app.
final class BitwardenService: ObservableObject, CredentialProvider {
    static let shared = BitwardenService()

    let id = "bitwarden"
    let displayName = "Bitwarden"

    /// Last observed status, published for settings/onboarding views. Refreshed
    /// by `refreshStatus()` and after every state-changing call.
    @Published private(set) var currentStatus: CredentialProviderStatus = .notInstalled

    private let client = BitwardenHelperClient()
    private let sessionPersistenceGate = BitwardenSessionPersistenceGate()

    private init() {
        // System-lock timeout: the helper can't see the macOS screen lock, so the
        // app watches for it and applies the action when that policy is chosen.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemLock()
        }

        // Session custody lives in the app's Keychain, not the helper (which is a
        // world-executable signed binary an attacker could spawn). Feed the
        // transport a `restore` built from that store — sent after every
        // handshake — and a sink for the helper's `persist` events. See
        // BitwardenSessionStore and docs/bitwarden-password-manager.md §7.
        let persistenceGate = sessionPersistenceGate
        client.sessionRestoreProvider = {
            persistenceGate.performIfEnabled {
                BitwardenSessionStore.load().map(Self.restoreParams(for:))
            } ?? nil
        }
        client.persistEventHandler = { session in
            persistenceGate.performIfEnabled {
                guard let session, let email = session["email"] as? String else {
                    BitwardenSessionStore.clear()
                    return
                }
                let server = session["server"] as? [String: Any]
                BitwardenSessionStore.save(BitwardenPersistedSession(
                    email: email,
                    masterPassword: session["masterPassword"] as? String,
                    twoFactorToken: session["twoFactorToken"] as? String,
                    identityURL: server?["identityUrl"] as? String,
                    apiURL: server?["apiUrl"] as? String))
            }
        }
        client.restoreFailureHandler = {
            persistenceGate.performIfEnabled {
                BitwardenSessionStore.clear()
            }
        }
    }

    /// Stops all helper activity and makes the session Keychain deletion the
    /// final possible write. A failed strict clear resumes the integration so a
    /// cancelled uninstall does not leave Bitwarden disabled until relaunch.
    func prepareForUninstall() async throws {
        sessionPersistenceGate.fence()
        await client.shutdownForUninstall()
        do {
            try sessionPersistenceGate.performExclusive {
                try BitwardenSessionStore.clearAndVerifyForUninstall()
            }
        } catch {
            sessionPersistenceGate.resume()
            await client.resumeAfterCancelledUninstall()
            throw error
        }
    }

    func resumeAfterCancelledUninstall() async {
        sessionPersistenceGate.resume()
        await client.resumeAfterCancelledUninstall()
    }

    /// Builds the `restore` params for a stored session, tagging on the current
    /// session-timeout policy so the re-established helper enforces and persists
    /// under the right policy immediately.
    private static func restoreParams(for session: BitwardenPersistedSession) -> [String: Any] {
        var params: [String: Any] = [
            "email": session.email,
            "timeout": BitwardenSessionTimeout.current.rawValue,
            "action": BitwardenTimeoutAction.current.rawValue,
        ]
        if let password = session.masterPassword { params["masterPassword"] = password }
        if let token = session.twoFactorToken { params["twoFactorToken"] = token }
        if let identityURL = session.identityURL, let apiURL = session.apiURL,
           !identityURL.isEmpty, !apiURL.isEmpty {
            params["server"] = ["identityUrl": identityURL, "apiUrl": apiURL]
        }
        return params
    }

    private func handleSystemLock() {
        guard BitwardenSessionTimeout.current == .onSystemLock else { return }
        Task {
            switch BitwardenTimeoutAction.current {
            case .lock: await self.lock()
            case .logOut: try? await self.logout()
            }
        }
    }

    // MARK: - CredentialProvider

    func status() async -> CredentialProviderStatus {
        do {
            let result = try await client.send(method: "status", params: [:])
            let status = Self.parseStatus(result)
            await MainActor.run { self.currentStatus = status }
            return status
        } catch {
            let status: CredentialProviderStatus =
                (error as? BitwardenHelperClient.ClientError) == .helperUnavailable
                ? .notInstalled
                : .unavailable(reason: error.localizedDescription)
            await MainActor.run { self.currentStatus = status }
            return status
        }
    }

    /// Convenience for views that want to kick a refresh without using the value.
    @discardableResult
    func refreshStatus() async -> CredentialProviderStatus { await status() }

    /// `identityURL`/`apiURL` target a non-default server (EU cloud or a
    /// self-hosted instance). Pass both or neither; omitting them uses the
    /// default US cloud. The caller (login sheet) derives them from the chosen
    /// server region, so this stays vendor-URL-agnostic.
    /// `newDeviceOtp` is the code Bitwarden emails when it does not recognize
    /// this install as a known device. Omit it on the first attempt: that
    /// attempt is what makes the server send the mail, and it comes back as
    /// `BitwardenHelperErrorCode.newDeviceVerificationRequired` so the sign-in
    /// sheet can ask for the code and retry.
    func login(
        email: String,
        masterPassword: String,
        twoFactor: String?,
        newDeviceOtp: String? = nil,
        identityURL: String? = nil,
        apiURL: String? = nil
    ) async throws {
        var params: [String: Any] = [
            "email": email,
            "masterPassword": masterPassword,
            // The session-timeout policy travels with the login so the helper
            // knows what to persist for the next start.
            "timeout": BitwardenSessionTimeout.current.rawValue,
            "action": BitwardenTimeoutAction.current.rawValue,
        ]
        if let twoFactor { params["twoFactor"] = twoFactor }
        if let newDeviceOtp, !newDeviceOtp.isEmpty { params["newDeviceOtp"] = newDeviceOtp }
        if let identityURL, let apiURL, !identityURL.isEmpty, !apiURL.isEmpty {
            params["server"] = ["identityUrl": identityURL, "apiUrl": apiURL]
        }
        // Login covers identity round trips + a full vault sync; the default
        // 10s transport timeout is too tight for it.
        _ = try await client.send(method: "login", params: params, timeout: 60)
        _ = await status()
    }

    /// Pushes the current session-timeout policy to a running helper (on startup
    /// and whenever the setting changes), so idle/restart behavior tracks it
    /// without waiting for the next login.
    func applyTimeoutPolicy() async {
        _ = try? await client.send(method: "setTimeout", params: [
            "timeout": BitwardenSessionTimeout.current.rawValue,
            "action": BitwardenTimeoutAction.current.rawValue,
        ])
    }

    /// `twoFactor` is a freshly typed second-factor code, needed only when a
    /// 2FA account's remember token is absent or expired (the helper replays
    /// its stored token otherwise).
    func unlock(secret: String?, twoFactor: String? = nil, newDeviceOtp: String? = nil) async throws {
        var params: [String: Any] = [:]
        if let secret { params["masterPassword"] = secret }
        if let twoFactor, !twoFactor.isEmpty { params["twoFactor"] = twoFactor }
        if let newDeviceOtp, !newDeviceOtp.isEmpty { params["newDeviceOtp"] = newDeviceOtp }
        _ = try await client.send(method: "unlock", params: params, timeout: 60)
        _ = await status()
    }

    func lock() async {
        _ = try? await client.send(method: "lock", params: [:])
        _ = await status()
    }

    func logout() async throws {
        _ = try await client.send(method: "logout", params: [:])
        _ = await status()
    }

    func lookup(_ query: CredentialQuery) async throws -> CredentialLookupResult {
        let cached = currentStatus
        if case .ready = cached {} else {
            // Re-check once before failing; status may be stale.
            let fresh = await status()
            if case .ready = fresh {} else { return .notReady(fresh) }
        }

        let result = try await client.send(method: "lookup", params: Self.queryParams(query))
        guard let found = result["found"] as? Bool else {
            throw CredentialProviderError.providerFailure(message: "Malformed lookup response")
        }
        // Several items fit the query: the helper released no secret, only
        // candidate identities for narrowing (see CredentialLookupResult).
        if result["ambiguous"] as? Bool == true {
            let candidates = (result["candidates"] as? [[String: Any]] ?? []).map {
                CredentialLookupCandidate(
                    credentialId: $0["credentialId"] as? String,
                    type: $0["type"] as? String,
                    name: $0["name"] as? String,
                    username: $0["username"] as? String,
                    uri: $0["uri"] as? String,
                    domain: $0["domain"] as? String)
            }
            return .ambiguous(candidates)
        }
        if !found { return .notFound }
        guard let item = result["item"] as? [String: Any] else {
            throw CredentialProviderError.providerFailure(message: "Missing item in lookup response")
        }
        return .found(Self.parseItem(item), matches: result["matches"] as? Int ?? 1)
    }

    func totp(for query: CredentialQuery) async throws -> RedactedSecret? {
        let result = try await client.send(method: "getTotp", params: Self.queryParams(query))
        guard let totp = result["totp"] as? String, !totp.isEmpty else { return nil }
        return RedactedSecret(totp)
    }

    // MARK: - Wire mapping

    private static func queryParams(_ query: CredentialQuery) -> [String: Any] {
        switch query {
        case .domain(let d, let username):
            var q: [String: Any] = ["domain": d]
            if let username, !username.isEmpty { q["username"] = username }
            return ["query": q]
        case .itemId(let i): return ["query": ["id": i]]
        case .search(let s): return ["query": ["search": s]]
        }
    }

    private static func parseStatus(_ result: [String: Any]) -> CredentialProviderStatus {
        switch result["status"] as? String {
        case "notInstalled": return .notInstalled
        case "notConfigured", "loggedOut": return .loggedOut
        case "locked": return .locked
        case "unlocked": return .ready(account: result["account"] as? String)
        default: return .unavailable(reason: "Unknown helper status")
        }
    }

    private static func parseItem(_ dict: [String: Any]) -> CredentialItem {
        func secret(_ key: String) -> RedactedSecret? {
            guard let s = dict[key] as? String, !s.isEmpty else { return nil }
            return RedactedSecret(s)
        }
        // Fixed keys are parsed by name; every other string the helper sends
        // is a type-specific field (card / identity / SSH key), carried
        // wire-named and uniformly redacted.
        let fixed: Set<String> = ["credentialId", "type", "name", "domain", "uri",
                                  "username", "password", "totp", "notes"]
        var typed: [String: RedactedSecret] = [:]
        for (key, value) in dict where !fixed.contains(key) {
            if let s = value as? String, !s.isEmpty { typed[key] = RedactedSecret(s) }
        }
        return CredentialItem(
            credentialId: dict["credentialId"] as? String,
            type: dict["type"] as? String,
            name: dict["name"] as? String,
            domain: dict["domain"] as? String,
            uri: dict["uri"] as? String,
            username: dict["username"] as? String,
            password: secret("password"),
            totp: secret("totp"),
            notes: secret("notes"),
            typed: typed
        )
    }
}

/// The `error.code` values the helper sends beside its message (its
/// `EngineError::code`), naming the failures a caller must *act* on: each one
/// says which credential the server is still missing. Failures without a code
/// are display-only.
enum BitwardenHelperErrorCode: String {
    /// The account's second factor is required and no remembered device trust
    /// covers this login.
    case twoFactorRequired
    /// Bitwarden's new-device login protection: the server does not recognize
    /// this install and has emailed a one-time code, which the next attempt
    /// must carry as `newDeviceOtp`.
    case newDeviceVerificationRequired
    /// The code sent with the last attempt was wrong or expired; a fresh one
    /// has been emailed.
    case invalidNewDeviceOtp
}

/// Low-level transport to `PhiBitwardenHelper`. Spawns the helper with one end
/// of a socketpair(2) as its stdin — there is no filesystem socket, so no other
/// process can connect to or impersonate either side — and keeps that single
/// connection for the helper's lifetime. Mirrors `SentinelIPCClient`'s framing
/// so the two IPC surfaces stay recognizably the same: a challenge handshake,
/// then 4-byte big-endian length prefixes around JSON payloads. Replies are
/// matched to requests by the echoed `request_id`, so a slow call (a 60s
/// `login`) never blocks a concurrent quick one (`status`).
///
/// This deliberately does not share a source file with the helper — like
/// `SentinelIPCClient`, each side re-implements the wire contract, keeping the
/// Apache app and the GPL helper cleanly separated at the process boundary.
final class BitwardenHelperClient: @unchecked Sendable {
    enum ClientError: Error, Equatable, LocalizedError {
        case helperUnavailable
        case untrustedHelper
        case connectionFailed
        case handshakeFailed
        case ioFailed
        case frameTooLarge
        case invalidResponse
        /// A failure the helper reported. `code` is present only for the ones a
        /// caller acts on rather than merely displays — see
        /// `BitwardenHelperErrorCode`.
        case helperError(message: String, code: String?)
        case shuttingDown

        /// Without this, every case renders as Foundation's opaque
        /// "The operation couldn't be completed." — in particular swallowing
        /// the helper's human-readable failure message in `helperError`.
        var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                return "The Bitwarden helper is not available in this build."
            case .untrustedHelper:
                return "The Bitwarden helper failed its code signature check."
            case .connectionFailed:
                return "Could not connect to the Bitwarden helper."
            case .handshakeFailed:
                return "The Bitwarden helper handshake failed."
            case .ioFailed:
                return "Lost the connection to the Bitwarden helper."
            case .frameTooLarge:
                return "The Bitwarden helper sent an oversized response."
            case .invalidResponse:
                return "The Bitwarden helper sent an invalid response."
            case .helperError(let message, _):
                return message
            case .shuttingDown:
                return "The Bitwarden helper is shutting down."
            }
        }

        /// The actionable code the helper tagged this failure with, if any.
        var helperCode: BitwardenHelperErrorCode? {
            guard case .helperError(_, let code) = self, let code else { return nil }
            return BitwardenHelperErrorCode(rawValue: code)
        }
    }

    private let clientVersion = "1.0.0"
    private let protocolVersion = 1

    /// Returns the `restore` params — built from the app's Keychain — to send
    /// right after the handshake on every freshly spawned helper, or nil when no
    /// session is stored. Set once by `BitwardenService` before any `send`; read
    /// on `queue`. This is how a restarted (or respawned) helper gets its session
    /// without ever reading a store of its own.
    var sessionRestoreProvider: (() -> [String: Any]?)?

    /// Receives a `persist` event's `session` payload (nil = forget) so the app
    /// can write its Keychain. Invoked on the reader thread; set once at startup.
    var persistEventHandler: (([String: Any]?) -> Void)?

    /// Called when a startup `restore` is rejected (the stored session no longer
    /// works) so the app can drop the now-stale Keychain record.
    var restoreFailureHandler: (() -> Void)?

    /// Serializes spawn and request writes; `connection` is only touched here.
    private let queue = DispatchQueue(label: "com.phibrowser.bitwarden-helper", qos: .userInitiated)
    private var connection: Connection?
    private var isShutDown = false

    /// Sends one request, spawning the helper first if it is not already up. If
    /// the connection fails (the helper died or never came up), drops it and
    /// respawns once before giving up.
    ///
    /// `timeout` bounds the wait for this request's reply. The default suits
    /// quick calls (`status`, `lookup`); `login` needs longer — it covers
    /// identity round trips plus a full vault sync before the helper responds.
    func send(
        method: String,
        params: [String: Any],
        timeout: TimeInterval = 10
    ) async throws -> [String: Any] {
        do {
            return try await attempt(method: method, params: params, timeout: timeout)
        } catch ClientError.connectionFailed {
            queue.sync {
                connection?.teardown()
                connection = nil
            }
            return try await attempt(method: method, params: params, timeout: timeout)
        }
    }

    func shutdownForUninstall() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isShutDown = true
                let activeConnection = connection
                connection = nil
                activeConnection?.teardown(
                    failingWith: ClientError.shuttingDown,
                    waitForProcessExit: true
                )
                continuation.resume()
            }
        }
    }

    func resumeAfterCancelledUninstall() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isShutDown = false
                continuation.resume()
            }
        }
    }

    static func terminateProcessForUninstall(
        _ process: Process,
        timeout: TimeInterval = 1
    ) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func attempt(
        method: String,
        params: [String: Any],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let response: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !isShutDown else { throw ClientError.shuttingDown }
                    let connection = try ensureConnection()
                    let requestID = UUID().uuidString
                    let request: [String: Any] = [
                        "protocol_version": protocolVersion,
                        "request_id": requestID,
                        "method": method,
                        "params": params,
                    ]
                    connection.submit(
                        id: requestID, request: request, timeout: timeout,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard let ok = response["ok"] as? Bool else { throw ClientError.invalidResponse }
        if ok { return response["result"] as? [String: Any] ?? [:] }
        let error = response["error"] as? [String: Any]
        let message = error?["message"] as? String ?? "Helper error"
        throw ClientError.helperError(message: message, code: error?["code"] as? String)
    }

    // MARK: - Helper lifecycle

    /// Absolute path to the embedded helper executable inside the app bundle
    /// (`Contents/Helpers/PhiBitwardenHelper`, copied by the "Copy Bitwarden
    /// Helper" build phase).
    private func helperExecutableURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PhiBitwardenHelper", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Helper identity pinning

    /// The pinned code-signing requirement the helper must satisfy before it is
    /// launched and handed vault secrets: correctly signed, the helper's signing
    /// identifier, and the same team that signed this app. Where the app bundle
    /// sits user-writable, a swapped-in binary would otherwise receive the
    /// master password on the very next login/restore. The team is read from the
    /// app's own signature at runtime, so canary and release (different bundle
    /// ids, one team) share the pin without a hardcoded constant.
    ///
    /// Returns nil in debug builds — enforcement off: the install-into-phi.sh
    /// hot-swap loop ad-hoc-signs the helper, which can never satisfy a team
    /// pin. Release fails closed: an app with no readable team identity refuses
    /// the helper rather than serving secrets blind.
    private static func pinnedHelperRequirement() throws -> SecRequirement? {
        #if DEBUG
            return nil
        #else
            guard let team = appTeamIdentifier() else { throw ClientError.untrustedHelper }
            let text = "anchor apple generic and identifier \"PhiBitwardenHelper\""
                + " and certificate leaf[subject.OU] = \"\(team)\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                let requirement
            else { throw ClientError.untrustedHelper }
            return requirement
        #endif
    }

    /// Team identifier from this app's own code signature, or nil when the app
    /// is unsigned/ad-hoc.
    private static func appTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Static (on-disk) validation of the helper against the pin, before it is
    /// launched — untrusted code must not run at all, even briefly: a spawned
    /// child inherits attribution to this app (e.g. its TCC grants).
    private static func helperOnDiskSatisfies(_ requirement: SecRequirement, at url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Returns the live connection, spawning the helper first if the previous
    /// one died (or none exists yet). Runs on `queue`. No peer authentication
    /// is needed in either direction: the socketpair has no filesystem name, so
    /// the kernel guarantees each end talks only to the other. What the socket
    /// cannot guarantee is *which code* was spawned — that is the identity
    /// gate below (see `pinnedHelperRequirement`).
    private func ensureConnection() throws -> Connection {
        guard !isShutDown else { throw ClientError.shuttingDown }
        if let connection, connection.isAlive { return connection }
        connection?.teardown()
        connection = nil
        guard let executable = helperExecutableURL() else { throw ClientError.helperUnavailable }
        // Identity gate: never launch a helper that fails the pinned signing
        // requirement (nil = debug build, enforcement off).
        let requirement = try Self.pinnedHelperRequirement()
        if let requirement, !Self.helperOnDiskSatisfies(requirement, at: executable) {
            throw ClientError.untrustedHelper
        }
        // Every fresh helper starts with no session; feed it the one the app
        // holds (if any) as a `restore` sent before any other request, so this
        // spawn is re-established exactly as the last one left it.
        let restoreParams = sessionRestoreProvider?()
        let fresh = try Connection.spawn(
            executable: executable,
            requirement: requirement,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion,
            restoreParams: restoreParams,
            persistHandler: persistEventHandler,
            onRestoreFailure: restoreFailureHandler
        )
        connection = fresh
        return fresh
    }

    // MARK: - Transport

    /// One spawned helper process plus the app-side end of its socketpair, with
    /// a blocking reader thread demuxing framed replies to pending continuations
    /// by `request_id`. Created and written to on the client's serial queue;
    /// replaced as a unit when the helper dies.
    private final class Connection: @unchecked Sendable {
        private let fd: Int32
        private let process: Process
        private let lock = NSLock()
        private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
        private var dead = false
        /// Sink for unsolicited `persist` event frames (see `handleEventFrame`).
        private let persistHandler: (([String: Any]?) -> Void)?
        private let protocolVersion: Int

        /// Creates the socketpair, spawns the helper with the far end as its
        /// stdin, completes the challenge handshake (bounded at 5s), then — if
        /// the app holds a session — sends and awaits a `restore` so the vault is
        /// re-established before any caller request is processed. The reader
        /// starts only after that, so the restore cannot race a concurrent
        /// request in the helper (which handles requests on independent threads).
        static func spawn(
            executable: URL,
            requirement: SecRequirement?,
            clientVersion: String,
            protocolVersion: Int,
            restoreParams: [String: Any]?,
            persistHandler: (([String: Any]?) -> Void)?,
            onRestoreFailure: (() -> Void)?
        ) throws -> Connection {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw ClientError.connectionFailed
            }
            let appEnd = fds[0]
            let helperEnd = fds[1]
            // Keep our end out of any other children the app spawns.
            _ = fcntl(appEnd, F_SETFD, FD_CLOEXEC)

            let process = Process()
            process.executableURL = executable
            process.standardInput = FileHandle(fileDescriptor: helperEnd, closeOnDealloc: false)
            // The helper keeps its Bitwarden device identifier inside the
            // browser's own data folder rather than a folder of its own.
            var environment = ProcessInfo.processInfo.environment
            environment["PHI_BROWSER_DATA_DIR"] = FileSystemUtils.applicationSupportDirctory()
            process.environment = environment
            do {
                try process.run()
            } catch {
                close(appEnd)
                close(helperEnd)
                throw ClientError.helperUnavailable
            }
            // The helper holds its own copy of this end now; ours must go, or
            // we never see EOF when the helper dies.
            close(helperEnd)

            // Re-check the *running* process against the pin before the
            // handshake (and the restore that follows it, which carries the
            // master password). The on-disk check runs pre-launch; this one
            // closes the window in which the file could be swapped between
            // validation and exec — a running process can no longer change
            // its code identity.
            if let requirement,
                !runningProcessSatisfies(requirement, pid: process.processIdentifier)
            {
                process.terminate()
                close(appEnd)
                throw ClientError.untrustedHelper
            }

            let connection = Connection(
                fd: appEnd, process: process,
                persistHandler: persistHandler, protocolVersion: protocolVersion)
            do {
                try connection.handshake(clientVersion: clientVersion, protocolVersion: protocolVersion)
            } catch {
                connection.teardown()
                throw error
            }
            // Restore before the reader starts: synchronous request/response on
            // the raw fd, so the vault is up before any caller request is sent.
            if let restoreParams {
                connection.performInlineRestore(params: restoreParams, onFailure: onRestoreFailure)
            }
            connection.startReader()
            return connection
        }

        /// Dynamic validation of an already-running helper process against the
        /// pinned requirement, via its code object rather than its on-disk file.
        private static func runningProcessSatisfies(
            _ requirement: SecRequirement, pid: Int32
        ) -> Bool {
            let attributes = [kSecGuestAttributePid: pid] as CFDictionary
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
                let code
            else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }

        private init(
            fd: Int32,
            process: Process,
            persistHandler: (([String: Any]?) -> Void)?,
            protocolVersion: Int
        ) {
            self.fd = fd
            self.process = process
            self.persistHandler = persistHandler
            self.protocolVersion = protocolVersion
            // Bound writes so a wedged helper cannot hang the client queue;
            // reads stay unbounded (per-request timers do the bounding).
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            withUnsafePointer(to: &tv) {
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
        }

        deinit {
            close(fd)
        }

        var isAlive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !dead && process.isRunning
        }

        /// Registers the continuation and writes the frame. Owns the
        /// continuation from here on: exactly one of the reader, the timeout,
        /// or a write failure resumes it.
        func submit(
            id: String,
            request: [String: Any],
            timeout: TimeInterval,
            continuation: CheckedContinuation<[String: Any], Error>
        ) {
            lock.lock()
            if dead {
                lock.unlock()
                continuation.resume(throwing: ClientError.connectionFailed)
                return
            }
            pending[id] = continuation
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.take(id)?.resume(throwing: ClientError.ioFailed)
            }

            do {
                try writeFrame(request)
            } catch {
                // Nothing reached the helper, so the submitter may retry;
                // anything else in flight is genuinely lost.
                markDead()
                take(id)?.resume(throwing: ClientError.connectionFailed)
                failAll(with: ClientError.ioFailed)
            }
        }

        /// Wakes the reader (which fails anything in flight) and reaps the
        /// helper. Idempotent; the fd itself closes in `deinit` once the reader
        /// thread has exited.
        func teardown(
            failingWith error: Error = ClientError.ioFailed,
            waitForProcessExit: Bool = false
        ) {
            markDead()
            failAll(with: error)
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            if waitForProcessExit {
                BitwardenHelperClient.terminateProcessForUninstall(process)
            } else if process.isRunning {
                process.terminate()
            }
        }

        // MARK: Reader

        private func startReader() {
            let thread = Thread { [self] in
                while true {
                    guard let response = try? readFrame() else { break }
                    // Unsolicited frames (no request_id) are helper→app events,
                    // e.g. a `persist` directive. Replies whose request already
                    // timed out have no taker and are dropped.
                    guard let id = response["request_id"] as? String else {
                        handleEventFrame(response)
                        continue
                    }
                    take(id)?.resume(returning: response)
                }
                // EOF or a broken frame: the helper is gone (quit, crash, or
                // teardown).
                markDead()
                failAll(with: ClientError.ioFailed)
            }
            thread.name = "bitwarden-helper-reader"
            thread.start()
        }

        /// Dispatches an unsolicited event frame. The only event today is
        /// `persist`, whose `session` payload the app writes to its Keychain (a
        /// null/absent session means "forget").
        private func handleEventFrame(_ frame: [String: Any]) {
            guard frame["event"] as? String == "persist" else { return }
            persistHandler?(frame["session"] as? [String: Any])
        }

        /// Sends a `restore` and blocks (on the raw fd, before the reader starts)
        /// until the helper acks it, so the vault is re-established before any
        /// caller request. Bounded by a generous receive timeout — restore is a
        /// full login + vault sync. A rejected restore means the stored session
        /// is stale; `onFailure` lets the app drop it. A transport failure leaves
        /// the record intact for the next spawn to retry.
        private func performInlineRestore(params: [String: Any], onFailure: (() -> Void)?) {
            setReceiveTimeout(seconds: 60)
            defer { setReceiveTimeout(seconds: 0) }
            let requestID = UUID().uuidString
            let request: [String: Any] = [
                "protocol_version": protocolVersion,
                "request_id": requestID,
                "method": "restore",
                "params": params,
            ]
            do {
                try writeFrame(request)
                while true {
                    let frame = try readFrame()
                    // A persist event could precede the reply; handle it and keep
                    // reading for our response.
                    guard frame["request_id"] as? String == requestID else {
                        handleEventFrame(frame)
                        continue
                    }
                    if let ok = frame["ok"] as? Bool, !ok { onFailure?() }
                    return
                }
            } catch {
                AppLogWarn("[BitwardenHelperClient] session restore did not complete: \(error.localizedDescription)")
            }
        }

        private func take(_ id: String) -> CheckedContinuation<[String: Any], Error>? {
            lock.lock()
            defer { lock.unlock() }
            return pending.removeValue(forKey: id)
        }

        private func markDead() {
            lock.lock()
            dead = true
            lock.unlock()
        }

        private func failAll(with error: Error) {
            lock.lock()
            let waiting = pending
            pending = [:]
            lock.unlock()
            for continuation in waiting.values { continuation.resume(throwing: error) }
        }

        // MARK: Handshake + framing

        /// Reads the helper's challenge and acks it. Bounded by a temporary
        /// receive timeout so a helper that wedges at startup cannot hang the
        /// spawn; runs before the reader thread exists.
        private func handshake(clientVersion: String, protocolVersion: Int) throws {
            setReceiveTimeout(seconds: 5)
            defer { setReceiveTimeout(seconds: 0) }
            do {
                let hello = try readFrame()
                guard let challenge = hello["challenge"] as? String else {
                    throw ClientError.handshakeFailed
                }
                try writeFrame([
                    "challenge_response": challenge,
                    "client_version": clientVersion,
                    "protocol_version": protocolVersion,
                ])
            } catch ClientError.handshakeFailed {
                throw ClientError.handshakeFailed
            } catch {
                // Timeout, EOF, or garbage from a helper that died at startup —
                // retryable, so `send` respawns once.
                throw ClientError.connectionFailed
            }
        }

        private func setReceiveTimeout(seconds: Int) {
            var tv = timeval(tv_sec: seconds, tv_usec: 0)
            withUnsafePointer(to: &tv) {
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
        }

        private func writeFrame(_ object: [String: Any]) throws {
            let json = try JSONSerialization.data(withJSONObject: object)
            var length = UInt32(json.count).bigEndian
            let wrote = withUnsafeBytes(of: &length) { Darwin.write(fd, $0.baseAddress!, 4) }
            guard wrote == 4 else { throw ClientError.ioFailed }
            var total = 0
            while total < json.count {
                let n = json.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + total, json.count - total) }
                guard n > 0 else { throw ClientError.ioFailed }
                total += n
            }
        }

        private func readFrame() throws -> [String: Any] {
            var lengthBE: UInt32 = 0
            let read = withUnsafeMutableBytes(of: &lengthBE) { Darwin.read(fd, $0.baseAddress!, 4) }
            guard read == 4 else { throw ClientError.ioFailed }
            let length = Int(UInt32(bigEndian: lengthBE))
            guard length > 0, length < 4 * 1024 * 1024 else { throw ClientError.frameTooLarge }

            var data = Data(count: length)
            var total = 0
            while total < length {
                let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, length - total) }
                guard n > 0 else { throw ClientError.ioFailed }
                total += n
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClientError.invalidResponse
            }
            return json
        }
    }
}
